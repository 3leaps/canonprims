#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Restore the remote annotated tag ref after actions/checkout peels it locally.
#
# The tag object is resolved through the GitHub REST API with the job token
# (GITHUB_TOKEN, read-only in every workflow), not by anonymous `git ls-remote`,
# so the lookup works on a private repository without persisting checkout
# credentials. The release workflows run no GitHub CLI, so this uses curl. The
# object is then made the runner-local ref and bound to HEAD.
set -euo pipefail

die() {
    echo "error: $*" >&2
    exit 1
}

repo=3leaps/canonprims
tag="${CANONPRIMS_RELEASE_TAG:-}"
[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'canonical release tag required'
[[ -n "${GITHUB_TOKEN:-}" ]] || die 'GITHUB_TOKEN (the job token) is required for the tag lookup'
case "$(git config --get remote.origin.url)" in
"https://github.com/$repo" | "https://github.com/$repo.git") ;;
*) die 'unexpected release origin' ;;
esac
api="${CANONPRIMS_GITHUB_API:-https://api.github.com}"
[[ "$api" == https://* ]] || die 'the GitHub API must be reached over https'

# The token travels in a curl config on stdin, never in argv or a file.
ref_json="$(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" |
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --retry 3 --config - \
        --header 'Accept: application/vnd.github+json' \
        "$api/repos/$repo/git/ref/tags/$tag")" || die 'remote release tag is absent'
remote_type="$(jq -r '.object.type // empty' <<<"$ref_json")" || die 'remote tag lookup returned invalid JSON'
remote_object="$(jq -r '.object.sha // empty' <<<"$ref_json")"
[[ "$(jq -r '.ref // empty' <<<"$ref_json")" == "refs/tags/$tag" ]] || die 'remote tag lookup named another ref'
[[ "$remote_type" == tag ]] || die 'remote release tag must be annotated'
[[ "$remote_object" =~ ^[0-9a-f]{40}$ ]] || die 'remote tag object is invalid'
if [[ -n "${CANONPRIMS_EXPECTED_TAG_OBJECT+x}" ]]; then
    [[ "$CANONPRIMS_EXPECTED_TAG_OBJECT" =~ ^[0-9a-f]{40}$ &&
        "$remote_object" == "$CANONPRIMS_EXPECTED_TAG_OBJECT" ]] ||
        die 'remote tag object differs from validated object'
fi

# A full-history checkout already holds the tag object. Otherwise fetch it with
# the job token for this one command only; checkout credentials stay
# unpersisted. Either way only the runner-local ref changes, and the checks
# below bind it to the API answer.
if [[ "$(git cat-file -t "$remote_object" 2>/dev/null || true)" == tag ]]; then
    git update-ref "refs/tags/$tag" "$remote_object"
else
    # The header travels in the environment, not argv, and its encoded form is
    # masked because the runner masks only the raw token.
    auth="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"
    [[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::add-mask::$auth"
    GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0='http.https://github.com/.extraheader' \
        GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth" \
        git fetch --quiet --no-tags origin "+refs/tags/$tag:refs/tags/$tag"
fi
[[ "$(git rev-parse "refs/tags/$tag")" == "$remote_object" &&
    "$(git cat-file -t "refs/tags/$tag")" == tag &&
    "$(git rev-parse "refs/tags/$tag^{}")" == "$(git rev-parse HEAD)" ]] ||
    die 'runner-local tag is not the remote annotated tag at HEAD'
echo "[ok] runner-local annotated tag restored for $tag"
