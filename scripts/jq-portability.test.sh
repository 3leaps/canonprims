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
for snippet in \
	'compat=(); maturin build "${compat[@]}"' \
	'compat=(); if false; then compat+=(--zig); fi; maturin build "${compat[@]}"' \
	'compat=(); maturin build "${compat[@]}"; compat+=(--zig)' \
	'compat=(); : "${#compat[@]}"; maturin build "${compat[@]}"' \
	'local a=1 compat=(); maturin build "${compat[@]}"' \
	'local -a a compat; maturin build "${compat[@]}"' \
	'g() { local -a compat; printf "%s\n" "${compat[@]}"; }; g' \
	$'local \\\n-a compat\nmaturin build "${compat[@]}"' \
	$'compat=()\nmaturin build "${compat[\\\n@]}"'; do
	printf '#!/usr/bin/env bash\nset -euo pipefail\nf() {\n%s\n}\n' "$snippet" >"$scratch/scripts/probe.sh"
	git -C "$scratch" add scripts/probe.sh
	if (cd "$scratch" && "$scratch/scripts/jq-portability.sh") >"$scratch/out" 2>&1; then
		echo "error: accepted unguarded Bash 3.2 empty-array expansion: $snippet" >&2
		exit 1
	fi
	grep -q 'empty array compat expanded without Bash 3.2' "$scratch/out" || { cat "$scratch/out" >&2; exit 1; }
done
printf '#!/usr/bin/env bash\nset -euo pipefail\ncompat=()\nmaturin build ${compat[@]+"${compat[@]}"}\n' >"$scratch/scripts/probe.sh"
git -C "$scratch" add scripts/probe.sh
(cd "$scratch" && "$scratch/scripts/jq-portability.sh") >/dev/null
echo '[ok] jq keyword guard'
