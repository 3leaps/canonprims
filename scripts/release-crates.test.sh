#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The ordered crate plan: order, publishability and the release version.
set -euo pipefail
# shellcheck source=scripts/release-test-fixture.sh
source "$(dirname "$0")/release-test-fixture.sh"
python3 -B - "$fixture_root/scripts" "$fixture_dir" <<'PY'
import importlib.util
import pathlib
import sys
spec = importlib.util.spec_from_file_location('rc', pathlib.Path(sys.argv[1]) / 'release-crates.py')
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)

def pkg(name, deps=(), publish=None):
    return {'name': name, 'publish': publish, 'dependencies': [{'name': d} for d in deps]}

def manifests(names, flag=True):
    return {n: {'package': {'publish': flag}} for n in names}

order = ['canonprims-core', 'canonprims-json']
graph = [pkg('canonprims-core'), pkg('canonprims-json', ['canonprims-core']),
         pkg('canonprims-cli', ['canonprims-core', 'canonprims-json'], publish=[])]
rc.validate(graph, order, manifests(order))

def rejects(packages, names, mans, needle):
    try:
        rc.validate(packages, names, mans)
    except ValueError as error:
        assert needle in str(error), (needle, str(error))
        return
    raise SystemExit(f'expected rejection: {needle}')

rejects(graph, order + ['canonprims-cbor'], manifests(order), 'not in this workspace: canonprims-cbor')
swapped = ['canonprims-json', 'canonprims-core']
rejects(graph, swapped, manifests(swapped), 'canonprims-json must follow canonprims-core')
rejects(graph, order[:-1], manifests(order[:-1]), 'missing from the list: canonprims-json')
rejects(graph, order, {**manifests(order), 'canonprims-core': {'package': {'publish': False}}}, 'explicitly set publish = true')
leaky = graph[:-1] + [pkg('canonprims-cli', ['canonprims-core'])]
rejects(leaky, order, manifests(order), 'missing from the list: canonprims-cli')
internal = [p if p['name'] != 'canonprims-json' else pkg('canonprims-json', ['canonprims-cli']) for p in graph]
rejects(internal, order, manifests(order), 'depends on unpublished workspace crate canonprims-cli')

plan = pathlib.Path(sys.argv[1]).parent / 'config/release/publishable-crates.txt'
names = rc.read_plan(plan)
assert names == order, names
for bad in ('canonprims-core\n\ncanonprims-json\n', 'canonprims-core\ncanonprims-core\n', ' canonprims-core\n', 'other-crate\n'):
    tmp = pathlib.Path(sys.argv[2]) / 'plan'
    try:
        tmp.write_text(bad)
        try:
            rc.read_plan(tmp)
        except ValueError:
            continue
        raise SystemExit(f'expected plan rejection for {bad!r}')
    finally:
        tmp.unlink(missing_ok=True)
PY

# A tagged tree whose crate version differs from VERSION is refused.
src="$fixture_dir/source"
mkdir -p "$src/crates" "$src/config/release"
cp "$fixture_root/Cargo.toml" "$fixture_root/Cargo.lock" "$fixture_root/VERSION" "$src/"
cp -R "$fixture_root/crates/." "$src/crates/"
cp -R "$fixture_root/scripts" "$src/scripts"
cp "$fixture_root/config/release/publishable-crates.txt" "$src/config/release/"
PYTHONDONTWRITEBYTECODE=1 python3 "$src/scripts/release-crates.py" --source-root "$src" check
printf '9.9.9\n' >"$src/VERSION"
expect_fail_with 'crate version differs from VERSION 9.9.9: canonprims-core, canonprims-json' \
	env PYTHONDONTWRITEBYTECODE=1 python3 "$src/scripts/release-crates.py" --source-root "$src" check
echo '[ok] crate plan controls passed'
