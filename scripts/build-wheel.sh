#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the Python binding's release wheel for one platform, then install it
# into a fresh environment and run the binding tests and the corpus against
# it. Used by the tag workflow; runs the same way locally.
#
#   build-wheel.sh <target> <out-dir>
#
# On Linux it must run inside the pinned manylinux2014 image for <target>
# (glibc 2.17): it installs the pinned Rust toolchain with the pinned
# rustup-init (config/ci-tools.sha256) and tags the wheel manylinux2014.
# On macOS and Windows it uses the runner's Rust and Python.
# PYTHON names the interpreter (CPython 3.10 or later); the wheel is abi3.
set -euo pipefail

target="${1:?target required}"
out="${2:?output directory required}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${root}"
toolchain="$(sed -n 's/^rust-version = "\(.*\)"/\1/p' Cargo.toml)"
python="${PYTHON:-python3}"
work="$(mktemp -d "${TMPDIR:-/tmp}/canonprims-wheel.XXXXXX")"
# BUILD_WHEEL_KEEP=1 keeps the scratch directory for diagnosis.
[ "${BUILD_WHEEL_KEEP:-}" = 1 ] || trap 'rm -rf "${work}"' EXIT

case "${target}" in
  x86_64-unknown-linux-gnu | aarch64-unknown-linux-gnu)
    platform=linux
    [ -f /etc/os-release ] && grep -q 'CentOS Linux' /etc/os-release && [ "$(ldd --version | head -1 | awk '{print $NF}')" = 2.17 ] ||
      { echo "build-wheel: Linux wheels build only inside the manylinux2014 image" >&2; exit 1; }
    [ "$(uname -m)" = "${target%%-*}" ] || { echo "build-wheel: host is not ${target}" >&2; exit 1; }
    name="rustup-init-1.29.1-${target}"
    want="$(awk -v n="${name}" '$2 == n { print $1 }' config/ci-tools.sha256)"
    [ -n "${want}" ] || { echo "build-wheel: no pin for ${name}" >&2; exit 1; }
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --retry 3 --output "${work}/rustup-init" \
      "https://static.rust-lang.org/rustup/archive/1.29.1/${target}/rustup-init"
    got="$(sha256sum "${work}/rustup-init" | cut -c1-64)"
    [ "${got}" = "${want}" ] || { echo "build-wheel: rustup-init checksum ${got} != ${want}" >&2; exit 1; }
    chmod +x "${work}/rustup-init"
    "${work}/rustup-init" -y -q --no-modify-path --profile minimal --default-toolchain "${toolchain}" >/dev/null
    export PATH="${HOME}/.cargo/bin:${PATH}"
    python=/opt/python/cp310-cp310/bin/python
    compat=(--compatibility manylinux2014)
    ;;
  aarch64-apple-darwin | x86_64-pc-windows-msvc | aarch64-pc-windows-msvc)
    platform=native
    compat=()
    ;;
  *) echo "build-wheel: unsupported target ${target}" >&2; exit 2 ;;
esac
rustc --version | grep -q "^rustc ${toolchain} " || { echo "build-wheel: rustc is not ${toolchain}" >&2; exit 1; }
[ "$(rustc -vV | awk '/^host:/{print $2}')" = "${target}" ] || { echo "build-wheel: rustc host is not ${target}" >&2; exit 1; }

"${python}" -I -m venv "${work}/build"
build_python="${work}/build/bin/python"
[ -x "${build_python}" ] || build_python="${work}/build/Scripts/python.exe"
"${build_python}" -I -m pip install --quiet --disable-pip-version-check --require-hashes \
  --only-binary :all: -r config/python-build-requirements.txt
# Map the checkout and the tool homes to fixed names: no build-host path in
# the extension.
RUSTFLAGS="--remap-path-prefix=$(pwd -P)=/canonprims --remap-path-prefix=${CARGO_HOME:-${HOME}/.cargo}=/cargo --remap-path-prefix=${RUSTUP_HOME:-${HOME}/.rustup}=/rustup" \
  "${build_python}" -I -m maturin build --release --locked --quiet "${compat[@]}" \
  --manifest-path bindings/python/Cargo.toml --interpreter "${build_python}" --out "${work}/wheels"
wheels=("${work}"/wheels/canonprims-*.whl)
[ "${#wheels[@]}" -eq 1 ] && [ -f "${wheels[0]}" ] || { echo "build-wheel: expected one wheel" >&2; exit 1; }
wheel="${wheels[0]##*/}"
version="$(tr -d ' \t\r\n' < VERSION)"
case "${target}" in
  x86_64-unknown-linux-gnu)  want="canonprims-${version}-cp310-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl" ;;
  aarch64-unknown-linux-gnu) want="canonprims-${version}-cp310-abi3-manylinux_2_17_aarch64.manylinux2014_aarch64.whl" ;;
  aarch64-apple-darwin)      want="canonprims-${version}-cp310-abi3-macosx_11_0_arm64.whl" ;;
  x86_64-pc-windows-msvc)    want="canonprims-${version}-cp310-abi3-win_amd64.whl" ;;
  aarch64-pc-windows-msvc)   want="canonprims-${version}-cp310-abi3-win_arm64.whl" ;;
esac
[ "${wheel}" = "${want}" ] || { echo "build-wheel: built ${wheel}, expected ${want}" >&2; exit 1; }

# The wheel itself, installed alone, must pass the binding tests and the corpus.
"${python}" -I -m venv "${work}/test"
test_python="${work}/test/bin/python"
[ -x "${test_python}" ] || test_python="${work}/test/Scripts/python.exe"
"${test_python}" -I -m pip install --quiet --disable-pip-version-check --no-index --no-deps "${work}/wheels/${wheel}"
tests="${root}/bindings/python/tests"
(cd "${work}" && CANONPRIMS_CORPUS_DIR="${root}/conformance/canonical-json/v0" \
  "${test_python}" -I -m unittest discover -s "${tests}" -t "${tests}") 2>"${work}/unittest.log" ||
  { cat "${work}/unittest.log" >&2; exit 1; }
! grep -q 'skipped' "${work}/unittest.log" || { echo "build-wheel: tests must not skip" >&2; exit 1; }
"${test_python}" -I scripts/host-path-check.py "${work}/wheels/${wheel}" \
  "$(pwd -P)" "${CARGO_HOME:-${HOME}/.cargo}" "${RUSTUP_HOME:-${HOME}/.rustup}" "${HOME}" ||
  { echo "build-wheel: the wheel embeds a build-host path" >&2; exit 1; }
mkdir -p "${out}"
cp "${work}/wheels/${wheel}" "${out}/"
echo "[ok] ${wheel} (${platform})"
