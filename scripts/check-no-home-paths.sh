#!/bin/bash
# Fails when something that ships carries a trace of the person or the Mac that built it.
#
# Usage: scripts/check-no-home-paths.sh [--provenance] <file-or-folder>...
#
# The account name (`id -un`) is often a person's real name, and every path in the home folder (/Users/<name>/...)
# carries it. scripts/build-app.sh runs this on release builds and scripts/build-dmg.sh on the disk image. Under
# each argument, without following symbolic links, it reads every file's bytes, every file's and folder's name
# (relative to the argument: where the argument itself sits does not ship), every symbolic link's target and every
# extended attribute's name and value, and looks for:
#   - "/Users/" and "/var/folders/" in any letter case: paths in a home folder and in a per-user temporary folder;
#   - the account name, the home folder's path and name, and the full name (`id -F`): as it is, run together, last
#     name first, and each part of three letters or more on its own (a part shorter than six letters only as a word
#     of its own, so it is not found inside longer words);
#   - this user's temporary-folder id and UUID; this Mac's hardware UUID, serial number and volume UUIDs; and the
#     provenance id macOS stamps on the files that apps it tracks make (as data inside files);
#   - any names listed one per line in CHECK_NO_HOME_PATHS_EXTRA_NAMES (to test the check with a made-up name; the
#     build scripts' output filter, scripts/lib/mask-home.sh, hides them too).
# Text is found as UTF-8 and UTF-16 and with %XX, &#NN; and backslash escapes decoded. Compressed streams that
# unpack completely and pass their checksums are unpacked and searched too: zlib (PNG chunks, compressed disk
# images), gzip, zip, LZFSE and LZVN (asset catalogs), LZ4 and xz; so are property list <data>, other base64 and
# long runs of hex digits.
#
#   --provenance  Also fail on any com.apple.provenance extended attribute that holds an id. macOS adds one to every
#                 file made by a process started from an app it tracks (a downloaded editor or terminal), and only a
#                 process it does not track can remove it (scripts/build-dmg.sh does, for the disk image).
#
# Each finding is printed with its path relative to the argument and a count; for a name looked for only as a word,
# also the byte offsets where it was found (look with xxd -s <offset> <file>), never the bytes around it, which can
# hold the rest of a name. Nothing looked for is ever printed: placeholders such as <account name> stand in for it, for
# the full name and for each part of it on its own.
#
# The check itself is scripts/check-no-home-paths.swift, compiled once per version of that file and of the compiler
# into the per-user temporary folder.
#
# Exit status: 0 when nothing was found, 1 when something was, 2 when the check could not run.

set -euo pipefail

readonly XCODE_BETA="/Applications/Xcode-beta.app/Contents/Developer"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SOURCE="$ROOT/scripts/check-no-home-paths.swift"
# shellcheck source=lib/mask-home.sh
source "$ROOT/scripts/lib/mask-home.sh"

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

broken() {
    echo "error: $*" >&2
    exit 2
}

case "${1:-}" in
    "")
        usage
        exit 2
        ;;
    -h|--help)
        usage
        exit 0
        ;;
esac

if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_BETA" ]]; then
    export DEVELOPER_DIR="$XCODE_BETA"
fi
[[ -f "$SOURCE" ]] || broken "scripts/check-no-home-paths.swift is missing"

CACHE="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
CACHE="${CACHE:-${TMPDIR:-/tmp}}"
CACHE="${CACHE%/}/sTools-check-no-home-paths"
KEY="$( { shasum -a 256 < "$SOURCE"; xcrun swiftc --version 2>&1; } | shasum -a 256 | cut -c1-16)" ||
    broken "cannot read scripts/check-no-home-paths.swift or the Swift compiler's version"
CHECKER="$CACHE/check-$KEY"
if [[ ! -x "$CHECKER" ]]; then
    mkdir -p "$CACHE" && chmod 700 "$CACHE" || broken "cannot create the folder for the compiled check"
    PARTIAL="$(mktemp "$CACHE/partial.XXXXXX")" || broken "cannot create a file in the folder for the compiled check"
    if ! xcrun swiftc -O -o "$PARTIAL" "$SOURCE" 2>"$PARTIAL.log"; then
        mask_home < "$PARTIAL.log" >&2
        rm -f "$PARTIAL" "$PARTIAL.log"
        broken "scripts/check-no-home-paths.swift does not compile"
    fi
    rm -f "$PARTIAL.log"
    mv -f "$PARTIAL" "$CHECKER"
fi
exec "$CHECKER" "$@"
