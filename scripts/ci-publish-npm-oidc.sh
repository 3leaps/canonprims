#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Re-verify the staged npm tarball against the stage job's verified SHA256SUMS
# and SHA512SUMS, ensure the OIDC-capable Node/npm floor (Node >= 22.14.0,
# npm >= 11.5.1), publish the tarball via npm OIDC Trusted Publishing with
# provenance, and verify that the npm registry serves the exact signed bytes.
#
# Usage: scripts/ci-publish-npm-oidc.sh <version> <expected-commit> <stage-dir>
set -euo pipefail

die() {
	echo "error: $*" >&2
	exit 1
}

version="${1:?version required}"
expected_commit="${2:?expected commit required}"
stage_dir="${3:?stage directory required}"

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "invalid version $version"
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || die 'invalid expected commit'
[[ "$(git rev-parse HEAD)" == "$expected_commit" ]] || die 'HEAD differs from verified stage commit'
[[ "$(tr -d ' \t\r\n' < "$root/VERSION")" == "$version" ]] || die 'VERSION differs from verified stage version'

tgz="$stage_dir/3leaps-canonprims-${version}.tgz"
python3 -I - "$stage_dir" "$version" <<'PY'
import hashlib
import json
import pathlib
import re
import sys
import tarfile

stage = pathlib.Path(sys.argv[1])
version = sys.argv[2]
tgz_name = f"3leaps-canonprims-{version}.tgz"
tgz = stage / tgz_name

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
if not tgz.is_file() or tgz.is_symlink():
    sys.exit(f"error: missing staged tarball {tgz_name}")
raw = tgz.read_bytes()
if hashlib.sha256(raw).hexdigest() != sha256s.get(tgz_name):
    sys.exit(f"error: sha256 mismatch for staged tarball {tgz_name}")
if hashlib.sha512(raw).hexdigest() != sha512s.get(tgz_name):
    sys.exit(f"error: sha512 mismatch for staged tarball {tgz_name}")

with tarfile.open(tgz, "r:gz") as tf:
    member = tf.extractfile("package/package.json")
    if member is None:
        sys.exit(f"error: {tgz_name} missing package/package.json")
    pkg = json.loads(member.read().decode("utf-8"))
repo_url = (pkg.get("repository") or {}).get("url")
if (
    pkg.get("name") != "@3leaps/canonprims"
    or pkg.get("version") != version
    or repo_url != "git+https://github.com/3leaps/canonprims.git"
):
    sys.exit(f"error: {tgz_name} package.json mismatch: {pkg}")
print(f"[ok] verified {tgz_name} against SHA256SUMS and SHA512SUMS")
PY

# npm Trusted Publishing requires Node >= 22.14.0 and npm >= 11.5.1.
node_ver="$(node --version)"
npm_ver="$(npm --version)"
if ! python3 -I -c 'import sys; a=tuple(map(int,sys.argv[1].lstrip("v").split("."))); b=tuple(map(int,sys.argv[2].split("."))); sys.exit(0 if a>=b else 1)' "$node_ver" "22.14.0"; then
	die "Node >= 22.14.0 required for npm OIDC Trusted Publishing (found $node_ver)"
fi
if ! python3 -I -c 'import sys; a=tuple(map(int,sys.argv[1].split("."))); b=tuple(map(int,sys.argv[2].split("."))); sys.exit(0 if a>=b else 1)' "$npm_ver" "11.5.1"; then
	npm install -g "npm@11.5.1"
	npm_ver="$(npm --version)"
	python3 -I -c 'import sys; a=tuple(map(int,sys.argv[1].split("."))); b=tuple(map(int,sys.argv[2].split("."))); sys.exit(0 if a>=b else 1)' "$npm_ver" "11.5.1" ||
		die "npm >= 11.5.1 required for npm OIDC Trusted Publishing (found $npm_ver)"
fi

unset NODE_AUTH_TOKEN NPM_TOKEN
npmrc="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/canonprims-npmrc.XXXXXX")"
trap 'rm -f "$npmrc"' EXIT
printf 'registry=https://registry.npmjs.org/\nalways-auth=false\n' >"$npmrc"
export NPM_CONFIG_USERCONFIG="$npmrc"

npm publish "$tgz" --provenance --access public
python3 -I -B "$root/scripts/release-verify-registries.py" --expect-provenance "$stage_dir" "$version" npm
