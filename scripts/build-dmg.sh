#!/bin/bash
# Builds the styled DMG build/sTools-<version>.dmg from build/sTools.app.
#
# Usage: scripts/build-dmg.sh [--app <path>] [--volume-icon <file.icns>]
#
#   --app          The app to package (default build/sTools.app; run scripts/build-app.sh first).
#                  Its CFBundleShortVersionString names the DMG.
#   --volume-icon  The DMG's volume icon (default packaging/sTools.icns; skipped when that file does not exist).
#
# Environment:
#   DEVELOPER_DIR  Defaults to the Xcode beta when it is installed.
#
# The window: a dark background drawn by scripts/dmg-window.swift (wordmark, a gold arrow from sTools to
# Applications, and the one-time Open Anyway steps), at 1x and 2x in one TIFF so it is sharp on Retina
# displays; the app and an Applications link at fixed positions; no toolbar, sidebar or status bar.
#
# No Finder scripting: the window layout is written straight into the volume's .DS_Store by
# scripts/dmg-window.swift, so building needs no Automation permission and works without a logged-in Finder.
# The read-write image is mounted at /Volumes/sTools (hidden from Finder) while the layout is written, because
# the background is referenced by an alias and bookmark that record that volume. A volume already mounted
# there is refused rather than worked around.
#
# The DMG itself is not signed: macOS checks the app's signature, not the disk image's.

set -euo pipefail

readonly VOLUME_NAME="sTools"
readonly APP_NAME="sTools.app"
readonly XCODE_BETA="/Applications/Xcode-beta.app/Contents/Developer"
readonly IDENTITY_NAME="ducky8x"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

fail() {
    echo "error: $*" >&2
    exit 1
}

