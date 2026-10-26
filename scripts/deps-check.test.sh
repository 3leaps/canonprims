#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The leaf-dependency guard refuses another *prims crate or rsfulmen however
# it is declared, and accepts the workspace's own crates. The root Go module
# must stay standard-library only.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git -C "$root" archive HEAD Cargo.toml Cargo.lock crates go.mod canon | tar -x -C "$scratch"
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
# Go: a require or replace directive in go.mod is refused, and so is any
# non-standard import, while the module's own packages are accepted.
cp "$scratch/go.mod" "$scratch/go.mod.orig"
printf 'require example.com/other v1.0.0\n' >>"$scratch/go.mod"
check && { echo 'error: accepted a go.mod require' >&2; exit 1; }
grep -q 'go.mod must have no require or replace directives' "$scratch/out" || { cat "$scratch/out" >&2; exit 1; }
cp "$scratch/go.mod.orig" "$scratch/go.mod"
mkdir -p "$scratch/canon/internal/probe"
# An import the module cannot resolve: go list fails, which is a refusal.
printf 'package probe\n\nimport _ "example.com/other"\n' >"$scratch/canon/internal/probe/probe.go"
check && { echo 'error: accepted an unresolvable Go import' >&2; exit 1; }
grep -q 'go list failed' "$scratch/out" || { cat "$scratch/out" >&2; exit 1; }
# A non-standard import that resolves (a stub go list reporting it): refused.
mkdir -p "$scratch/gobin"
real_go="$(command -v go)"
# shellcheck disable=SC2016 # expands in the stub
printf '#!/bin/bash\nif [[ "$1" == list && " $* " == *" -deps "* ]]; then printf "%%s\\n" github.com/3leaps/canonprims/canon example.com/other; exit 0; fi\nexec %q "$@"\n' \
	"$real_go" >"$scratch/gobin/go"
chmod +x "$scratch/gobin/go"
rm -rf "$scratch/canon/internal/probe"
if (cd "$scratch" && PATH="$scratch/gobin:$PATH" scripts/deps-check.sh) >"$scratch/out" 2>&1; then
	echo 'error: accepted a non-standard Go import' >&2
	exit 1
fi
grep -q 'imports a non-standard package' "$scratch/out" || { cat "$scratch/out" >&2; exit 1; }
# A look-alike module path is not the module's own.
printf '#!/bin/bash\nif [[ "$1" == list && " $* " == *" -deps "* ]]; then echo github.com/3leaps/canonprims-evil/x; exit 0; fi\nexec %q "$@"\n' \
	"$real_go" >"$scratch/gobin/go"
if (cd "$scratch" && PATH="$scratch/gobin:$PATH" scripts/deps-check.sh) >"$scratch/out" 2>&1; then
	echo 'error: accepted a look-alike module path' >&2
	exit 1
fi
grep -q 'imports a non-standard package' "$scratch/out" || { cat "$scratch/out" >&2; exit 1; }
# A foreign package's test variant is not the module's own.
printf '#!/bin/bash\nif [[ "$1" == list && " $* " == *" -deps "* ]]; then echo "example.com/other [github.com/3leaps/canonprims/canon.test]"; exit 0; fi\nexec %q "$@"\n' \
	"$real_go" >"$scratch/gobin/go"
if (cd "$scratch" && PATH="$scratch/gobin:$PATH" scripts/deps-check.sh) >"$scratch/out" 2>&1; then
	echo 'error: accepted a foreign test-variant package' >&2
	exit 1
fi
grep -q 'imports a non-standard package' "$scratch/out" || { cat "$scratch/out" >&2; exit 1; }
# Imports outside the default build: a test-only import, an import behind a
# build tag for another platform, and an import only reachable with cgo on.
# Each is a go list failure in at least one cell (nothing here resolves).
controls() {
	local name="$1" file="$2" body="$3" reason="$4"
	printf '%b' "$body" >"$scratch/canon/$file"
	if check; then rm -f "$scratch/canon/$file"; echo "error: accepted $name" >&2; exit 1; fi
	grep -q -- "$reason" "$scratch/out" || { echo "error: $name refused for another reason" >&2; cat "$scratch/out" >&2; exit 1; }
	rm -f "$scratch/canon/$file"
}
controls 'a test-only import' zz_probe_test.go 'package canon\n\nimport _ "golang.org/x/crypto/sha3"\n' 'go list failed under GOOS=linux GOARCH=amd64 CGO_ENABLED=0'
controls 'a windows-tagged import' zz_win.go '//go:build windows\n\npackage canon\n\nimport _ "golang.org/x/sys/windows"\n' 'go list failed under GOOS=windows'
controls 'an arm64-tagged import' zz_tagged.go '//go:build arm64\n\npackage canon\n\nimport _ "golang.org/x/sys/cpu"\n' 'GOARCH=arm64'
controls 'a cgo-only import' zz_cgo.go 'package canon\n\n// #include <stdio.h>\nimport "C"\nimport _ "golang.org/x/sys/unix"\n' 'CGO_ENABLED=1'
# cgo itself, with no non-standard import, is refused: the module is cgo-free.
controls 'import "C" behind a cgo tag' zz_cgo2.go '//go:build cgo\n\npackage canon\n\n// #include <stdio.h>\nimport "C"\n' 'uses cgo (import "C")'
check || { cat "$scratch/out" >&2; echo 'error: pristine Go tree refused after controls' >&2; exit 1; }
echo '[ok] leaf-dependency guard: comments, dev/build/target tables and aliases, renames, separators, unreadable graph, Go require, failed go list, imports, look-alike paths, test-only, platform-tagged and cgo imports, and cgo itself'
