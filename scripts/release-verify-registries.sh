#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Verify that PyPI and npm serve the exact signed release bytes for
# CANONPRIMS_RELEASE_TAG. Re-verifies the staged manifests' minisign and
# OpenPGP signatures and all 20 asset checksums before comparing registry
# responses against SHA256SUMS and SHA512SUMS.
#
# Usage: scripts/release-verify-registries.sh [stage-dir] [all|pypi|npm]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
# shellcheck source=scripts/release-common.sh
source "$root/scripts/release-common.sh"

tag="$(release_tag)"
version="${tag#v}"
stage_dir="${1:-dist/published}"
scope="${2:-all}"

"$root/scripts/verify-signatures.sh" "$stage_dir"
CANONPRIMS_RELEASE_TAG="$tag" "$root/scripts/verify-checksums.sh" "$stage_dir"
python3 -I -B "$root/scripts/release-verify-registries.py" "$stage_dir" "$version" "$scope"
