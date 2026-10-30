#!/bin/bash
# Builds build/sTools.app from the SwiftPM package and signs it.
#
# Usage: scripts/build-app.sh [debug|release] [--dev] [--adhoc] [--keychain <path>]
#
#   debug       Host architecture only (fast). The default. Keeps its debug info; never ship it.
#   release     Universal binary (arm64 + x86_64), for shipping. Its debug symbols go to dSYMs in
#               build/dSYMs/sTools-<version>-<build>-<UUIDs>/ (kept for crash reports, never shipped; the folder is
#               named after the executable's UUIDs, so a rebuild never replaces the symbols of another binary) and
#               are stripped from every binary in the app. The build fails when a step fails or anything in the app
#               holds a home-folder path, a name or a trace of this Mac (scripts/check-no-home-paths.sh).
#   --dev       The dev build, the copy to use day to day: build/sTools Dev.app, beside build/sTools.app and never
#               replacing it. The same bundle identifier (com.ducky8x.sTools) and the same "ducky8x" signature, so
#               settings, saved data and macOS permissions are shared with the normal build and carry over; only one of
#               the two should be installed at a time. Named "sTools Dev" (CFBundleName and CFBundleDisplayName), with
#               the blue icon from packaging/dev (scripts/generate-icon.swift --tint blue packaging/dev) and no update
#               feed or key, so it never updates itself into the normal build: Settings > Updates says so, and
#               Install from DMG... still works. Info.plist says STVariant "dev". Package it with
#               scripts/build-dmg.sh --dev. Every guard of the normal build stays.
#   --adhoc     Debug only. When the "ducky8x" identity does not exist, sign ad hoc instead of failing.
#   --keychain  Look for the identity in, and sign with, this keychain instead of the search list.
#               For testing the signing flow with a throwaway keychain.
#   --identity  Accepts only the name "ducky8x" (the default); any other name is refused.
#
# Environment:
#   VERSION       CFBundleShortVersionString (default 0.2.0)
#   BUILD_NUMBER  CFBundleVersion (default: the number of commits on HEAD plus 1000, or 1001 outside a git checkout;
#                 scripts/lib/build-number.sh says why)
#   DEVELOPER_DIR Defaults to the Xcode beta when it is installed.
#
# Updates (spec 6.3): Sparkle.framework, which the build produces from the SwiftPM dependency, goes into
# Contents/Frameworks without its headers, and the executable finds it through @executable_path/../Frameworks; rpaths
# into the build folder are removed. SUPublicEDKey in Info.plist is filled from packaging/sparkle-public-key.txt
# (written by scripts/make-update-key.sh). Without that file a release build fails and a debug build leaves the key
# out, so it explains in Settings that it can't check for updates. The dev build leaves the feed and the key out
# whatever the file holds, and needs neither the file nor the key.
#
# A failed build: the app is made in build/.staging (build/.staging-dev with --dev) and moved to build/sTools.app
# (build/sTools Dev.app) only once it is signed and every check has passed (scripts/lib/stage-app.sh). So a failure, at
# any step, never leaves a
# half-made or unsigned app under that name, and the app from the last good build stays where it was, usable. The
# script then says that build/sTools.app was not replaced and which version and build it still is, so it cannot be taken
# for this run's.
#
# Signing safety: the only identity this script will ever sign with is the code-signing identity whose
# common name is exactly "ducky8x". It is matched by exact name, never by substring, and signing uses its
# SHA-1 hash, so other identities in the keychain can never be picked up. Everything inside the app that holds
# code or is a bundle (resource bundles, embedded frameworks, XPC services, helper apps and tools, plug-ins) is
# signed with it too, inside out, keeping each item's own entitlements and, for a loose tool, its identifier.
#
# Output: everything printed, by the script and by the tools it runs, shows the home folder as ~ and never the
# account name, the full name or a part of it, so terminals and logs don't carry them either
# (scripts/lib/mask-home.sh).

set -euo pipefail

readonly IDENTITY_NAME="ducky8x"
readonly XCODE_BETA="/Applications/Xcode-beta.app/Contents/Developer"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

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

