#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Read-only GitHub repository and OIDC environment preflight check:
#   1. Both OIDC publishing environments (publish-pypi and publish-npm) must
#      require maintainer review solely from @3leapsdave (no alternate reviewers,
#      can_admins_bypass: false) and restrict deployments to a custom tag policy
#      of `v*` only (`protected_branches: false`, `custom_branch_policies: true`).
#   2. The active repository `Tag Publish Protection` ruleset must protect
#      `refs/tags/v*` against creation, update, deletion, and non_fast_forward
#      with only OrganizationAdmin bypass.
#   3. Immutable releases must be enabled on the repository via the authoritative
#      `repos/3leaps/canonprims/immutable-releases` settings endpoint.
#
# Usage: scripts/release-github-preflight.sh [--read-only | --full]
set -euo pipefail

die() {
	echo "error: $*" >&2
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--full | --read-only) ;;
	*) die "usage: release-github-preflight.sh [--read-only | --full]" ;;
	esac
	shift
done

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
# shellcheck source=scripts/release-common.sh
source "$root/scripts/release-common.sh"
# shellcheck source=scripts/release-tag-common.sh
source "$root/scripts/release-tag-common.sh"

for cmd in gh jq; do
	command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
done
tag_origin

check_environment() {
	local env_name="$1" env_json policy_json
	env_json="$(release_gh api "repos/$CANONPRIMS_REPOSITORY/environments/$env_name" 2>/dev/null)" ||
		die "could not read GitHub environment $env_name on $CANONPRIMS_REPOSITORY"
	jq -e --arg want_name "$env_name" '
		.name == $want_name and
		.can_admins_bypass == false and
		.deployment_branch_policy == {"protected_branches": false, "custom_branch_policies": true} and
		([.protection_rules[]? | select(.type == "branch_policy")] | length) == 1 and
		([.protection_rules[]? | select(.type == "required_reviewers")] | length) == 1 and
		(
			[
				.protection_rules[]
				| select(.type == "required_reviewers")
				| .reviewers[]?
				| {type: .type, login: .reviewer.login}
			] == [{"type": "User", "login": "3leapsdave"}]
		)
	' >/dev/null <<<"$env_json" ||
		die "environment $env_name must require exact reviewer @3leapsdave, can_admins_bypass=false, and custom_branch_policies only"

	policy_json="$(release_gh api "repos/$CANONPRIMS_REPOSITORY/environments/$env_name/deployment-branch-policies" 2>/dev/null)" ||
		die "could not read deployment-branch-policies for environment $env_name"
	jq -e '
		.total_count == 1 and
		([.branch_policies[] | {name: .name, type: .type}] == [{"name": "v*", "type": "tag"}])
	' >/dev/null <<<"$policy_json" ||
		die "environment $env_name deployment policy must allow only tag pattern v*"
	echo "[ok] GitHub environment $env_name: required reviewer @3leapsdave + can_admins_bypass=false + tag-only policy v*"
}

check_tag_ruleset() {
	local rulesets_json ruleset_id ruleset_json
	rulesets_json="$(release_gh api "repos/$CANONPRIMS_REPOSITORY/rulesets?per_page=100" 2>/dev/null)" ||
		die "could not read rulesets for $CANONPRIMS_REPOSITORY"
	ruleset_id="$(jq -r '
		[ .[] | select(.name == "Tag Publish Protection") ] |
		if length == 1 then .[0].id else empty end
	' <<<"$rulesets_json")"
	[[ -n "$ruleset_id" ]] || die "expected exactly one 'Tag Publish Protection' ruleset on $CANONPRIMS_REPOSITORY"

	ruleset_json="$(release_gh api "repos/$CANONPRIMS_REPOSITORY/rulesets/$ruleset_id" 2>/dev/null)" ||
		die "could not read ruleset $ruleset_id on $CANONPRIMS_REPOSITORY"
	jq -e --arg repo "$CANONPRIMS_REPOSITORY" '
		.name == "Tag Publish Protection" and
		.source_type == "Repository" and
		.source == $repo and
		.target == "tag" and
		.enforcement == "active" and
		.conditions.ref_name.exclude == [] and
		(.conditions.ref_name.include | index("refs/tags/v*") != null) and
		all(.conditions.ref_name.include[]; . == "refs/tags/v*" or . == "refs/tags/go/*/v*") and
		(.rules | length) == 4 and
		([.rules[].type] | sort) == ["creation", "deletion", "non_fast_forward", "update"] and
		.bypass_actors == [{"actor_id": null, "actor_type": "OrganizationAdmin", "bypass_mode": "always"}]
	' >/dev/null <<<"$ruleset_json" ||
		die "ruleset 'Tag Publish Protection' does not match the required tag protection policy"
	echo "[ok] GitHub ruleset 'Tag Publish Protection': active on refs/tags/v*"
}

check_immutable_releases() {
	local imm_json
	imm_json="$(release_gh api "repos/$CANONPRIMS_REPOSITORY/immutable-releases" 2>/dev/null)" ||
		die "could not read repos/$CANONPRIMS_REPOSITORY/immutable-releases (authoritative immutable_releases setting required)"
	jq -e '.enabled == true' >/dev/null <<<"$imm_json" ||
		die "immutable_releases is not enabled on $CANONPRIMS_REPOSITORY"
	echo "[ok] GitHub immutable_releases: enabled (verified via /immutable-releases)"
}

check_environment publish-pypi
check_environment publish-npm
check_tag_ruleset
check_immutable_releases
