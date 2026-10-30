#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Verify that PyPI and npm serve the exact signed release bytes for
# CANONPRIMS_RELEASE_TAG. Re-verifies that the staged public keys, fingerprint
# pins, and release notes match the verified tagged commit, re-verifies the
# staged manifests' minisign and OpenPGP signatures and all 20 asset checksums,
# and then compares live registry responses against SHA256SUMS and SHA512SUMS.
#
# Usage: scripts/release-verify-registries.sh [stage-dir] [all|pypi|npm]
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

tag="$(release_tag)"
version="${tag#v}"
stage_dir="${1:-dist/published}"
scope="${2:-all}"

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
CANONPRIMS_RELEASE_TAG="$tag" assert_exact_directory_inventory "$stage_dir" release_signed_assets

scratch="$(mktemp -d "${TMPDIR:-/tmp}/canonprims-verify-reg.XXXXXX")"
trap 'rc=$?; rm -rf "$scratch"; exit "$rc"' EXIT

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
	compare_blob "keys/expected-fingerprints.$ext" "$stage_dir/expected-fingerprints.$ext"
done
compare_blob docs/security/release-signing-keys.asc "$stage_dir/canonprims-release-signing-key.asc"
compare_blob docs/security/canonprims-minisign.pub "$stage_dir/canonprims-minisign.pub"
compare_blob "docs/releases/$tag.md" "$stage_dir/release-notes-$tag.md"
"$root/scripts/verify-public-keys.sh" "$stage_dir"
"$root/scripts/verify-signatures.sh" "$stage_dir"
CANONPRIMS_RELEASE_TAG="$tag" "$root/scripts/verify-checksums.sh" "$stage_dir"
python3 -I -B "$root/scripts/release-verify-registries.py" "$stage_dir" "$version" "$scope"