# Everything printed goes through mask_home (scripts/lib/mask-home.sh): this script's own lines and what the tools it runs
# print (swift build's diagnostics, codesign's "replacing existing signature" and "valid on disk" lines, ...), which name
# files in the home folder. So the script runs itself once more with its output and its errors each passed through it.
# shellcheck source=lib/mask-home.sh
source "$ROOT/scripts/lib/mask-home.sh"
mask_output_of "${BASH_SOURCE[0]}" "$@"
# shellcheck source=lib/stage-app.sh
source "$ROOT/scripts/lib/stage-app.sh"
# shellcheck source=lib/build-number.sh
source "$ROOT/scripts/lib/build-number.sh"

# The UUID and architecture of each slice of a Mach-O file or dSYM, one per line, sorted.
macho_uuids() {
    xcrun dwarfdump --uuid "$1" | awk '{ print $2, $3 }' | sort
}

# Prints everything inside the app that is signed on its own, deepest first, one path per line: bundles (resource
# bundles, frameworks, XPC services, helper apps, app extensions, plug-ins) and Mach-O files that are not a bundle's
# main executable (a framework's helper tool, a dylib). A bundle's main executable is signed with its bundle, and
# symbolic links are not followed, so a framework's Versions/Current links are not visited twice.
list_nested_code() {
    local path parent bundle executable
    while IFS= read -r -d '' path; do
        [[ "$path" != *$'\n'* ]] || fail "a file name in the app holds a line break: ${path#"$APP/"}"
        if [[ -f "$path" ]]; then
            [[ "$(file -b "$path")" == Mach-O* ]] || continue
            parent="$(dirname "$path")"
            if [[ "$(basename "$parent")" == MacOS && "$(basename "$(dirname "$parent")")" == Contents ]]; then
                bundle="$(dirname "$(dirname "$parent")")"
                executable="$(plutil -extract CFBundleExecutable raw -o - "$bundle/Contents/Info.plist" 2>/dev/null ||
                    true)"
                [[ "$executable" != "$(basename "$path")" ]] || continue
            fi
            if [[ "$(basename "$(dirname "$parent")")" == Versions && "$(dirname "$(dirname "$parent")")" == *.framework ]]; then
                bundle="$(dirname "$(dirname "$parent")")"
                [[ "$(basename "$bundle" .framework)" != "$(basename "$path")" ]] || continue
            fi
        fi
        printf '%s\n' "$path"
    done < <(find "$APP/Contents" -mindepth 1 \( -type d \( -name '*.app' -o -name '*.appex' -o -name '*.bundle' \
        -o -name '*.framework' -o -name '*.plugin' -o -name '*.xpc' \) -o -type f \) -print0) |
        awk -F/ '{ print NF "\t" $0 }' | sort -t "$(printf '\t')" -k1,1nr -k2 | cut -f2-
}

MODE=""
ADHOC=0
DEV=0
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
        --dev)
            DEV=1
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

# The dev build sits beside the normal one under its own name, so building either never touches the other.
if [[ "$DEV" -eq 1 ]]; then
    readonly APP_NAME="sTools Dev.app"
    readonly STAGE_NAME=".staging-dev"
else
    readonly APP_NAME="sTools.app"
    readonly STAGE_NAME=".staging"
fi
# Where the finished app goes, and where it is made until then. The dev build has a staging folder of its own, so a
# normal build and a dev build running at the same time cannot clear each other's.
readonly FINAL_APP="$ROOT/build/$APP_NAME"
readonly STAGE="$ROOT/build/$STAGE_NAME"
readonly APP="$STAGE/$APP_NAME"

COMMITTED=0
SIGN_WORK=""
# Whatever the build ends with, the staging folder goes. A build that failed says that the app in place is not its own.
on_exit() {
    local status=$?
    [[ -z "$SIGN_WORK" ]] || rm -rf "$SIGN_WORK"
    rm -rf "$STAGE"
    if [[ "$status" -ne 0 ]]; then
        stage_report_failure "$FINAL_APP" "$COMMITTED"
    fi
}
trap on_exit EXIT

if [[ "$MODE" == "release" && "$ADHOC" -eq 1 ]]; then
    fail "release builds must be signed with the \"$IDENTITY_NAME\" identity; --adhoc is not allowed"
