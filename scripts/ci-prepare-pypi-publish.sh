#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Re-verify the staged Python wheels against the stage job's verified
# SHA256SUMS and SHA512SUMS and copy only the five wheels into an isolated
# directory inside the workspace for pypa/gh-action-pypi-publish.
#
# Usage: scripts/ci-prepare-pypi-publish.sh <version> <expected-commit> <stage-dir> <wheels-out-dir>
set -euo pipefail

die() {
	echo "error: $*" >&2
	exit 1
}

version="${1:?version required}"
expected_commit="${2:?expected commit required}"
stage_dir="${3:?stage directory required}"
out_dir="${4:?wheels output directory required}"

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
# shellcheck source=scripts/release-common.sh
source "$root/scripts/release-common.sh"

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "invalid version $version"
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || die 'invalid expected commit'
[[ "$(git rev-parse HEAD)" == "$expected_commit" ]] || die 'HEAD differs from verified stage commit'
[[ "$(tr -d ' \t\r\n' < "$root/VERSION")" == "$version" ]] || die 'VERSION differs from verified stage version'
[[ ! -e "$out_dir" && ! -L "$out_dir" ]] || die "$out_dir already exists"

python3 -I - "$stage_dir" "$out_dir" "$version" <<'PY'
import hashlib
import pathlib
import re
import shutil
import sys

stage = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
version = sys.argv[3]

tags = (
    "manylinux_2_17_x86_64.manylinux2014_x86_64",
    "manylinux_2_17_aarch64.manylinux2014_aarch64",
    "macosx_11_0_arm64",
    "win_amd64",
    "win_arm64",
)
expected_wheels = [f"canonprims-{version}-cp310-abi3-{tag}.whl" for tag in tags]

def read_manifest(path: pathlib.Path, width: int) -> dict[str, str]:
    if not path.is_file() or path.is_symlink():
        sys.exit(f"error: missing or unsafe {path}")
    entries = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        digest, sep, name = line.partition("  ")
        if not sep or not re.fullmatch(f"[0-9a-f]{{{width}}}", digest) or name in entries:
            sys.exit(f"error: malformed entry in {path.name}")
        entries[name] = digest
    return entries

sha256s = read_manifest(stage / "SHA256SUMS", 64)
sha512s = read_manifest(stage / "SHA512SUMS", 128)
out.mkdir(parents=True, exist_ok=False)

for name in expected_wheels:
    wheel = stage / name
    if not wheel.is_file() or wheel.is_symlink():
        sys.exit(f"error: missing staged wheel {name}")
    raw = wheel.read_bytes()
    if hashlib.sha256(raw).hexdigest() != sha256s.get(name):
        sys.exit(f"error: sha256 mismatch for staged wheel {name}")
    if hashlib.sha512(raw).hexdigest() != sha512s.get(name):
        sys.exit(f"error: sha512 mismatch for staged wheel {name}")
    shutil.copy2(wheel, out / name)

copied = sorted(p.name for p in out.iterdir())
if copied != sorted(expected_wheels):
    sys.exit(f"error: unexpected wheel output inventory: {copied}")
print(f"[ok] verified 5 wheels for canonprims=={version} in {out}")
PY
