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
# The images are mounted at private mount points in the work folder, hidden from Finder, so a disk image already
# mounted at /Volumes/sTools does not get in the way. The background is referenced by an alias and a bookmark that
# record the volume as mounted at /Volumes/sTools plus its identity, so Finder finds the picture wherever the volume
# is mounted; the check at the end mounts the finished DMG elsewhere and resolves both (while another volume is
# mounted at /Volumes/sTools, macOS resolves the alias into that one by name, so the alias is checked field by field).
#
# Nothing in the DMG may carry a trace of the person or the Mac that built it (scripts/check-no-home-paths.sh):
#   - The work folder is in the per-user temporary folder, outside the home folder, and removed on exit.
#   - The bookmark is written field by field: the system's own also records the disk image file's path (in the
#     per-user temporary folder), the startup volume's name, UUID, size and dates, and sandbox tokens.
#   - macOS stamps com.apple.provenance, with an id for the app the build was started from, on every file a process
#     started from a tracked app (a downloaded editor or terminal) makes, and only an untracked process can remove
#     it: a one-off launchd job removes it from the volume, and from the DMG file, when it is there.
#   - The check runs on the mounted volume before it is compressed (every file, name, link and extended
#     attribute, .DS_Store included), on the whole uncompressed image (file system records and free space too),
#     then on the finished DMG's files and on the DMG file itself. Any finding fails the build.
#
# The DMG itself is not signed: macOS checks the app's signature, not the disk image's.

set -euo pipefail

readonly VOLUME_NAME="sTools"
readonly APP_NAME="sTools.app"
readonly XCODE_BETA="/Applications/Xcode-beta.app/Contents/Developer"
readonly IDENTITY_NAME="ducky8x"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
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
[[ -d "$APP" ]] || fail "no app at $(shown "$APP"). Build it first with scripts/build-app.sh release"
APP="$(cd "$APP" && pwd -P)"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" ||
    fail "cannot read CFBundleShortVersionString from $(shown "$APP")/Contents/Info.plist"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] ||
    fail "the app's version must look like 1.2.3 or 1.2.3-beta.1, got \"$VERSION\""
codesign --verify --deep --strict "$APP" 2>/dev/null || fail "$(shown "$APP") has no valid code signature"
SIGNATURE_INFO="$(codesign -dvv "$APP" 2>&1)"
if ! grep -qx "Authority=$IDENTITY_NAME" <<< "$SIGNATURE_INFO"; then
    echo "warning: $(shown "$APP") is not signed by \"$IDENTITY_NAME\"; testers would lose their permission" >&2
    echo "warning: grants on every update. Release builds come from: scripts/build-app.sh release" >&2
fi

# The volume icon.
if [[ -f "$VOLUME_ICON" ]]; then
    [[ "$(head -c 4 "$VOLUME_ICON")" == "icns" ]] || fail "$(shown "$VOLUME_ICON") is not an .icns file"
elif [[ "$VOLUME_ICON_GIVEN" -eq 1 ]]; then
    fail "no volume icon at $(shown "$VOLUME_ICON")"
else
    echo "note: no $(shown "$VOLUME_ICON") yet; the DMG gets the standard disk image icon."
    VOLUME_ICON=""
fi

readonly OUTPUT="$ROOT/build/sTools-$VERSION.dmg"
mkdir -p "$ROOT/build"

# In the per-user temporary folder, never in build/ (in the home folder). mktemp -t takes the system's per-user
# folder (where $TMPDIR points by default) even when TMPDIR is changed, and falls back to $TMPDIR and /tmp. pwd -P
# spells the path the way hdiutil reports it (/private/var/..., not /var/...).
WORK="$(mktemp -d -t sTools-dmg)" || fail "cannot create a work folder in the temporary folder"
WORK="$(cd "$WORK" && pwd -P)"
readonly WORK
ATTACHED=""
JOB_LABEL=""

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
    if [[ -n "$JOB_LABEL" ]]; then
        launchctl remove "$JOB_LABEL" 2>/dev/null || true
    fi
    if [[ -n "$ATTACHED" ]]; then
        detach "$ATTACHED" || echo "warning: could not detach $ATTACHED; eject it in Finder" >&2
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

WORK_LOWER="$(printf '%s' "$WORK" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
ACCOUNT_LOWER="$(id -un | LC_ALL=C tr '[:upper:]' '[:lower:]')"
if [[ "$WORK" == *"/Users/"* || "$WORK_LOWER" == *"$ACCOUNT_LOWER"* ]]; then
    fail "the temporary folder is in the home folder, and the DMG would record its path;" \
        "set TMPDIR to a folder outside it"
fi

