// SPDX-License-Identifier: MIT OR Apache-2.0
// The module never receives an input over maxBytes: an observer wraps the real
// instance's input_reserve before the package is imported (node --test runs
// each file in its own process, so the observer sees every call).
import assert from "node:assert/strict";
import { test } from "node:test";

const reserved = [];
const RealInstance = WebAssembly.Instance;
WebAssembly.Instance = function (module, imports) {
  const real = new RealInstance(module, imports);
  return {
    exports: {
      ...real.exports,
      input_reserve(n) {
        reserved.push(n);
        return real.exports.input_reserve(n);
      },
    },
  };
};
let canonprims;
try {
  canonprims = await import("@3leaps/canonprims");
} finally {
  WebAssembly.Instance = RealInstance;
}

test("an oversized input reserves no module memory", () => {
  const big = new Uint8Array(1024 * 1024).fill(0x31);
  for (const max of [0, -1, 4, big.length - 1]) {
    for (const verb of [canonprims.canonicalize, canonprims.check, canonprims.digest]) {
      reserved.length = 0;
      assert.throws(() => verb(big, canonprims.limits({ maxBytes: max })), (e) => e instanceof canonprims.Refusal && e.code === "too_large");
      assert.deepEqual(reserved, [], `${verb.name} maxBytes=${max} reserved ${reserved}`);
    }
  }
});

test("an admitted input reserves exactly its length", () => {
  reserved.length = 0;
  canonprims.canonicalize("[1,2]", canonprims.limits({ maxBytes: 5 }));
  assert.deepEqual(reserved, [5]);
});

test("a string with an unpaired surrogate reserves nothing", () => {
  reserved.length = 0;
  assert.throws(() => canonprims.canonicalize('"\ud800"', canonprims.DEFAULT_LIMITS), TypeError);
  assert.deepEqual(reserved, []);
});
