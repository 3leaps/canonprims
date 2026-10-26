#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Report each host tool's version against the recommended minimum declared in
# .goneat/tools.yaml, and fail when one is missing or older.
#
# Usage: scripts/doctor.sh [release|dev]   (default: release)
#
# goneat does the comparison. It does not compare a version with only two
# parts (minisign prints "minisign 0.12"), so minisign is also checked here
# against the same declared minimum.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scope="${1:-release}"
config="$root/.goneat/tools.yaml"
case "$scope" in release | dev) ;; *)
	echo "error: unknown scope $scope (release or dev)" >&2
	exit 2
	;;
esac

die() {
	echo "error: $*" >&2
	exit 1
}

# declared_minimum TOOL: the minimum_version of TOOL in the tools file.
declared_minimum() {
	awk -v tool="  $1:" '
		$0 == tool {in_tool = 1; next}
		in_tool && /^  [^ ]/ {exit}
		in_tool && $1 == "minimum_version:" {print $2; exit}
	' "$config"
}

# at_least HAVE WANT: true when dotted version HAVE >= WANT; missing parts are 0.
at_least() {
	awk -v have="$1" -v want="$2" 'BEGIN {
		nh = split(have, h, "."); nw = split(want, w, ".")
		n = nh > nw ? nh : nw
		for (i = 1; i <= n; i++) {
			if ((h[i] + 0) > (w[i] + 0)) exit 0
			if ((h[i] + 0) < (w[i] + 0)) exit 1
		}
		exit 0
	}'
}

check_minisign() {
	local want have
	want="$(declared_minimum minisign)"
	[[ "$want" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die 'minisign has no minimum_version in .goneat/tools.yaml'
	command -v minisign >/dev/null 2>&1 || die 'minisign is missing'
	have="$(minisign -v 2>&1 | sed -n 's/^minisign \([0-9][0-9.]*\).*/\1/p' | head -1)"
	[[ -n "$have" ]] || die 'cannot read the minisign version'
	at_least "$have" "$want" || die "minisign $have is below the recommended minimum $want"
	echo "[ok] minisign $have (minimum $want)"
}

if [[ "${CANONPRIMS_DOCTOR_MINISIGN_ONLY:-}" == 1 ]]; then
	check_minisign
	exit 0
fi
command -v goneat >/dev/null 2>&1 || die 'goneat is required for make doctor (see .goneat/tools.yaml)'
goneat doctor tools --config "$config" --scope "$scope" --no-cooling
if [[ "$scope" == release ]]; then
	check_minisign
fi
echo "[ok] doctor ($scope): every tool meets its recommended minimum"
