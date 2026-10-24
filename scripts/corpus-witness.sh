#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Witness the canonical-json/v0 accept cases with implementations that are
# not canonprims: ECMAScript (node) and the crucible RFC 8785 checker, fetched
# at the commit and checked against the sha256 in config/witness.sha256.
#
# Both witnesses are required. They check expected bytes for the file-based
# accept cases only: neither enforces the strict input domain, so refusal
# cases and generated cases are not witnessed, and the Python checker
# declares the ES6-spelled integer cases it cannot witness.
#
# WITNESS_CHECKER=<path> uses a local copy instead of fetching; it must still
# match the pinned sha256.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
corpus="${root}/conformance/canonical-json/v0"
python="${PYTHON:-python3}"

"${python}" -I "${root}/scripts/canonical-json-corpus.py" --check > /dev/null
node "${root}/scripts/corpus-witness.mjs" "${corpus}"

pins="${root}/config/witness.sha256"
commit="$(sed -n 's/^# commit \([0-9a-f]\{40\}\),.*/\1/p' "${pins}")"
want="$(awk '$2 == "rfc8785-canonicalize.py" { print $1 }' "${pins}")"
if [ -z "${commit}" ] || [ -z "${want}" ]; then
  echo "python witness: no pin in ${pins}" >&2
  exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/canonprims-witness.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
checker="${work}/rfc8785-canonicalize.py"
if [ -n "${WITNESS_CHECKER:-}" ]; then
  if ! cp "${WITNESS_CHECKER}" "${checker}" 2> /dev/null; then
    echo "python witness: cannot read checker ${WITNESS_CHECKER}" >&2
    exit 1
  fi
else
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
    --output "${checker}" \
    "https://raw.githubusercontent.com/3leaps/crucible/${commit}/scripts/rfc8785-canonicalize.py"
fi
got="$("${python}" -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${checker}")"
if [ "${got}" != "${want}" ]; then
  echo "python witness: checker sha256 ${got} does not match the pin ${want}" >&2
  exit 1
fi
# WITNESS_KEEP=<path> keeps a copy of the verified checker (used by
# scripts/witness-controls.sh).
if [ -n "${WITNESS_KEEP:-}" ]; then
  cp "${checker}" "${WITNESS_KEEP}"
fi
"${python}" -I - "${corpus}" "${checker}" <<'PY'
import importlib.util, json, sys
from pathlib import Path
corpus, checker = Path(sys.argv[1]), sys.argv[2]
spec = importlib.util.spec_from_file_location("rfc8785", checker)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
doc = json.loads((corpus / "cases.json").read_text())
# This checker refuses integer tokens that are ES6 spellings rather than
# exact values (docs/spec/jcs-rfc8785.md, "Numbers in detail"); it cannot
# witness those cases, and says so rather than skipping silently.
checked = failed = refused = 0
for c in doc["cases"]:
    if c["expect"] != "ok" or "generate" in c:
        continue
    raw = (corpus / c["input"]).read_bytes().decode("utf-8")
    want = (corpus / c["output"]).read_bytes()
    try:
        got = mod.jcs_dumps(mod.jcs_loads(raw)).encode("utf-8")
    except ValueError as exc:
        if "integer is outside" in str(exc) and c["id"].endswith("-es6-spelling"):
            refused += 1
            continue
        raise
    checked += 1
    if got != want:
        failed += 1
        print(f"python witness: {c['id']}: got {got!r}", file=sys.stderr)
print(f"python witness: {checked} accept cases, {failed} failed, "
      f"{refused} not witnessed (ES6-spelled integers)", file=sys.stderr)
sys.exit(1 if failed else 0)
PY
