#!/bin/bash
# Reads an update feed (appcast.xml) the way sTools will: with Sparkle's own parser, from the Sparkle.framework of the
# SwiftPM dependency. Fails when Sparkle can't read it or would skip one of its items.
#
# Usage: scripts/check-appcast.sh <appcast.xml>
#
# Prints how many items the feed has and, for each, its version, build, minimum macOS, download URL and whether it
# carries an EdDSA signature. scripts/create-releases-repo.sh and scripts/publish-update.sh run it before anything
# is published.
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

[[ $# -eq 1 ]] || fail "usage: scripts/check-appcast.sh <appcast.xml>"
[[ "$1" != -h && "$1" != --help ]] || { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 0; }
[[ -f "$1" ]] || fail "no file at $1"
FEED="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"

if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_BETA" ]]; then
    export DEVELOPER_DIR="$XCODE_BETA"
fi
if [[ ! -d "$XCFRAMEWORK/Sparkle.framework" ]]; then
    (cd "$ROOT" && swift package resolve)
fi
[[ -d "$XCFRAMEWORK/Sparkle.framework" ]] || fail "Sparkle.framework is not in .build/artifacts; run swift package resolve"

WORK="$(mktemp -d -t sTools-appcast)"
trap 'rm -rf "$WORK"' EXIT
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
xmllint --noout "$FEED" || fail "$(basename "$FEED") is not well-formed XML"
"$WORK/check-appcast" "$FEED"
