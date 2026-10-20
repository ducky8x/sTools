#!/bin/bash
# Builds build/sTools.app from the SwiftPM package and signs it.
#
# Usage: scripts/build-app.sh [debug|release] [--adhoc] [--keychain <path>]
#
#   debug       Host architecture only (fast). The default.
#   release     Universal binary (arm64 + x86_64).
#   --adhoc     Debug only. When the "ducky8x" identity does not exist, sign ad hoc instead of failing.
#   --keychain  Look for the identity in, and sign with, this keychain instead of the search list.
#               For testing the signing flow with a throwaway keychain.
#   --identity  Accepts only the name "ducky8x" (the default); any other name is refused.
#
# Environment:
#   VERSION       CFBundleShortVersionString (default 0.1.0)
#   BUILD_NUMBER  CFBundleVersion (default: the number of commits on HEAD, or 1 outside a git checkout)
#   DEVELOPER_DIR Defaults to the Xcode beta when it is installed.
#
# Signing safety: the only identity this script will ever sign with is the code-signing identity whose
# common name is exactly "ducky8x". It is matched by exact name, never by substring, and signing uses its
# SHA-1 hash, so other identities in the keychain can never be picked up.

set -euo pipefail

readonly IDENTITY_NAME="ducky8x"
readonly XCODE_BETA="/Applications/Xcode-beta.app/Contents/Developer"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly APP="$ROOT/build/sTools.app"

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

fail() {
    echo "error: $*" >&2
    exit 1
}

MODE=""
ADHOC=0
KEYCHAIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|release)
            [[ -z "$MODE" ]] || fail "build mode given twice"
            MODE="$1"
            ;;
        --adhoc)
            ADHOC=1
            ;;
        --keychain)
            [[ $# -ge 2 ]] || fail "--keychain needs a path"
            KEYCHAIN="$2"
            shift
            ;;
        --identity)
            [[ $# -ge 2 ]] || fail "--identity needs a name"
            [[ "$2" == "$IDENTITY_NAME" ]] ||
                fail "refusing to sign with \"$2\": this script only ever signs with the identity \"$IDENTITY_NAME\""
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            fail "unknown argument \"$1\""
            ;;
    esac
    shift
done
MODE="${MODE:-debug}"

if [[ "$MODE" == "release" && "$ADHOC" -eq 1 ]]; then
    fail "release builds must be signed with the \"$IDENTITY_NAME\" identity; --adhoc is not allowed"
fi
if [[ -n "$KEYCHAIN" ]]; then
    [[ -f "$KEYCHAIN" ]] || fail "keychain not found: $KEYCHAIN"
    # The script changes directory later, so a relative path must be made absolute now.
    KEYCHAIN="$(cd "$(dirname "$KEYCHAIN")" && pwd -P)/$(basename "$KEYCHAIN")"
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_BETA" ]]; then
    export DEVELOPER_DIR="$XCODE_BETA"
fi

VERSION="${VERSION:-0.1.0}"
if [[ -z "${BUILD_NUMBER:-}" ]]; then
    BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] ||
    fail "VERSION must look like 1.2.3 or 1.2.3-beta.1, got \"$VERSION\""
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "BUILD_NUMBER must be a whole number, got \"$BUILD_NUMBER\""

# Prints the SHA-1 hash of the "ducky8x" identity. Prints nothing when it does not exist; fails when the
# identity exists but cannot be used (expired, ambiguous, ...).
find_identity_hash() {
    local listing line hash name status
    local hashes=""
    local unusable=""
    if [[ -n "$KEYCHAIN" ]]; then
        listing="$(security find-identity -p codesigning "$KEYCHAIN")"
    else
        listing="$(security find-identity -p codesigning)"
    fi
    # A line looks like:   1) 40-hex-digit-hash "common name" (optional status)
    # The pattern is in a variable so bash 3.2 treats the quotes literally.
    local pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"([^"]*)"[[:space:]]*(\(([^)]*)\))?[[:space:]]*$'
    while IFS= read -r line; do
        [[ "$line" =~ $pattern ]] || continue
        hash="${BASH_REMATCH[1]}"
        name="${BASH_REMATCH[2]}"
        status="${BASH_REMATCH[4]:-}"
        [[ "$name" == "$IDENTITY_NAME" ]] || continue
        # A self-signed certificate that was never added to the trust settings is reported as
        # CSSMERR_TP_NOT_TRUSTED. codesign signs with it fine, and trust is not needed for permissions.
        if [[ -z "$status" || "$status" == "CSSMERR_TP_NOT_TRUSTED" ]]; then
            case " $hashes " in
                *" $hash "*) ;;
                *) hashes="$hashes $hash" ;;
            esac
        else
            unusable="$unusable $hash($status)"
        fi
    done <<< "$listing"
    hashes="${hashes# }"
    if [[ -z "$hashes" && -n "$unusable" ]]; then
        fail "the \"$IDENTITY_NAME\" identity exists but cannot sign:$unusable"
    fi
    if [[ "$hashes" == *" "* ]]; then
        fail "more than one \"$IDENTITY_NAME\" identity found ($hashes); delete the extras in Keychain Access"
    fi
    echo "$hashes"
}

SIGN_ID=""
SIGN_DESCRIPTION=""
IDENTITY_HASH="$(find_identity_hash)"
if [[ -n "$IDENTITY_HASH" ]]; then
    SIGN_ID="$IDENTITY_HASH"
    SIGN_DESCRIPTION="\"$IDENTITY_NAME\" ($IDENTITY_HASH)"
    if [[ "$ADHOC" -eq 1 ]]; then
        echo "note: the \"$IDENTITY_NAME\" identity exists, so --adhoc is not needed; signing with it."
    fi
