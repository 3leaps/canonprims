// SPDX-License-Identifier: MIT OR Apache-2.0
/**
 * RFC 8785 JSON canonicalization over a strict I-JSON loader.
 *
 * A binding over the Rust `canonprims-json` crate, compiled to WebAssembly
 * with no imports: one module for Node, Deno, Bun and browsers. The same four
 * verbs as Rust, Go and Python: {@link canonicalize}, {@link check},
 * {@link digest} and {@link schemeInfo}. Input is a `Uint8Array` (or any
 * `ArrayBufferView`, read as its bytes); a string is encoded as UTF-8 and
 * nothing else. An input with no canonical form throws {@link Refusal} with one
 * normative code; nothing is repaired.
 */

import { WASM_BASE64 } from "./wasm.js";

/** Every refusal code, in spec order. `not_canonical` comes only from check. */
export const CODES = [
  "too_large",
  "invalid_utf8",
  "invalid_json",
  "lone_surrogate",
  "noncharacter",
  "duplicate_member",
  "non_finite_number",
  "integer_outside_binary64",
  "too_deep",
  "not_canonical",
] as const;

export type Code = (typeof CODES)[number];

/** The input has no canonical form (or, from {@link check}, is not in it). */
export class Refusal extends Error {
  /** Normative, identical across languages. */
  readonly code: Code;
  /** Informative byte offset in the input where the defect was found. */
  readonly offset: number;

  constructor(code: Code, offset: number) {
    super(`${code} at byte ${offset}`);
    this.name = "Refusal";
    this.code = code;
    this.offset = offset;
  }
}

/**
 * Explicit resource limits; every verb takes one. Exceeding a limit is a
 * `too_large` or `too_deep` refusal. A limit of 0 allows none of that thing; a
 * negative limit behaves as 0, and a limit above 2^32 - 1 (the module's
 * address range) behaves as that maximum. Each limit must be an integer
 * `number`.
 */
export interface Limits {
  readonly maxBytes: number;
  readonly maxDepth: number;
  readonly maxObjectMembers: number;
  readonly maxStringBytes: number;
}

export interface SchemeInfo {
  readonly scheme: string;
  readonly spec: string;
  readonly corpus: string;
  readonly corpusDigest: string;
}

export type Input = ArrayBufferView | string;

interface Exports {
  memory: WebAssembly.Memory;
  input_reserve(len: number): number;
  output_ptr(): number;
  output_len(): number;
  refusal_offset(): number;
  release(): void;
  canonicalize(a: number, b: number, c: number, d: number): number;
  check(a: number, b: number, c: number, d: number): number;
  digest(a: number, b: number, c: number, d: number, alg: number): number;
  scheme_info(): void;
  default_limit(which: number): number;
}

const OK = 0;
const REFUSED = 1;
const U32_MAX = 0xffff_ffff;

function decodeBase64(text: string): Uint8Array {
  const g = globalThis as { atob?: (s: string) => string };
  if (typeof g.atob !== "function") throw new Error("canonprims: atob is unavailable");
  const raw = g.atob(text);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

const wasm = new WebAssembly.Instance(new WebAssembly.Module(decodeBase64(WASM_BASE64)), {})
  .exports as unknown as Exports;

const utf8 = new TextEncoder();
const text = new TextDecoder("utf-8", { fatal: true });

function output(): Uint8Array {
  // Copy out: the next call may grow (and detach) memory.
  return new Uint8Array(wasm.memory.buffer, wasm.output_ptr(), wasm.output_len()).slice();
}

/** The documented defaults, shared by every canonprims implementation. */
export const DEFAULT_LIMITS: Limits = Object.freeze({
  maxBytes: wasm.default_limit(0),
  maxDepth: wasm.default_limit(1),
  maxObjectMembers: wasm.default_limit(2),
  maxStringBytes: wasm.default_limit(3),
});

/** Limits with the documented defaults, overridden field by field. */
export function limits(overrides: Partial<Limits> = {}): Limits {
  return Object.freeze({ ...DEFAULT_LIMITS, ...overrides });
}

function limit(l: Limits, name: keyof Limits): number {
  const v = l[name];
  if (typeof v !== "number" || !Number.isInteger(v)) {
    throw new TypeError(`canonprims: limits.${name} must be an integer number, got ${String(v)}`);
  }
  return Math.min(Math.max(v, 0), U32_MAX);
}

function limitArgs(l: Limits): [number, number, number, number] {
  if (l === null || typeof l !== "object") throw new TypeError("canonprims: limits are required");
  return [limit(l, "maxBytes"), limit(l, "maxDepth"), limit(l, "maxObjectMembers"), limit(l, "maxStringBytes")];
}

function bytes(data: Input): Uint8Array {
  if (typeof data === "string") return utf8.encode(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  throw new TypeError("canonprims: input must be an ArrayBufferView or a string");
}

function call(data: Input, l: Limits, verb: (a: number, b: number, c: number, d: number) => number): Uint8Array {
  const args = limitArgs(l);
  const input = bytes(data);
  if (input.length > U32_MAX) throw new Refusal("too_large", 0);
  try {
    const at = wasm.input_reserve(input.length);
    new Uint8Array(wasm.memory.buffer, at, input.length).set(input);
    const status = verb(...args);
    const out = output();
    if (status === OK) return out;
    if (status === REFUSED) throw new Refusal(text.decode(out) as Code, wasm.refusal_offset());
    throw new Error(`canonprims: unexpected status ${status}`);
  } finally {
    wasm.release();
  }
}

/** The RFC 8785 canonical form of a strict I-JSON text. */
export function canonicalize(data: Input, limits: Limits): Uint8Array {
  return call(data, limits, wasm.canonicalize);
}

/** Return if the input is already canonical; throw {@link Refusal} if not. */
export function check(data: Input, limits: Limits): void {
  call(data, limits, wasm.check);
}

/** Hash the canonical form, written `<alg>:<lowercase hex>`. */
export function digest(data: Input, limits: Limits, alg = "sha256"): string {
  if (alg !== "sha256") throw new RangeError(`canonprims: unknown digest algorithm ${JSON.stringify(alg)}`);
  return text.decode(call(data, limits, (a, b, c, d) => wasm.digest(a, b, c, d, 0)));
}

function info(): [string, string, string, string, string] {
  wasm.scheme_info();
  try {
    const parts = text.decode(output()).split("\n");
    if (parts.length !== 5) throw new Error("canonprims: malformed scheme info");
    return parts as [string, string, string, string, string];
  } finally {
    wasm.release();
  }
}

/** The scheme, its specification, and the corpus this build was gated on. */
export function schemeInfo(): SchemeInfo {
  const [scheme, spec, corpus, corpusDigest] = info();
  return Object.freeze({ scheme, spec, corpus, corpusDigest });
}

/** The package version (the Rust workspace version it was built from). */
export const VERSION: string = info()[4];
