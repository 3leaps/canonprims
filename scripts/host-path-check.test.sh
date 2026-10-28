#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# host-path-check.py: a build-host directory followed by a separator is
# found in plain files and in every wheel member; a short root that is only a
# substring of a longer path (/src in library/alloc/src/) is not; "/" alone is
# ignored.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
check="$root/scripts/host-path-check.py"
python="${PYTHON:-python3}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
ok() { "$python" -I "$check" "$@" >/dev/null 2>&1 || { echo "error: refused: $*" >&2; exit 1; }; }
bad() { if "$python" -I "$check" "$@" >/dev/null 2>&1; then echo "error: accepted: $*" >&2; exit 1; fi; }

printf 'x/rustc/abc/library/alloc/src/string.rs /canonprims/crates/x.rs /cargo/registry/src/y.rs' >"$scratch/clean"
ok "$scratch/clean" /src /build/.cargo /build/.rustup /build
ok "$scratch/clean" /
printf 'x/home/user/work/canonprims/crates/x.rs' >"$scratch/home"
bad "$scratch/home" /home/user
bad "$scratch/home" /home/user/work/canonprims
# A directory whose name merely starts the same way is a different directory.
printf 'x/home/username/x.rs' >"$scratch/home-longer"
ok "$scratch/home-longer" /home/user
# A single-component root counts at the start of a path (after a NUL, a
# quote or file://), not inside a longer one.
printf 'x\000/src/crates/x.rs' >"$scratch/root"
bad "$scratch/root" /src
printf '"path":"/src/crates/x.rs"' >"$scratch/root-json"
bad "$scratch/root-json" /src
printf 'path+file:///src/crates#1' >"$scratch/root-url"
bad "$scratch/root-url" /src
printf 'x/alloc/src/crates/x.rs' >"$scratch/root-inner"
ok "$scratch/root-inner" /src
printf 'x C:\\Users\\someone\\x.rs' >"$scratch/win"
bad "$scratch/win" 'C:\Users\someone'
# A wheel: the path in any member is found.
"$python" -I - "$scratch/clean.whl" "$scratch/dirty.whl" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("pkg/a.so", b"/rustc/abc/library/core/src/x.rs")
    z.writestr("pkg-1.dist-info/RECORD", b"pkg/a.so,sha256=x,1")
with zipfile.ZipFile(sys.argv[2], "w") as z:
    z.writestr("pkg/a.so", b"clean")
    z.writestr("pkg-1.dist-info/sboms/x.json", b"path+file:///home/someone/pkg#1")
PY
ok "$scratch/clean.whl" /src /home/someone
bad "$scratch/dirty.whl" /home/someone
echo '[ok] host-path-check: directory prefixes in files and wheel members; no substring false positives'
