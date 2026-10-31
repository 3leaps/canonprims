#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Signed-tag ceremony invariants, shared by the tag scripts. canonprims tags one
# commit with every name in the release tag set; no signing material lives in
# this repository.
set -euo pipefail

tag_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tag_repo_slug=3leaps/canonprims
tag_go_module=github.com/3leaps/canonprims

tag_die() {
	echo "error: $*" >&2
	return 1
}

# The release tag is the explicit input; it must name the canonical vX.Y.Z tag
# for the version under release.
tag_version() {
	[[ -n "${CANONPRIMS_RELEASE_TAG:-}" ]] || {
		tag_die 'CANONPRIMS_RELEASE_TAG is required'
		return 1
	}
	[[ "$CANONPRIMS_RELEASE_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
		tag_die 'CANONPRIMS_RELEASE_TAG must be a canonical vX.Y.Z tag'
		return 1
	}
	[[ "$CANONPRIMS_RELEASE_TAG" == "v$(tr -d '\r\n' <"$tag_root/VERSION")" ]] || {
		tag_die 'CANONPRIMS_RELEASE_TAG does not match VERSION'
		return 1
	}
}

# The release tag set is fixed: the one vX.Y.Z tag, which the Rust crates and
# the root Go module share. It is not configuration, so nothing in a checkout
# can widen or rename it. tag_load_set fills the tag_names array; callers use it
# directly and never read the set through a pipe or process substitution.
# With --tagged, the caller has already checked VERSION and go.mod in the
# tagged commit, so the working tree is not consulted.
tag_load_set() {
	tag_names=()
	if [[ "${1:-}" == --tagged ]]; then
		[[ "${CANONPRIMS_RELEASE_TAG:-}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
			tag_die 'CANONPRIMS_RELEASE_TAG must be a canonical vX.Y.Z tag'
			return 1
		}
	else
		tag_version || return 1
		[[ -f "$tag_root/go.mod" ]] || {
			tag_die 'go.mod is required at the repository root; the release tag also releases the Go module'
			return 1
		}
		[[ "$(sed -n 's/^module[[:space:]]\{1,\}//p' "$tag_root/go.mod" | tr -d '\r')" == "$tag_go_module" ]] || {
			tag_die "go.mod must declare module $tag_go_module"
			return 1
		}
	fi
	# shellcheck disable=SC2034 # Consumed by scripts sourcing this helper.
	tag_names=("$CANONPRIMS_RELEASE_TAG")
}

tag_identity() {
	[[ "${CANONPRIMS_TAGGER_NAME:-} <${CANONPRIMS_TAGGER_EMAIL:-}>" == "$(cat "$tag_root/config/release/tagger-identity.txt")" ]] || {
		tag_die 'the committed tagger identity is required'
		return 1
	}
	local value
	for value in "$CANONPRIMS_TAGGER_NAME" "$CANONPRIMS_TAGGER_EMAIL"; do
		[[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *'<'* && "$value" != *'>'* ]] || {
			tag_die 'invalid tagger identity'
			return 1
		}
	done
}

# Tag messages live outside the repository in one per-release directory, one
# file per tag: the tag name with "/" replaced by "__", plus ".txt".
tag_message_dir() {
	local dir="${CANONPRIMS_TAG_MESSAGE_DIR:-}" canonical
	[[ -n "$dir" && -d "$dir" && ! -L "$dir" ]] || {
		tag_die 'CANONPRIMS_TAG_MESSAGE_DIR must name an existing directory'
		return 1
	}
	[[ "$dir" == /* && "/$dir/" != *'/../'* ]] || {
		tag_die 'CANONPRIMS_TAG_MESSAGE_DIR must be absolute without parent traversal'
		return 1
	}
	[[ "${dir%/}" == */"$CANONPRIMS_RELEASE_TAG" ]] || {
		tag_die 'CANONPRIMS_TAG_MESSAGE_DIR must end in the release tag'
		return 1
	}
	# The directory itself must not be a symlink. Ancestors may be (macOS /tmp
	# and /var are), so the repository check uses the fully resolved path.
	[[ ! -L "${dir%/}" ]] || {
		tag_die 'CANONPRIMS_TAG_MESSAGE_DIR may not be a symlink'
		return 1
	}
	canonical="$(cd "$dir" && pwd -P)"
	[[ "${canonical##*/}" == "$CANONPRIMS_RELEASE_TAG" ]] || {
		tag_die 'CANONPRIMS_TAG_MESSAGE_DIR must resolve to a directory named for the release tag'
		return 1
	}
	case "$canonical" in "$tag_root" | "$tag_root"/*)
		tag_die 'CANONPRIMS_TAG_MESSAGE_DIR must be outside the repository'
		return 1
		;;
	esac
	printf '%s\n' "${dir%/}"
}

tag_message_file() {
	local tag="$1" dir file
	dir="$(tag_message_dir)" || return 1
	file="$dir/${tag//\//__}.txt"
	[[ -f "$file" && ! -L "$file" && -s "$file" ]] || {
		tag_die "tag message for $tag is missing"
		return 1
	}
	local subject="$tag"
	[[ "$tag" == "$CANONPRIMS_RELEASE_TAG" ]] && subject="Release ${CANONPRIMS_RELEASE_TAG#v}"
	"$tag_root/scripts/release-prepare-tag-message.py" --validate-message "$file" "$subject" || return 1
	printf '%s\n' "$file"
}

tag_origin() {
	local url host
	url="$(git config --get remote.origin.url)"
	case "$url" in
	"https://github.com/$tag_repo_slug" | "https://github.com/$tag_repo_slug.git" | \
		"git@github.com:$tag_repo_slug" | "git@github.com:$tag_repo_slug.git") ;;
	git@*:"$tag_repo_slug" | git@*:"$tag_repo_slug.git")
		host="${url#git@}"
		host="${host%%:*}"
		[[ "$(ssh -G "$host" 2>/dev/null | awk '$1=="hostname" {print $2;exit}')" == github.com ]] || {
			tag_die 'origin SSH host must resolve to github.com'
			return 1
		}
		;;
	*)
		tag_die "origin must be $tag_repo_slug on GitHub"
		return 1
		;;
	esac
}

tag_checkout() {
	tag_origin
	git fetch --quiet origin '+refs/heads/main:refs/remotes/origin/main'
	[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || tag_die 'clean checkout required'
	[[ "$(git rev-parse HEAD)" == "$(git rev-parse refs/remotes/origin/main)" ]] || tag_die 'HEAD must match fetched origin/main'
}

# The operator's subkey selector must name the committed signing subkey.
tag_selector() {
	[[ "${CANONPRIMS_PGP_KEY_ID:-}" =~ ^[0-9A-F]{40}!$ ]] || {
		tag_die 'CANONPRIMS_PGP_KEY_ID must be the exact uppercase signing subkey followed by !'
		return 1
	}
	[[ "${CANONPRIMS_PGP_KEY_ID%!}" == "$(tr -d '\r\n' <"$tag_root/config/release/signing-subkey.txt")" ]] || {
		tag_die 'CANONPRIMS_PGP_KEY_ID differs from config/release/signing-subkey.txt'
		return 1
	}
}

# The approved primary comes from the maintainer environment, never from the
# tree, and must be the primary the committed anchors name at HEAD. Checked
# before signing and before pushing.
tag_approved_primary() {
	local approved="${CANONPRIMS_GPG_SIGNING_FINGERPRINT:-}" pinned
	[[ "$approved" =~ ^[0-9A-F]{40}$ ]] || {
		tag_die 'approved primary CANONPRIMS_GPG_SIGNING_FINGERPRINT required (40 uppercase hex)'
		return 1
	}
	pinned="$(git cat-file blob HEAD:keys/expected-fingerprints.txt 2>/dev/null | awk '$1=="gpg" {print $2}')"
	[[ -n "$pinned" && "$pinned" == "$approved" ]] || {
		tag_die 'the committed anchor is not the approved primary'
		return 1
	}
}

tag_key_home() {
	[[ -n "${CANONPRIMS_GPG_HOMEDIR:-}" && ( "$CANONPRIMS_GPG_HOMEDIR" == /* || "$CANONPRIMS_GPG_HOMEDIR" == [A-Za-z]:/* || "$CANONPRIMS_GPG_HOMEDIR" == [A-Za-z]:\\* || "$CANONPRIMS_GPG_HOMEDIR" == \\\\* ) && -d "$CANONPRIMS_GPG_HOMEDIR" && ! -L "$CANONPRIMS_GPG_HOMEDIR" ]] || {
		tag_die 'an external CANONPRIMS_GPG_HOMEDIR is required'
		return 1
	}
	local home
	home="$(
		python3 -I - "$CANONPRIMS_GPG_HOMEDIR" "$tag_root" "${HOME:-}" <<'PY'
import os
import pathlib
import subprocess
import sys

probe = os.fsencode(sys.argv[1])
seps = (b"/", b"\\") if os.name == "nt" else (b"/",)
dot_seps = (b"/.", b"\\.") if os.name == "nt" else (b"/.",)
dotdot_seps = (b"/..", b"\\..") if os.name == "nt" else (b"/..",)
while True:
    if len(probe) > 1 and probe.endswith(seps):
        probe = probe[:-1]
    elif probe.endswith(dot_seps):
        probe = probe[:-2] or b"/"
    else:
        break
if probe.endswith(dotdot_seps) or os.path.islink(probe):
    print("error: an external CANONPRIMS_GPG_HOMEDIR is required", file=sys.stderr)
    sys.exit(1)

def is_win_style(raw: str) -> bool:
    return (
        os.name == "nt"
        or os.path.sep == "\\"
        or raw.startswith("\\\\")
        or (len(raw) >= 3 and raw[0].isalpha() and raw[1:3] in (":/", ":\\"))
    )


def resolve_path(raw: bytes) -> str:
    s = os.fsdecode(raw)
    if os.name != "nt" and is_win_style(s):
        return s
    return os.fsdecode(os.path.realpath(raw))


home = pathlib.Path(resolve_path(os.fsencode(sys.argv[1])))
repo_root = pathlib.Path(resolve_path(os.fsencode(sys.argv[2])))
env_home = sys.argv[3]


def strip_line_terminator(raw: bytes) -> bytes:
    if (os.name == "nt" or os.path.sep == "\\") and raw.endswith(b"\r\n"):
        return raw[:-2]
    if raw.endswith(b"\r\n") and is_win_style(os.fsdecode(raw[:-2])):
        return raw[:-2]
    if raw.endswith(b"\n"):
        return raw[:-1]
    return raw


def same_or_within(path: pathlib.Path, target: pathlib.Path) -> bool:
    p_str = str(path)
    t_str = str(target)
    if is_win_style(p_str) or is_win_style(t_str):
        p_low = p_str.replace("\\", "/").lower().rstrip("/")
        t_low = t_str.replace("\\", "/").lower().rstrip("/")
    else:
        p_low = p_str.lower().rstrip("/")
        t_low = t_str.lower().rstrip("/")
    if p_low == t_low or p_low.startswith(t_low + "/"):
        return True
    for cur in (path, *path.parents):
        try:
            if target.exists() and cur.exists() and os.path.samefile(cur, target):
                return True
            if (
                cur.parent.exists()
                and target.parent.exists()
                and os.path.samefile(cur.parent, target.parent)
                and cur.name.lower() == target.name.lower()
            ):
                return True
        except OSError:
            continue
    return False


repo_roots = {repo_root}
try:
    wt_records = subprocess.run(
        ["git", "-C", str(repo_root), "worktree", "list", "--porcelain", "-z"],
        check=True,
        capture_output=True,
    ).stdout.split(b"\0")
except (OSError, subprocess.CalledProcessError):
    print("error: failed to enumerate repository worktrees", file=sys.stderr)
    sys.exit(1)
found_worktree = False
for rec in wt_records:
    if rec.startswith(b"worktree "):
        wt_bytes = rec[len(b"worktree ") :]
        if not wt_bytes:
            print("error: empty worktree path from git worktree list", file=sys.stderr)
            sys.exit(1)
        found_worktree = True
        repo_roots.add(pathlib.Path(os.fsdecode(os.path.realpath(wt_bytes))))
if not found_worktree:
    print("error: no repository worktrees reported by git worktree list", file=sys.stderr)
    sys.exit(1)
for git_flag in ("--git-dir", "--git-common-dir"):
    try:
        git_dir_raw = strip_line_terminator(
            subprocess.run(
                ["git", "-C", str(repo_root), "rev-parse", "--path-format=absolute", git_flag],
                check=True,
                capture_output=True,
            ).stdout
        )
    except (OSError, subprocess.CalledProcessError):
        print(f"error: failed to resolve repository {git_flag}", file=sys.stderr)
        sys.exit(1)
    if not git_dir_raw:
        print(f"error: empty repository {git_flag}", file=sys.stderr)
        sys.exit(1)
    repo_roots.add(pathlib.Path(os.fsdecode(os.path.realpath(git_dir_raw))))

for r_root in repo_roots:
    if same_or_within(home, r_root):
        print("error: CANONPRIMS_GPG_HOMEDIR must be outside the repository", file=sys.stderr)
        sys.exit(1)

candidates = set()
for home_candidate in (
    env_home,
    os.environ.get("USERPROFILE", ""),
    (os.environ.get("HOMEDRIVE", "") + os.environ.get("HOMEPATH", "")) if os.environ.get("HOMEDRIVE") and os.environ.get("HOMEPATH") else "",
    os.path.expanduser("~"),
):
    if home_candidate and home_candidate != "~":
        candidates.add(pathlib.Path(os.path.realpath(os.path.expanduser(home_candidate))) / ".gnupg")
for appdata_candidate in (os.environ.get("APPDATA", ""), os.environ.get("LOCALAPPDATA", "")):
    if appdata_candidate:
        candidates.add(pathlib.Path(os.path.realpath(os.path.expanduser(appdata_candidate))) / "gnupg")
try:
    import pwd

    acct = pathlib.Path(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))
    candidates.add(acct / ".gnupg")
except (ImportError, AttributeError, KeyError, OSError):
    pass
env = {k: v for k, v in os.environ.items() if k != "GNUPGHOME"}
try:
    out = strip_line_terminator(
        subprocess.run(
            ["gpgconf", "--list-dirs", "homedir"],
            env=env,
            check=True,
            capture_output=True,
        ).stdout
    )
    out_str = os.fsdecode(out)
    if is_win_style(out_str) or out.startswith(b"/") or os.path.isabs(out_str):
        candidates.add(pathlib.Path(resolve_path(out)))
        candidates.add(pathlib.Path(out_str))
except (OSError, subprocess.CalledProcessError):
    pass

for cand in candidates:
    if same_or_within(home, cand):
        print("error: the default GPG home is not approved for release signing", file=sys.stderr)
        sys.exit(1)

sys.stdout.write(str(home) + "x")
PY
	)" || return 1
	home="${home%x}"
	export GNUPGHOME="$home"
}

tag_signing_git() {
	git -c gpg.format=openpgp -c gpg.program=gpg -c gpg.openpgp.program=gpg "$@"
}

# PDR-0008 §2.10: the signing command pins gpg.format, gpg.program and
# gpg.openpgp.program on its own command line; a configured value the pin
# overrides is reported, and the step stops only if the pin would not take
# effect.
tag_signing_program() {
	local key want value effective rc
	for key in gpg.format gpg.program gpg.openpgp.program; do
		want=gpg
		[[ "$key" == gpg.format ]] && want=openpgp
		rc=0
		effective="$(tag_signing_git config --get "$key")" || rc=$?
		if ((rc != 0)) || [[ "$effective" != "$want" ]]; then
			tag_die "release signing would not use $key=$want; not signing"
			return 1
		fi
		rc=0
		value="$(git config --get-all "$key")" || rc=$?
		if ((rc == 1)); then
			continue
		fi
		if ((rc != 0)); then
			tag_die "could not read git config $key"
			return 1
		fi
		if [[ "$value" != "$want" ]]; then
			echo "note: git config $key is '${value//$'\n'/, }'; release signing uses $want" >&2
		fi
	done
}

# Check one annotated tag object: name, target, tagger and exact message bytes.
tag_verify_object() {
	local tag="$1" target="$2" object expected actual tagger
	object="$(git rev-parse --verify --quiet "refs/tags/$tag")" || {
		tag_die "tag $tag is absent"
		return 1
	}
	[[ "$(git cat-file -t "$object")" == tag ]] || {
		tag_die "$tag must be an annotated tag"
		return 1
	}
	[[ "$(git cat-file tag "$object" | sed -n 's/^tag //p' | head -1)" == "$tag" ]] || {
		tag_die "$tag object names a different tag"
		return 1
	}
	[[ "$(git rev-parse "${object}^{commit}")" == "$target" ]] || {
		tag_die "$tag does not point at $target"
		return 1
	}
	tagger="$(git cat-file tag "$object" | sed -n 's/^tagger \(.*\) [0-9][0-9]* [+-][0-9][0-9][0-9][0-9]$/\1/p' | head -1)"
	[[ "$tagger" == "$(cat "$tag_root/config/release/tagger-identity.txt")" ]] || {
		tag_die "$tag tagger differs from the committed identity"
		return 1
	}
	expected="$(tag_message_file "$tag")" || return 1
	actual="$(mktemp)"
	if ! "$tag_root/scripts/release-tag-body.sh" "$object" >"$actual"; then
		rm -f "$actual"
		return 1
	fi
	if ! cmp -s "$expected" "$actual"; then
		rm -f "$actual"
		tag_die "$tag message differs from the prepared message"
		return 1
	fi
	rm -f "$actual"
}
