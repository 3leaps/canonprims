#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# jq 1.6 (the stock version on Debian 12) does not accept a jq keyword as a
# variable name ($module, $import, $if, ...), while jq 1.7 does. Refuse any
# --arg/--argjson binding to a keyword in tracked scripts, workflows and the
# Makefile, so release steps run with either version.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
keywords='module|import|include|def|if|then|elif|else|end|as|reduce|foreach|try|catch|label|and|or|not|__loc__'
if git grep -n -E -- "--arg(json)?[[:space:]]+(${keywords})[[:space:]]" -- 'scripts/*' '.github/**' Makefile ':!scripts/jq-portability.sh' ':!scripts/jq-portability.test.sh'; then
	echo 'jq-portability: a jq variable is named after a jq keyword (jq 1.6 refuses it)' >&2
	exit 1
fi
echo '[ok] jq variables avoid jq keywords'
