#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The doctor's own minisign check (goneat does not compare two-part versions):
# the declared minimum is read from .goneat/tools.yaml, a version at or above
# it passes, and an older, unreadable or missing minisign fails. Stubbed; no
# goneat needed.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
want="$(awk '$0 == "  minisign:" {t = 1; next} t && /^  [^ ]/ {exit} t && $1 == "minimum_version:" {print $2; exit}' "$root/.goneat/tools.yaml")"
[[ "$want" == 0.11.0 ]] || { echo "error: unexpected declared minisign minimum $want" >&2; exit 1; }
stub() {
	printf '#!/bin/sh\necho "%s"\n' "$1" >"$scratch/bin/minisign"
	chmod +x "$scratch/bin/minisign"
}
doctor() { env PATH="$scratch/bin:/usr/bin:/bin" CANONPRIMS_DOCTOR_MINISIGN_ONLY=1 "$root/scripts/doctor.sh" >"$scratch/out" 2>&1; }
passes() {
	stub "$1"
	doctor || { echo "error: refused minisign output '$1'" >&2; cat "$scratch/out" >&2; exit 1; }
}
refused() {
	local reason="$1"
	shift
	if [[ "$#" -gt 0 ]]; then stub "$1"; else rm -f "$scratch/bin/minisign"; fi
	if doctor; then
		echo "error: accepted minisign output '${1:-<missing>}'" >&2
		exit 1
	fi
	grep -q -- "$reason" "$scratch/out" || { echo "error: refused for another reason than '$reason'" >&2; cat "$scratch/out" >&2; exit 1; }
}
passes 'minisign 0.12'
passes 'minisign 0.11'
passes 'minisign 0.11.0'
passes 'minisign 1.0'
refused 'below the recommended minimum 0.11.0' 'minisign 0.10'
refused 'below the recommended minimum 0.11.0' 'minisign 0.9.9'
refused 'cannot read the minisign version' 'something else'
refused 'minisign is missing'
# An unknown scope is a usage error.
if "$root/scripts/doctor.sh" bogus >"$scratch/out" 2>&1; then
	echo 'error: accepted an unknown scope' >&2
	exit 1
fi
grep -q 'unknown scope bogus' "$scratch/out"
echo '[ok] doctor minisign minimum: declared floor, older, unreadable and missing versions'
