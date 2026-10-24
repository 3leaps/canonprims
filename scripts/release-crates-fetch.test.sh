#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Mock remote/API state for the crate verification handoff: the exact run of
# the right workflow at the anchored commit, its current attempt, the record's
# identity and the archive digest each bind the fetch. Tag verification is
# tested on its own.
# shellcheck disable=SC2016 # Positional parameters expand in the child bash.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fixture="$scratch/repo"
git init -q "$fixture"
mkdir -p "$fixture/scripts" "$fixture/config/release" "$scratch/bin"
cp "$root/scripts/"{release-common.sh,release-gh.sh,release-crates-fetch.sh,release-crate-record.py} "$fixture/scripts/"
printf 'canonprims-core\ncanonprims-json\n' >"$fixture/config/release/publishable-crates.txt"
printf '1.2.3\n' >"$fixture/VERSION"
cat >"$fixture/scripts/release-verify-published-tag.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# The remote tags, as the real verifier would find them.
object=1111111111111111111111111111111111111111 module=3333333333333333333333333333333333333333
[[ "${MOVED:-0}" == 0 ]] || module=6666666666666666666666666666666666666666
[[ "$CANONPRIMS_EXPECTED_TAG_OBJECT" == "$object" && "$CANONPRIMS_EXPECTED_MODULE_TAG_OBJECT" == "$module" &&
	"$CANONPRIMS_EXPECTED_COMMIT" == "$FIXTURE_COMMIT" ]] || { echo 'error: published tags differ from the anchor' >&2; exit 1; }
printf 'tag=v1.2.3\nobject=%s\nmodule_object=%s\ncommit=%s\n' "$object" "$module" "$FIXTURE_COMMIT" >"$CANONPRIMS_ANCHOR_OUT"
SH
chmod +x "$fixture/scripts/"*.sh
git -C "$fixture" config user.name fixture
git -C "$fixture" config user.email fixture@example.invalid
git -C "$fixture" add -A
git -C "$fixture" commit -qm fixture
commit="$(git -C "$fixture" rev-parse HEAD)"
object=1111111111111111111111111111111111111111
module=3333333333333333333333333333333333333333
printf 'tag=v1.2.3\nobject=%s\nmodule_object=%s\ncommit=%s\n' "$object" "$module" "$commit" >"$scratch/ceremony.anchor"
cat >"$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FIXTURE_CALLS"
case "$1 $2" in
'run list')
	# The fixture answers only for the workflow and event the caller asks for.
	[[ "$*" == *"--workflow ${RUN_WORKFLOW:-release.yml} "* && "$*" == *"\"${RUN_EVENT:-push}\""* ]] || { echo '[]'; exit 0; }
	[[ "${MULTIPLE:-0}" == 0 ]] && echo '[7]' || echo '[7,8]' ;;
'api repos/3leaps/canonprims/actions/runs/7')
	if [[ "$*" == *'--jq'* ]]; then
		[[ "${ATTEMPT_MOVED:-0}" == 0 ]] && echo 2 || echo 3
	else
		printf '{"run_attempt":2,"status":"completed","conclusion":"success","event":"%s","head_sha":"%s","head_branch":"%s","path":".github/workflows/%s"}\n' \
			"${RUN_EVENT:-push}" "${RUN_SHA:-$FIXTURE_COMMIT}" "${RUN_BRANCH:-v1.2.3}" "${RUN_PATH:-${RUN_WORKFLOW:-release.yml}}"
	fi ;;
'run download')
	name= dir=
	while [[ $# -gt 0 ]]; do
		case "$1" in --name) name="$2"; shift ;; --dir) dir="$2"; shift ;; esac
		shift
	done
	crate="${name#crate-}"
	mkdir -p "$dir"
	printf 'package bytes of %s' "$crate" >"$dir/$crate-1.2.3.crate"
	digest="$(shasum -a 256 "$dir/$crate-1.2.3.crate" | cut -c1-64)"
	[[ "${TAMPER:-0}" == 0 ]] || printf x >>"$dir/$crate-1.2.3.crate"
	python3 - "$dir/$crate.identity.json" "$crate" "$digest" <<'PY'
import json, os, sys
r = {"format": "canonprims-crate-verification/v0", "repository": "3leaps/canonprims", "tag": "v1.2.3",
     "object": "1" * 40, "module_object": "3" * 40, "commit": os.environ["FIXTURE_COMMIT"],
     "crate": sys.argv[2], "version": "1.2.3", "cargo": "cargo 1.88.0", "registry": "crates-io",
     "sha256": sys.argv[3], "run_id": os.environ.get("RECORD_RUN", "7"), "run_attempt": os.environ.get("RECORD_ATTEMPT", "2")}
