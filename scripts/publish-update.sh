#!/bin/bash
# Publishes a new version of sTools as a GitHub release on ducky8x/sTools: builds the release app and its DMG, signs the
# DMG for Sparkle, adds the version to the update feed, and creates the release with the DMG and the feed attached. Every
# copy of sTools that checks for updates then offers it.
#
# Usage: scripts/publish-update.sh --version <x.y.z> [--beta] [--notes <file.md>] [--dry-run] [--yes]
#
#   --version  The version people see (CFBundleShortVersionString), such as 0.1.0. Its build number is the number of
#              commits on HEAD, which must be higher than every build already in the feed.
#   --beta     Names the DMG as a beta (sTools-<version>-beta-macOS.dmg). The release is still the Latest one, never a
#              pre-release: see below.
#   --notes    Release notes in Markdown, shown in Sparkle's update window and on the GitHub release
#              (default: one line naming the version).
#   --dry-run  Checks, builds, signs and writes the feed and the notes into build/publish/v<version>, then prints the
#              gh command it would run and stops. Nothing is created on GitHub.
#   --yes      Publish without asking first.
#
# How updates are served: sTools reads https://github.com/ducky8x/sTools/releases/latest/download/appcast.xml (SUFeedURL
# in packaging/Info.plist), which GitHub sends to the appcast.xml attached to the release marked Latest. So each version
# is one release, tagged v<version> on the commit the build came from and marked Latest, with two files attached: the DMG
# and an appcast.xml that lists every version so far, newest first, each item signed. A pre-release or a draft is never
# "Latest", and the address would stop finding the feed, so this script makes neither. The address resolves only while
# ducky8x/sTools is public.
#
# Steps, stopping at the first failure:
#   1. Checks, all read-only: nothing is uncommitted; this build's commit is already on origin/main (push main first;
#      this script never pushes); gh is signed in as ducky8x and GitHub has the commit; no release or tag v<version>
#      exists yet; the previous feed (the Latest release's appcast.xml, or packaging/appcast-template.xml for the
#      first release) has only lower builds; the update key in the login keychain matches
#      packaging/sparkle-public-key.txt.
#   2. Builds: VERSION=<version> scripts/build-app.sh release, then scripts/build-dmg.sh, which writes the DMG to
#      ~/Projects/App Outputs (never into the repository).
#   3. Signs the DMG with Sparkle's sign_update (macOS may ask once whether sign_update may use the key in the
#      keychain: choose Always Allow) and verifies the signature.
#   4. Adds the version to the top of the previous feed and reads the result back with Sparkle's parser
#      (scripts/check-appcast.sh). The feed and the notes go to build/publish/v<version>, are checked for home-folder
#      paths and names (scripts/check-no-home-paths.sh), and are what gets attached and shown.
#   5. Asks (not with --dry-run or --yes), then runs one gh release create: tag v<version> at the build's commit, the DMG
#      and the feed attached, marked Latest. It creates the tag on GitHub; this script runs no git push, git tag or
#      git commit.
#   6. Checks the release on GitHub (not a draft or a pre-release, both files attached, the Latest one) and, when the
#      repository is public, reads the feed at the address sTools uses (scripts/check-appcast.sh --live).
#
# Only ducky runs it. Environment: DEVELOPER_DIR defaults to the Xcode beta when it is installed.
# STOOLS_PUBLISH_WAIT_SECONDS (default 5) scales the waits between the final checks; the tests set it to 0.

set -euo pipefail

readonly OWNER="ducky8x"
readonly REPO="$OWNER/sTools"
readonly ACCOUNT="sTools"
readonly XCODE_BETA="/Applications/Xcode-beta.app/Contents/Developer"
readonly MARKER="<!-- New versions go right below this line"
readonly FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT
readonly SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
readonly APP="$ROOT/build/sTools.app"

fail() {
    echo "error: $*" >&2
    exit 1
}

