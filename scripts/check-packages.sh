#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Verify publishable crate archives without publishing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$PROJECT_ROOT/VERSION"

"$SCRIPT_DIR/check-registry-config.py"
version=$(tr -d '[:space:]' <"$VERSION_FILE")
"$SCRIPT_DIR/release-crates.py" check
mapfile_crates() {
    while IFS= read -r crate; do crates+=("$crate"); done < <("$SCRIPT_DIR/release-crates.py" list)
}
crates=()
mapfile_crates
[[ "${#crates[@]}" -gt 0 ]] || {
    echo 'error: no publishable crates declared' >&2
    exit 1
}
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
package_target=$(mktemp -d "$temp_root/canonprims-package.XXXXXX")
trap 'rm -rf "$package_target"' EXIT

export CARGO_TARGET_DIR="$package_target"

cd "$PROJECT_ROOT"
# The release toolchain is the workspace MSRV.
msrv="$(sed -n 's/^rust-version = "\(.*\)"/\1/p' "$PROJECT_ROOT/Cargo.toml")"
[[ "$msrv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo 'error: workspace rust-version is required' >&2
    exit 1
}
package_args=()
patch_args=()
expected=()
for crate in "${crates[@]}"; do
    package_args+=(-p "$crate")
    if [[ "$crate" != "${crates[${#crates[@]} - 1]}" ]]; then
        patch_args+=(--config "patch.crates-io.${crate}.path=\"crates/${crate}\"")
    fi
    expected+=("$crate-$version.crate")
done
# CI verifies the packages (which builds them). Elsewhere (the pre-tag gate)
# packaging does not compile and runs in an empty Cargo home, so no build code
# runs where a registry credential could be read.
verify_args=()
if [[ "${CI:-}" != true ]]; then
    verify_args=(--no-verify)
    cargo_home=$(mktemp -d "$temp_root/canonprims-cargo-home.XXXXXX")
    trap 'rm -rf "$package_target" "$cargo_home"' EXIT
    export CARGO_HOME="$cargo_home"
fi
cargo "+$msrv" package "${package_args[@]}" ${verify_args[@]+"${verify_args[@]}"} --locked ${patch_args[@]+"${patch_args[@]}"}

package_dir="$CARGO_TARGET_DIR/package"
actual=()
while IFS= read -r archive; do
    actual+=("$(basename "$archive")")
done < <(find "$package_dir" -maxdepth 1 -type f -name 'canonprims-*.crate' | sort)

sorted_expected=()
while IFS= read -r archive; do
    sorted_expected+=("$archive")
done < <(printf '%s\n' "${expected[@]}" | LC_ALL=C sort)
if [[ "${actual[*]+"${actual[*]}"}" != "${sorted_expected[*]+"${sorted_expected[*]}"}" ]]; then
    printf '[ERROR] package artifacts differ from the expected publishable crates\n' >&2
    printf 'expected: %s\n' "${sorted_expected[*]+"${sorted_expected[*]}"}" >&2
    printf 'actual:   %s\n' "${actual[*]+"${actual[*]}"}" >&2
    exit 1
fi

for crate in "${crates[@]}"; do
    archive="$package_dir/$crate-$version.crate"
    manifest_path="$crate-$version/Cargo.toml"
    python3 -I - "$archive" "$manifest_path" "$version" <<'PY'
import sys
import tarfile
if sys.version_info < (3, 11):
    sys.exit("error: package inspection requires Python 3.11 or newer")
import tomllib

archive, manifest_path, version = sys.argv[1:]
with tarfile.open(archive) as packaged:
    manifest = tomllib.loads(packaged.extractfile(manifest_path).read().decode())

assert "patch" not in manifest, "local patches leaked into archive"

def check_dependencies(sections):
    for section in ("dependencies", "dev-dependencies", "build-dependencies"):
        for name, spec in sections.get(section, {}).items():
            if (spec.get("package", name) if isinstance(spec, dict) else name).startswith("canonprims-"):
                assert isinstance(spec, dict) and spec.get("version") == version and not any(key in spec for key in ("path", "git", "registry", "registry-index")), (name, spec)

check_dependencies(manifest)
for target in manifest.get("target", {}).values():
    check_dependencies(target)
PY
done

printf '[ok] Verified package archives: %s\n' "${expected[*]}"
