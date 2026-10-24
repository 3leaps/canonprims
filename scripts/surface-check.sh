#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Run the maintainer's public-surface check. CANONPRIMS_SURFACE_CHECK names an
# executable outside this repository; it is run with the repository root and
# its exit status is the result. Unset, the check is skipped, unless
# CANONPRIMS_SURFACE_CHECK_REQUIRED=1 (the pre-tag gate).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
check="${CANONPRIMS_SURFACE_CHECK:-}"
if [[ -z "$check" ]]; then
	[[ "${CANONPRIMS_SURFACE_CHECK_REQUIRED:-0}" != 1 ]] || {
		echo 'error: CANONPRIMS_SURFACE_CHECK is required for this gate' >&2
		exit 1
	}
	echo '[skip] surface check: CANONPRIMS_SURFACE_CHECK is not set'
	exit 0
fi
[[ "$check" == /* && -f "$check" && -x "$check" && ! -L "$check" ]] ||
	{ echo 'error: CANONPRIMS_SURFACE_CHECK must be an absolute path to an executable regular file' >&2; exit 1; }
canonical="$(cd "$(dirname "$check")" && pwd -P)/$(basename "$check")"
case "$canonical" in "$root" | "$root"/*)
	echo 'error: CANONPRIMS_SURFACE_CHECK must be outside the repository' >&2
	exit 1
	;;
esac
"$canonical" "$root"
echo '[ok] surface check'
