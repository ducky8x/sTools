#!/bin/bash
# Publishes a new version of sTools: builds the release app and its DMG, signs the DMG for Sparkle, creates the GitHub
# release on ducky8x/sTools-releases with the DMG, and adds the version to the update feed there, so every copy of
# sTools that checks for updates offers it.
#
# Usage: scripts/publish-update.sh --version <x.y.z> [--beta] [--notes <file.md>] [--clone <folder>] [--yes]
#
#   --version  The version people see (CFBundleShortVersionString), such as 0.1.0. Its build number is the number of
#              commits on HEAD, which must be higher than every build already in the feed.
#   --beta     Names the DMG as a beta (sTools-<version>-beta-macOS.dmg) and marks the GitHub release a pre-release.
#   --notes    Release notes in Markdown, shown in Sparkle's update window and on the GitHub release
#              (default: one line naming the version).
#   --clone    The local clone of ducky8x/sTools-releases (default ~/Projects/sTools-releases, where
#              scripts/create-releases-repo.sh puts it).
#   --yes      Publish without asking first.
#
# Steps, stopping at the first failure:
#   1. Checks: this repository is on main with nothing uncommitted (the build number counts commits); gh is signed in
#      as ducky8x; the clone is clean and up to date; no release of that version exists; the update key in the login
#      keychain matches packaging/sparkle-public-key.txt.
#   2. Builds: VERSION=<version> scripts/build-app.sh release, then scripts/build-dmg.sh, which writes the DMG to
#      ~/Projects/App Outputs (never into the repository).
#   3. Signs the DMG with Sparkle's sign_update (macOS may ask once whether sign_update may use the key in the
#      keychain: choose Always Allow) and verifies the signature.
#   4. Adds the version to the top of appcast.xml in the clone and reads the feed back with Sparkle's parser
#      (scripts/check-appcast.sh).
#   5. Asks, then creates the GitHub release v<version> with the DMG, checks that the download works, and only then
#      commits and pushes the feed, so it never offers a download that isn't there.
#
# Only ducky runs it. Environment: DEVELOPER_DIR defaults to the Xcode beta when it is installed.

set -euo pipefail

readonly OWNER="ducky8x"
readonly REPO="$OWNER/sTools-releases"
readonly ACCOUNT="sTools"
readonly XCODE_BETA="/Applications/Xcode-beta.app/Contents/Developer"
readonly MARKER="<!-- New versions go right below this line"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT
readonly SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
readonly APP="$ROOT/build/sTools.app"

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