APP="$ROOT/build/$APP_NAME"
VOLUME_ICON="$ROOT/packaging/sTools.icns"
VOLUME_ICON_GIVEN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            [[ $# -ge 2 ]] || fail "--app needs a path"
            APP="$2"
            shift
            ;;
        --volume-icon)
            [[ $# -ge 2 ]] || fail "--volume-icon needs a path"
            VOLUME_ICON="$2"
            VOLUME_ICON_GIVEN=1
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

if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_BETA" ]]; then
    export DEVELOPER_DIR="$XCODE_BETA"
fi

# The app.
[[ -d "$APP" ]] || fail "no app at $APP. Build it first with scripts/build-app.sh"
APP="$(cd "$APP" && pwd -P)"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" ||
    fail "cannot read CFBundleShortVersionString from $APP/Contents/Info.plist"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] ||
    fail "the app's version must look like 1.2.3 or 1.2.3-beta.1, got \"$VERSION\""
codesign --verify --deep --strict "$APP" 2>/dev/null || fail "$APP has no valid code signature"
SIGNATURE_INFO="$(codesign -dvv "$APP" 2>&1)"
if ! grep -qx "Authority=$IDENTITY_NAME" <<< "$SIGNATURE_INFO"; then
    echo "warning: $APP is not signed by \"$IDENTITY_NAME\"; testers would lose their permission grants" >&2
    echo "warning: on every update. Release builds come from: scripts/build-app.sh release" >&2
fi

# The volume icon.
if [[ -f "$VOLUME_ICON" ]]; then
    [[ "$(head -c 4 "$VOLUME_ICON")" == "icns" ]] || fail "$VOLUME_ICON is not an .icns file"
elif [[ "$VOLUME_ICON_GIVEN" -eq 1 ]]; then
    fail "no volume icon at $VOLUME_ICON"
else
    echo "note: no ${VOLUME_ICON#"$ROOT/"} yet; the DMG gets the standard disk image icon."
    VOLUME_ICON=""
fi

readonly MOUNT_POINT="/Volumes/$VOLUME_NAME"
[[ ! -e "$MOUNT_POINT" ]] ||
    fail "$MOUNT_POINT is in use (another $VOLUME_NAME disk image is mounted?). Eject it and run again."

readonly OUTPUT="$ROOT/build/sTools-$VERSION.dmg"
mkdir -p "$ROOT/build"
WORK="$(mktemp -d "$ROOT/build/.dmg-work.XXXXXX")"
readonly WORK
ATTACHED=""

# Detaches a disk image, retrying while Spotlight or fseventsd still hold it, and forcing it at the end.
detach() {
    local device="$1" attempt
    for attempt in 1 2 3 4 5; do
        hdiutil detach "$device" -quiet 2>/dev/null && return 0
        sleep "$attempt"
    done
    hdiutil detach "$device" -force -quiet
}

cleanup() {
    if [[ -n "$ATTACHED" ]]; then
        detach "$ATTACHED" || echo "warning: could not detach $ATTACHED; eject it in Finder" >&2
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# Attaches a disk image (extra hdiutil options follow the path) and sets ATTACHED and ATTACHED_MOUNT.
# macOS 26 and later print a deprecation notice for these options; it is dropped, other messages are kept.
attach() {
    local output device kind mount
    if ! output="$(hdiutil attach "$@" -noautoopen -nobrowse 2>"$WORK/attach.log")"; then
        cat "$WORK/attach.log" >&2
        fail "hdiutil could not attach $1"
    fi
    grep -v 'is deprecated' "$WORK/attach.log" >&2 || true
    ATTACHED_MOUNT=""
    while IFS=$'\t' read -r device kind mount; do
        device="${device%"${device##*[![:space:]]}"}"
        mount="${mount%"${mount##*[![:space:]]}"}"
        if [[ "$mount" == /* ]]; then
            ATTACHED="$device"
            ATTACHED_MOUNT="$mount"
        fi
    done <<< "$output"
    [[ -n "$ATTACHED_MOUNT" ]] || fail "hdiutil attached $1 but reported no mount point:"$'\n'"$output"
}

echo "==> Compiling scripts/dmg-window.swift"
swiftc -o "$WORK/dmg-window" "$ROOT/scripts/dmg-window.swift"

echo "==> Drawing the background"
"$WORK/dmg-window" background "$WORK/background" --version "$VERSION" | sed 's/^/    /'
mkdir -p "$WORK/stage/.background"
tiffutil -cathidpicheck "$WORK/background/background.png" "$WORK/background/background@2x.png" \
    -out "$WORK/stage/.background/background.tiff" 2>&1 | sed 's/^/    /'
[[ -f "$WORK/stage/.background/background.tiff" ]] || fail "tiffutil did not write the background"

echo "==> Staging $APP_NAME, the Applications link$( [[ -n "$VOLUME_ICON" ]] && echo " and the volume icon")"
ditto "$APP" "$WORK/stage/$APP_NAME"
ln -s /Applications "$WORK/stage/Applications"
if [[ -n "$VOLUME_ICON" ]]; then
    cp "$VOLUME_ICON" "$WORK/stage/.VolumeIcon.icns"
fi

echo "==> Creating the read-write image"
STAGE_KB="$(du -sk "$WORK/stage" | cut -f1)"
SIZE_MB=$(( STAGE_KB * 12 / 10 / 1024 + 16 ))
hdiutil create -quiet -srcfolder "$WORK/stage" -volname "$VOLUME_NAME" -fs HFS+ -format UDRW \
    -size "${SIZE_MB}m" "$WORK/rw.dmg"

echo "==> Writing the Finder layout"
attach "$WORK/rw.dmg" -readwrite -noverify
[[ "$ATTACHED_MOUNT" == "$MOUNT_POINT" ]] ||
    fail "the image mounted at $ATTACHED_MOUNT instead of $MOUNT_POINT"
"$WORK/dmg-window" ds-store "$MOUNT_POINT" | sed 's/^/    /'
chflags hidden "$MOUNT_POINT/.background"
if [[ -n "$VOLUME_ICON" ]]; then
    # The volume root's Finder info, with only the "has custom icon" flag (0x0400) set.
    xattr -wx com.apple.FinderInfo \
        "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT_POINT"
    chflags hidden "$MOUNT_POINT/.VolumeIcon.icns"
fi
rm -rf "$MOUNT_POINT/.fseventsd" "$MOUNT_POINT/.Spotlight-V100" "$MOUNT_POINT/.Trashes" 2>/dev/null || true
sync
detach "$ATTACHED"
ATTACHED=""

echo "==> Compressing to ${OUTPUT#"$ROOT/"}"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUTPUT"
hdiutil verify -quiet "$OUTPUT" || fail "hdiutil verify failed for $OUTPUT"

echo "==> Checking the DMG's contents"
mkdir -p "$WORK/check"
attach "$OUTPUT" -readonly -mountpoint "$WORK/check"
CHECK="$ATTACHED_MOUNT"
[[ -d "$CHECK/$APP_NAME" ]] || fail "the DMG has no $APP_NAME"
codesign --verify --deep --strict "$CHECK/$APP_NAME" 2>/dev/null || fail "the app's signature broke in the DMG"
[[ -L "$CHECK/Applications" && "$(readlink "$CHECK/Applications")" == "/Applications" ]] ||
    fail "the DMG has no Applications link"
[[ -f "$CHECK/.background/background.tiff" ]] || fail "the DMG has no background"
[[ "$(tiffutil -info "$CHECK/.background/background.tiff" 2>/dev/null | grep -c 'Image Width')" -eq 2 ]] ||
    fail "the background TIFF should hold a 1x and a 2x image"
LAYOUT="$("$WORK/dmg-window" dump "$CHECK/.DS_Store")" || fail "the DMG's .DS_Store does not read back"
for record in $'.\tbwsp' $'.\ticvp' $'.\tpBBk' $'.\tvstl' "$APP_NAME"$'\tIloc' $'Applications\tIloc'; do
    grep -q "^$record"$'\t' <<< "$LAYOUT" || fail "the .DS_Store lacks the record \"${record//$'\t'/ }\""
done
# Mounted somewhere other than /Volumes/sTools, the background's alias and bookmark must still find it
# (by the volume's identity), as Finder does when another "sTools" volume is already mounted.
BACKGROUND_PATH="$CHECK/.background/background.tiff"
grep -qF "backgroundImageAlias -> $BACKGROUND_PATH " <<< "$LAYOUT" ||
    fail "the background's alias does not lead to the background"
grep -qF "bookmark -> $BACKGROUND_PATH" <<< "$LAYOUT" || fail "the background's bookmark does not lead to the background"
if [[ -n "$VOLUME_ICON" ]]; then
    [[ -f "$CHECK/.VolumeIcon.icns" ]] || fail "the DMG has no volume icon"
fi
sed 's/^/    /' <<< "$LAYOUT" | cut -c1-160
detach "$ATTACHED"
ATTACHED=""

echo
echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1 | tr -d ' '), version $VERSION)"
echo "SHA-256 $(shasum -a 256 "$OUTPUT" | cut -d' ' -f1)"
