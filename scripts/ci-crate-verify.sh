#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Credential-free package verification of one crate, for CI: build and verify
# the crate's package (cargo package, which compiles it) against the registry
# exactly as it will be published, with every predecessor already on the
# index, then record the SHA-256 of the archive that was verified.
#
# Usage: ci-crate-verify.sh CRATE OUT_DIR
# Creates OUT_DIR (absent, outside the checkout) holding exactly
# CRATE-VERSION.crate and CRATE.identity.json. The
# identity names the repository, both tag objects, the commit, the crate,
# version, Cargo version and the archive digest. Runs in a checkout of the
# verified release commit with the release tags restored.
set -euo pipefail
crate="${1:?crate required}"
out="${2:?output directory required}"
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# The output is the artifact: a new directory outside the checkout, so nothing
# else is uploaded with the package and its record.
[[ "$out" == /* && ! -e "$out" && ! -L "$out" ]] || { echo 'error: OUT_DIR must be an absolute path that does not exist' >&2; exit 1; }
out_parent="$(cd "$(dirname "$out")" && pwd -P)" || { echo 'error: OUT_DIR parent must exist' >&2; exit 1; }
case "$out_parent" in "$root" | "$root"/*)
	echo 'error: OUT_DIR must be outside the checkout' >&2
	exit 1
	;;
esac
out="$out_parent/$(basename "$out")"
cd "$root"
tag="${CANONPRIMS_RELEASE_TAG:?CANONPRIMS_RELEASE_TAG required}"
version="$(tr -d '\r\n' <VERSION)"
[[ "$tag" == "v$version" ]] || { echo "error: $tag does not match VERSION $version" >&2; exit 1; }
grep -Fxq "$crate" config/release/publishable-crates.txt || { echo "error: $crate is not a published crate" >&2; exit 1; }
commit="$(git rev-parse --verify "refs/tags/$tag^{commit}")"
[[ "$(git rev-parse HEAD)" == "$commit" ]] || { echo 'error: HEAD is not the release commit' >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || { echo 'error: clean checkout required' >&2; exit 1; }
# The release source is inert for Cargo before anything compiles it.
python3 -I scripts/release-source-check.py "$commit"
msrv="$(sed -n 's/^rust-version = "\(.*\)"/\1/p' Cargo.toml)"
# Every predecessor in the publication plan must already be on the index, so
# the package resolves exactly as it will for consumers (no path patch).
registry="${CANONPRIMS_CRATES_REGISTRY:-crates-io}"
sparse_index="${CANONPRIMS_CRATES_INDEX:-https://index.crates.io/}"
while IFS= read -r predecessor; do
	[[ "$predecessor" != "$crate" ]] || break
	python3 -I scripts/release-index-entry.py "$sparse_index" "$predecessor" "$version" >/dev/null || {
		echo "error: $predecessor@$version is not on the $registry index yet" >&2
		exit 1
	}
done <config/release/publishable-crates.txt
# Packaging resolves dependencies from the default registry, crates.io (the
# --registry flag is unstable for cargo package on stable Cargo).
cargo "+$msrv" package --locked -p "$crate"
archive="target/package/$crate-$version.crate"
# Hash the archive that was verified, before anything could repackage it.
digest="$(sha256sum "$archive" 2>/dev/null | cut -c1-64 || shasum -a 256 "$archive" | cut -c1-64)"
mkdir "$out"
cp "$archive" "$out/"
python3 -I - "$out/$crate.identity.json" <<PY
import json, sys
json.dump({
    "format": "canonprims-crate-verification/v0",
    "repository": "3leaps/canonprims",
    "tag": "$tag",
    "object": "$(git rev-parse "refs/tags/$tag")",
    "module_object": "$(git rev-parse "refs/tags/go/canon/$tag")",
    "commit": "$commit",
    "crate": "$crate",
    "version": "$version",
    "cargo": "$(cargo "+$msrv" --version)",
    "registry": "$registry",
    "sha256": "$digest",
    "run_id": "${GITHUB_RUN_ID:-local}",
    "run_attempt": "${GITHUB_RUN_ATTEMPT:-local}",
}, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
echo "[ok] verified $crate $version package: sha256 $digest"
