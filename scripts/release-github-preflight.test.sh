#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Synthetic controls for scripts/release-github-preflight.sh.
set -euo pipefail
unset GH_HOST GH_REPO GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN

root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rc=$?; rm -rf "$scratch"; exit "$rc"' EXIT

repo="$scratch/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" remote add origin https://github.com/3leaps/canonprims.git
mkdir -p "$repo/scripts" "$scratch/api" "$scratch/bin"
cp "$root/scripts/"{release-github-preflight.sh,release-common.sh,release-gh.sh,release-tag-common.sh} "$repo/scripts/"
chmod +x "$repo/scripts/release-github-preflight.sh"
printf '0.1.3\n' >"$repo/VERSION"

write_pristine_api() {
	for env_name in publish-pypi publish-npm; do
		cat >"$scratch/api/env-$env_name.json" <<JSON
{
  "name": "$env_name",
  "can_admins_bypass": false,
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  },
  "protection_rules": [
    {
      "type": "required_reviewers",
      "reviewers": [
        {
          "type": "User",
          "reviewer": {"login": "3leapsdave"}
        }
      ]
    },
    {"type": "branch_policy"}
  ]
}
JSON
		cat >"$scratch/api/policies-$env_name.json" <<'JSON'
{
  "total_count": 1,
  "branch_policies": [
    {"name": "v*", "type": "tag"}
  ]
}
JSON
	done

	cat >"$scratch/api/rulesets.json" <<'JSON'
[
  {
    "id": 25798917,
    "name": "Tag Publish Protection",
    "target": "tag",
    "source_type": "Repository",
    "source": "3leaps/canonprims",
    "enforcement": "active"
  }
]
JSON

	cat >"$scratch/api/ruleset-25798917.json" <<'JSON'
{
  "id": 25798917,
  "name": "Tag Publish Protection",
  "target": "tag",
  "source_type": "Repository",
  "source": "3leaps/canonprims",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "exclude": [],
      "include": ["refs/tags/v*", "refs/tags/go/*/v*"]
    }
  },
  "rules": [
    {"type": "creation"},
    {"type": "update"},
    {"type": "deletion"},
    {"type": "non_fast_forward"}
  ],
  "bypass_actors": [
    {"actor_id": null, "actor_type": "OrganizationAdmin", "bypass_mode": "always"}
  ]
}
JSON

	cat >"$scratch/api/immutable-releases.json" <<'JSON'
{"enabled": true}
JSON
}

cat >"$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "api" ]] || exit 1
shift
endpoint=""
for arg in "$@"; do
	case "$arg" in
	--paginate | --slurp | --hostname | github.com) ;;
	repos/*) endpoint="$arg" ;;
	esac
done
case "$endpoint" in
repos/3leaps/canonprims/environments/publish-pypi)
	cat "$FIXTURE_API/env-publish-pypi.json"
	;;
repos/3leaps/canonprims/environments/publish-pypi/deployment-branch-policies)
	cat "$FIXTURE_API/policies-publish-pypi.json"
	;;
repos/3leaps/canonprims/environments/publish-npm)
	cat "$FIXTURE_API/env-publish-npm.json"
	;;
repos/3leaps/canonprims/environments/publish-npm/deployment-branch-policies)
	cat "$FIXTURE_API/policies-publish-npm.json"
	;;
"repos/3leaps/canonprims/rulesets?per_page=100")
	cat "$FIXTURE_API/rulesets.json"
	;;
repos/3leaps/canonprims/rulesets/25798917)
	cat "$FIXTURE_API/ruleset-25798917.json"
	;;
repos/3leaps/canonprims/immutable-releases)
	[[ "${FIXTURE_IMMUTABLE_403:-0}" == "0" ]] || exit 1
	cat "$FIXTURE_API/immutable-releases.json"
	;;
*)
	echo "unexpected endpoint: $endpoint" >&2
	exit 1
	;;
esac
SH
chmod +x "$scratch/bin/gh"

run_preflight() {
	(cd "$repo" && PATH="$scratch/bin:$PATH" FIXTURE_API="$scratch/api" "$repo/scripts/release-github-preflight.sh" "$@") >"$scratch/out" 2>&1
}

expect_refused() {
	local pattern="$1"
	shift
	if run_preflight "$@"; then
		echo "error: preflight accepted, expected refusal matching '$pattern'" >&2
		cat "$scratch/out" >&2
		exit 1
	fi
	grep -Eq -- "$pattern" "$scratch/out" || {
		echo "error: preflight failed for unexpected reason (want '$pattern')" >&2
		cat "$scratch/out" >&2
		exit 1
	}
}

write_pristine_api
run_preflight
run_preflight --full

# Unreadable /immutable-releases fails closed in all modes (never falls back to historical releases).
FIXTURE_IMMUTABLE_403=1 expect_refused "could not read .*/immutable-releases"
FIXTURE_IMMUTABLE_403=1 expect_refused "could not read .*/immutable-releases" --full

