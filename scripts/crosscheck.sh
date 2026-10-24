#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Rust and Go must agree byte for byte.
#
# 1. Both corpus harnesses write one result line per case
#    (docs/spec/jcs-rfc8785.md, "Conformance harness protocol"); the files
#    must be identical.
# 2. Both differential drivers read the same generated inputs; their outputs
#    must be identical.
#
# A failure in either implementation fails both.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python="${PYTHON:-python3}"
seeds="${CROSSCHECK_SEEDS:-20261022 20261023}"
count="${CROSSCHECK_COUNT:-5000}"
work="$(mktemp -d "${TMPDIR:-/tmp}/canonprims-crosscheck.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

cd "${root}"

# Each harness writes its result lines before asserting, so a disagreement is
# reported here even when one side also fails its own corpus test.
run() {
  local name="$1"; shift
  if ! "$@" > "${work}/${name}.log" 2>&1; then
    echo "crosscheck: ${name} corpus test failed:" >&2
    tail -40 "${work}/${name}.log" >&2
    status=1
  fi
}
status=0
run rust env CANON_RESULTS_OUT="${work}/rust.results" cargo test --locked -p canonprims-json --test corpus corpus
run go bash -c "cd go/canon && GOWORK=off CGO_ENABLED=0 CANON_RESULTS_OUT=\"${work}/go.results\" go test -count=1 -run '^TestCorpus$' ."
if [ ! -s "${work}/rust.results" ] || [ ! -s "${work}/go.results" ]; then
  echo "crosscheck: a harness wrote no result lines" >&2
  exit 1
fi
if ! cmp -s "${work}/rust.results" "${work}/go.results"; then
  echo "crosscheck: corpus results differ (rust vs go):" >&2
  diff "${work}/rust.results" "${work}/go.results" | head -20 >&2
  exit 1
fi
if [ "${status}" -ne 0 ]; then
  exit 1
fi
echo "crosscheck: corpus agrees ($(wc -l < "${work}/rust.results" | tr -d ' ') cases)" >&2

rust_driver="$(cargo build --quiet --locked --release -p canonprims-json --example canon-diff --message-format=json \
  | "${python}" -I -c 'import json,sys
for line in sys.stdin:
    m = json.loads(line)
    if m.get("reason") == "compiler-artifact" and m.get("target", {}).get("name") == "canon-diff" and m.get("executable"):
        print(m["executable"])')"
go_driver="${work}/canon-diff-go"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) go_driver="${go_driver}.exe" ;; esac
(cd go/canon && GOWORK=off CGO_ENABLED=0 go build -o "${go_driver}" ./internal/difftool)

for seed in ${seeds}; do
  "${python}" -I scripts/crosscheck-gen.py "${seed}" "${count}" > "${work}/in.${seed}"
  "${rust_driver}" < "${work}/in.${seed}" > "${work}/rust.${seed}"
  "${go_driver}" < "${work}/in.${seed}" > "${work}/go.${seed}"
  if ! cmp -s "${work}/rust.${seed}" "${work}/go.${seed}"; then
    echo "crosscheck: drivers differ for seed ${seed}; first differing input:" >&2
    line="$(cmp "${work}/rust.${seed}" "${work}/go.${seed}" | awk '{print $NF}')"
    sed -n "${line}p" "${work}/in.${seed}" >&2
    echo "rust: $(sed -n "${line}p" "${work}/rust.${seed}" | cut -c1-200)" >&2
    echo "go:   $(sed -n "${line}p" "${work}/go.${seed}" | cut -c1-200)" >&2
    exit 1
  fi
  ok="$(grep -c '^ok ' "${work}/rust.${seed}" || true)"
  echo "crosscheck: seed ${seed} agrees (${count} inputs, ${ok} accepted)" >&2
done
