// SPDX-License-Identifier: MIT OR Apache-2.0
// Differential driver (docs/spec/jcs-rfc8785.md, "Conformance harness
// protocol"): one lowercase-hex input per stdin line, one result per stdout
// line, default limits.
import { readFileSync, writeSync } from "node:fs";

import { DEFAULT_LIMITS, Refusal, canonicalize } from "@3leaps/canonprims";

const data = readFileSync(0);
let start = 0;
const out = [];
while (start < data.length) {
  let end = data.indexOf(0x0a, start);
  if (end < 0) end = data.length;
  const line = data.subarray(start, end).toString("latin1");
  start = end + 1;
  if (line.length % 2 !== 0 || !/^[0-9a-f]*$/.test(line)) {
    process.stderr.write("canon-diff: line is not hex\n");
    process.exit(2);
  }
  try {
    out.push("ok " + Buffer.from(canonicalize(Buffer.from(line, "hex"), DEFAULT_LIMITS)).toString("hex") + "\n");
  } catch (e) {
    if (!(e instanceof Refusal)) throw e;
    out.push(e.code + "\n");
  }
}
writeSync(1, out.join(""));