# Environment negative controls: missing reviewer, extra alternate reviewer, can_admins_bypass=true, branch policy.
jq '.protection_rules = [{"type": "branch_policy"}]' "$scratch/api/env-publish-pypi.json" >"$scratch/api/tmp.json"
mv "$scratch/api/tmp.json" "$scratch/api/env-publish-pypi.json"
expect_refused "environment publish-pypi must require exact reviewer @3leapsdave"
write_pristine_api

jq '.protection_rules[0].reviewers += [{"type": "User", "reviewer": {"login": "otheruser"}}]' \
	"$scratch/api/env-publish-pypi.json" >"$scratch/api/tmp.json"
mv "$scratch/api/tmp.json" "$scratch/api/env-publish-pypi.json"
expect_refused "environment publish-pypi must require exact reviewer @3leapsdave"
write_pristine_api

jq '.can_admins_bypass = true' "$scratch/api/env-publish-pypi.json" >"$scratch/api/tmp.json"
mv "$scratch/api/tmp.json" "$scratch/api/env-publish-pypi.json"
expect_refused "environment publish-pypi must require exact reviewer @3leapsdave, can_admins_bypass=false"
write_pristine_api

jq '.deployment_branch_policy.protected_branches = true' "$scratch/api/env-publish-npm.json" >"$scratch/api/tmp.json"
mv "$scratch/api/tmp.json" "$scratch/api/env-publish-npm.json"
expect_refused "environment publish-npm must require exact reviewer @3leapsdave"
write_pristine_api

jq '.branch_policies = [{"name": "main", "type": "branch"}]' "$scratch/api/policies-publish-npm.json" >"$scratch/api/tmp.json"
mv "$scratch/api/tmp.json" "$scratch/api/policies-publish-npm.json"
expect_refused "environment publish-npm deployment policy must allow only tag pattern v\\*"
write_pristine_api

jq '.total_count = 2 | .branch_policies += [{"name": "main", "type": "branch"}]' "$scratch/api/policies-publish-npm.json" >"$scratch/api/tmp.json"
mv "$scratch/api/tmp.json" "$scratch/api/policies-publish-npm.json"
expect_refused "environment publish-npm deployment policy must allow only tag pattern v\\*"
write_pristine_api

# Tag ruleset negative controls.
jq '.enforcement = "disabled"' "$scratch/api/ruleset-25798917.json" >"$scratch/api/tmp.json"
mv "$scratch/api/tmp.json" "$scratch/api/ruleset-25798917.json"
expect_refused "ruleset 'Tag Publish Protection' does not match"
write_pristine_api

jq '.rules = [{"type": "creation"}, {"type": "deletion"}]' "$scratch/api/ruleset-25798917.json" >"$scratch/api/tmp.json"
mv "$scratch/api/tmp.json" "$scratch/api/ruleset-25798917.json"
expect_refused "ruleset 'Tag Publish Protection' does not match"
write_pristine_api

jq 'del(.bypass_actors)' "$scratch/api/ruleset-25798917.json" >"$scratch/api/tmp.json"
mv "$scratch/api/tmp.json" "$scratch/api/ruleset-25798917.json"
expect_refused "ruleset 'Tag Publish Protection' does not match"
write_pristine_api

# Immutable releases negative controls.
jq '.enabled = false' "$scratch/api/immutable-releases.json" >"$scratch/api/tmp.json"
mv "$scratch/api/tmp.json" "$scratch/api/immutable-releases.json"
expect_refused "immutable_releases is not enabled"
write_pristine_api

echo '[ok] GitHub environment, tag ruleset, and immutable_releases preflight controls'
