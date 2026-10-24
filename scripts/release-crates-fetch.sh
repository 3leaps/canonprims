#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Fetch one crate's CI verification (the verified package and its record) from
# an exact successful run into the records directory the publication step
# reads.
#
# Usage: release-crates-fetch.sh TAG CRATE [RECORDS_DIR]
# The first crate of config/release/publishable-crates.txt comes from the tag
# push run of release.yml; every later crate from a crates-verify.yml run
# dispatched on the tag after its predecessors were published. The run must be
# completed and successful for the tag at the anchored commit, the record must
# name both anchored tag objects, the commit, this run and attempt, and the
# archive must have the recorded digest.
set -euo pipefail
die() {
	echo "error: $*" >&2
	exit 1
}
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
# shellcheck source=scripts/release-common.sh
source "$root/scripts/release-common.sh"
export CANONPRIMS_RELEASE_TAG="${1:?canonical tag required}"
tag="$(release_tag)"
crate="${2:?crate required}"
dest="${3:-dist/crates}"
version="${tag#v}"
grep -Fxq "$crate" config/release/publishable-crates.txt || die "$crate is not a published crate"
if [[ "$crate" == "$(head -n 1 config/release/publishable-crates.txt)" ]]; then
	workflow=release.yml event=push
else
	workflow=crates-verify.yml event=workflow_dispatch
fi
[[ ! -L "$dest" ]] || die 'unsafe records destination'
mkdir -p "$dest"
for name in "$crate-$version.crate" "$crate.identity.json"; do
	[[ ! -e "$dest/$name" && ! -L "$dest/$name" ]] || die "$dest/$name exists; clean explicitly first"
done
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
load_ceremony_anchor || die 'the recorded ceremony anchor (CANONPRIMS_RELEASE_ANCHOR_FILE) is required'
CANONPRIMS_ANCHOR_OUT="$scratch/anchor" "$root/scripts/release-verify-published-tag.sh"
commit="$(awk -F= '$1=="commit" {print $2}' "$scratch/anchor")"
object="$(awk -F= '$1=="object" {print $2}' "$scratch/anchor")"
module_object="$(awk -F= '$1=="module_object" {print $2}' "$scratch/anchor")"
[[ "$object" == "$CANONPRIMS_EXPECTED_TAG_OBJECT" && "$module_object" == "$CANONPRIMS_EXPECTED_MODULE_TAG_OBJECT" &&
	"$commit" == "$CANONPRIMS_EXPECTED_COMMIT" ]] || die 'verified tags differ from the recorded ceremony anchor'
runs="$(release_gh run list --repo "$CANONPRIMS_REPOSITORY" --workflow "$workflow" --branch "$tag" --limit 100 \
	--json databaseId,headSha,conclusion,event \
	--jq "[.[] | select(.headSha == \"$commit\" and .conclusion == \"success\" and .event == \"$event\") | .databaseId]")"
run="${CANONPRIMS_CRATE_RUN_ID:-}"
if [[ -n "$run" ]]; then
	[[ "$run" =~ ^[1-9][0-9]*$ ]] || die 'invalid selected run'
	jq -e --argjson run "$run" 'index($run) != null' <<<"$runs" >/dev/null || die "selected run is not a successful $workflow run for this tag and commit"
else
	[[ "$(jq length <<<"$runs")" == 1 ]] || die 'select an exact successful run with CANONPRIMS_CRATE_RUN_ID'
	run="$(jq -r '.[0]' <<<"$runs")"
fi
release_gh api "repos/$CANONPRIMS_REPOSITORY/actions/runs/$run" >"$scratch/run.json"
attempt="$(jq -r .run_attempt "$scratch/run.json")"
[[ "$attempt" =~ ^[1-9][0-9]*$ ]] || die 'invalid run attempt'
jq -e --arg commit "$commit" --arg tag "$tag" --arg event "$event" --arg path ".github/workflows/$workflow" \
	'.status == "completed" and .conclusion == "success" and .event == $event and .head_sha == $commit and .head_branch == $tag and .path == $path' \
	"$scratch/run.json" >/dev/null || die 'workflow identity mismatch'
release_gh run download "$run" --repo "$CANONPRIMS_REPOSITORY" --name "crate-$crate" --dir "$scratch/download"
[[ "$(release_gh api "repos/$CANONPRIMS_REPOSITORY/actions/runs/$run" --jq .run_attempt)" == "$attempt" ]] || die 'run attempt changed during download'
# Exactly the package and its record, as regular files.
[[ "$(cd "$scratch/download" && find . -mindepth 1 -print | LC_ALL=C sort | tr '\n' ' ')" == "./$crate-$version.crate ./$crate.identity.json " ]] ||
	die 'artifact holds other entries than the package and its record'
for name in "$crate-$version.crate" "$crate.identity.json"; do
	[[ -f "$scratch/download/$name" && ! -L "$scratch/download/$name" ]] || die 'unsafe artifact entry'
done
jq -e --arg run "$run" --arg attempt "$attempt" '.run_id == $run and .run_attempt == $attempt' \
	"$scratch/download/$crate.identity.json" >/dev/null || die 'record names another run or attempt'
python3 -I "$root/scripts/release-crate-record.py" check "$scratch/download/$crate.identity.json" "$scratch/download/$crate-$version.crate" \
	--tag "$tag" --object "$object" --module-object "$module_object" --commit "$commit" \
	--crate "$crate" --version "$version" --registry crates-io >"$scratch/digest" || die 'record does not match this release'
cp "$scratch/download/$crate-$version.crate" "$scratch/download/$crate.identity.json" "$dest/"
echo "[ok] fetched $crate $version verification from $workflow run $run attempt $attempt: sha256 $(cat "$scratch/digest")"
