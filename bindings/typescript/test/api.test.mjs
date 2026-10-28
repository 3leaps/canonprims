// SPDX-License-Identifier: MIT OR Apache-2.0
// The TypeScript surface: inputs, limits, refusals and the module's isolation.
import assert from "node:assert/strict";
import { test } from "node:test";

import * as canonprims from "@3leaps/canonprims";
import { Refusal, limits } from "@3leaps/canonprims";

const L = canonprims.DEFAULT_LIMITS;
const enc = (s) => new TextEncoder().encode(s);
const dec = (b) => new TextDecoder().decode(b);
const code = (f) => {
  try {
    f();
  } catch (e) {
    if (e instanceof Refusal) return e.code;
    throw e;
  }
  return "ok";
};

test("defaults", () => {
  assert.deepEqual({ ...L }, { maxBytes: 16 * 1024 * 1024, maxDepth: 128, maxObjectMembers: 1024 * 1024, maxStringBytes: 16 * 1024 * 1024 });
  assert.ok(Object.isFrozen(L));
});

test("byte views and strings", () => {
  const text = '{"b":1,"a":2}';
  const backing = new Uint8Array([0x78, ...enc(text), 0x78]);
  for (const data of [enc(text), Buffer.from(text), new DataView(backing.buffer, 1, text.length), backing.subarray(1, 1 + text.length), text]) {
    assert.equal(dec(canonprims.canonicalize(data, L)), '{"a":2,"b":1}');
  }
  assert.equal(dec(canonprims.canonicalize('"é"', L)), '"é"');
});

test("a string with an unpaired surrogate is refused, never repaired", () => {
  // It has no UTF-8 form; TextEncoder would substitute U+FFFD.
  for (const s of ['"\ud800"', '"\udc00"', '"a\ud800b"', '"\udc00\ud800"', '"\ud83d"']) {
    for (const verb of [canonprims.canonicalize, canonprims.check, canonprims.digest]) {
      assert.throws(() => verb(s, L), (e) => e instanceof TypeError && !(e instanceof Refusal) && /unpaired surrogate/.test(e.message));
    }
  }
  // Paired surrogates and a literal U+FFFD are ordinary characters.
  assert.equal(dec(canonprims.canonicalize('"\ud83d\ude00"', L)), '"\u{1f600}"');
  assert.equal(dec(canonprims.canonicalize('"\ufffd"', L)), '"\ufffd"');
  // An escaped lone surrogate is JSON text, refused by the scheme.
  assert.equal(code(() => canonprims.canonicalize('"\\ud800"', L)), "lone_surrogate");
});

test("other inputs are type errors", () => {
  for (const bad of [null, undefined, 1, ["{}"], { a: 1 }, new ArrayBuffer(2)]) {
    assert.throws(() => canonprims.canonicalize(bad, L), TypeError);
  }
});

test("limits are required and integer", () => {
  assert.throws(() => canonprims.canonicalize("1"), TypeError);
  assert.throws(() => canonprims.canonicalize("1", null), TypeError);
  for (const bad of [1.5, Number.NaN, Infinity, "1", true, null, 1n]) {
    assert.throws(() => canonprims.canonicalize("1", limits({ maxDepth: bad })), TypeError);
  }
});

test("negative limits behave as 0", () => {
  const cases = [
    ["maxBytes", "1"],
    ["maxDepth", "1"],
    ["maxDepth", "[]"],
    ["maxObjectMembers", "{}"],
    ["maxObjectMembers", '{"a":1}'],
    ["maxStringBytes", '""'],
    ["maxStringBytes", '"a"'],
  ];
  for (const [field, data] of cases) {
    const want = code(() => canonprims.canonicalize(data, limits({ [field]: 0 })));
    for (const v of [-1, -(2 ** 52)]) {
      assert.equal(code(() => canonprims.canonicalize(data, limits({ [field]: v }))), want, `${field}=${v} on ${data}`);
    }
  }
  assert.equal(dec(canonprims.canonicalize("{}", limits({ maxObjectMembers: -1 }))), "{}");
  assert.equal(code(() => canonprims.canonicalize("[]", limits({ maxDepth: -1 }))), "too_deep");
});

test("an input over maxBytes is refused before the module sees it", () => {
  for (const [data, max] of [["12345", 4], ["[1]", 0], ["{}", -1]]) {
    for (const verb of [canonprims.canonicalize, canonprims.check, canonprims.digest]) {
      try {
        verb(data, limits({ maxBytes: max }));
        assert.fail("accepted an oversized input");
      } catch (e) {
        assert.ok(e instanceof Refusal);
        // Same code and offset as the module (and Rust, Go and Python).
        assert.deepEqual([e.code, e.offset], ["too_large", Math.max(max, 0)]);
      }
    }
  }
  // At exactly maxBytes the input is admitted.
  assert.equal(dec(canonprims.canonicalize("1234", limits({ maxBytes: 4 }))), "1234");
});

test("huge limits behave as the maximum", () => {
  assert.equal(dec(canonprims.canonicalize("[1]", limits({ maxDepth: 2 ** 53 - 1, maxBytes: 2 ** 40 }))), "[1]");
});

test("refusals are typed", () => {
  try {
    canonprims.canonicalize('{"a":1,"a":2}', L);
    assert.fail("accepted a duplicate member");
  } catch (e) {
    assert.ok(e instanceof Refusal && e instanceof Error);
    assert.equal(e.name, "Refusal");
    assert.equal(e.code, "duplicate_member");
    assert.ok(canonprims.CODES.includes(e.code));
    assert.ok(Number.isInteger(e.offset));
    assert.equal(e.message, `duplicate_member at byte ${e.offset}`);
  }
  assert.equal(code(() => canonprims.canonicalize("[[1]]", limits({ maxDepth: 1 }))), "too_deep");
  assert.equal(code(() => canonprims.canonicalize("12345", limits({ maxBytes: 4 }))), "too_large");
});

test("check and digest", () => {
  assert.equal(canonprims.check('{"a":1}', L), undefined);
  assert.equal(code(() => canonprims.check('{ "a":1}', L)), "not_canonical");
  assert.equal(canonprims.digest("1", L), "sha256:6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b");
  assert.throws(() => canonprims.digest("1", L, "md5"), RangeError);
});

test("scheme info and version", () => {
  const i = canonprims.schemeInfo();
  assert.deepEqual([i.scheme, i.spec, i.corpus], ["jcs/rfc8785", "RFC 8785", "canonical-json/v0"]);
  assert.match(i.corpusDigest, /^sha256:[0-9a-f]{64}$/);
  assert.equal(canonprims.VERSION, process.env.CANONPRIMS_VERSION);
});

test("results are copies; the input is never written", () => {
  const input = enc('{"b":1,"a":2}');
  const before = Uint8Array.from(input);
  const a = canonprims.canonicalize(input, L);
  canonprims.canonicalize("[1,2,3]", L);
  assert.equal(dec(a), '{"a":2,"b":1}');
  assert.deepEqual(input, before);
});

test("a large input grows memory without corrupting later calls", () => {
  const big = '"' + "a".repeat(4 * 1024 * 1024) + '"';
  assert.equal(canonprims.canonicalize(big, L).length, big.length);
  assert.equal(dec(canonprims.canonicalize('{"b":1,"a":2}', L)), '{"a":2,"b":1}');
});
