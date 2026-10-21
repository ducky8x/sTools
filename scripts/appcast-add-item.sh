#!/bin/bash
# Prints an update feed (appcast.xml) with one more version at its top, right below the line that marks where new
# versions go. scripts/publish-update.sh uses it; it only reads files and writes to standard output.
#
# Usage: scripts/appcast-add-item.sh <appcast.xml> <version> <build> <minimum macOS> <download URL> <length>
#                                    <EdDSA signature> <notes.md>
#
# The notes (Markdown) go into the item's description, which Sparkle shows in its update window.

set -euo pipefail

MARKER="<!-- New versions go right below this line"

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ $# -eq 8 ]] || fail "usage: scripts/appcast-add-item.sh <appcast.xml> <version> <build> <minimum macOS> <URL> <length> <signature> <notes.md>"
FEED="$1" VERSION="$2" BUILD="$3" MINIMUM_MACOS="$4" URL="$5" LENGTH="$6" SIGNATURE="$7" NOTES="$8"
[[ -f "$FEED" ]] || fail "no feed at $FEED"
[[ -f "$NOTES" ]] || fail "no notes at $NOTES"
grep -qF "$MARKER" "$FEED" || fail "the feed lacks the line that marks where new versions go"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version must look like 1.2.3"
[[ "$BUILD" =~ ^[0-9]+$ && "$LENGTH" =~ ^[0-9]+$ ]] || fail "the build and the length must be whole numbers"
[[ "$MINIMUM_MACOS" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "the minimum macOS must look like 15.0"
[[ "$URL" =~ ^https://[^\"\<\>[:space:]]+$ ]] || fail "the download URL must be an https URL"
[[ "$SIGNATURE" =~ ^[A-Za-z0-9+/]+=*$ ]] || fail "the signature must be base64"
! grep -qF ']]>' "$NOTES" || fail "the notes must not contain \"]]>\""
for existing in $(sed -n 's#.*<sparkle:version>\([0-9]*\)</sparkle:version>.*#\1#p' "$FEED"); do
    [[ "$BUILD" -gt "$existing" ]] || fail "build $BUILD is not newer than build $existing in the feed"
done

ITEM="$(cat <<EOF
        <item>
            <title>Version $VERSION</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MINIMUM_MACOS</sparkle:minimumSystemVersion>
            <description sparkle:format="markdown"><![CDATA[
$(cat "$NOTES")
]]></description>
            <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
        </item>
EOF
)"
ITEM="$ITEM" MARKER="$MARKER" awk '{ print } index($0, ENVIRON["MARKER"]) { print ENVIRON["ITEM"] }' "$FEED"