VERSION=""
BETA=0
NOTES=""
CLONE="$HOME/Projects/sTools-releases"
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
        --clone)
            [[ $# -ge 2 ]] || fail "--clone needs a folder"
            CLONE="$2"
            shift
            ;;
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
    [[ -f "$NOTES" ]] || fail "no notes file at $NOTES"
    ! grep -qF ']]>' "$NOTES" || fail "the notes must not contain \"]]>\""
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_BETA" ]]; then
    export DEVELOPER_DIR="$XCODE_BETA"
fi

TAG="v$VERSION"
SUFFIX=""
[[ "$BETA" -eq 0 ]] || SUFFIX="-beta"
DMG_NAME="sTools-$VERSION$SUFFIX-macOS.dmg"
DMG="$HOME/Projects/App Outputs/$DMG_NAME"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME"
FEED="$CLONE/appcast.xml"

echo "==> Checking this repository, GitHub, the clone and the update key"
[[ "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" == main ]] || fail "publish from main; this checkout is on another branch"
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || fail "commit or stash every change first: the build number counts commits"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"

command -v gh > /dev/null || fail "the GitHub CLI is not installed (brew install gh), then: gh auth login"
LOGIN="$(gh api user --jq .login 2>/dev/null)" || fail "gh is not signed in; run: gh auth login"
[[ "$LOGIN" == "$OWNER" ]] || fail "gh is signed in as \"$LOGIN\", not \"$OWNER\"; run: gh auth switch --user $OWNER"
! gh release view "$TAG" --repo "$REPO" > /dev/null 2>&1 || fail "$REPO already has a release $TAG"

[[ -f "$FEED" ]] || fail "no feed at $(shown "$FEED"); create the repository first: scripts/create-releases-repo.sh"
[[ -z "$(git -C "$CLONE" status --porcelain)" ]] || fail "$(shown "$CLONE") has uncommitted changes"
git -C "$CLONE" pull -q --ff-only || fail "cannot bring $(shown "$CLONE") up to date with GitHub"
grep -qF "$MARKER" "$FEED" || fail "the feed lacks the line that marks where new versions go"
for existing in $(sed -n 's#.*<sparkle:version>\([0-9]*\)</sparkle:version>.*#\1#p' "$FEED"); do
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
[[ "$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist")" == "$PUBLIC_KEY" ]] ||
    fail "the app's SUPublicEDKey is not the committed public key"
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

echo "==> Adding $VERSION to the feed"
NOTES_FILE="$(mktemp -t sTools-notes)"
FEED_NEW="$(mktemp -t sTools-appcast)"
trap 'rm -f "$NOTES_FILE" "$FEED_NEW"' EXIT
if [[ -n "$NOTES" ]]; then
    cp "$NOTES" "$NOTES_FILE"
else
    printf 'sTools %s.\n' "$VERSION" > "$NOTES_FILE"
fi
"$ROOT/scripts/appcast-add-item.sh" "$FEED" "$VERSION" "$BUILD" "$MINIMUM_MACOS" "$DOWNLOAD_URL" "$LENGTH" "$SIGNATURE" \
    "$NOTES_FILE" > "$FEED_NEW"
READ_BACK="$("$ROOT/scripts/check-appcast.sh" "$FEED_NEW")" || fail "Sparkle cannot read the feed with the new version"
echo "$READ_BACK" | sed 's/^/    /'
grep -qF "$VERSION (build $BUILD), macOS $MINIMUM_MACOS or newer, $DOWNLOAD_URL, EdDSA signature" <<< "$READ_BACK" ||
    fail "Sparkle does not read the new version from the feed as expected"

if [[ "$ASSUME_YES" -eq 0 ]]; then
    read -r -p "Publish sTools $VERSION (build $BUILD) to $REPO? [y/N] " answer
    [[ "$answer" == [yY]* ]] || fail "nothing was published"
fi

echo "==> Creating the GitHub release $TAG"
RELEASE_ARGS=(--repo "$REPO" --title "sTools $VERSION" --notes-file "$NOTES_FILE")
[[ "$BETA" -eq 0 ]] || RELEASE_ARGS+=(--prerelease)
gh release create "$TAG" "$DMG" "${RELEASE_ARGS[@]}"
cp "$FEED_NEW" "$FEED"
for attempt in 1 2 3 4 5 6; do
    curl -fsSIL -o /dev/null "$DOWNLOAD_URL" && break
    [[ "$attempt" -lt 6 ]] || fail "the release exists, but $DOWNLOAD_URL does not download yet. The new feed is in" \
        "$(shown "$CLONE") but not committed; once the download works, publish it with:" \
        "git -C \"$(shown "$CLONE")\" commit -am \"Add sTools $VERSION (build $BUILD)\" && git -C \"$(shown "$CLONE")\" push origin main"
    sleep $((attempt * 5))
done

echo "==> Publishing the feed"
git -C "$CLONE" add appcast.xml
git -C "$CLONE" commit -q -m "Add sTools $VERSION (build $BUILD)"
git -C "$CLONE" push -q origin main || fail "the release exists but the feed was not pushed; push it: git -C \"$(shown "$CLONE")\" push origin main"

echo
echo "Published sTools $VERSION (build $BUILD): https://github.com/$REPO/releases/tag/$TAG"
echo "Copies of sTools that check for updates now offer it (GitHub may take a few minutes to serve the new feed)."
