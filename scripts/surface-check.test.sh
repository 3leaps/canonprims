#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The surface-check hook runs only an absolute, regular, executable file
# outside the repository, propagates its status, and is required when asked.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
hook="$root/scripts/surface-check.sh"
# shellcheck disable=SC2016 # $1 expands in the check script
printf '#!/bin/sh\necho "ran $1" >"%s/ran"\n' "$scratch" >"$scratch/ok"
printf '#!/bin/sh\nexit 3\n' >"$scratch/fail"
printf '#!/bin/sh\necho ran >"%s/ran"\n' "$scratch" >"$scratch/plain"
chmod +x "$scratch/ok" "$scratch/fail"
ln -s "$scratch/ok" "$scratch/link"
mkdir "$scratch/dir"
run() { env "$@" "$hook" >"$scratch/out" 2>&1; }
refused() {
	local reason="$1"
	shift
	rm -f "$scratch/ran"
	if run "$@"; then
		echo "error: accepted: $*" >&2
		exit 1
	fi
	grep -q -- "$reason" "$scratch/out" || { echo "error: refused for another reason than '$reason': $*" >&2; cat "$scratch/out" >&2; exit 1; }
	[[ ! -e "$scratch/ran" ]] || { echo "error: the check ran: $*" >&2; exit 1; }
}
run -u CANONPRIMS_SURFACE_CHECK
grep -q '^\[skip\]' "$scratch/out"
refused 'is required for this gate' -u CANONPRIMS_SURFACE_CHECK CANONPRIMS_SURFACE_CHECK_REQUIRED=1
run CANONPRIMS_SURFACE_CHECK="$scratch/ok"
[[ "$(cat "$scratch/ran")" == "ran $root" ]]
# A relative path that names a real executable from the current directory.
rm -f "$scratch/ran"
(cd "$scratch" && env CANONPRIMS_SURFACE_CHECK=ok "$hook") >"$scratch/out" 2>&1 && { echo 'error: accepted a relative path' >&2; exit 1; }
grep -q 'must be an absolute path' "$scratch/out"
[[ ! -e "$scratch/ran" ]]
refused 'must be an absolute path' CANONPRIMS_SURFACE_CHECK="$scratch/link"
refused 'must be an absolute path' CANONPRIMS_SURFACE_CHECK="$scratch/plain"
refused 'must be an absolute path' CANONPRIMS_SURFACE_CHECK="$scratch/dir"
refused 'must be outside the repository' CANONPRIMS_SURFACE_CHECK="$root/scripts/deps-check.sh"
rm -f "$scratch/ran"
if run CANONPRIMS_SURFACE_CHECK="$scratch/fail"; then
	echo 'error: a failing check passed' >&2
	exit 1
fi
echo '[ok] surface-check hook: required, regular, outside the repository, status propagated'
