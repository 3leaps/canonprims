#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Controls for scripts/corpus-witness.sh. Each negative control must fail at
# its intended check, identified by its diagnostic, so that removing that
# check makes this script fail:
#
#   missing checker        -> refused before anything runs
#   altered checker        -> a working checker with one extra comment line,
#                             refused by the sha256 pin (it would otherwise
#                             witness every case successfully)
#   wrong expected output  -> the ECMAScript witness reports the case
#
# The positive control runs the pristine pinned checker and must pass.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/canonprims-witness-controls.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
fail=0

# expect <name> <0|1> <diagnostic regex or ""> <command...>
expect() {
  local name="$1" want="$2" pattern="$3"; shift 3
  local rc=0
  "$@" > "${work}/${name}.log" 2>&1 || rc=$?
  if [ "${want}" = 0 ] && [ "${rc}" -ne 0 ]; then
    echo "witness-controls: ${name}: expected success, got exit ${rc}" >&2
    tail -5 "${work}/${name}.log" >&2
    fail=1
  elif [ "${want}" = 1 ] && [ "${rc}" -eq 0 ]; then
    echo "witness-controls: ${name}: gate passed but must fail" >&2
    fail=1
  elif [ -n "${pattern}" ] && ! grep -Eq "${pattern}" "${work}/${name}.log"; then
    echo "witness-controls: ${name}: failed, but not at the intended check (want /${pattern}/):" >&2
    tail -5 "${work}/${name}.log" >&2
    fail=1
  fi
}

# Fetch the pinned checker once through the gate's own path, keeping a copy.
pristine="${work}/pristine.py"
expect fetch 0 "python witness: [0-9]+ accept cases, 0 failed" \
  env WITNESS_KEEP="${pristine}" "${root}/scripts/corpus-witness.sh"
if [ ! -s "${pristine}" ]; then
  echo "witness-controls: could not obtain the pinned checker" >&2
  exit 1
fi

expect pristine 0 "python witness: [0-9]+ accept cases, 0 failed" \
  env WITNESS_CHECKER="${pristine}" "${root}/scripts/corpus-witness.sh"

expect missing-checker 1 "cannot read checker" \
  env WITNESS_CHECKER="${work}/absent.py" "${root}/scripts/corpus-witness.sh"

{ cat "${pristine}"; printf '# harmless extra line\n'; } > "${work}/altered.py"
expect altered-checker 1 "python witness: checker sha256 [0-9a-f]{64} does not match the pin" \
  env WITNESS_CHECKER="${work}/altered.py" "${root}/scripts/corpus-witness.sh"

cp -R "${root}/conformance/canonical-json/v0" "${work}/corpus"
printf '{"y":2,"x":1}' > "${work}/corpus/cases/ws-object.out"
expect wrong-expected-output 1 "node witness: ws-object: got " \
  node "${root}/scripts/corpus-witness.mjs" "${work}/corpus"

if [ "${fail}" -ne 0 ]; then
  exit 1
fi
echo "witness-controls: pristine passes; missing, altered and wrong-output fail at their intended checks" >&2
