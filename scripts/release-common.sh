#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Shared release asset and repository invariants.

set -euo pipefail

# shellcheck source=scripts/release-gh.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-gh.sh"

CANONPRIMS_REPOSITORY="3leaps/canonprims"

release_repo_root() {
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
}

release_version() {
    local repo_path
    repo_path="$(release_repo_root)"
    local version
    version="$(cat "$repo_path/VERSION")"
    if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        echo "error: VERSION must contain one stable semantic version" >&2
        return 1
    fi
    printf '%s\n' "$version"
}

release_tag() {
    local tag="${1:-${CANONPRIMS_RELEASE_TAG:-}}"
    if [[ -z "$tag" ]]; then
        echo "error: CANONPRIMS_RELEASE_TAG is required" >&2
        return 1
    fi
    if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        echo "error: release tag must be canonical vX.Y.Z" >&2
        return 1
    fi
    printf '%s\n' "$tag"
}

release_base_assets() {
    local version
    version="$(release_tag)"
    version="${version#v}"
    printf '%s\n' LICENSE-APACHE LICENSE-MIT "sbom-${version}.cdx.json" "canonprims-${version}-src.tar.gz"
    local platform ext
    for platform in linux-amd64 linux-arm64 darwin-arm64 windows-amd64 windows-arm64; do
        ext=tar.gz
        [[ "$platform" == windows-* ]] && ext=zip
        printf 'canon-%s-%s.%s\n' "$version" "$platform" "$ext"
    done
    release_binding_assets "$version"
}

# The Python wheels (abi3, CPython 3.10 and later) and the npm package the
# tag workflow builds and tests. Names are exact: maturin's platform tags and
# npm pack's scoped tarball name.
release_binding_assets() {
    local version="$1" tag
    for tag in manylinux_2_17_x86_64.manylinux2014_x86_64 manylinux_2_17_aarch64.manylinux2014_aarch64 \
        macosx_11_0_arm64 win_amd64 win_arm64; do
        printf 'canonprims-%s-cp310-abi3-%s.whl\n' "$version" "$tag"
    done
    printf '3leaps-canonprims-%s.tgz\n' "$version"
}

# The source archive of a commit: git archive of the whole tree under a
# versioned prefix. The tag workflow builds it; the maintainer rebuilds it from
# the same commit and requires identical bytes.
release_source_archive() {
    local commit="$1" version="$2" output="$3"
    git -C "$(release_repo_root)" archive --format=tar.gz --prefix="canonprims-${version}/" \
        -o "$output" "$commit"
}

