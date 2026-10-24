#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Upload only the exact verified signed set; remain a draft.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
source "$root/scripts/release-common.sh"
export CANONPRIMS_RELEASE_TAG="${1:?canonical tag required}"
directory="${2:-dist/release}"
"$root/scripts/validate-release-assets.sh" "$directory" signed
"$root/scripts/verify-checksums.sh" "$directory"
"$root/scripts/verify-staged-public.sh" "$directory"
"$root/scripts/verify-signatures.sh" "$directory"
assert_github_release_state release_signed_assets resume
files=()
while IFS= read -r name; do files+=("$directory/$name"); done < <(release_signed_assets)
require_published_anchor "$directory"
release_gh release upload "$(release_tag)" --repo "$CANONPRIMS_REPOSITORY" "${files[@]}" --clobber
require_published_anchor "$directory"
release_gh release edit "$(release_tag)" --repo "$CANONPRIMS_REPOSITORY" --notes-file "$directory/release-notes-$(release_tag).md"