fi
if [[ -n "$KEYCHAIN" ]]; then
    [[ -f "$KEYCHAIN" ]] || fail "keychain not found: $(shown "$KEYCHAIN")"
    # The script changes directory later, so a relative path must be made absolute now.
    KEYCHAIN="$(cd "$(dirname "$KEYCHAIN")" && pwd -P)/$(basename "$KEYCHAIN")"
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_BETA" ]]; then
    export DEVELOPER_DIR="$XCODE_BETA"
fi

VERSION="${VERSION:-0.2.0}"
BUILD_NUMBER="$(build_number "$ROOT")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] ||
    fail "VERSION must look like 1.2.3 or 1.2.3-beta.1, got \"$VERSION\""

# Sparkle's public EdDSA key: base64 of 32 bytes, on the file's first line.
readonly UPDATE_KEY_FILE="$ROOT/packaging/sparkle-public-key.txt"
UPDATE_KEY=""
if [[ "$DEV" -eq 1 ]]; then
    : # A dev build never updates itself, so it has no key.
elif [[ -f "$UPDATE_KEY_FILE" ]]; then
    UPDATE_KEY="$(head -n 1 "$UPDATE_KEY_FILE" | tr -d '[:space:]')"
    [[ "$UPDATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ && "$(printf '%s' "$UPDATE_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] ||
        fail "packaging/sparkle-public-key.txt does not hold a Sparkle public key (base64 of 32 bytes)"
elif [[ "$MODE" == "release" ]]; then
    fail "packaging/sparkle-public-key.txt is missing; run scripts/make-update-key.sh once to create the update key"
else
    echo "warning: packaging/sparkle-public-key.txt is missing, so this build can't check for updates;" >&2
    echo "warning: run scripts/make-update-key.sh once to create the update key." >&2
fi

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

echo "==> Building ($MODE): version $VERSION, build $BUILD_NUMBER"
if [[ "$MODE" == "release" ]]; then
    # Swift Build, pinned: the native build system's Bundle.module accessor (STDesign and KeyRebinder fall back
    # to it) holds the build folder's absolute path as a string literal, which no strip removes. Swift Build's
    # accessor holds no path: it looks in the main bundle's and its own bundle's resources and in the main bundle.
    BUILD_FLAGS=(-c release --arch arm64 --arch x86_64 --build-system swiftbuild)
else
    BUILD_FLAGS=(-c debug)
fi
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
[[ -x "$BIN_PATH/sTools" ]] || fail "build did not produce $(shown "$BIN_PATH/sTools")"

echo "==> Assembling $(shown "$APP")"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/sTools" "$APP/Contents/MacOS/sTools"

# Sparkle.framework, as SwiftPM unpacked it, without what only compiling against it needs (Xcode leaves the same
# out). It is signed again with everything else nested in the app, below.
[[ -d "$BIN_PATH/Sparkle.framework" ]] || fail "the build did not produce Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_PATH/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE/Headers" "$SPARKLE/PrivateHeaders" "$SPARKLE/Modules" \
    "$SPARKLE/Versions/B/Headers" "$SPARKLE/Versions/B/PrivateHeaders" "$SPARKLE/Versions/B/Modules"
for item in Sparkle Autoupdate Updater.app XPCServices/Downloader.xpc XPCServices/Installer.xpc; do
    [[ -e "$SPARKLE/Versions/B/$item" ]] || fail "Sparkle.framework lacks $item"
done
echo "    embedded Sparkle $(plutil -extract CFBundleShortVersionString raw "$SPARKLE/Versions/B/Resources/Info.plist")"

# The executable finds Sparkle through @executable_path/../Frameworks (Package.swift). The build also gives it
# rpaths into the build folder and the toolchain, which name this Mac's folders and are no use elsewhere.
RPATHS="$(otool -l "$APP/Contents/MacOS/sTools" | awk '$1 == "cmd" { cmd = $2 } cmd == "LC_RPATH" && $1 == "path" { print $2 }' |
    sort -u)"
grep -qx '@executable_path/../Frameworks' <<< "$RPATHS" ||
    fail "the executable has no @executable_path/../Frameworks rpath, so it would not find Sparkle.framework"
while IFS= read -r rpath; do
    [[ "$rpath" == /* && "$rpath" != /usr/lib/swift ]] || continue
    # install_name_tool removes one copy per -delete_rpath, and a universal binary may list it in each slice.
    while grep -qF " path $rpath (offset" <<< "$(otool -l "$APP/Contents/MacOS/sTools")"; do
        xcrun install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/sTools" 2>/dev/null ||
            fail "cannot remove an rpath into the build folder or the toolchain from the executable"
    done
    echo "    removed the rpath $(sed "s#^$HOME/#~/#" <<< "$rpath" | mask_home)"
done <<< "$RPATHS"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s#__EDKEY__#$UPDATE_KEY#" \
    "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"
if [[ -z "$UPDATE_KEY" ]]; then
    plutil -remove SUPublicEDKey "$APP/Contents/Info.plist"
fi
if [[ "$DEV" -eq 1 ]]; then
    # The dev build: its own name in the menu bar and in Finder, a marker the app reads (STVariant), and nothing that
    # would let it update itself (the app and Sparkle both need the feed and the key). The bundle identifier stays.
    for key in CFBundleName CFBundleDisplayName; do
        plutil -replace "$key" -string "sTools Dev" "$APP/Contents/Info.plist"
    done
    for key in SUFeedURL SUEnableAutomaticChecks SUScheduledCheckInterval; do
        plutil -remove "$key" "$APP/Contents/Info.plist"
    done
    plutil -insert STVariant -string dev "$APP/Contents/Info.plist"
    echo "    dev build: named sTools Dev, no update feed or key"
fi
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

# The build system names each resource bundle's identifier after the checkout folder ("<folder>.STDesign.resources"),
# so the folder's name would ship and the app would differ by where it was built; it also records the build Mac's
# macOS and Xcode versions. Each bundle gets a fixed identifier instead (it is also the bundle's code-signing
# identifier; the code finds its bundles by name, never by identifier), and those keys go.
while IFS= read -r -d '' bundle; do
    name="$(basename "$bundle" .bundle)"
    target="${name#sTools_}"
    [[ "$target" =~ ^[A-Za-z0-9-]+$ ]] || fail "unexpected resource bundle name: $name.bundle"
    plist="$bundle/Contents/Info.plist"
    [[ -f "$plist" ]] || plist="$bundle/Info.plist"
    [[ -f "$plist" ]] || fail "$name.bundle has no Info.plist"
    plutil -replace CFBundleIdentifier -string "com.ducky8x.sTools.$target.resources" "$plist"
    for key in $(plutil -p "$plist" | sed -n 's/^  "\([^"]*\)" =>.*/\1/p' | grep -E '^(DT|BuildMachine)' || true); do
        plutil -remove "${key//./\\.}" "$plist"
    done
    if plutil -p "$plist" | grep -Eq '^  "(DT|BuildMachine)'; then
        fail "$name.bundle's Info.plist still records the build Mac"
    fi
    echo "    $name.bundle: identifier com.ducky8x.sTools.$target.resources"
done < <(find "$APP/Contents/Resources" -maxdepth 1 -type d -name '*.bundle' -print0)

echo "==> Adding the app icon"
# packaging/AppIcon.icon (an Icon Composer document) compiles to Assets.car, which macOS reads through
# CFBundleIconName; packaging/sTools.icns is the flat fallback named by CFBundleIconFile. Both are made by
# scripts/generate-icon.swift. actool's own fallback .icns is not used: it lacks the 32, 256 and 512 sizes.
# The dev build's, in blue, are the same two files under packaging/dev.
ICON_BUILD="$ROOT/build/AppIcon"
ICON_SOURCE="$ROOT/packaging"
ICON_SOURCE_SHOWN="packaging"
if [[ "$DEV" -eq 1 ]]; then
    ICON_BUILD="$ROOT/build/AppIcon-Dev"
    ICON_SOURCE="$ROOT/packaging/dev"
    ICON_SOURCE_SHOWN="packaging/dev"
fi
rm -rf "$ICON_BUILD"
mkdir -p "$ICON_BUILD"
MIN_MACOS="$(plutil -extract LSMinimumSystemVersion raw "$ROOT/packaging/Info.plist")"
if ! ACTOOL_LOG="$(xcrun actool "$ICON_SOURCE/AppIcon.icon" --compile "$ICON_BUILD" \
        --app-icon AppIcon --platform macosx --target-device mac --minimum-deployment-target "$MIN_MACOS" \
        --output-partial-info-plist "$ICON_BUILD/partial.plist" \
        --errors --warnings --output-format human-readable-text 2>&1)" || [[ ! -f "$ICON_BUILD/Assets.car" ]]; then
    echo "$ACTOOL_LOG" >&2
    fail "actool could not compile $ICON_SOURCE_SHOWN/AppIcon.icon (it needs the Xcode 26 or newer actool)"
fi
[[ "$(plutil -extract CFBundleIconName raw "$ICON_BUILD/partial.plist")" == \
   "$(plutil -extract CFBundleIconName raw "$APP/Contents/Info.plist")" ]] ||
    fail "CFBundleIconName in packaging/Info.plist does not match the icon in $ICON_SOURCE_SHOWN/AppIcon.icon"
cp "$ICON_BUILD/Assets.car" "$APP/Contents/Resources/Assets.car"
cp "$ICON_SOURCE/sTools.icns" "$APP/Contents/Resources/sTools.icns"

# What is signed on its own, deepest first, and what its current signature says that re-signing must keep: its
# entitlements and, for a loose tool its vendor signed, its identifier. Read now, because stripping can drop a
# signature. Entitlements tied to the original signer's team or meant for debugging are not kept: under another
# identity, without a provisioning profile, they would stop the item from launching or must not ship.
readonly SIGNER_BOUND_ENTITLEMENTS="com.apple.application-identifier com.apple.developer.team-identifier
    com.apple.security.get-task-allow get-task-allow"
NESTED_LIST="$(list_nested_code)" || fail "cannot list the code inside the app"
NESTED=()
while IFS= read -r item; do
    [[ -z "$item" ]] || NESTED+=("$item")
done <<< "$NESTED_LIST"
SIGN_WORK="$(mktemp -d -t sTools-sign)" || fail "cannot create a temporary folder for signing"
if [[ "${#NESTED[@]}" -gt 0 ]]; then
    for index in "${!NESTED[@]}"; do
        item="${NESTED[$index]}"
        entitlements="$SIGN_WORK/$index.entitlements"
        codesign -d --entitlements - --xml "$item" > "$entitlements" 2>/dev/null || true
        if [[ -s "$entitlements" ]]; then
            plutil -lint -s "$entitlements" || fail "cannot read the entitlements of ${item#"$APP/"}"
            for key in $SIGNER_BOUND_ENTITLEMENTS; do
                # plutil reads dots as key path separators unless they are escaped.
                plutil -remove "${key//./\\.}" "$entitlements" 2>/dev/null || true
            done
            # Nothing left: sign without an entitlements file.
            [[ "$(plutil -p "$entitlements" | tr -d '[:space:]')" != "{}" ]] || : > "$entitlements"
        fi
        if [[ -f "$item" ]]; then
            SIGNATURE="$(codesign -dv "$item" 2>&1 || true)"
            # An ad hoc identifier is made up by the linker (name-hash); codesign makes a better one.
            if [[ "$SIGNATURE" != *"Signature=adhoc"* ]]; then
                sed -n 's/^Identifier=//p' <<< "$SIGNATURE" > "$SIGN_WORK/$index.identifier"
            fi
        fi
    done
fi

if [[ "$MODE" == "release" ]]; then
    ARCHS="$(lipo -archs "$APP/Contents/MacOS/sTools")"
    for arch in arm64 x86_64; do
        [[ " $ARCHS " == *" $arch "* ]] || fail "release binary lacks $arch (has: $ARCHS)"
    done
    echo "    architectures: $ARCHS"

    # Debug info names every source and object file by its absolute path, in the home folder, so it carries the
    # account name, often a real name. dsymutil first collects it into a dSYM for symbolicating crash
    # reports, then strip -S takes it out of every Mach-O in the app. Compiler prefix maps (-debug-prefix-map,
    # -file-prefix-map) are not used instead: the linker still records each object file's absolute path, they do
    # not reach string literals, and they miss any spelling of the path other than the one they are given.
    # The folder is named after the executable's UUIDs: rebuilding the same version and build number makes a new
    # folder unless the binary is the same, so the symbols of a binary that may have shipped are never replaced.
    UUID_TAG="$(xcrun dwarfdump --uuid "$APP/Contents/MacOS/sTools" | awk '{ print $3, $2 }' | sort |
        awk '{ printf "%s%s", (NR > 1 ? "-" : ""), substr($2, 1, 8) }')"
    [[ "$UUID_TAG" =~ ^[0-9A-F]{8}(-[0-9A-F]{8})+$ ]] || fail "cannot read the executable's UUIDs"
    DSYM_NAME="sTools-$VERSION-$BUILD_NUMBER-$UUID_TAG"
    [[ "$DEV" -eq 0 ]] || DSYM_NAME="sTools-Dev-$VERSION-$BUILD_NUMBER-$UUID_TAG"
    # Made in the staging folder, like the app, and moved to build/dSYMs with it.
    DSYM_DIR="$STAGE/dSYMs/$DSYM_NAME"
    DSYM_FINAL="$ROOT/build/dSYMs/$DSYM_NAME"
    echo "==> Saving the debug symbols to ${DSYM_FINAL#"$ROOT/"} and stripping them from the app"
    rm -rf "$DSYM_DIR"
    mkdir -p "$DSYM_DIR"
    STRIPPED=0
    while IFS= read -r -d '' macho; do
        [[ "$(file -b "$macho")" == Mach-O* ]] || continue
        dsym=""
        # A debug map (OSO entries naming the object files) is what dsymutil reads the debug info through.
        if xcrun nm -ap "$macho" | awk '$5 == "OSO" { found = 1 } END { exit !found }'; then
            dsym="$DSYM_DIR/$(basename "$macho").dSYM"
            [[ ! -e "$dsym" ]] || fail "two binaries in the app are named $(basename "$macho")"
            # A warning means part of the debug info was not found (an object file gone, say): the dSYM would
            # match the binary's UUIDs and still leave crash reports without names.
            if ! DSYMUTIL_LOG="$(xcrun dsymutil "$macho" -o "$dsym" 2>&1)" ||
                grep -Eqi '(warning|error):' <<< "$DSYMUTIL_LOG"; then
                mask_home <<< "$DSYMUTIL_LOG" >&2
                fail "dsymutil could not save all of the debug symbols of ${macho#"$APP/"}"
            fi
        fi
        # strip warns that it breaks a binary's signature (everything is signed again below); anything else it says
        # is passed on with the home folder shortened.
        STRIP_STATUS=0
        STRIP_LOG="$(xcrun strip -S "$macho" 2>&1)" || STRIP_STATUS=$?
        grep -v 'changes being made to the file will invalidate the code signature' <<< "$STRIP_LOG" |
            grep -v '^$' | mask_home >&2 || true
        [[ "$STRIP_STATUS" -eq 0 ]] || fail "strip failed on ${macho#"$APP/"}"
        if [[ -n "$dsym" ]]; then
            [[ "$(macho_uuids "$dsym")" == "$(macho_uuids "$macho")" ]] ||
                fail "the dSYM does not match ${macho#"$APP/"} after stripping"
            echo "    ${macho#"$APP/"}: stripped; $(basename "$dsym") matches its $(macho_uuids "$macho" | wc -l | tr -d ' ') slices"
        else
            echo "    ${macho#"$APP/"}: stripped (it had no debug map)"
        fi
        STRIPPED=$((STRIPPED + 1))
    done < <(find "$APP" -type f -print0)
    [[ "$STRIPPED" -gt 0 ]] || fail "found no Mach-O binary in the app to strip"
fi

echo "==> Signing with $SIGN_DESCRIPTION"
xattr -cr "$APP"
SIGN_ARGS=(--force --sign "$SIGN_ID" --timestamp=none)
if [[ -n "$KEYCHAIN" && "$SIGN_ID" != "-" ]]; then
    SIGN_ARGS+=(--keychain "$KEYCHAIN")
fi
# Inside out: everything nested, deepest first (a framework's XPC services, helper app and tool before the
# framework), with Hardened Runtime and its own entitlements; then the app with its entitlements.
if [[ "${#NESTED[@]}" -gt 0 ]]; then
    for index in "${!NESTED[@]}"; do
        item="${NESTED[$index]}"
        ITEM_ARGS=(--options runtime)
        if [[ -s "$SIGN_WORK/$index.entitlements" ]]; then
            ITEM_ARGS+=(--entitlements "$SIGN_WORK/$index.entitlements")
        fi
        if [[ -s "$SIGN_WORK/$index.identifier" ]]; then
            ITEM_ARGS+=(--identifier "$(head -n 1 "$SIGN_WORK/$index.identifier")")
        fi
        codesign "${SIGN_ARGS[@]}" "${ITEM_ARGS[@]}" "$item"
        echo "    signed ${item#"$APP/"}$( [[ -s "$SIGN_WORK/$index.entitlements" ]] && echo " (with its entitlements)")"
    done
fi
codesign "${SIGN_ARGS[@]}" --options runtime --entitlements "$ROOT/packaging/sTools.entitlements" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
# Signed by the expected identity, or ad hoc when that was asked for.
check_signer() {
    local info="$1" what="$2"
    if [[ "$SIGN_ID" == "-" ]]; then
        [[ "$info" == *"Signature=adhoc"* ]] || fail "expected an ad hoc signature on $what"
    else
        grep -qx "Authority=$IDENTITY_NAME" <<< "$info" || fail "$what was not signed by \"$IDENTITY_NAME\""
    fi
}
if [[ "${#NESTED[@]}" -gt 0 ]]; then
    for item in "${NESTED[@]}"; do
        check_signer "$(codesign -dvv "$item" 2>&1)" "${item#"$APP/"}"
    done
    echo "    ${#NESTED[@]} nested item(s) signed by $SIGN_DESCRIPTION"
fi
SIGNATURE_INFO="$(codesign -dvv "$APP" 2>&1)"
grep -E '^(Identifier|Format|CodeDirectory|Signature|Authority|TeamIdentifier)' <<< "$SIGNATURE_INFO" || true
check_signer "$SIGNATURE_INFO" "the app"
# Both builds share one bundle identifier, which is what keeps macOS's permissions and the app's own settings.
grep -qx 'Identifier=com.ducky8x.sTools' <<< "$SIGNATURE_INFO" ||
    fail "the app's signing identifier is not com.ducky8x.sTools"
if [[ "$DEV" -eq 1 ]]; then
    # What makes it the dev build, read back from the finished app: its marker, its name and no way to update.
    [[ "$(plutil -extract STVariant raw -o - "$APP/Contents/Info.plist")" == "dev" ]] || fail "the dev build lacks STVariant dev"
    for key in CFBundleName CFBundleDisplayName; do
        [[ "$(plutil -extract "$key" raw -o - "$APP/Contents/Info.plist")" == "sTools Dev" ]] ||
            fail "the dev build's $key is not \"sTools Dev\""
    done
    for key in SUFeedURL SUPublicEDKey; do
        ! plutil -extract "$key" raw -o - "$APP/Contents/Info.plist" >/dev/null 2>&1 ||
            fail "the dev build has $key in its Info.plist: it must never update itself"
    done
    echo "    dev build: STVariant dev, named sTools Dev, no update feed or key"
fi
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<< "$SIGNATURE_INFO" ||
    fail "Hardened Runtime is not enabled"
codesign -dr - "$APP" 2>&1 | grep -E '^(# )?designated'

if [[ "$MODE" == "release" ]]; then
    echo "==> Checking the app for home-folder paths, names and traces of this Mac"
    "$ROOT/scripts/check-no-home-paths.sh" "$APP" ||
        fail "build/$APP_NAME must not ship: it holds a home-folder path, a name or a trace of this Mac (listed above)"
fi

# Every step and check has passed: the app, and its symbols, take their places.
echo "==> Moving the finished app to $(shown "$FINAL_APP")"
if [[ "$MODE" == "release" ]]; then
    mkdir -p "$ROOT/build/dSYMs"
    rm -rf "$DSYM_FINAL"
    mv "$DSYM_DIR" "$DSYM_FINAL"
fi
stage_commit "$APP" "$FINAL_APP" "$STAGE"
COMMITTED=1

echo
echo "Built $(shown "$FINAL_APP") ($MODE, version $VERSION, build $BUILD_NUMBER)"
if [[ "$MODE" == "release" ]]; then
    echo "Debug symbols for its crash reports: ${DSYM_FINAL#"$ROOT/"} (not shipped; keep them)"
fi
echo "Run it from the repository's folder with: open \"$(shown "$FINAL_APP")\""