elif [[ "$ADHOC" -eq 1 ]]; then
    SIGN_ID="-"
    SIGN_DESCRIPTION="ad hoc"
    echo "warning: no \"$IDENTITY_NAME\" identity found; signing ad hoc." >&2
    echo "warning: macOS forgets permission grants (Screen Recording, Accessibility, Microphone, ...) for" >&2
    echo "warning: ad hoc builds every time you rebuild. Run scripts/make-signing-identity.sh once to fix that." >&2
else
    fail "no code-signing identity named \"$IDENTITY_NAME\" found. Run scripts/make-signing-identity.sh once to create it (or pass --adhoc for a throwaway debug build)."
fi

cd "$ROOT"

echo "==> Building ($MODE)"
if [[ "$MODE" == "release" ]]; then
    BUILD_FLAGS=(-c release --arch arm64 --arch x86_64)
else
    BUILD_FLAGS=(-c debug)
fi
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
[[ -x "$BIN_PATH/sTools" ]] || fail "build did not produce $BIN_PATH/sTools"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/sTools" "$APP/Contents/MacOS/sTools"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"
if grep -q '__[A-Z]*__' "$APP/Contents/Info.plist"; then
    fail "Info.plist still contains an unfilled placeholder"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "generated Info.plist is not valid"

BUNDLE_COUNT=0
while IFS= read -r -d '' bundle; do
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
    BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done < <(find "$BIN_PATH" -maxdepth 1 -type d -name '*.bundle' -print0)
[[ -d "$APP/Contents/Resources/sTools_STDesign.bundle" ]] ||
    fail "sTools_STDesign.bundle was not produced by the build"
echo "    copied $BUNDLE_COUNT resource bundle(s)"

echo "==> Adding the app icon"
# packaging/AppIcon.icon (an Icon Composer document) compiles to Assets.car, which macOS reads through
# CFBundleIconName; packaging/sTools.icns is the flat fallback named by CFBundleIconFile. Both are made by
# scripts/generate-icon.swift. actool's own fallback .icns is not used: it lacks the 32, 256 and 512 sizes.
ICON_BUILD="$ROOT/build/AppIcon"
rm -rf "$ICON_BUILD"
mkdir -p "$ICON_BUILD"
MIN_MACOS="$(plutil -extract LSMinimumSystemVersion raw "$ROOT/packaging/Info.plist")"
if ! ACTOOL_LOG="$(xcrun actool "$ROOT/packaging/AppIcon.icon" --compile "$ICON_BUILD" \
        --app-icon AppIcon --platform macosx --target-device mac --minimum-deployment-target "$MIN_MACOS" \
        --output-partial-info-plist "$ICON_BUILD/partial.plist" \
        --errors --warnings --output-format human-readable-text 2>&1)" || [[ ! -f "$ICON_BUILD/Assets.car" ]]; then
    echo "$ACTOOL_LOG" >&2
    fail "actool could not compile packaging/AppIcon.icon (it needs the Xcode 26 or newer actool)"
fi
[[ "$(plutil -extract CFBundleIconName raw "$ICON_BUILD/partial.plist")" == \
   "$(plutil -extract CFBundleIconName raw "$APP/Contents/Info.plist")" ]] ||
    fail "CFBundleIconName in packaging/Info.plist does not match the icon in packaging/AppIcon.icon"
cp "$ICON_BUILD/Assets.car" "$APP/Contents/Resources/Assets.car"
cp "$ROOT/packaging/sTools.icns" "$APP/Contents/Resources/sTools.icns"

if [[ "$MODE" == "release" ]]; then
    ARCHS="$(lipo -archs "$APP/Contents/MacOS/sTools")"
    for arch in arm64 x86_64; do
        [[ " $ARCHS " == *" $arch "* ]] || fail "release binary lacks $arch (has: $ARCHS)"
    done
    echo "    architectures: $ARCHS"
fi

echo "==> Signing with $SIGN_DESCRIPTION"
xattr -cr "$APP"
SIGN_ARGS=(--force --sign "$SIGN_ID")
if [[ -n "$KEYCHAIN" && "$SIGN_ID" != "-" ]]; then
    SIGN_ARGS+=(--keychain "$KEYCHAIN")
fi
# Inside out: resource bundles first, then the app with Hardened Runtime and entitlements.
while IFS= read -r -d '' bundle; do
    codesign "${SIGN_ARGS[@]}" --timestamp=none "$bundle"
done < <(find "$APP/Contents/Resources" -maxdepth 1 -type d -name '*.bundle' -print0)
codesign "${SIGN_ARGS[@]}" --timestamp=none --options runtime \
    --entitlements "$ROOT/packaging/sTools.entitlements" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE_INFO="$(codesign -dvv "$APP" 2>&1)"
grep -E '^(Identifier|Format|CodeDirectory|Signature|Authority|TeamIdentifier)' <<< "$SIGNATURE_INFO" || true
if [[ "$SIGN_ID" == "-" ]]; then
    [[ "$SIGNATURE_INFO" == *"Signature=adhoc"* ]] || fail "expected an ad hoc signature"
else
    grep -qx "Authority=$IDENTITY_NAME" <<< "$SIGNATURE_INFO" ||
        fail "the app was not signed by \"$IDENTITY_NAME\""
fi
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<< "$SIGNATURE_INFO" ||
    fail "Hardened Runtime is not enabled"
codesign -dr - "$APP" 2>&1 | grep -E '^(# )?designated'

echo
echo "Built $APP ($MODE, version $VERSION, build $BUILD_NUMBER)"
echo "Run it with: open \"$APP\""
