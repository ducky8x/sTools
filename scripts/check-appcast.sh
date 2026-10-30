#!/bin/bash
# Reads an update feed (appcast.xml) the way sTools will: with Sparkle's own parser, from the Sparkle.framework of the
# SwiftPM dependency. Fails when Sparkle can't read it or would skip one of its items.
#
# Usage: scripts/check-appcast.sh [--expect <version>] <appcast.xml>
#        scripts/check-appcast.sh [--expect <version>] --url <address>
#        scripts/check-appcast.sh [--expect <version>] --live
#
#   --url     Reads the feed at an address (https:// or file://) instead of in a file.
#   --live    Reads the feed at the address built into sTools (SUFeedURL in packaging/Info.plist): the appcast.xml of
#             the release GitHub marks Latest on ducky8x/sTools. That address answers only once ducky8x/sTools is
#             public and its Latest release has an appcast.xml attached.
#   --expect  Also fails unless the feed lists this version.
#
# Prints how many items the feed has and, for each, its version, build, minimum macOS, download URL and whether it
# carries an EdDSA signature. scripts/publish-update.sh runs it on the new feed before anything is published, and on
# the live address afterwards.
#
# The parser is Sparkle's SUAppcast, reached through its private initializer (the one SPUUpdater uses), from a small
# Objective-C tool compiled into a temporary folder each run.
#
# Environment:
#   DEVELOPER_DIR  Defaults to the Xcode beta when it is installed.

set -euo pipefail

readonly XCODE_BETA="/Applications/Xcode-beta.app/Contents/Developer"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly XCFRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"

fail() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

# Text as printed: the home folder as ~ (it holds the account name).
shown() {
    printf '%s' "$1" | sed "s#$HOME#~#g"
}

EXPECT=""
ADDRESS=""
LIVE=0
FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --expect)
            [[ $# -ge 2 ]] || fail "--expect needs a version"
            EXPECT="$2"
            shift
            ;;
        --url)
            [[ $# -ge 2 ]] || fail "--url needs an address"
            ADDRESS="$2"
            shift
            ;;
        --live) LIVE=1 ;;
        -*) fail "unknown option \"$1\"" ;;
        *)
            [[ -z "$FILE" ]] || fail "give one feed, not two"
            FILE="$1"
            ;;
    esac
    shift
done
SOURCES=0
[[ -z "$FILE" ]] || SOURCES=$((SOURCES + 1))
[[ -z "$ADDRESS" ]] || SOURCES=$((SOURCES + 1))
[[ "$LIVE" -eq 0 ]] || SOURCES=$((SOURCES + 1))
[[ "$SOURCES" -eq 1 ]] || { usage; fail "give exactly one feed: a file, --url <address> or --live"; }

if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_BETA" ]]; then
    export DEVELOPER_DIR="$XCODE_BETA"
fi

WORK="$(mktemp -d -t sTools-appcast)"
trap 'rm -rf "$WORK"' EXIT

# The feed, as a file in $FEED named $LABEL: the file given, or what an address answers.
HINT=""
if [[ "$LIVE" -eq 1 ]]; then
    ADDRESS="$(plutil -extract SUFeedURL raw -o - "$ROOT/packaging/Info.plist")" ||
        fail "cannot read SUFeedURL from packaging/Info.plist"
    HINT=" That address answers only once ducky8x/sTools is public and its Latest release has an appcast.xml attached."
fi
if [[ -n "$ADDRESS" ]]; then
    LABEL="the feed at $(shown "$ADDRESS")"
    if ! curl --fail --silent --show-error --location --max-time 60 --retry 2 --retry-delay 3 \
            --output "$WORK/fetched.xml" "$ADDRESS" 2> "$WORK/curl.log"; then
        shown "$(cat "$WORK/curl.log")" >&2
        echo >&2
        fail "could not fetch the feed at $(shown "$ADDRESS").$HINT"
    fi
    FEED="$WORK/fetched.xml"
