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
# An interpreter that cannot run would make every case look refused.
"$python" -I -c 'import re, zipfile' || { echo "error: no usable Python ($python); set PYTHON" >&2; exit 1; }
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
# A Windows home in every form an artifact carries it: raw, JSON-escaped
# (doubled backslashes), a file URL with forward slashes and a lowercase drive,
# URL-encoded and mixed separators.
win='C:\\Users\\someone'
for form in 'C:\\Users\\someone\\x.rs' 'C:\\\\Users\\\\someone\\\\x.rs' \
	'path+file:///C:/Users/someone/pkg#1' 'file:///c:/Users/someone/x' \
	'C:%5CUsers%5Csomeone%5Cx' 'C:/Users\\someone/x'; do
	printf '%s' "$form" >"$scratch/win-form"
	bad "$scratch/win-form" "$win"
done
# Another user's profile is not the build host's.
printf 'C:\\Users\\user\\x.rs' >"$scratch/win-other"
ok "$scratch/win-other" "$win"
# A JSON-escaped Unix home is still found.
printf '{"p":"\\/home\\/someone\\/x"}' >"$scratch/json-unix"
bad "$scratch/json-unix" /home/someone
# A name written with JSON or URL escapes is the same directory: devrev's
# repros (a space, a non-ASCII letter) in plain files and in wheel metadata.
# Python writes the fixtures so the escapes are exact bytes.
"$python" -I - "$scratch" <<'PY'
import json, pathlib, sys, zipfile
d = pathlib.Path(sys.argv[1])
d.joinpath("enc-space-url").write_bytes(b"path+file:///C:/Users/user%20name/pkg#1")
d.joinpath("enc-space-json").write_text(json.dumps({"p": "C:\\Users\\user name\\pkg"}))
d.joinpath("enc-umlaut-json").write_text(json.dumps({"p": "/home/user\u00e9/pkg"}))
d.joinpath("enc-umlaut-url").write_bytes(b"file:///home/user%C3%A9/pkg")
d.joinpath("enc-umlaut-raw").write_bytes("/home/user\u00e9/pkg".encode())
d.joinpath("enc-url-in-json").write_text(json.dumps({"u": "file:///home/user%C3%A9/pkg"}))
d.joinpath("enc-other-user").write_text(json.dumps({"p": "/home/user\u00e9s/pkg"}))
with zipfile.ZipFile(d / "enc.whl", "w") as z:
    z.writestr("pkg-1.dist-info/build.json", json.dumps({"root": "/home/user\u00e9/pkg"}))
PY
bad "$scratch/enc-space-url" 'C:\Users\user name'
bad "$scratch/enc-space-json" 'C:\Users\user name'
for f in enc-umlaut-json enc-umlaut-url enc-umlaut-raw enc-url-in-json enc.whl; do
	bad "$scratch/$f" "/home/user$(printf '\303\251')"
done
# A longer name (with a trailing s) is another user, a different directory.
ok "$scratch/enc-other-user" "/home/user$(printf '\303\251')"
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
# devrev RELB-DV-02: a Windows home inside JSON in a wheel member.
"$python" -I - "$scratch/winjson.whl" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("pkg-1.dist-info/build.json", json.dumps({"root": "C:\\Users\\someone\\work\\pkg"}))
PY
bad "$scratch/winjson.whl" "$win"
echo '[ok] host-path-check: directory prefixes in files and wheel members; no substring false positives'
