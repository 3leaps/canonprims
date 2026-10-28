#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Install the pinned static jq (config/ci-tools.sha256) into DEST and print
# DEST. For the manylinux wheel-build images, which ship no jq; the tag
# restore (scripts/release-restore-tag-ref.sh) needs it.
# Usage: ci-install-jq.sh <x86_64|aarch64> DEST
set -euo pipefail
arch="${1:?architecture required}"
dest="${2:?destination required}"
root="$(cd "$(dirname "$0")/.." && pwd)"
case "${arch}" in
  x86_64) name=jq-1.8.2-linux-amd64; asset=jq-linux-amd64 ;;
  aarch64) name=jq-1.8.2-linux-arm64; asset=jq-linux-arm64 ;;
  *) echo "ci-install-jq: unsupported architecture ${arch}" >&2; exit 2 ;;
esac
[ "$(uname -m)" = "${arch}" ] || { echo "ci-install-jq: host is not ${arch}" >&2; exit 1; }
want="$(awk -v n="${name}" '$2 == n { print $1 }' "${root}/config/ci-tools.sha256")"
[ -n "${want}" ] || { echo "ci-install-jq: no pin for ${name}" >&2; exit 1; }
mkdir -p "${dest}"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
  --output "${dest}/jq" "https://github.com/jqlang/jq/releases/download/jq-1.8.2/${asset}"
got="$(sha256sum "${dest}/jq" | cut -c1-64)"
[ "${got}" = "${want}" ] || { rm -f "${dest}/jq"; echo "ci-install-jq: checksum ${got} != ${want}" >&2; exit 1; }
chmod +x "${dest}/jq"
"${dest}/jq" --version >&2
echo "${dest}"
