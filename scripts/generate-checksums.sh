#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Generate manifests only after complete public material is staged.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$root/scripts/release-common.sh"
directory="${1:-dist/release}"
export CANONPRIMS_RELEASE_TAG="${2:-${CANONPRIMS_RELEASE_TAG:-}}"
"$root/scripts/validate-release-assets.sh" "$directory" signable
"$root/scripts/verify-public-keys.sh" "$directory"
files=()
while IFS= read -r name; do files+=("$name"); done < <(release_signable_assets | LC_ALL=C sort)
(
    cd "$directory"
    # Never write through a link: the manifests are created, not followed.
    for manifest in SHA256SUMS SHA512SUMS; do
        [[ ! -e "$manifest" && ! -L "$manifest" ]] || { echo "error: $manifest already exists" >&2; exit 1; }
    done
    shasum -a 256 "${files[@]}" >SHA256SUMS
    shasum -a 512 "${files[@]}" >SHA512SUMS
)
"$root/scripts/verify-checksums.sh" "$directory"
