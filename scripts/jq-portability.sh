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
# macOS ships GNU Bash 3.2 (/bin/bash), where expanding "${arr[@]}" or
# "${arr[*]}" on an empty array fails under `set -u` (`unbound variable`) and
# an EXIT trap can mask the non-zero status. Every script must parse under
# bash -n, and any array initialized as `name=()` that is not guaranteed
# non-empty before expansion must use `${name[@]+"${name[@]}"}`.
for script in scripts/*.sh; do
	bash -n "$script"
done
python3 -I - <<'PY'
import pathlib
import re
import sys

for path in sorted(pathlib.Path("scripts").glob("*.sh")):
    if path.name in ("jq-portability.sh", "jq-portability.test.sh"):
        continue
    text = path.read_text(encoding="utf-8")
    empty_arrays = set(re.findall(r"(?m)^\s*(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)=\(\)\s*$", text))
    for name in sorted(empty_arrays):
        # Accept when guarded with ${name[@]+"${name[@]}"} / ${name[*]+"${name[*]}"}
        # or when populated via += and checked with ${#name[@]} before bare expansion.
        scrubbed = re.sub(rf"\$\{{{name}\[[@*]\]\+\"\$\{{{name}\[[@*]\]\}}\"\}}", "", text)
        if not re.search(rf"\"\$\{{{name}\[[@*]\]\}}\"", scrubbed):
            continue
        if re.search(rf"{name}\+=\(", text) or re.search(rf"\$\{{#{name}\[@\]\}}", text):
            continue
        print(f"jq-portability: {path}: empty array {name}=() expanded without Bash 3.2 ${{arr[@]+\"${{arr[@]}}\"}} guard", file=sys.stderr)
        sys.exit(1)
PY
echo '[ok] jq variables avoid jq keywords'
