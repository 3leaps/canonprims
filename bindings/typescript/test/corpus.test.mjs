// SPDX-License-Identifier: MIT OR Apache-2.0
// The canonical-json/v0 conformance corpus, against the installed package.
// Same protocol as the Rust, Go and Python harnesses (docs/spec/jcs-rfc8785.md,
// "Conformance harness protocol"): CANONPRIMS_CORPUS_DIR names the corpus and
// CANONPRIMS_RESULTS_OUT receives one result line per case.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";

import * as canonprims from "@3leaps/canonprims";

const dir = process.env.CANONPRIMS_CORPUS_DIR;
assert.ok(dir, "CANONPRIMS_CORPUS_DIR is required");

const FIELDS = { max_bytes: "maxBytes", max_depth: "maxDepth", max_object_members: "maxObjectMembers", max_string_bytes: "maxStringBytes" };
function limitsOf(overrides) {
  const out = {};
  for (const [k, v] of Object.entries(overrides)) {
    assert.ok(k in FIELDS, `unknown limit ${k}`);
    out[FIELDS[k]] = v;
  }
  return canonprims.limits(out);
}
const sha256 = (b) => createHash("sha256").update(b).digest("hex");
const outcome = (f) => {
  try {
    return { ok: f() };
  } catch (e) {
    if (e instanceof canonprims.Refusal) return { code: e.code };
    throw e;
  }
};

test("manifest digest is pinned", () => {
  const got = "sha256:" + sha256(readFileSync(join(dir, "MANIFEST.json")));
  assert.equal(got, canonprims.schemeInfo().corpusDigest);
});

test("corpus", () => {
  const index = JSON.parse(readFileSync(join(dir, "cases.json"), "utf8"));
  const info = canonprims.schemeInfo();
  assert.equal(index.scheme, info.scheme);
  assert.equal(index.corpus, info.corpus);
  assert.deepEqual(limitsOf(index.default_limits), canonprims.DEFAULT_LIMITS);
  assert.ok(index.cases.length > 150, "corpus looks truncated");

  const results = [];
  const failures = [];
  for (const c of index.cases) {
    assert.ok(("input" in c) !== ("generate" in c), `${c.id}: needs exactly one of input/generate`);
    const input = c.input
      ? new Uint8Array(readFileSync(join(dir, c.input)))
      : new TextEncoder().encode(c.generate.prefix + c.generate.unit.repeat(c.generate.count) + c.generate.suffix);
    const l = limitsOf(c.limits ?? {});
    const got = outcome(() => canonprims.canonicalize(input, l));
    results.push(got.code ? `${c.id} ${got.code}\n` : `${c.id} ok ${sha256(got.ok)}\n`);
    const kind = got.code ?? "ok";
    if (kind !== c.expect) {
      failures.push(`${c.id}: expected ${c.expect}, got ${kind}`);
      continue;
    }
    if (got.code) {
      for (const [name, verb] of [["check", canonprims.check], ["digest", canonprims.digest]]) {
        const r = outcome(() => verb(input, l));
        if (r.code !== got.code) failures.push(`${c.id}: ${name} gave ${r.code ?? "ok"}`);
      }
      continue;
    }
    const want = c.output === "=input" ? input : new Uint8Array(readFileSync(join(dir, c.output)));
    if (Buffer.compare(Buffer.from(got.ok), Buffer.from(want)) !== 0) {
      failures.push(`${c.id}: canonical bytes differ`);
      continue;
    }
    if (canonprims.digest(input, l) !== c.digest) failures.push(`${c.id}: digest differs`);
    const self = outcome(() => canonprims.check(got.ok, l));
    if (self.code) failures.push(`${c.id}: check refused its own output (${self.code})`);
    const same = Buffer.compare(Buffer.from(got.ok), Buffer.from(input)) === 0;
    const checked = outcome(() => canonprims.check(input, l)).code ?? "ok";
    if (checked !== (same ? "ok" : "not_canonical")) failures.push(`${c.id}: check on input gave ${checked}`);
  }
  if (process.env.CANONPRIMS_RESULTS_OUT) writeFileSync(process.env.CANONPRIMS_RESULTS_OUT, results.join(""));
  assert.deepEqual(failures, []);
});