# Run Cargo for a registry step in an isolated home: a cleared environment,
# HOME and CARGO_HOME inside ISOLATED (an empty per-ceremony directory, so no
# operator Cargo configuration, credentials or network settings are read), the
# operator's rustup toolchains with the toolchain pinned, and the registry
# token only with --with-token. Anything that runs during a build (a build
# script or macro in a dependency) therefore sees no credential; uploads use
# --no-verify so nothing is compiled while the token is present.
# Usage: release_cargo <msrv> <isolated-dir> [--with-token] <cargo args...>
release_cargo() {
    local msrv="$1" isolated="$2" cargo_bin rustup_home token=()
    shift 2
    if [[ "${1:-}" == --with-token ]]; then
        shift
        [[ -n "${CARGO_REGISTRY_TOKEN:-}" ]] || {
            echo 'error: CARGO_REGISTRY_TOKEN is required for an upload' >&2
            return 1
        }
        token=("CARGO_REGISTRY_TOKEN=$CARGO_REGISTRY_TOKEN")
    fi
    [[ "$isolated" == /* && -d "$isolated" && ! -L "$isolated" ]] || {
        echo 'error: release_cargo needs an isolated absolute directory' >&2
        return 1
    }
    cargo_bin="$(command -v cargo)" || { echo 'error: cargo is required' >&2; return 1; }
    rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
    mkdir -p "$isolated/home" "$isolated/cargo"
    env -i PATH="$PATH" HOME="$isolated/home" CARGO_HOME="$isolated/cargo" RUSTUP_HOME="$rustup_home" \
        RUSTUP_TOOLCHAIN="$msrv" CARGO_TERM_COLOR=never ${token[@]+"${token[@]}"} \
        "$cargo_bin" "$@"
}

release_signable_assets() {
    local tag
    tag="$(release_tag)"
    release_base_assets
    printf 'release-notes-%s.md\n' "$tag"
    printf '%s\n' expected-fingerprints.txt expected-fingerprints.ndjson canonprims-minisign.pub canonprims-release-signing-key.asc
}

release_checksummed_assets() {
    release_signable_assets
    printf '%s\n' SHA256SUMS SHA512SUMS
}

release_signed_without_keys_assets() {
    release_checksummed_assets
    # Both manifests carry both signatures: minisign and OpenPGP.
    printf '%s\n' SHA256SUMS.minisig SHA512SUMS.minisig SHA256SUMS.asc SHA512SUMS.asc
}

release_signed_assets() {
    release_signed_without_keys_assets
}

assert_exact_directory_inventory() (
    local directory="$1"
    local producer="$2"
    if [[ ! -d "$directory" || -L "$directory" ]]; then
        echo "error: release directory is absent or unsafe" >&2
        return 1
    fi

    local expected_file actual_file
    expected_file="$(mktemp "${TMPDIR:-/tmp}/canonprims-expected.XXXXXX")"
    actual_file="$(mktemp "${TMPDIR:-/tmp}/canonprims-actual.XXXXXX")"
    trap 'rm -f "$expected_file" "$actual_file"' EXIT

    "$producer" | LC_ALL=C sort >"$expected_file"
    find "$directory" -mindepth 1 -maxdepth 1 -print |
        while IFS= read -r entry; do basename "$entry"; done |
        LC_ALL=C sort >"$actual_file"

    if ! cmp -s "$expected_file" "$actual_file"; then
        echo "error: release directory inventory mismatch" >&2
        diff -u "$expected_file" "$actual_file" >&2 || true
        return 1
    fi
    while IFS= read -r name; do
        if [[ ! -f "$directory/$name" || ! -s "$directory/$name" || -L "$directory/$name" ]]; then
            echo "error: release asset is not a regular file: $name" >&2
            return 1
        fi
    done <"$expected_file"
)

assert_github_release_state() (
    local expected_assets_producer="$1" inventory_mode="${2:-exact}"
    local tag repo_path tag_commit
    tag="$(release_tag)"
    repo_path="$(release_repo_root)"
    tag_commit="$(git -C "$repo_path" rev-parse "refs/tags/${tag}^{}")"

    if [[ -n "${GH_REPO+x}" ]]; then
        echo "error: GH_REPO must be unset; repository authority is fixed" >&2
        return 1
    fi
    for command_name in gh jq; do
        command -v "$command_name" >/dev/null 2>&1 || {
            echo "error: required release command is unavailable" >&2
            return 1
        }
    done
    if [[ "$(release_gh repo view "$CANONPRIMS_REPOSITORY" \
        --json nameWithOwner --jq .nameWithOwner)" != "$CANONPRIMS_REPOSITORY" ]]; then
        echo "error: GitHub repository identity mismatch" >&2
        return 1
    fi

    local state expected actual
    state="$(mktemp "${TMPDIR:-/tmp}/canonprims-release-state.XXXXXX")"
    expected="$(mktemp "${TMPDIR:-/tmp}/canonprims-remote-expected.XXXXXX")"
    actual="$(mktemp "${TMPDIR:-/tmp}/canonprims-remote-actual.XXXXXX")"
    trap 'rm -f "$state" "$expected" "$actual"' EXIT
    release_gh release view "$tag" --repo "$CANONPRIMS_REPOSITORY" \
        --json tagName,targetCommitish,isDraft,assets >"$state"

    if [[ "$(jq -r .tagName "$state")" != "$tag" ||
    "$(jq -r .targetCommitish "$state")" != "$tag_commit" ||
    "$(jq -r .isDraft "$state")" != "true" ]]; then
        echo "error: GitHub release tag, target, or draft state mismatch" >&2
        return 1
    fi
    "$expected_assets_producer" | LC_ALL=C sort >"$expected"
    jq -r '.assets[].name' "$state" | LC_ALL=C sort >"$actual"
    python3 - "$expected" "$actual" "$inventory_mode" <<'PYTHON'
from pathlib import Path
import sys
expected = Path(sys.argv[1]).read_text().splitlines()
actual = Path(sys.argv[2]).read_text().splitlines()
mode = sys.argv[3]
if len(actual) != len(set(actual)) or mode not in ('exact', 'resume'):
    sys.exit('error: invalid remote inventory or validation mode')
if (mode == 'exact' and actual != expected) or (mode == 'resume' and not set(actual) <= set(expected)):
    sys.exit('error: remote draft asset inventory mismatch')
PYTHON
)

# Bind operator work to the staged annotated object and peeled commit.
require_published_anchor() {
    local directory="$1" anchor tag object commit
    tag="$(release_tag)"
    anchor="$directory.anchor"
    [[ -s "$anchor" && -f "$anchor" && ! -L "$anchor" ]] || {
        echo 'error: staged anchor missing' >&2
        return 1
    }
    [[ "$(awk -F= '$1=="tag" {print $2}' "$anchor")" == "$tag" ]] || {
        echo 'error: staged tag mismatch' >&2
        return 1
    }
    object="$(awk -F= '$1=="object" {print $2}' "$anchor")"
    commit="$(awk -F= '$1=="commit" {print $2}' "$anchor")"
    [[ "$object" =~ ^[0-9a-f]{40}$ && "$commit" =~ ^[0-9a-f]{40}$ ]] || {
        echo 'error: malformed staged identity anchor' >&2
        return 1
    }
    # The staged anchor is a working copy; the recorded ceremony anchor outside
    # the checkout is the authority, and every staged field must equal it.
    (
        load_ceremony_anchor || exit 2
        [[ "$object" == "$CANONPRIMS_EXPECTED_TAG_OBJECT" && "$commit" == "$CANONPRIMS_EXPECTED_COMMIT" ]] || {
            echo 'error: staged anchor differs from the recorded ceremony anchor' >&2
            exit 1
        }
    ) || return 1
    CANONPRIMS_RELEASE_TAG="$tag" CANONPRIMS_EXPECTED_TAG_OBJECT="$object" CANONPRIMS_EXPECTED_COMMIT="$commit" \
        "$(release_repo_root)/scripts/release-verify-published-tag.sh"
}

# The original approved ceremony identity is required across separate registry calls.
load_ceremony_anchor() {
    local anchor="${CANONPRIMS_RELEASE_ANCHOR_FILE:-}" identity canonical repo_path
    [[ "$anchor" == /* && -f "$anchor" && -s "$anchor" && ! -L "$anchor" ]] || {
        echo 'error: approved external ceremony anchor required' >&2
        return 1
    }
    canonical="$(cd "$(dirname "$anchor")" && pwd -P)/$(basename "$anchor")"
    repo_path="$(release_repo_root)"
    case "$canonical" in "$repo_path" | "$repo_path"/*)
        echo 'error: ceremony anchor must be outside trusted checkout' >&2
        return 1
        ;;
    esac
    identity="$(
        python3 - "$anchor" "$(release_tag)" <<'PYTHON'
from pathlib import Path
import re
import sys
entries = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    key, sep, value = line.partition('=')
    if not sep or key in entries or key not in ('tag', 'object', 'commit', 'run', 'attempt'):
        sys.exit('error: malformed ceremony anchor')
    entries[key] = value
if entries.get('tag') != sys.argv[2] or any(not re.fullmatch('[0-9a-f]{40}', entries.get(key, '')) for key in ('object', 'commit')):
    sys.exit('error: ceremony tag/object/commit mismatch or missing')
print(entries['object'], entries['commit'])
PYTHON
    )" || return 1
    read -r CANONPRIMS_EXPECTED_TAG_OBJECT CANONPRIMS_EXPECTED_COMMIT <<<"$identity"
    export CANONPRIMS_EXPECTED_TAG_OBJECT CANONPRIMS_EXPECTED_COMMIT
}

verify_remote_release_bytes() (
    local directory="$1" remote_dir name
    remote_dir="$(mktemp -d)"
    trap 'rm -rf "$remote_dir"' EXIT
    assert_github_release_state release_signed_assets
    release_gh release download "$(release_tag)" --repo "$CANONPRIMS_REPOSITORY" --pattern '*' --dir "$remote_dir"
    assert_exact_directory_inventory "$remote_dir" release_signed_assets
    while IFS= read -r name; do
        cmp -s "$directory/$name" "$remote_dir/$name" || {
            echo 'error: remote draft asset bytes differ from verified local set' >&2
            return 1
        }
    done < <(release_signed_assets)
)