else
    [[ -f "$FILE" ]] || fail "no file at $(shown "$FILE")"
    FEED="$(cd "$(dirname "$FILE")" && pwd -P)/$(basename "$FILE")"
    LABEL="$(basename "$FILE")"
fi
if ! xmllint --noout "$FEED" > "$WORK/xmllint.log" 2>&1; then
    sed -e "s#$FEED#$LABEL#g" -e "s#$HOME#~#g" "$WORK/xmllint.log" >&2
    fail "$LABEL is not well-formed XML"
fi

if [[ ! -d "$XCFRAMEWORK/Sparkle.framework" ]]; then
    (cd "$ROOT" && swift package resolve)
fi
[[ -d "$XCFRAMEWORK/Sparkle.framework" ]] || fail "Sparkle.framework is not in .build/artifacts; run swift package resolve"

cat > "$WORK/main.m" <<'EOF'
#import <Foundation/Foundation.h>
#import <Sparkle/Sparkle.h>

// Sparkle's private parts that SPUUpdater uses to read a feed.
@interface SPUAppcastItemStateResolver : NSObject
- (instancetype)initWithHostVersion:(NSString *)hostVersion applicationVersionComparator:(id<SUVersionComparison>)applicationVersionComparator standardVersionComparator:(SUStandardVersionComparator *)standardVersionComparator;
@end

@interface SUAppcast (Parsing)
- (nullable instancetype)initWithXMLData:(NSData *)xmlData relativeToURL:(nullable NSURL *)relativeURL stateResolver:(SPUAppcastItemStateResolver *)stateResolver signingValidationStatus:(SPUAppcastSigningValidationStatus)signingValidationStatus error:(NSError * __autoreleasing *)error;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data == nil) { fprintf(stderr, "cannot read the feed\n"); return 1; }
        SUStandardVersionComparator *comparator = [[SUStandardVersionComparator alloc] init];
        // As a copy at build 0 sees the feed: every item is newer than it, so none is left out for that.
        SPUAppcastItemStateResolver *resolver = [[SPUAppcastItemStateResolver alloc] initWithHostVersion:@"0" applicationVersionComparator:comparator standardVersionComparator:comparator];
        NSError *error = nil;
        SUAppcast *appcast = [[SUAppcast alloc] initWithXMLData:data relativeToURL:url stateResolver:resolver signingValidationStatus:SPUAppcastSigningValidationStatusSkipped error:&error];
        if (appcast == nil) {
            fprintf(stderr, "Sparkle could not read the feed: %s\n", error.localizedDescription.UTF8String ?: "unknown error");
            return 1;
        }
        printf("Sparkle read the feed: %lu item(s)\n", (unsigned long)appcast.items.count);
        for (SUAppcastItem *item in appcast.items) {
            printf("  %s (build %s), macOS %s or newer, %s, %s\n", item.displayVersionString.UTF8String,
                   item.versionString.UTF8String, (item.minimumSystemVersion ?: @"any").UTF8String,
                   (item.fileURL.absoluteString ?: @"no download").UTF8String,
                   [item.propertiesDictionary[@"enclosure"][@"sparkle:edSignature"] length] > 0 ? "EdDSA signature" : "NO EdDSA signature");
        }
    }
    return 0;
}
EOF
xcrun clang -fobjc-arc -fmodules -F "$XCFRAMEWORK" -framework Sparkle -framework Foundation \
    -Wl,-rpath,"$XCFRAMEWORK" -o "$WORK/check-appcast" "$WORK/main.m" 2>"$WORK/clang.log" || {
    sed "s#$HOME#~#g" "$WORK/clang.log" >&2
    fail "could not compile the feed reader against Sparkle.framework"
}
RESULT="$("$WORK/check-appcast" "$FEED")"
echo "$RESULT"
if [[ -n "$EXPECT" ]]; then
    grep -qF "  $EXPECT (build " <<< "$RESULT" || fail "$LABEL does not list version $EXPECT"
fi
