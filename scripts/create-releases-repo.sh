#!/bin/bash
# Creates the public releases repository, ducky8x/sTools-releases, once: a short README and an update feed with no
# items yet, both from packaging/releases-repo/. sTools reads its updates from that feed (SUFeedURL in
# packaging/Info.plist); scripts/publish-update.sh adds each version to it.
#
# Usage: scripts/create-releases-repo.sh [--clone <folder>]
#
#   --clone  Where the local clone goes (default ~/Projects/sTools-releases), outside this repository.
#            scripts/publish-update.sh uses the same default.
#
# Needs the GitHub CLI (gh) signed in as ducky8x. It refuses when the repository already exists on GitHub or the
# folder is already there, and reads the feed with Sparkle's own parser (scripts/check-appcast.sh) before anything is
# created. Only ducky runs it.

set -euo pipefail

readonly OWNER="ducky8x"
readonly REPO="$OWNER/sTools-releases"
readonly DESCRIPTION="Release downloads and the update feed for sTools"
readonly FEED_URL="https://raw.githubusercontent.com/$REPO/main/appcast.xml"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT
readonly TEMPLATES="$ROOT/packaging/releases-repo"

fail() {
    echo "error: $*" >&2
    exit 1
}

# A path as printed: the home folder as ~ (it holds the account name).
shown() {
    case "$1" in
        "$HOME"/*) printf '~/%s' "${1#"$HOME/"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

CLONE="$HOME/Projects/sTools-releases"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clone)
            [[ $# -ge 2 ]] || fail "--clone needs a folder"
            CLONE="$2"
            shift
            ;;
        -h|--help)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        *) fail "unknown argument \"$1\"" ;;
    esac
    shift
done
[[ "$CLONE" == /* ]] || CLONE="$(pwd -P)/$CLONE"
case "$CLONE/" in
    "$ROOT"/*) fail "the clone must not be inside this repository" ;;
esac
[[ ! -e "$CLONE" ]] || fail "$(shown "$CLONE") already exists; pass --clone with a new folder"

echo "==> Checking the GitHub CLI"
command -v gh > /dev/null || fail "the GitHub CLI is not installed (brew install gh), then: gh auth login"
LOGIN="$(gh api user --jq .login 2>/dev/null)" || fail "gh is not signed in; run: gh auth login"
[[ "$LOGIN" == "$OWNER" ]] || fail "gh is signed in as \"$LOGIN\", not \"$OWNER\"; run: gh auth switch --user $OWNER"
if gh repo view "$REPO" > /dev/null 2>&1; then
    fail "$REPO already exists on GitHub; clone it instead: gh repo clone $REPO \"$(shown "$CLONE")\""
fi

echo "==> Reading the feed with Sparkle's parser"
"$ROOT/scripts/check-appcast.sh" "$TEMPLATES/appcast.xml"

echo "==> Preparing $(shown "$CLONE")"
mkdir -p "$CLONE"
cp "$TEMPLATES/README.md" "$TEMPLATES/appcast.xml" "$CLONE/"
git -C "$CLONE" init -q -b main
git -C "$CLONE" add README.md appcast.xml
git -C "$CLONE" commit -q -m "Start the update feed for sTools"

echo "==> Creating $REPO (public) and pushing"
gh repo create "$REPO" --public --description "$DESCRIPTION" --source "$CLONE" --remote origin --push

echo "==> Checking the feed URL sTools reads (GitHub may take a minute to serve it)"
for attempt in 1 2 3 4 5 6; do
    if curl -fsS "$FEED_URL" 2>/dev/null | cmp -s - "$TEMPLATES/appcast.xml"; then
        echo
        echo "Created https://github.com/$REPO with its local clone at $(shown "$CLONE")."
        echo "sTools now finds the feed at $FEED_URL (no versions in it yet)."
        echo "Publish a version with: scripts/publish-update.sh --version <x.y.z> [--beta]"
        exit 0
    fi
    sleep $((attempt * 10))
done
echo "warning: $FEED_URL does not serve the feed yet; GitHub can take a few minutes. Check it later with:" >&2
echo "warning:   curl -fsS $FEED_URL" >&2
