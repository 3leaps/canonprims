#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Download the published (non-draft) GitHub release for CANONPRIMS_RELEASE_TAG
# into a clean directory, verify that the tag and release point at the same
# commit, verify that the public keys/anchors/notes match the tagged commit,
# verify both minisign and OpenPGP subkey signatures on SHA256SUMS and
# SHA512SUMS, verify all 20 asset checksums, and verify the embedded metadata
# of the five Python wheels and the npm tarball before moving the directory into
# place.
#
# Usage: scripts/release-stage-published.sh [tag] [out-dir]
set -euo pipefail

die() {
	echo "error: $*" >&2
	exit 1
}

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
# shellcheck source=scripts/release-common.sh
source "$root/scripts/release-common.sh"
# shellcheck source=scripts/release-decernor.sh
source "$root/scripts/release-decernor.sh"

tag="$(release_tag "${1:-${CANONPRIMS_RELEASE_TAG:-}}")"
version="${tag#v}"
out_dir="${2:-dist/published}"
[[ ! -e "$out_dir" && ! -L "$out_dir" ]] || die "$out_dir already exists; clean explicitly first"

resolve_release_decernor || die 'the checker is required to verify the published release'
export RELEASE_DECERNOR_BIN

if [[ -n "${CANONPRIMS_GPG_SIGNING_FINGERPRINT:-}" ]]; then
	if [[ -n "${CANONPRIMS_RELEASE_ANCHOR_FILE:-}" ]]; then
		load_ceremony_anchor
	fi
	CANONPRIMS_RELEASE_TAG="$tag" "$root/scripts/release-verify-published-tag.sh"
fi
CANONPRIMS_RELEASE_TAG="$tag" "$root/scripts/verify-pinned-tag.sh" --published

commit="$(git rev-parse "refs/tags/${tag}^{commit}")"
object="$(git rev-parse "refs/tags/${tag}")"

if [[ "$(release_gh repo view "$CANONPRIMS_REPOSITORY" --json nameWithOwner --jq .nameWithOwner)" != "$CANONPRIMS_REPOSITORY" ]]; then
	die 'GitHub repository identity mismatch'
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/canonprims-published.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

state="$scratch/state.json"
expected="$scratch/expected.txt"
actual="$scratch/actual.txt"
release_gh release view "$tag" --repo "$CANONPRIMS_REPOSITORY" \
	--json tagName,targetCommitish,isDraft,assets >"$state"

if [[ "$(jq -r .tagName "$state")" != "$tag" ||
	"$(jq -r .targetCommitish "$state")" != "$commit" ||
	"$(jq -r .isDraft "$state")" != "false" ]]; then
	die 'GitHub release must be published (non-draft) at the verified tagged commit'
fi

CANONPRIMS_RELEASE_TAG="$tag" release_signed_assets | LC_ALL=C sort >"$expected"
jq -r '.assets[].name' "$state" | LC_ALL=C sort >"$actual"
if ! cmp -s "$expected" "$actual"; then
	diff -u "$expected" "$actual" >&2 || true
	die 'published GitHub release asset inventory mismatch'
fi

stage="$scratch/stage"
mkdir -p "$stage"
release_gh release download "$tag" --repo "$CANONPRIMS_REPOSITORY" --pattern '*' --dir "$stage"
CANONPRIMS_RELEASE_TAG="$tag" assert_exact_directory_inventory "$stage" release_signed_assets

compare_blob() {
	local path="$1" file="$2" mode
	mode="$(git ls-tree "$commit" -- "$path" | awk '{print $1}')"
	[[ "$mode" == 100644 || "$mode" == 100755 ]] || die "committed public file missing: $path"
	git cat-file blob "$commit:$path" >"$scratch/blob"
	if [[ ! -s "$scratch/blob" || ! -f "$file" || -L "$file" ]] || ! cmp -s "$scratch/blob" "$file"; then
		die "published release public material differs from verified commit ($path)"
	fi
}
for ext in txt ndjson; do
	compare_blob "keys/expected-fingerprints.$ext" "$stage/expected-fingerprints.$ext"
done
compare_blob docs/security/release-signing-keys.asc "$stage/canonprims-release-signing-key.asc"
compare_blob docs/security/canonprims-minisign.pub "$stage/canonprims-minisign.pub"
compare_blob "docs/releases/$tag.md" "$stage/release-notes-$tag.md"
"$root/scripts/verify-public-keys.sh" "$stage"
"$root/scripts/verify-signatures.sh" "$stage"
CANONPRIMS_RELEASE_TAG="$tag" "$root/scripts/verify-checksums.sh" "$stage"

python3 -I - "$stage" "$version" <<'PY'
import json
import pathlib
import sys
import tarfile
import zipfile

stage = pathlib.Path(sys.argv[1])
version = sys.argv[2]

wheels = sorted(stage.glob(f"canonprims-{version}-cp310-abi3-*.whl"))
if len(wheels) != 5:
    sys.exit(f"error: expected 5 wheels for {version}, found {len(wheels)}")
for wheel in wheels:
    meta_name = f"canonprims-{version}.dist-info/METADATA"
    with zipfile.ZipFile(wheel) as zf:
        if meta_name not in zf.namelist():
            sys.exit(f"error: {wheel.name} missing {meta_name}")
        lines = zf.read(meta_name).decode("utf-8").splitlines()
    headers = {}
    for line in lines:
        if not line.strip():
            break
        key, sep, val = line.partition(": ")
        if sep and key not in headers:
            headers[key] = val
    if headers.get("Name") != "canonprims" or headers.get("Version") != version:
        sys.exit(f"error: {wheel.name} metadata mismatch: {headers}")

tgz = stage / f"3leaps-canonprims-{version}.tgz"
with tarfile.open(tgz, "r:gz") as tf:
    member = tf.extractfile("package/package.json")
    if member is None:
        sys.exit(f"error: {tgz.name} missing package/package.json")
    pkg = json.loads(member.read().decode("utf-8"))
repo_url = (pkg.get("repository") or {}).get("url")
if (
    pkg.get("name") != "@3leaps/canonprims"
    or pkg.get("version") != version
    or repo_url != "git+https://github.com/3leaps/canonprims.git"
):
    sys.exit(f"error: {tgz.name} package.json mismatch: {pkg}")
PY

printf 'tag=%s\nobject=%s\ncommit=%s\n' "$tag" "$object" "$commit" >"$stage.anchor"
mkdir -p "$(dirname "$out_dir")"
mv "$stage" "$out_dir"
mv "$stage.anchor" "$out_dir.anchor"
echo "[ok] verified published release $tag staged in $out_dir"