# Attaches a disk image at a private mount point (extra hdiutil options follow) and sets ATTACHED. macOS 26 and
# later print a deprecation notice for these options; it is dropped, other messages are kept.
attach() {
    local image="$1" mount_point="$2" output device kind mount found=""
    shift 2
    mkdir -p "$mount_point"
    if ! output="$(hdiutil attach "$image" "$@" -mountpoint "$mount_point" -noautoopen -nobrowse \
            2>"$WORK/attach.log")"; then
        cat "$WORK/attach.log" >&2
        fail "hdiutil could not attach $(shown "$image")"
    fi
    grep -v 'is deprecated' "$WORK/attach.log" >&2 || true
    while IFS=$'\t' read -r device kind mount; do
        device="${device%"${device##*[![:space:]]}"}"
        mount="${mount%"${mount##*[![:space:]]}"}"
        if [[ "$mount" == /* ]]; then
            ATTACHED="$device"
            found="$mount"
        fi
    done <<< "$output"
    [[ "$found" == "$mount_point" ]] ||
        fail "hdiutil attached $(shown "$image") at ${found:-no mount point} instead of the work folder"
}

# Whether anything under the given paths carries com.apple.provenance.
has_provenance() {
    find "$@" -print0 | xargs -0 xattr -s 2>/dev/null | grep -q 'com\.apple\.provenance'
}

# Removes com.apple.provenance from everything under the given paths, from a one-off launchd job: launchd starts it
# untracked, and only an untracked process can remove the attribute (a tracked one gets no error, but it stays).
clear_provenance() {
    local finished="$WORK/provenance.done" attempt
    has_provenance "$@" || return 0
    cat > "$WORK/clear-provenance.sh" <<'EOF'
#!/bin/sh
# $1: the file to write when done; then the paths to clear. An item without the attribute is not an error.
finished="$1"
shift
/usr/bin/find "$@" -print0 | /usr/bin/xargs -0 /usr/bin/xattr -s -d com.apple.provenance 2>/dev/null
echo done > "$finished"
EOF
    rm -f "$finished"
    JOB_LABEL="com.ducky8x.sTools.build-dmg.clear-provenance.$$.$RANDOM"
    launchctl submit -l "$JOB_LABEL" -o "$WORK/provenance.log" -e "$WORK/provenance.log" -- \
        /bin/sh "$WORK/clear-provenance.sh" "$finished" "$@" ||
        fail "could not start the launchd job that removes com.apple.provenance"
    for attempt in $(seq 1 120); do
        [[ -f "$finished" ]] && break
        sleep 0.5
    done
    # launchctl submit jobs are kept alive: remove it now that it has run once.
    launchctl remove "$JOB_LABEL" 2>/dev/null || true
    JOB_LABEL=""
    [[ -f "$finished" ]] || fail "the launchd job that removes com.apple.provenance did not finish"
    ! has_provenance "$@" || fail "com.apple.provenance is still there after the launchd job removed it"
    echo "    removed com.apple.provenance (macOS sets it on files made from tracked apps)"
}

# Copies standard input to standard output with the work folder's path (it holds this user's temporary-folder id)
# shortened, as /private/var/... and as /var/..., and indented.
indented() {
    sed -e "s#$WORK/#(work folder)/#g" -e "s#${WORK#/private}/#(work folder)/#g" -e 's/^/    /'
}

echo "==> Compiling scripts/dmg-window.swift"
swiftc -o "$WORK/dmg-window" "$ROOT/scripts/dmg-window.swift"

echo "==> Drawing the background"
"$WORK/dmg-window" background "$WORK/background" --version "$VERSION" | indented
mkdir -p "$WORK/stage/.background"
cp "$WORK/background/background.tiff" "$WORK/stage/.background/background.tiff"

echo "==> Staging $APP_NAME, the Applications link$( [[ -n "$VOLUME_ICON" ]] && echo " and the volume icon")"
# Without extended attributes: a signed app needs none, and they could carry anything.
ditto --noextattr "$APP" "$WORK/stage/$APP_NAME"
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
VOLUME="$WORK/volume/$VOLUME_NAME"
attach "$WORK/rw.dmg" "$VOLUME" -readwrite -noverify
"$WORK/dmg-window" ds-store "$VOLUME" | indented
chflags hidden "$VOLUME/.background"
if [[ -n "$VOLUME_ICON" ]]; then
    # The volume root's Finder info, with only the "has custom icon" flag (0x0400) set.
    xattr -wx com.apple.FinderInfo \
        "0000000000000000040000000000000000000000000000000000000000000000" "$VOLUME"
    chflags hidden "$VOLUME/.VolumeIcon.icns"
fi
rm -rf "$VOLUME/.fseventsd" "$VOLUME/.Spotlight-V100" "$VOLUME/.Trashes" 2>/dev/null || true
clear_provenance "$VOLUME"

echo "==> Checking the volume and then the whole image before compressing"
# Everything on the volume, file by file, so a finding names its file; then, once it is detached, the whole image
# byte for byte: the file system's own records, extended attributes and free space too.
"$ROOT/scripts/check-no-home-paths.sh" --provenance "$VOLUME" ||
    fail "the DMG would carry a home-folder path, a name or a trace of this Mac (listed above)." \
        "Package a release build (scripts/build-app.sh release): a debug build keeps its debug info"
sync
detach "$ATTACHED"
ATTACHED=""
"$ROOT/scripts/check-no-home-paths.sh" "$WORK/rw.dmg" ||
    fail "the uncompressed image carries a home-folder path, a name or a trace of this Mac outside its files"

echo "==> Compressing to $(shown "$OUTPUT")"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUTPUT"
hdiutil verify -quiet "$OUTPUT" || fail "hdiutil verify failed for $(shown "$OUTPUT")"

echo "==> Checking the DMG's contents"
# Mounted somewhere other than /Volumes/sTools, as when another sTools volume is already mounted; named like the
# volume, so the check below reports paths as users see them (sTools/sTools.app/...).
CHECK="$WORK/check/$VOLUME_NAME"
attach "$OUTPUT" "$CHECK" -readonly
[[ -d "$CHECK/$APP_NAME" ]] || fail "the DMG has no $APP_NAME"
codesign --verify --deep --strict "$CHECK/$APP_NAME" 2>/dev/null || fail "the app's signature broke in the DMG"
[[ -L "$CHECK/Applications" && "$(readlink "$CHECK/Applications")" == "/Applications" ]] ||
    fail "the DMG has no Applications link"
[[ -f "$CHECK/.background/background.tiff" ]] || fail "the DMG has no background"
BACKGROUND_INFO="$(tiffutil -info "$CHECK/.background/background.tiff" 2>/dev/null)"
[[ "$(grep -c 'Image Width' <<< "$BACKGROUND_INFO")" -eq 2 ]] ||
    fail "the background TIFF should hold a 1x and a 2x image"
! grep -Eq 'Software|Image Description' <<< "$BACKGROUND_INFO" ||
    fail "the background TIFF names the tool or the files it was made with"
LAYOUT="$("$WORK/dmg-window" dump "$CHECK/.DS_Store")" || fail "the DMG's .DS_Store does not read back"
for record in $'.\tbwsp' $'.\ticvp' $'.\tpBBk' $'.\tvstl' "$APP_NAME"$'\tIloc' $'Applications\tIloc'; do
    grep -q "^$record"$'\t' <<< "$LAYOUT" || fail "the .DS_Store lacks the record \"${record//$'\t'/ }\""
done
# The background's alias and bookmark record /Volumes/sTools: mounted here, they must still find it by the
# volume's identity, as Finder does when another "sTools" volume is mounted. The bookmark does, by the volume's
# UUID. macOS resolves the alias into any volume named "sTools" mounted at /Volumes/sTools, so while one is (an
# earlier DMG, say), the alias's fields are what is checked.
BACKGROUND_PATH="$CHECK/.background/background.tiff"
grep -qF "bookmark -> $BACKGROUND_PATH" <<< "$LAYOUT" || fail "the background's bookmark does not lead to the background"
grep -qF "backgroundImageAlias matches this volume" <<< "$LAYOUT" ||
    fail "the background's alias does not describe this volume's background"
if ! grep -qF "backgroundImageAlias -> $BACKGROUND_PATH " <<< "$LAYOUT"; then
    [[ -e "/Volumes/$VOLUME_NAME" ]] || fail "the background's alias does not lead to the background"
    echo "note: another volume is mounted at /Volumes/$VOLUME_NAME, and macOS resolves the alias into it by name;"
    echo "note: the alias was checked field by field against this volume instead (it matches)."
fi
if [[ -n "$VOLUME_ICON" ]]; then
    [[ -f "$CHECK/.VolumeIcon.icns" ]] || fail "the DMG has no volume icon"
fi
indented <<< "$LAYOUT" | cut -c1-160
if ! "$ROOT/scripts/check-no-home-paths.sh" --provenance "$CHECK"; then
    detach "$ATTACHED"
    ATTACHED=""
    rm -f "$OUTPUT"
    fail "the DMG carries a home-folder path, a name or a trace of this Mac (listed above); it was deleted"
fi
detach "$ATTACHED"
ATTACHED=""

echo "==> Checking the DMG file"
# Mounting and verifying leave extended attributes on the file (a checksum cache that names this Mac's volume);
# they are not part of the image, but they travel with the file to some places.
xattr -c "$OUTPUT"
clear_provenance "$OUTPUT"
# Its block table, trailer and every compressed block, unpacked.
if ! "$ROOT/scripts/check-no-home-paths.sh" --provenance "$OUTPUT"; then
    rm -f "$OUTPUT"
    fail "the DMG file carries a home-folder path, a name or a trace of this Mac (listed above); it was deleted"
fi

echo
echo "Built $(shown "$OUTPUT") ($(du -h "$OUTPUT" | cut -f1 | tr -d ' '), version $VERSION)"
echo "SHA-256 $(shasum -a 256 "$OUTPUT" | cut -d' ' -f1)"
