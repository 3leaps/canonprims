#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The manifest and signature writers refuse to write through an existing entry
# even when the inventory check before them is bypassed (the inventory check
# is the first refusal; this proves the second). The validators are stubs
# here so a planted link reaches the write step.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo/scripts" "$scratch/assets"
cp "$root/scripts/"{generate-checksums.sh,sign-release-assets.sh,release-common.sh,release-gh.sh} "$repo/scripts/"
for stub in validate-release-assets verify-public-keys verify-checksums verify-staged-public release-post-tag-selector; do
	printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/scripts/$stub.sh"
done
chmod +x "$repo/scripts/"*.sh
cat >>"$repo/scripts/release-common.sh" <<'SH'
release_signable_assets() { echo asset.txt; }
require_published_anchor() { :; }
SH
export CANONPRIMS_RELEASE_TAG=v1.2.3
printf 'asset\n' >"$scratch/assets/asset.txt"
printf 'victim\n' >"$scratch/victim"
refused() {
	local reason="$1"
	shift
	if "$@" >"$scratch/out" 2>&1; then
		echo "error: accepted: $*" >&2
		exit 1
	fi
	grep -q -- "$reason" "$scratch/out" || { echo "error: refused for another reason than '$reason'" >&2; cat "$scratch/out" >&2; exit 1; }
	[[ "$(cat "$scratch/victim")" == victim ]] || { echo 'error: the link target was written' >&2; exit 1; }
}
# A manifest planted as a link is refused, and its target is untouched.
ln -s "$scratch/victim" "$scratch/assets/SHA512SUMS"
refused 'SHA512SUMS already exists' "$repo/scripts/generate-checksums.sh" "$scratch/assets"
rm "$scratch/assets/SHA512SUMS"
"$repo/scripts/generate-checksums.sh" "$scratch/assets" >/dev/null
[[ -f "$scratch/assets/SHA256SUMS" && ! -L "$scratch/assets/SHA256SUMS" ]]
# A signature planted as a link is refused before anything is signed.
printf 'not a key\n' >"$scratch/minisign.key"
export CANONPRIMS_MINISIGN_KEY="$scratch/minisign.key" CANONPRIMS_PGP_KEY_ID='0!' CANONPRIMS_GPG_HOMEDIR="$scratch/gpg"
for signature in SHA256SUMS.minisig SHA512SUMS.asc; do
	ln -s "$scratch/victim" "$scratch/assets/$signature"
	refused "$signature already exists" "$repo/scripts/sign-release-assets.sh" v1.2.3 "$scratch/assets"
	rm "$scratch/assets/$signature"
done
echo '[ok] manifest and signature writers refuse to write through existing entries'
