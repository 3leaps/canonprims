#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The leaf-dependency guard refuses another *prims crate or rsfulmen however
# it is declared, and accepts the workspace's own crates.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git -C "$root" archive HEAD Cargo.toml Cargo.lock crates go | tar -x -C "$scratch"
mkdir -p "$scratch/scripts"
cp "$root/scripts/deps-check.sh" "$scratch/scripts/"
manifest="$scratch/crates/canonprims-json/Cargo.toml"
cp "$manifest" "$scratch/json.toml"
check() { (cd "$scratch" && scripts/deps-check.sh) >"$scratch/out" 2>&1; }
check || { cat "$scratch/out" >&2; echo 'error: pristine tree refused' >&2; exit 1; }
refused() {
	cp "$scratch/json.toml" "$manifest"
	printf '%s\n' "$1" >>"$manifest"
	if check; then
		echo "error: accepted: $1" >&2
		exit 1
	fi
	grep -q 'depends on another prim or on rsfulmen' "$scratch/out" || { echo "error: refused for another reason: $1" >&2; cat "$scratch/out" >&2; exit 1; }
}
refused $'[dev-dependencies.rsfulmen]\nversion = "1" # : canonprims-'
refused $'[dev-dependencies.other-prims]\nversion = "1"'
refused $'[dev-dependencies.other_prims]\nversion = "1"'
refused $'[dev-dependencies.x]\npackage = "sysprims"\nversion = "1"'
refused $'[build-dependencies.examplprims-core]\nversion = "1"'
refused $'[target.\'cfg(unix)\'.dependencies.someprims]\nversion = "1"'
refused $'[dev_dependencies.other-prims]\nversion = "1"'
refused $'[build_dependencies.rsfulmen]\nversion = "1"'
refused $'[target.\'cfg(unix)\'.dev_dependencies.someprims]\nversion = "1"'
# The resolved graph cannot be read (a lockfile that no longer matches): the
# check fails rather than skipping the graph.
cp "$scratch/json.toml" "$manifest"
printf '%s\n' '[dev-dependencies.serde]' 'version = "1"' >>"$manifest"
if check; then
	echo 'error: accepted with an unreadable dependency graph' >&2
	exit 1
fi
grep -q 'cargo metadata failed' "$scratch/out" || { echo 'error: graph failure not reported' >&2; cat "$scratch/out" >&2; exit 1; }
cp "$scratch/json.toml" "$manifest"
# A readable graph that names a forbidden package (a transitive dependency the
# manifests do not show) is refused.
mkdir -p "$scratch/bin"
real_cargo="$(command -v cargo)"
# shellcheck disable=SC2016 # expands in the stub
printf '#!/bin/bash\nif [[ "$1" == metadata ]]; then echo %q; exit 0; fi\nexec %q "$@"\n' \
	'{"packages":[{"name":"canonprims-core"},{"name":"other-prims"}]}' "$real_cargo" >"$scratch/bin/cargo"
chmod +x "$scratch/bin/cargo"
if (cd "$scratch" && PATH="$scratch/bin:$PATH" scripts/deps-check.sh) >"$scratch/out" 2>&1; then
	echo 'error: accepted a forbidden package in the resolved graph' >&2
	exit 1
fi
grep -q 'appears in the resolved dependency graph' "$scratch/out" || { echo 'error: graph refusal not reported' >&2; cat "$scratch/out" >&2; exit 1; }
# shellcheck disable=SC2016 # expands in the stub
printf '#!/bin/bash\nif [[ "$1" == metadata ]]; then echo %q; exit 0; fi\nexec %q "$@"\n' \
	'{"packages":[{"name":"canonprims-core"},{"name":"serde"}]}' "$real_cargo" >"$scratch/bin/cargo"
(cd "$scratch" && PATH="$scratch/bin:$PATH" scripts/deps-check.sh) >"$scratch/out" 2>&1 || { echo 'error: refused a clean graph' >&2; cat "$scratch/out" >&2; exit 1; }
echo '[ok] leaf-dependency guard: comments, dev/build/target tables and aliases, renames, separators, unreadable graph'
