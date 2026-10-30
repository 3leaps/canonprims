#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The jq keyword guard refuses a keyword-named binding in a tracked script
# and accepts the tree as committed.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# The tracked files as they are in the working tree.
(cd "$root" && git ls-files -z | xargs -0 tar -cf -) | tar -x -C "$scratch"
git -C "$scratch" init -q
git -C "$scratch" add -A
"$scratch/scripts/jq-portability.sh" >/dev/null
for name in module import if def; do
	printf 'jq -n --arg %s x %s\n' "$name" "'\$$name'" >"$scratch/scripts/probe.sh"
	git -C "$scratch" add scripts/probe.sh
	if "$scratch/scripts/jq-portability.sh" >"$scratch/out" 2>&1; then
		echo "error: accepted a jq variable named $name" >&2
		exit 1
	fi
	grep -q 'named after a jq keyword' "$scratch/out" || { cat "$scratch/out" >&2; exit 1; }
done
printf 'jq -n --arg module_object x %s\n' "'\$module_object'" >"$scratch/scripts/probe.sh"
git -C "$scratch" add scripts/probe.sh
"$scratch/scripts/jq-portability.sh" >/dev/null
printf '#!/usr/bin/env bash\nset -euo pipefail\ncompat=()\nmaturin build "${compat[@]}"\n' >"$scratch/scripts/probe.sh"
git -C "$scratch" add scripts/probe.sh
if (cd "$scratch" && "$scratch/scripts/jq-portability.sh") >"$scratch/out" 2>&1; then
	echo 'error: accepted unguarded Bash 3.2 empty-array expansion' >&2
	exit 1
fi
grep -q 'empty array compat=()' "$scratch/out" || { cat "$scratch/out" >&2; exit 1; }
printf '#!/usr/bin/env bash\nset -euo pipefail\ncompat=()\nmaturin build ${compat[@]+"${compat[@]}"}\n' >"$scratch/scripts/probe.sh"
git -C "$scratch" add scripts/probe.sh
(cd "$scratch" && "$scratch/scripts/jq-portability.sh") >/dev/null
echo '[ok] jq keyword guard'
