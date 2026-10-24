// SPDX-License-Identifier: MIT OR Apache-2.0
// Check every accept case in canonical-json/v0 against ECMAScript itself.
//
// JSON.parse is not a strict I-JSON loader (it keeps the last duplicate and
// accepts lone surrogates), so this witnesses expected bytes for accept cases
// only. Usage: node scripts/corpus-witness.mjs <corpus-dir>
import { readFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.argv[2];
const doc = JSON.parse(readFileSync(join(dir, "cases.json"), "utf8"));

function canon(v) {
  if (Array.isArray(v)) return "[" + v.map(canon).join(",") + "]";
  if (v !== null && typeof v === "object") {
    // Array.prototype.sort with no comparator compares UTF-16 code units.
    return "{" + Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + canon(v[k])).join(",") + "}";
  }
  return JSON.stringify(v);
}

let checked = 0;
let failed = 0;
for (const c of doc.cases) {
  if (c.expect !== "ok" || c.generate) continue;
  const input = readFileSync(join(dir, c.input)).toString("utf8");
  const want = readFileSync(join(dir, c.output));
  const got = Buffer.from(canon(JSON.parse(input)), "utf8");
  checked++;
  if (!got.equals(want)) {
    failed++;
    console.error(`node witness: ${c.id}: got ${got.toString("utf8")}`);
  }
}
console.error(`node witness: ${checked} accept cases, ${failed} failed`);
process.exit(failed ? 1 : 0);
