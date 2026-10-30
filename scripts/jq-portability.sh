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
# bash -n, and every array that can be initialized empty (`name=()` or
# `local/declare/typeset -a name`) must use `${name[@]+"${name[@]}"}` or
# `${name[*]+"${name[*]}"}` at every `[@]`/`[*]` expansion site.
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
    raw = path.read_text(encoding="utf-8")
    # Fold line continuations before scanning declarations and expansions.
    text = re.sub(r"\\\r?\n", "", raw)
    empty_arrays = set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)=\(\s*\)", text))
    for match in re.finditer(
        r"(?m)(?:^|[;{&(]|\b(?:then|do|else)\b)\s*(?:local|declare|typeset)\b([^;#\n{}]*)",
        text,
    ):
        decl = match.group(1)
        if re.search(r"(?:^|\s)-[A-Za-z]*a[A-Za-z]*(?:\s|$)", decl):
            for token in decl.split():
                if token.startswith("-"):
                    continue
                if "=" not in token and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token):
                    empty_arrays.add(token)
    scrubbed = re.sub(
        r"\$\{([A-Za-z_][A-Za-z0-9_]*)\[[@*]\]\+\"\$\{\1\[[@*]\]\}\"\}",
        "",
        text,
    )
    for name in sorted(empty_arrays):
        if re.search(rf"\$\{{{name}\[[@*]\]\}}", scrubbed):
            print(
                f"jq-portability: {path}: empty array {name} expanded without Bash 3.2 ${{arr[@]+\"${{arr[@]}}\"}} guard",
                file=sys.stderr,
            )
            sys.exit(1)
PY
echo '[ok] jq variables avoid jq keywords'
