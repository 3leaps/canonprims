#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Guard the reviewed release workflow's read-only artifact boundary: the
# workflow passes, and every listed mutation of it is refused.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# YAML is read by the yamlprims CLI (scripts/yaml_json.py); the loader's own
# failure modes are covered by yaml-json.test.sh.
[[ -n "${CANONPRIMS_YAMLPRIMS_BIN:-}" ]] || {
	echo 'error: the workflow permission test needs CANONPRIMS_YAMLPRIMS_BIN (absolute path to the yamlprims CLI)' >&2
	exit 1
}
# Every publishing workflow is pinned by digest (release-workflow-pin.py);
# the semantic checks below are a second layer that explains why an edit
# would be refused. The pin is the boundary.
(cd "$root" && python3 -B -E scripts/release-workflow-pin.py check) >/dev/null
for workflow in release crates-verify registry-publish; do
	PYTHONDONTWRITEBYTECODE=1 python3 "$root/scripts/release-workflow-permissions.py" mutations "$root/.github/workflows/$workflow.yml"
done
# Pin controls, on a scratch repository holding the real workflows and pin.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo/.github/workflows" "$repo/.github/actions/make-check" "$repo/config/release"
cp "$root"/.github/workflows/*.yml "$repo/.github/workflows/"
cp "$root/.github/actions/make-check/action.yml" "$repo/.github/actions/make-check/"
cp "$root/config/release/release-workflow.sha256" "$repo/config/release/"
git -C "$repo" init -q -b main
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" config commit.gpgsign false
git -C "$repo" add -A
git -C "$repo" commit -qm base
# Edit in place without leaving a backup file among the workflows.
sed_in_place() {
	local script="$1" file="$2"
	sed "$script" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}
pin() { (cd "$repo" && PYTHONDONTWRITEBYTECODE=1 python3 -B -E "$root/scripts/release-workflow-pin.py" "$@") >"$scratch/out" 2>&1; }
refused() {
	if pin "${@:2}"; then
		echo "error: workflow pin accepted: $1" >&2
		exit 1
	fi
	grep -q "$1" "$scratch/out" || { cat "$scratch/out" >&2; exit 1; }
}
pin_with() {
	(cd "$repo" && for f in .github/actions/make-check/action.yml .github/workflows/ci.yml .github/workflows/crates-verify.yml .github/workflows/registry-publish.yml .github/workflows/release.yml; do
		printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -c1-64)" "$f"
	done) >"$repo/config/release/release-workflow.sha256"
}
pin check
pin verify-commit HEAD
# A workflow edited without its pin fails, however small the edit.
sed_in_place 's/timeout-minutes: 15/timeout-minutes: 16/' "$repo/.github/workflows/release.yml"
refused 'differs from its reviewed digest' check
git -C "$repo" checkout -q -- .github
# A local action edited without its pin fails: it changes what a workflow runs.
printf '# changed\n' >>"$repo/.github/actions/make-check/action.yml"
refused 'action.yml differs from its reviewed digest' check
git -C "$repo" checkout -q -- .github
printf 'name: x\n' >"$repo/.github/actions/make-check/extra.yml"
refused 'extra.yml is not pinned' check
rm "$repo/.github/actions/make-check/extra.yml"
# The pin edited without the workflow fails.
git -C "$repo" checkout -q -- .github
sed_in_place '1s/^./0/' "$repo/config/release/release-workflow.sha256"
refused 'differs from its reviewed digest' check
git -C "$repo" checkout -q -- config
# Both edited together, as one reviewed change, passes.
sed_in_place 's/timeout-minutes: 15/timeout-minutes: 16/' "$repo/.github/workflows/release.yml"
pin_with
pin check
git -C "$repo" checkout -q -- .
# Every workflow file is pinned, whatever its triggers (a plain push, push
# with no filter, create, or anything else can run on a tag).
for body in 'on: push' 'on: [push]' 'on:\n  push:\n' 'on:\n  push: {}\n' 'on:\n  push:\n    paths: [x]\n' 'on: create' 'on:\n  workflow_dispatch:\n'; do
	printf "$body\npermissions:\n  contents: read\njobs: {}\n" >"$repo/.github/workflows/extra.yml"
	refused 'extra.yml is not pinned' check
done
rm "$repo/.github/workflows/extra.yml"
# A pinned workflow must be read-only, at the top and in every job.
sed_in_place 's/^  contents: read$/  contents: write/' "$repo/.github/workflows/ci.yml"
pin_with
refused 'ci.yml must declare top-level permissions: contents: read' check
git -C "$repo" checkout -q -- .
sed_in_place 's/^    timeout-minutes: 15$/    timeout-minutes: 15\n    permissions:\n      id-token: write/' "$repo/.github/workflows/release.yml"
pin_with
refused 'grants more than read' check
git -C "$repo" checkout -q -- .
# registry-publish.yml may grant id-token: write only on publish-pypi and
# publish-npm when bound to their matching environments and workflow_dispatch.
sed_in_place 's/^    environment: publish-pypi$/    environment: other-env/' "$repo/.github/workflows/registry-publish.yml"
pin_with
refused 'grants more than read' check
git -C "$repo" checkout -q -- .
sed_in_place 's/^  workflow_dispatch:$/  push:\n  workflow_dispatch:/' "$repo/.github/workflows/registry-publish.yml"
pin_with
refused 'must trigger on workflow_dispatch only' check
git -C "$repo" checkout -q -- .
pin check
# A module beside either checker is never imported (a script's own directory
# is the one path Python adds by itself); only the YAML helper is loaded, by
# its path.
mkdir -p "$scratch/shadow" "$scratch/config"
cp "$root/scripts/release-workflow-pin.py" "$root/scripts/release-workflow-permissions.py" "$root/scripts/yaml_json.py" "$scratch/shadow/"
cp "$root/config/yamlprims-cli.txt" "$scratch/config/"
for module in yaml json re subprocess tempfile threading hashlib copy; do
	printf 'raise SystemExit("shadow %s imported")\n' "$module" >"$scratch/shadow/$module.py"
done
(cd "$repo" && python3 -B -E "$scratch/shadow/release-workflow-pin.py" check) >"$scratch/out" 2>&1 || true
if grep -q 'shadow' "$scratch/out"; then
	echo 'error: a yaml.py beside the pin checker was imported' >&2
	exit 1
fi
grep -q 'every workflow matches' "$scratch/out" || { cat "$scratch/out" >&2; exit 1; }
python3 -B -E "$scratch/shadow/release-workflow-permissions.py" check "$root/.github/workflows/release.yml" >"$scratch/out" 2>&1 || true
if grep -q 'shadow' "$scratch/out"; then
	echo 'error: a yaml.py beside the workflow checker was imported' >&2
	exit 1
fi
[[ ! -s "$scratch/out" ]] || { cat "$scratch/out" >&2; exit 1; }
rm "$scratch/shadow/"{yaml,json,re,subprocess,tempfile,threading,hashlib,copy}.py
# The mutation guards: an empty case list, or a case that leaves the workflow
# unchanged, fails the run rather than passing silently.
perm="$scratch/shadow/release-workflow-permissions.py"
cp "$root/scripts/release-workflow-permissions.py" "$perm"
mutation_guard() {
	local expected="$1"
	if python3 -B -E "$perm" mutations "$root/.github/workflows/release.yml" >"$scratch/out" 2>&1; then
		echo "error: mutation guard did not fire: $expected" >&2
		exit 1
	fi
	grep -q "$expected" "$scratch/out" || { cat "$scratch/out" >&2; exit 1; }
	cp "$root/scripts/release-workflow-permissions.py" "$perm"
}
sed_in_place 's/            cases = mutations(text)$/            cases = []/' "$perm"
mutation_guard 'no mutation cases'
sed_in_place 's/        text.replace("decernor-ci-sha256.txt", "x.txt"),$/        text.replace("no-such-anchor", "x.txt"),/' "$perm"
mutation_guard 'does not change the workflow'
# The ceremony reads the tagged commit, not the working tree: an uncommitted
# fix does not rescue a bad commit, and an uncommitted edit does not break a
# good one.
sed_in_place 's/timeout-minutes: 15/timeout-minutes: 16/' "$repo/.github/workflows/release.yml"
pin verify-commit HEAD
git -C "$repo" add .github/workflows/release.yml
git -C "$repo" commit -qm unreviewed
git -C "$repo" checkout -q HEAD~1 -- .github/workflows/release.yml
refused 'differs from its reviewed digest' verify-commit HEAD
echo '[ok] read-only workflow boundary and mutation controls'
