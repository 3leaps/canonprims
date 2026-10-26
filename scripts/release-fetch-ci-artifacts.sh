#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Adapted from the spanwit exact-run handoff for five native canonprims targets.
set -euo pipefail
die() {
    echo "error: $*" >&2
    exit 1
}
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
source "$root/scripts/release-common.sh"
export CANONPRIMS_RELEASE_TAG="${1:?canonical tag required}"
tag="$(release_tag)"
dest="${2:-dist/release}"
[[ ! -L "$dest" && ! -L "$dest.anchor" ]] || die 'unsafe artifact destination'
mkdir -p "$dest"
[[ -z "$(find "$dest" -mindepth 1 -maxdepth 1 -print)" ]] || die 'destination must be empty; clean explicitly first'
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# The original ceremony anchor (the tag object and the commit) binds the
# download: a tag replaced since the ceremony, even re-signed by the approved
# key at the same commit, fails here before anything is staged.
load_ceremony_anchor || die 'the recorded ceremony anchor (CANONPRIMS_RELEASE_ANCHOR_FILE) is required'
CANONPRIMS_ANCHOR_OUT="$scratch/anchor" "$root/scripts/release-verify-published-tag.sh"
commit="$(awk -F= '$1=="commit" {print $2}' "$scratch/anchor")"
object="$(awk -F= '$1=="object" {print $2}' "$scratch/anchor")"
[[ "$commit" =~ ^[0-9a-f]{40}$ && "$object" =~ ^[0-9a-f]{40}$ ]] || die 'verification returned no valid anchor'
[[ "$object" == "$CANONPRIMS_EXPECTED_TAG_OBJECT" &&
    "$commit" == "$CANONPRIMS_EXPECTED_COMMIT" ]] || die 'verified tags differ from the recorded ceremony anchor'
runs="$(release_gh run list --repo "$CANONPRIMS_REPOSITORY" --workflow release.yml --branch "$tag" --limit 100 \
    --json databaseId,headSha,conclusion,event \
    --jq "[.[] | select(.headSha == \"$commit\" and .conclusion == \"success\" and .event == \"push\") | .databaseId]")"
run="${CANONPRIMS_RELEASE_RUN_ID:-}"
if [[ -n "$run" ]]; then
    [[ "$run" =~ ^[1-9][0-9]*$ ]] || die 'invalid selected run'
    jq -e --argjson run "$run" 'index($run) != null' <<<"$runs" >/dev/null || die 'selected run is not successful for this tag and commit'
else
    [[ "$(jq length <<<"$runs")" == 1 ]] || die 'select an exact successful run with CANONPRIMS_RELEASE_RUN_ID'
    run="$(jq -r '.[0]' <<<"$runs")"
fi
release_gh api "repos/$CANONPRIMS_REPOSITORY/actions/runs/$run" >"$scratch/run.json"
attempt="$(jq -r .run_attempt "$scratch/run.json")"
[[ "$attempt" =~ ^[1-9][0-9]*$ ]] || die 'invalid run attempt'
[[ -z "${CANONPRIMS_RELEASE_RUN_ATTEMPT:-}" || "$CANONPRIMS_RELEASE_RUN_ATTEMPT" == "$attempt" ]] || die 'requested attempt is not the current downloadable attempt'
jq -e --arg commit "$commit" --arg tag "$tag" \
    '.status == "completed" and .conclusion == "success" and .event == "push" and .head_sha == $commit and .head_branch == $tag and .path == ".github/workflows/release.yml"' "$scratch/run.json" >/dev/null || die 'workflow identity mismatch'
for suffix in linux-amd64 linux-arm64 darwin-arm64 windows-amd64 windows-arm64; do
    release_gh run download "$run" --repo "$CANONPRIMS_REPOSITORY" --name "cli-$suffix" --dir "$scratch/download/cli-$suffix"
done
release_gh run download "$run" --repo "$CANONPRIMS_REPOSITORY" --name sbom --dir "$scratch/download/sbom"
release_gh run download "$run" --repo "$CANONPRIMS_REPOSITORY" --name source --dir "$scratch/download/source"
release_gh run download "$run" --repo "$CANONPRIMS_REPOSITORY" --name release-identity --dir "$scratch/download/identity"
# A successful rerun during download must not silently change the attempt.
[[ "$(release_gh api "repos/$CANONPRIMS_REPOSITORY/actions/runs/$run" --jq .run_attempt)" == "$attempt" ]] || die 'run attempt changed during download'
jq -e --arg tag "$tag" --arg object "$object" --arg commit "$commit" \
    '(keys == ["commit", "object", "tag"]) and .tag == $tag and .object == $object and .commit == $commit' "$scratch/download/identity/release-identity.json" >/dev/null || die 'artifact tag object or commit mismatch'
[[ "$(find "$scratch/download" -name release-identity.json -type f | wc -l | tr -d ' ')" == 1 ]] || die 'duplicate or missing artifact identity'
while IFS= read -r -d '' file; do
    [[ -f "$file" && ! -L "$file" ]] || die 'unsafe artifact entry'
    name="${file##*/}"
    [[ "$name" != release-identity.json ]] || continue
    [[ ! -e "$dest/$name" ]] || die 'duplicate artifact basename'
    cp "$file" "$dest/$name"
done < <(find "$scratch/download" -mindepth 1 ! -type d -print0)
"$root/scripts/validate-release-assets.sh" "$dest" base
# The source archive's content must be exactly what this checkout archives from
# the verified commit. The tar streams are compared: git archive's tar layer is
# defined by the tree, while its gzip bytes may differ between git or zlib
# builds. The shipped bytes are the CI archive, covered by both manifests.
version="${tag#v}"
release_source_archive "$commit" "$version" "$scratch/source.tar.gz" || die 'local source archive build failed'
gzip -dc "$scratch/source.tar.gz" >"$scratch/source.local.tar" || die 'local source archive is not gzip'
gzip -dc "$dest/canonprims-${version}-src.tar.gz" >"$scratch/source.ci.tar" || die 'source archive is not gzip'
cmp -s "$scratch/source.local.tar" "$scratch/source.ci.tar" ||
    die 'source archive content differs from a local archive of the verified commit'
cp "$scratch/anchor" "$dest.anchor"
printf 'run=%s\nattempt=%s\n' "$run" "$attempt" >>"$dest.anchor"
require_published_anchor "$dest"
echo "[ok] staged exact tag object and commit from run $run attempt $attempt"