if os.environ.get("RECORD_MODULE"):
    r["module_object"] = os.environ["RECORD_MODULE"]
if os.environ.get("RECORD_REGISTRY"):
    r["registry"] = os.environ["RECORD_REGISTRY"]
json.dump(r, open(sys.argv[1], "w"))
PY
	[[ "${EXTRA:-0}" == 0 ]] || printf extra >"$dir/.extra"
	[[ "${LINK:-0}" == 0 ]] || { rm "$dir/$crate-1.2.3.crate"; ln -s "$FIXTURE_REPO/VERSION" "$dir/$crate-1.2.3.crate"; } ;;
*) exit 1 ;;
esac
SH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" FIXTURE_CALLS="$scratch/calls" FIXTURE_COMMIT="$commit" FIXTURE_REPO="$fixture"
export CANONPRIMS_RELEASE_ANCHOR_FILE="$scratch/ceremony.anchor" CANONPRIMS_RELEASE_TAG=v1.2.3
cd "$fixture"
fetch() {
	rm -rf "$scratch/records"
	./scripts/release-crates-fetch.sh v1.2.3 "$@" "$scratch/records"
}
refused() {
	local reason="$1"
	shift
	if env "$@" bash -c 'rm -rf "$1/records"; ./scripts/release-crates-fetch.sh v1.2.3 "${CRATE:-canonprims-core}" "$1/records"' _ "$scratch" >"$scratch/output" 2>&1; then
		echo "error: fetch accepted: $*" >&2
		exit 1
	fi
	grep -q -- "$reason" "$scratch/output" || {
		echo "error: refused for another reason than '$reason': $*" >&2
		cat "$scratch/output" >&2
		exit 1
	}
}

# core comes from the tag push run of release.yml; json from a crates-verify.yml dispatch.
fetch canonprims-core >/dev/null
[[ -f "$scratch/records/canonprims-core-1.2.3.crate" && -f "$scratch/records/canonprims-core.identity.json" ]]
RUN_WORKFLOW=crates-verify.yml RUN_EVENT=workflow_dispatch fetch canonprims-json >/dev/null
[[ -f "$scratch/records/canonprims-json-1.2.3.crate" ]]
refused 'select an exact successful run' CRATE=canonprims-json
refused 'select an exact successful run' RUN_WORKFLOW=crates-verify.yml RUN_EVENT=workflow_dispatch
refused 'is not a published crate' CRATE=canonprims-cli
refused 'select an exact successful run' MULTIPLE=1
refused 'is not a successful release.yml run' MULTIPLE=1 CANONPRIMS_CRATE_RUN_ID=9
refused 'workflow identity mismatch' RUN_SHA=0000000000000000000000000000000000000000
refused 'workflow identity mismatch' RUN_BRANCH=main
refused 'workflow identity mismatch' RUN_PATH=ci.yml
refused 'run attempt changed during download' ATTEMPT_MOVED=1
refused 'record names another run or attempt' RECORD_RUN=8
refused 'record names another run or attempt' RECORD_ATTEMPT=1
refused 'module_object differs' RECORD_MODULE=4444444444444444444444444444444444444444
refused 'registry differs' RECORD_REGISTRY=testreg
refused 'does not have the recorded digest' TAMPER=1
refused 'other entries than the package' EXTRA=1
refused 'unsafe artifact entry' LINK=1
refused 'ceremony anchor' -u CANONPRIMS_RELEASE_ANCHOR_FILE
sed 's/^module_object=.*/module_object=5555555555555555555555555555555555555555/' "$scratch/ceremony.anchor" >"$scratch/other.anchor"
refused 'published tags differ from the anchor' CANONPRIMS_RELEASE_ANCHOR_FILE="$scratch/other.anchor"
refused 'published tags differ from the anchor' MOVED=1
# An existing record is never overwritten.
fetch canonprims-core >/dev/null
if ./scripts/release-crates-fetch.sh v1.2.3 canonprims-core "$scratch/records" >"$scratch/output" 2>&1; then
	echo 'error: fetch overwrote an existing record' >&2
	exit 1
fi
grep -q 'clean explicitly first' "$scratch/output"
echo '[ok] crate verification handoff binds run, attempt, record identity and digest'
