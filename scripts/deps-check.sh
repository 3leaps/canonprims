#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# canonprims is a leaf: it imports no other prim and no rsfulmen, and the Go
# module uses the standard library only.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${root}"
fail=0

# No dependency of any kind (normal, dev, build, target-specific) on another
# *prims crate or on rsfulmen, by package name, in any workspace manifest.
if ! python3 -I - Cargo.toml crates/*/Cargo.toml <<'PY'
import re, sys, tomllib
forbidden = re.compile(r"^(?:[a-z0-9_-]*prims|rsfulmen)(?:[-_][a-z0-9_-]*)?$")
# Cargo accepts the underscore spellings as aliases.
KEYS = ("dependencies", "dev-dependencies", "dev_dependencies", "build-dependencies", "build_dependencies")
bad = []
def tables(doc):
    for key in KEYS:
        yield key, doc.get(key, {})
    for target, spec in doc.get("target", {}).items():
        for key in KEYS:
            yield f"target.{target}.{key}", spec.get(key, {})
for path in sys.argv[1:]:
    doc = tomllib.load(open(path, "rb"))
    sources = list(tables(doc)) + [(f"workspace.{k}", v) for k, v in tables(doc.get("workspace", {}))]
    for table, deps in sources:
        for alias, spec in deps.items():
            name = spec.get("package", alias) if isinstance(spec, dict) else alias
            name = name.lower()
            if forbidden.match(name) and not name.startswith("canonprims-") and name != "canonprims":
                bad.append(f"{path}: [{table}] {alias}")
for line in bad:
    print(line)
sys.exit(1 if bad else 0)
PY
then
  echo "deps-check: a canonprims crate depends on another prim or on rsfulmen" >&2
  fail=1
fi
# The resolved graph (every edge kind). Failing to read it fails the check.
if ! metadata="$(cargo metadata --locked --format-version 1 2>/dev/null)"; then
  echo "deps-check: cargo metadata failed; the dependency graph was not checked" >&2
  fail=1
elif ! printf '%s' "$metadata" | python3 -I -c '
import json, re, sys
forbidden = re.compile(r"^(?:[a-z0-9_-]*prims|rsfulmen)(?:[-_][a-z0-9_-]*)?$")
names = {p["name"].lower() for p in json.load(sys.stdin)["packages"]}
bad = sorted(n for n in names if forbidden.match(n) and not n.startswith("canonprims-") and n != "canonprims")
print("\n".join(bad))
sys.exit(1 if bad else 0)'; then
  echo "deps-check: a prim or rsfulmen appears in the resolved dependency graph, or the graph could not be read" >&2
  fail=1
fi
if grep -nE '^[[:space:]]*(require|replace)\b' go.mod; then
  echo "deps-check: go.mod must have no require or replace directives" >&2
  fail=1
fi
# The Go module is standard library only on every platform CI builds, with
# and without cgo, and including test files: each cell lists the full import
# graph with -test, and a failed go list (an unresolvable import, a broken
# module, an import "C" when cgo is off) is a refusal, never an empty result.
# Only the module's own packages and their test variants may be non-standard.
own='github.com/3leaps/canonprims(/[A-Za-z0-9_./-]*)?'
own_line="^${own}(\.test)?( \[${own}\.test\])?$"
for platform in linux/amd64 linux/arm64 darwin/arm64 darwin/amd64 windows/amd64 windows/arm64; do
  for cgo in 0 1; do
    cell="GOOS=${platform%/*} GOARCH=${platform#*/} CGO_ENABLED=${cgo}"
    if ! go_deps="$(env GOWORK=off GOFLAGS=-mod=readonly GOOS="${platform%/*}" GOARCH="${platform#*/}" CGO_ENABLED="${cgo}" \
      go list -deps -test -f '{{if not .Standard}}{{.ImportPath}}{{end}}' ./... 2>&1)"; then
      echo "deps-check: go list failed under ${cell}; the Go dependency graph could not be read" >&2
      printf '%s\n' "$go_deps" | head -5 >&2
      fail=1
    elif [ -n "$(printf '%s\n' "$go_deps" | grep -Ev "${own_line}" | grep -v '^$' || true)" ]; then
      echo "deps-check: the Go module imports a non-standard package under ${cell}" >&2
      printf '%s\n' "$go_deps" | grep -Ev "${own_line}" | grep -v '^$' | head -5 >&2
      fail=1
    fi
    # cgo-free: no package of the module uses import "C" in any cell.
    if cgo_files="$(env GOWORK=off GOFLAGS=-mod=readonly GOOS="${platform%/*}" GOARCH="${platform#*/}" CGO_ENABLED="${cgo}" \
      go list -test -f '{{if .CgoFiles}}{{.ImportPath}}: {{join .CgoFiles " "}}{{end}}' ./... 2>/dev/null)" &&
      [ -n "$(printf '%s' "$cgo_files" | tr -d '[:space:]')" ]; then
      echo "deps-check: the Go module uses cgo (import \"C\") under ${cell}" >&2
      printf '%s\n' "$cgo_files" | grep -v '^$' | head -5 >&2
      fail=1
    fi
  done
done
exit "${fail}"
