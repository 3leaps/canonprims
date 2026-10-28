#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the Python binding as a wheel with the pinned maturin, install it into
# a throwaway virtual environment, and test the installed package:
#
# 0. the wheel is abi3 for 3.10 and carries both licenses and py.typed;
# 1. bindings/python/tests (the API tests and the canonical-json/v0 corpus,
#    no skips);
# 2. its corpus result lines equal Rust's, byte for byte;
# 3. its differential driver equals Rust's on the crosscheck seeds.
#
# The tests run from outside the source tree with -I, so they import the
# installed wheel, never bindings/python/python.
# PYTHON names the interpreter the wheel is installed into (>= 3.10).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python="${PYTHON:-python3}"
seeds="${CROSSCHECK_SEEDS:-20261022 20261023}"
count="${CROSSCHECK_COUNT:-5000}"
work="$(mktemp -d "${TMPDIR:-/tmp}/canonprims-python.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
cd "${root}"

# The wheel's license files are copies of the root ones.
for license in LICENSE-MIT LICENSE-APACHE; do
  cmp -s "${license}" "bindings/python/${license}" ||
    { echo "python-check: bindings/python/${license} differs from ${license}" >&2; exit 1; }
done
"${python}" -I -c 'import sys; sys.exit(sys.version_info < (3, 10))' ||
  { echo "python-check: Python 3.10 or later required" >&2; exit 1; }
"${python}" -I -m venv "${work}/venv"
venv_python="${work}/venv/bin/python"
[ -x "${venv_python}" ] || venv_python="${work}/venv/Scripts/python.exe"
"${venv_python}" -I -m pip install --quiet --disable-pip-version-check --require-hashes \
  --only-binary :all: -r config/python-build-requirements.txt
# Map the checkout, the Cargo home and the rustup home to fixed names so the
# extension carries no build-host path.
# Git Bash on Windows spells a drive path as /d/a while rustc sees D:\a or
# D:/a, so on Windows each directory is remapped in both native spellings.
here="$(pwd -P)" cargo_home="${CARGO_HOME:-${HOME}/.cargo}" rustup_home="${RUSTUP_HOME:-${HOME}/.rustup}" home="${HOME}"
rustflags=""
for pair in "${here}=/canonprims" "${cargo_home}=/cargo" "${rustup_home}=/rustup"; do
  dir="${pair%=*}" to="${pair##*=}"
  if command -v cygpath >/dev/null 2>&1; then
    rustflags+=" --remap-path-prefix=$(cygpath -w "${dir}")=${to} --remap-path-prefix=$(cygpath -m "${dir}")=${to}"
  else
    rustflags+=" --remap-path-prefix=${dir}=${to}"
  fi
done
if command -v cygpath >/dev/null 2>&1; then
  here="$(cygpath -m "${here}")" cargo_home="$(cygpath -m "${cargo_home}")"
  rustup_home="$(cygpath -m "${rustup_home}")" home="$(cygpath -m "${home}")"
fi
# The MSVC linker records the PDB's full path in the DLL; record its name only.
# RUSTFLAGS already holds native paths: Git Bash must not convert it.
case "$(rustc -vV | awk '/^host:/{print $2}')" in *-windows-msvc) rustflags+=" -Clink-arg=/PDBALTPATH:%_PDB%" ;; esac
MSYS2_ENV_CONV_EXCL=RUSTFLAGS RUSTFLAGS="${rustflags}" \
  "${venv_python}" -I -m maturin build --release --locked --quiet \
  --manifest-path bindings/python/Cargo.toml --interpreter "${venv_python}" --out "${work}/wheels"
wheels=("${work}"/wheels/canonprims-*.whl)
# The extension must carry no build-host path (panic locations are remapped).
"${venv_python}" -I scripts/host-path-check.py "${wheels[0]}" \
  "${here}" "${cargo_home}" "${rustup_home}" "${home}" ||
  { echo "python-check: the wheel embeds a build-host path" >&2; exit 1; }
[ "${#wheels[@]}" -eq 1 ] && [ -f "${wheels[0]}" ] || { echo "python-check: expected one wheel" >&2; exit 1; }
case "${wheels[0]##*/}" in *-cp310-abi3-*) ;; *) echo "python-check: wheel is not abi3 for 3.10: ${wheels[0]##*/}" >&2; exit 1 ;; esac
"${venv_python}" -I -m pip install --quiet --disable-pip-version-check --no-index --no-deps "${wheels[0]}"
"${venv_python}" -I - <<'PY'
import importlib.metadata as md
files = {str(f).rsplit("/", 1)[-1] for f in md.files("canonprims") or []}
missing = {"LICENSE-MIT", "LICENSE-APACHE", "py.typed"} - files
if missing:
    raise SystemExit(f"python-check: wheel lacks {sorted(missing)}")
PY

tests="${root}/bindings/python/tests"
corpus="${root}/conformance/canonical-json/v0"
(cd "${work}" && CANONPRIMS_CORPUS_DIR="${corpus}" CANONPRIMS_RESULTS_OUT="${work}/py.results" \
  "${venv_python}" -I -m unittest discover -v -s "${tests}" -t "${tests}") 2>"${work}/unittest.log" ||
  { cat "${work}/unittest.log" >&2; exit 1; }
if grep -q 'skipped' "${work}/unittest.log"; then
  echo "python-check: the Python tests must not skip" >&2
  exit 1
fi

CANONPRIMS_RESULTS_OUT="${work}/rust.results" cargo test --quiet --locked -p canonprims-json --test corpus corpus >/dev/null
if [ ! -s "${work}/py.results" ] || ! cmp -s "${work}/rust.results" "${work}/py.results"; then
  echo "python-check: corpus results differ (rust vs python):" >&2
  diff "${work}/rust.results" "${work}/py.results" | head -20 >&2 || true
  exit 1
fi
echo "python-check: corpus agrees with Rust ($(wc -l < "${work}/py.results" | tr -d ' ') cases)" >&2

rust_driver="$(cargo build --quiet --locked --release -p canonprims-json --example canon-diff --message-format=json \
  | "${python}" -I -c 'import json,sys
for line in sys.stdin:
    m = json.loads(line)
    if m.get("reason") == "compiler-artifact" and m.get("target", {}).get("name") == "canon-diff" and m.get("executable"):
        print(m["executable"])')"
for seed in ${seeds}; do
  "${python}" -I scripts/crosscheck-gen.py "${seed}" "${count}" > "${work}/in.${seed}"
  "${rust_driver}" < "${work}/in.${seed}" > "${work}/rust.${seed}"
  (cd "${work}" && "${venv_python}" -I "${tests}/canon_diff.py" < "${work}/in.${seed}" > "${work}/py.${seed}")
  if ! cmp -s "${work}/rust.${seed}" "${work}/py.${seed}"; then
    echo "python-check: drivers differ for seed ${seed} (rust vs python)" >&2
    exit 1
  fi
  echo "python-check: seed ${seed} agrees with Rust (${count} inputs)" >&2
done
echo "[ok] python-check"