# A path as printed: the repository's own relative to it, the home folder as ~ (it holds the account name).
shown() {
    case "$1" in
        "$ROOT"/*) printf '%s' "${1#"$ROOT/"}" ;;
        "$HOME"/*) printf '~/%s' "${1#"$HOME/"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# A command as printed, one word at a time, so that it can be pasted into a terminal in the repository: paths in the
# repository relative to it, the home folder as $HOME (it holds the account name), words that hold a space in quotes.
show_command() {
    local word text
    for word in "$@"; do
        case "$word" in
            "$ROOT"/*) text="${word#"$ROOT/"}" ;;
            "$HOME"/*) text="\$HOME/${word#"$HOME/"}" ;;
            *) text="$word" ;;
        esac
        case "$text" in
            *" "*) printf ' "%s"' "$text" ;;
            *) printf ' %s' "$text" ;;
        esac
    done
    printf '\n'
}

VERSION=""
BETA=0
NOTES=""
DRY_RUN=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail "--version needs a version"
            VERSION="$2"
            shift
            ;;
        --beta) BETA=1 ;;
        --notes)
            [[ $# -ge 2 ]] || fail "--notes needs a file"
            NOTES="$2"
            shift
            ;;
        --dry-run) DRY_RUN=1 ;;
        --yes) ASSUME_YES=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        *) fail "unknown argument \"$1\"" ;;
    esac
    shift
done
[[ -n "$VERSION" ]] || fail "give the version: scripts/publish-update.sh --version <x.y.z>"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version must look like 1.2.3, got \"$VERSION\""
if [[ -n "$NOTES" ]]; then
    [[ -f "$NOTES" ]] || fail "no notes file at $(shown "$NOTES")"
    ! grep -qF ']]>' "$NOTES" || fail "the notes must not contain \"]]>\""
fi
WAIT_SECONDS="${STOOLS_PUBLISH_WAIT_SECONDS:-5}"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || WAIT_SECONDS=5

if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_BETA" ]]; then
    export DEVELOPER_DIR="$XCODE_BETA"
fi

TAG="v$VERSION"
SUFFIX=""
[[ "$BETA" -eq 0 ]] || SUFFIX="-beta"
DMG_NAME="sTools-$VERSION$SUFFIX-macOS.dmg"
DMG="$HOME/Projects/App Outputs/$DMG_NAME"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME"
OUT="$ROOT/build/publish/$TAG"

WORK="$(mktemp -d -t sTools-publish)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Checking this checkout, GitHub and the update key"
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || fail "commit or stash every change first: the build number counts commits"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
SHA="$(git -C "$ROOT" rev-parse HEAD)"
SHORT_SHA="$(git -C "$ROOT" rev-parse --short HEAD)"

git -C "$ROOT" fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main" ||
    fail "cannot reach origin to check that this build's commit is pushed (git fetch origin main failed)"
git -C "$ROOT" merge-base --is-ancestor "$SHA" refs/remotes/origin/main 2>/dev/null ||
    fail "this build's commit ($SHORT_SHA) is not on origin/main yet. Push main first (git push origin main), then run this" \
        "again: the release is made at a commit GitHub already has, and this script never pushes."
AHEAD="$(git -C "$ROOT" rev-list --count "$SHA..refs/remotes/origin/main")"
echo "    commit $SHORT_SHA is on origin/main"
if [[ "$AHEAD" -gt 0 ]]; then
    echo "    note: origin/main is $AHEAD commit(s) ahead of this checkout; the release is of this checkout."
fi

command -v gh > /dev/null || fail "the GitHub CLI is not installed (brew install gh), then: gh auth login"
LOGIN="$(gh api user --jq .login 2>/dev/null)" || fail "gh is not signed in; run: gh auth login"
[[ "$LOGIN" == "$OWNER" ]] || fail "gh is signed in as \"$LOGIN\", not \"$OWNER\"; run: gh auth switch --user $OWNER"
[[ "$(gh api "repos/$REPO/commits/$SHA" --jq .sha 2>/dev/null || true)" == "$SHA" ]] ||
    fail "GitHub's $REPO has no commit $SHORT_SHA, although origin/main has it. Does origin point at $REPO? (git remote -v)"
VISIBILITY="$(gh repo view "$REPO" --json visibility --jq .visibility 2>/dev/null)" ||
    fail "cannot read $REPO from GitHub"
echo "    gh is signed in as $LOGIN, and GitHub has the commit"
if [[ "$VISIBILITY" != PUBLIC ]]; then
    echo "    note: $REPO is private. The release is made either way, but only you can read it, and copies of sTools"
    echo "    note: cannot fetch the feed until the repository is public."
fi

if gh release view "$TAG" --repo "$REPO" --json tagName --jq .tagName > /dev/null 2> "$WORK/gh.log"; then
    fail "$REPO already has a release $TAG; give a new version"
fi
grep -qi 'release not found' "$WORK/gh.log" || fail "cannot ask GitHub whether the release $TAG exists: $(cat "$WORK/gh.log")"
if git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$TAG" > /dev/null 2>&1; then
    fail "the tag $TAG already exists on origin; give a new version"
fi

# The feed so far: the Latest release's appcast.xml, or the empty template for the first release.
if LATEST_TAG="$(gh release view --repo "$REPO" --json tagName --jq .tagName 2> "$WORK/gh.log")"; then
    gh release download "$LATEST_TAG" --repo "$REPO" --pattern appcast.xml --dir "$WORK" --clobber > /dev/null 2> "$WORK/gh.log" ||
        fail "the latest release ($LATEST_TAG) has no appcast.xml, so there is no feed to add $VERSION to: $(cat "$WORK/gh.log")"
    PREVIOUS_FEED="$WORK/appcast.xml"
    echo "    the feed so far is the appcast.xml of $LATEST_TAG"
else
    grep -qi 'release not found' "$WORK/gh.log" || fail "cannot ask GitHub for the latest release: $(cat "$WORK/gh.log")"
    PREVIOUS_FEED="$ROOT/packaging/appcast-template.xml"
    echo "    $REPO has no release yet; the feed starts from packaging/appcast-template.xml"
fi
grep -qF "$MARKER" "$PREVIOUS_FEED" || fail "the feed so far lacks the line that marks where new versions go"
for existing in $(sed -n 's#.*<sparkle:version>\([0-9]*\)</sparkle:version>.*#\1#p' "$PREVIOUS_FEED"); do
    [[ "$BUILD" -gt "$existing" ]] || fail "build $BUILD is not newer than build $existing in the feed"
done

if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
    (cd "$ROOT" && swift package resolve)
fi
[[ -x "$SPARKLE_BIN/sign_update" && -x "$SPARKLE_BIN/generate_keys" ]] || fail "Sparkle's tools are not in .build/artifacts"
PUBLIC_KEY="$(head -n 1 "$ROOT/packaging/sparkle-public-key.txt" | tr -d '[:space:]')"
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p 2>/dev/null | tr -d '[:space:]')" ||
    fail "the login keychain has no update key for the account \"$ACCOUNT\"; restore it (generate_keys -f) first"
[[ "$KEYCHAIN_KEY" == "$PUBLIC_KEY" ]] ||
    fail "the update key in the keychain does not match packaging/sparkle-public-key.txt; sTools would reject the update"

echo "==> Building sTools $VERSION (build $BUILD)"
VERSION="$VERSION" BUILD_NUMBER="$BUILD" "$ROOT/scripts/build-app.sh" release
# What was built is what was asked for, and reads its updates from the feed this script writes.
for pair in "CFBundleShortVersionString:$VERSION" "CFBundleVersion:$BUILD" "SUFeedURL:$FEED_URL" "SUPublicEDKey:$PUBLIC_KEY"; do
    [[ "$(plutil -extract "${pair%%:*}" raw "$APP/Contents/Info.plist")" == "${pair#*:}" ]] ||
        fail "$(shown "$APP")'s ${pair%%:*} is not \"${pair#*:}\", so it is not the build this release is of"
done
MINIMUM_MACOS="$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")"
if [[ "$BETA" -eq 1 ]]; then
    "$ROOT/scripts/build-dmg.sh" --beta
else
    "$ROOT/scripts/build-dmg.sh"
fi
[[ -f "$DMG" ]] || fail "scripts/build-dmg.sh did not write $(shown "$DMG")"

echo "==> Signing the DMG for Sparkle"
SIGNED="$("$SPARKLE_BIN/sign_update" --account "$ACCOUNT" "$DMG")" || fail "sign_update could not sign the DMG"
[[ "$SIGNED" =~ sparkle:edSignature=\"([A-Za-z0-9+/=]+)\"\ length=\"([0-9]+)\" ]] ||
    fail "sign_update printed something unexpected"
SIGNATURE="${BASH_REMATCH[1]}"
LENGTH="${BASH_REMATCH[2]}"
[[ "$LENGTH" == "$(stat -f %z "$DMG")" ]] || fail "the signed length does not match the DMG"
"$SPARKLE_BIN/sign_update" --account "$ACCOUNT" --verify "$DMG" "$SIGNATURE" > /dev/null ||
    fail "the DMG's signature does not verify"
echo "    signed $DMG_NAME ($LENGTH bytes)"

echo "==> Writing the feed and the notes to $(shown "$OUT")"
rm -rf "$OUT"
mkdir -p "$OUT"
if [[ -n "$NOTES" ]]; then
    cp "$NOTES" "$OUT/release-notes.md"
else
    printf 'sTools %s.\n' "$VERSION" > "$OUT/release-notes.md"
fi
"$ROOT/scripts/appcast-add-item.sh" "$PREVIOUS_FEED" "$VERSION" "$BUILD" "$MINIMUM_MACOS" "$DOWNLOAD_URL" "$LENGTH" "$SIGNATURE" \
    "$OUT/release-notes.md" > "$OUT/appcast.xml"
READ_BACK="$("$ROOT/scripts/check-appcast.sh" "$OUT/appcast.xml")" || fail "Sparkle cannot read the feed with the new version"
echo "$READ_BACK" | sed 's/^/    /'
EXPECTED_ITEM="$VERSION (build $BUILD), macOS $MINIMUM_MACOS or newer, $DOWNLOAD_URL, EdDSA signature"
grep -qF "$EXPECTED_ITEM" <<< "$READ_BACK" || fail "Sparkle does not read the new version from the feed as expected"
"$ROOT/scripts/check-no-home-paths.sh" "$OUT/appcast.xml" "$OUT/release-notes.md" ||
    fail "the feed or the notes hold a home-folder path, a name or a trace of this Mac (listed above); nothing was published"

CREATE=(release create "$TAG" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --target "$SHA"
    --title "sTools $VERSION" --notes-file "$OUT/release-notes.md" --latest)
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    echo "Dry run: nothing was created on GitHub. The feed and the notes are in $(shown "$OUT")."
    echo "A real run, without --dry-run, creates the release with:"
    printf '    gh'
    show_command "${CREATE[@]}"
    exit 0
fi

if [[ "$ASSUME_YES" -eq 0 ]]; then
    echo
    echo "About to create the GitHub release $TAG on $REPO at commit $SHORT_SHA, marked Latest, with $DMG_NAME and the feed."
    read -r -p "Create it? [y/N] " answer || answer=""
    [[ "$answer" == [yY]* ]] || fail "nothing was published"
fi

echo "==> Creating the GitHub release $TAG"
gh "${CREATE[@]}" ||
    fail "gh could not create the release. Look at https://github.com/$REPO/releases for a draft it left, and delete the" \
        "draft before running this again."

echo "==> Checking the release on GitHub"
FLAGS="$(gh release view "$TAG" --repo "$REPO" --json isDraft,isPrerelease --jq '[.isDraft, .isPrerelease] | @tsv')"
[[ "$FLAGS" == $'false\tfalse' ]] ||
    fail "the release $TAG is a draft or a pre-release, so the address sTools reads will not find it; publish it as the" \
        "latest release on https://github.com/$REPO/releases"
ASSETS="$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[] | "\(.name) \(.size)"')"
grep -qx "$DMG_NAME $LENGTH" <<< "$ASSETS" || fail "the release $TAG does not hold $DMG_NAME ($LENGTH bytes)"
grep -q '^appcast.xml ' <<< "$ASSETS" || fail "the release $TAG does not hold appcast.xml"
[[ "$(gh api "repos/$REPO/releases/latest" --jq .tag_name)" == "$TAG" ]] ||
    fail "the release $TAG is not the Latest one on GitHub, so the address sTools reads does not lead to it"
echo "    $TAG is the Latest release, with $DMG_NAME and appcast.xml"

if [[ "$VISIBILITY" == PUBLIC ]]; then
    echo "==> Reading the feed at the address sTools uses"
    for attempt in 1 2 3 4 5 6; do
        if LIVE="$("$ROOT/scripts/check-appcast.sh" --live --expect "$VERSION" 2>&1)" && grep -qF "$EXPECTED_ITEM" <<< "$LIVE"; then
            echo "$LIVE" | sed 's/^/    /'
            break
        fi
        [[ "$attempt" -lt 6 ]] || fail "the release $TAG exists, but the feed does not resolve at $FEED_URL (GitHub can take a few" \
            "minutes to serve a new release). Try again with: scripts/check-appcast.sh --live --expect $VERSION"
        sleep $((attempt * WAIT_SECONDS))
    done
else
    echo "note: $REPO is private, so the feed at $FEED_URL does not resolve for anyone yet. Once the repository is public," \
        "check it with: scripts/check-appcast.sh --live --expect $VERSION"
fi

echo
echo "Published sTools $VERSION (build $BUILD): https://github.com/$REPO/releases/tag/$TAG"
if [[ "$VISIBILITY" == PUBLIC ]]; then
    echo "Copies of sTools that check for updates now offer it."
fi
