# Shared by the git hooks in this folder. Sourced, not run.
#
# WHY THESE HOOKS EXIST. This repository is published under a pseudonym, and
# every way the author's real identity has reached GitHub so far has been a
# commit, not a file:
#   - a commit message that named the author in passing;
#   - Co-Authored-By trailers, which GitHub turns into extra listed
#     contributors - added by tooling that appends them by default, even while
#     a written rule said not to;
#   - commits authored under the wrong identity (fixed once by deleting and
#     recreating the repository, because a force-push does not unpublish).
# A written rule did not stop the second one. A check that runs every time does.
#
# THE NAMES TO REFUSE ARE NEVER WRITTEN HERE. This file is published; listing
# them would be the leak. They come from the environment (the Windows account,
# machine and domain names - the same source tools/package.ps1 uses for its
# .pex identity gate) plus tools/identity-denylist.txt, which is gitignored and
# holds anything the environment cannot know, one token per line.
#
# Enable once per clone:   git config core.hooksPath tools/hooks

EXPECTED_IDENT="deadohiosky48 <deadohiosky48@users.noreply.github.com>"
HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
DENYLIST="$HOOK_DIR/../identity-denylist.txt"

identity_tokens() {
    for v in "$USERNAME" "$COMPUTERNAME" "$USERDOMAIN"; do
        # Short tokens match ordinary words; the packager uses the same floor.
        [ ${#v} -ge 4 ] && printf '%s\n' "$v"
    done
    [ -f "$DENYLIST" ] && tr -d '\r' < "$DENYLIST" | grep -v -E '^[[:space:]]*(#|$)'
}

# A drive letter must START a word, so registry hives (HKLM:\SOFTWARE\...) and
# URL schemes (mod://, https://) are never mistaken for a drive.
PATH_RE='(^|[^A-Za-z0-9])[A-Za-z]:[\\/][A-Za-z0-9_.-]+[\\/][A-Za-z0-9_.-]+|/(Users|home)/[A-Za-z0-9_.-]+/'

# check_text LABEL < text  - refuse identity tokens (whole words) and absolute
# paths. Paths need two folders after the drive, as in package.ps1, so that
# "USE:\n- ..." in a YAML string is not mistaken for one. Never quote a real
# path as the example - the first version of package.ps1's comment did.
check_text() {
    label="$1"
    text=$(cat)
    bad=0
    tokens=$(identity_tokens)
    if [ -n "$tokens" ]; then
        printf '%s\n' "$tokens" | while IFS= read -r t; do
            [ -z "$t" ] && continue
            if printf '%s\n' "$text" | grep -i -q -w -F -- "$t"; then
                echo "  $label: contains an identity token (see tools/hooks/_identity.sh)" >&2
                exit 1
            fi
        done || bad=1
    fi
    if printf '%s\n' "$text" | grep -q -E "$PATH_RE"; then
        echo "  $label: contains an absolute path:" >&2
        printf '%s\n' "$text" | grep -o -E "$PATH_RE" | head -3 | sed 's/^/      /' >&2
        bad=1
    fi
    return $bad
}

# check_message LABEL < message
check_message() {
    label="$1"
    msg=$(grep -v '^#')
    bad=0
    if printf '%s\n' "$msg" | grep -i -q -E '^[[:space:]]*co-authored-by:'; then
        echo "  $label: has a Co-Authored-By trailer. Remove it - every co-author is listed as a contributor on GitHub." >&2
        bad=1
    fi
    printf '%s\n' "$msg" | check_text "$label" || bad=1
    return $bad
}
