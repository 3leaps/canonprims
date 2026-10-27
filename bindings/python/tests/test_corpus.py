# SPDX-License-Identifier: MIT OR Apache-2.0
"""The canonical-json/v0 conformance corpus, against the installed package.

Same protocol as the Rust and Go harnesses (docs/spec/jcs-rfc8785.md,
"Conformance harness protocol"): CANONPRIMS_CORPUS_DIR overrides the corpus
location and CANONPRIMS_RESULTS_OUT writes one result line per case, so
scripts/crosscheck.sh can compare this binding with Rust and Go.
"""

import hashlib
import json
import os
import pathlib
import unittest

import canonprims

ROOT = pathlib.Path(__file__).resolve().parents[3]
CORPUS = pathlib.Path(os.environ.get("CANONPRIMS_CORPUS_DIR", ROOT / "conformance/canonical-json/v0"))


def _limits(overrides):
    fields = {"max_bytes", "max_depth", "max_object_members", "max_string_bytes"}
    unknown = set(overrides) - fields
    if unknown:
        raise AssertionError(f"unknown limit {sorted(unknown)}")
    return canonprims.Limits(**overrides)


def _input(case):
    if ("input" in case) == ("generate" in case):
        raise AssertionError(f"{case['id']}: needs exactly one of input/generate")
    if "input" in case:
        return (CORPUS / case["input"]).read_bytes()
    g = case["generate"]
    return (g["prefix"] + g["unit"] * g["count"] + g["suffix"]).encode("utf-8")


class Corpus(unittest.TestCase):
    def test_manifest_digest_is_pinned(self):
        got = "sha256:" + hashlib.sha256((CORPUS / "MANIFEST.json").read_bytes()).hexdigest()
        self.assertEqual(got, canonprims.scheme_info().corpus_digest)

    def test_corpus(self):
        index = json.loads((CORPUS / "cases.json").read_bytes())
        self.assertEqual(index["scheme"], canonprims.scheme_info().scheme)
        self.assertEqual(index["corpus"], canonprims.scheme_info().corpus)
        self.assertEqual(_limits(index["default_limits"]), canonprims.Limits())
        cases = index["cases"]
        self.assertGreater(len(cases), 150, "corpus looks truncated")

        results = []
        failures = []
        for case in cases:
            data = _input(case)
            limits = _limits(case.get("limits", {}))
            try:
                out = canonprims.canonicalize(data, limits)
            except canonprims.Refusal as r:
                out, outcome = None, r.code
                results.append(f"{case['id']} {r.code}\n")
            else:
                outcome = "ok"
                results.append(f"{case['id']} ok {hashlib.sha256(out).hexdigest()}\n")
            if outcome != case["expect"]:
                failures.append(f"{case['id']}: expected {case['expect']}, got {outcome}")
                continue
            if out is None:
                for verb in (canonprims.check, canonprims.digest):
                    try:
                        verb(data, limits)
                    except canonprims.Refusal as r:
                        if r.code != outcome:
                            failures.append(f"{case['id']}: {verb.__name__} refused {r.code}")
                    else:
                        failures.append(f"{case['id']}: {verb.__name__} accepted a refused input")
                continue
            want = data if case["output"] == "=input" else (CORPUS / case["output"]).read_bytes()
            if out != want:
                failures.append(f"{case['id']}: canonical bytes differ")
                continue
            if canonprims.digest(data, limits) != case["digest"]:
                failures.append(f"{case['id']}: digest differs")
            try:
                canonprims.check(out, limits)
            except canonprims.Refusal as r:
                failures.append(f"{case['id']}: check refused its own output ({r.code})")
            try:
                canonprims.check(data, limits)
                checked = "ok"
            except canonprims.Refusal as r:
                checked = r.code
            if checked != ("ok" if data == out else "not_canonical"):
                failures.append(f"{case['id']}: check on input gave {checked}")

        path = os.environ.get("CANONPRIMS_RESULTS_OUT")
        if path:
            with open(path, "w", encoding="ascii", newline="\n") as f:
                f.writelines(results)
        self.assertEqual(failures, [], f"{len(failures)} corpus failures")


if __name__ == "__main__":
    unittest.main()
