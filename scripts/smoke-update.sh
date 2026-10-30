#!/bin/bash
# Tests auto-updates end to end on this Mac, offline, without publishing anything: an older copy of sTools finds a newer
# one in a local update feed, downloads it, checks its EdDSA signature, installs it when it quits, and starts again as
# the newer version; a changed or unsigned update is refused and the older copy stays as it was.
#
# Usage: scripts/smoke-update.sh [--app <sTools.app>] [--keep]
#
#   --app   The packaged app to test (default build/sTools.app; a release build from scripts/build-app.sh release).
#           It is only read: the test works on copies.
#   --keep  Keep the work folder (apps, feed, logs) for a look afterwards; it is printed at the end.
#
# What it does, in a work folder made with mktemp -d in $TMPDIR:
#   1. Makes two copies of the app: A (0.1.0, build 100) and B (0.1.1, build 101). Each gets the bundle identifier
#      com.ducky8x.sTools.smoketest, the local feed (SUFeedURL http://localhost:<port>/appcast.xml) and a throwaway
#      update key (SUPublicEDKey), and is signed again with the "ducky8x" identity (no other identity is ever used).
#   2. Packs B with scripts/build-dmg.sh, signs the DMG with Sparkle's sign_update using the throwaway key (made with
#      CryptoKit for this run; never the real update key, and the keychain is never read), and writes the feed with
#      scripts/appcast-add-item.sh, read back by scripts/check-appcast.sh.
#   3. Serves the feed with python3 -m http.server on 127.0.0.1, at a free port.
#   4. Runs three cases, each on a fresh copy of A, launched hidden (open -g -j -n) with automatic checks and automatic
#      installs on, so Sparkle checks at launch and installs when the app quits:
#        signed    The DMG as signed: A must install B when it quits (SIGTERM), B must be valid and signed by
#                  "ducky8x", and B, started again, must find itself up to date.
#        one-byte  The DMG with one byte changed (a name in its resource list, so it still mounts) and the same
#                  signature: Sparkle must reject it ("improperly signed") and A must stay A.
#        unsigned  The feed item without its signature: Sparkle must reject it and A must stay A.
#   5. Cleans up whatever happens: quits the copies it started, stops the server and the log reader, ejects any disk
#      image Sparkle left mounted, and deletes the work folder and the test identifier's preferences and caches.
#
# Isolation: the copies never use com.ducky8x.sTools, so they share nothing with an installed sTools, even a running
# one: not its preferences (macOS keeps those by bundle identifier, whatever CFFIXED_USER_HOME says), not Sparkle's
# caches, launchd jobs or XPC names. CFFIXED_USER_HOME points them at a temporary home, which moves their Application
# Support folder (settings) out of the real one.
#
# Sparkle's own "Install and Relaunch" button is not pressed (that needs a click); the automatic install on quit is
# what is tested, then the installed app is started again.
#
# Environment: DEVELOPER_DIR defaults to the Xcode beta when it is installed.

set -euo pipefail

readonly IDENTITY_NAME="ducky8x"
readonly TEST_ID="com.ducky8x.sTools.smoketest"
readonly XCODE_BETA="/Applications/Xcode-beta.app/Contents/Developer"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT
readonly SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

fail() {
    echo "error: $*" >&2
    exit 1
}

# Lines as printed: the home folder as ~ and the account name, the full name and each part of it hidden
# (scripts/lib/mask-home.sh).
# shellcheck source=lib/mask-home.sh
source "$ROOT/scripts/lib/mask-home.sh"
masked() { mask_home; }

APP_IN="$ROOT/build/sTools.app"
KEEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            [[ $# -ge 2 ]] || fail "--app needs a path"
            APP_IN="$2"
            shift
            ;;
        --keep) KEEP=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        *) fail "unknown argument \"$1\"" ;;
    esac
    shift
done

if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_BETA" ]]; then
    export DEVELOPER_DIR="$XCODE_BETA"
fi

[[ -d "$APP_IN/Contents/Frameworks/Sparkle.framework" ]] ||
    fail "$(masked <<< "$APP_IN") is not a packaged sTools with Sparkle; build one with scripts/build-app.sh release"
[[ -x "$SPARKLE_BIN/sign_update" ]] || (cd "$ROOT" && swift package resolve)
[[ -x "$SPARKLE_BIN/sign_update" ]] || fail "Sparkle's sign_update is not in .build/artifacts"
command -v python3 > /dev/null || fail "python3 is needed for the local feed server"
! pgrep -f "/sTools-smoke-update[^/]*/" > /dev/null || fail "another smoke test is running"

# The "ducky8x" identity, by exact name, as scripts/build-app.sh finds it.
IDENTITY_HASH="$(security find-identity -p codesigning | awk -v name="\"$IDENTITY_NAME\"" '$3 == name { print $2 }' | sort -u)"
[[ "$IDENTITY_HASH" =~ ^[0-9A-F]{40}$ ]] || fail "need exactly one code-signing identity named \"$IDENTITY_NAME\""

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sTools-smoke-update.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
readonly WORK
SERVER_PID=""
LOG_PID=""

# Removes what the test made outside the work folder: the test identifier's preferences, caches and HTTP storage.
forget_test_id() {
    defaults delete "$TEST_ID" > /dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$TEST_ID.plist"
    rm -rf "$HOME/Library/Caches/$TEST_ID" "$HOME/Library/HTTPStorages/$TEST_ID" \
        "$HOME/Library/Saved Application State/$TEST_ID.savedState"
}

cleanup() {
    local status=$? pid device
    for pid in $(pgrep -f "$WORK/.*/sTools.app/Contents/MacOS/sTools" || true); do
        kill -TERM "$pid" 2> /dev/null || true
    done
    [[ -z "$SERVER_PID" ]] || kill -TERM "$SERVER_PID" 2> /dev/null || true
    [[ -z "$LOG_PID" ]] || kill -TERM "$LOG_PID" 2> /dev/null || true
    sleep 1
    # Sparkle can leave an update's disk image mounted when copying out of it fails.
    for device in $(hdiutil info | awk -v a="$WORK" -v b="$HOME/Library/Caches/$TEST_ID" '
            /^image-path/ { keep = index($0, a) || index($0, b) }
            /^\/dev\/disk[0-9]+[ \t]/ { if (keep) print $1 }'); do
        hdiutil detach -quiet "$device" 2> /dev/null || hdiutil detach -quiet -force "$device" 2> /dev/null || true
    done
    for app in "$WORK"/*/sTools.app; do
        [[ ! -d "$app" ]] || "$LSREGISTER" -u "$app" 2> /dev/null || true
    done
    forget_test_id
    if [[ "$KEEP" -eq 1 ]]; then
        echo "Kept the work folder: $WORK"
    else
        rm -rf "$WORK"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

forget_test_id

PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
FEED_URL="http://localhost:$PORT/appcast.xml"
DMG_NAME="sTools-0.1.1-macOS.dmg"
mkdir -p "$WORK/feed" "$WORK/home/Library/Application Support/sTools" "$WORK/key"
chmod 700 "$WORK/key"

echo "==> Making a throwaway update key (never the real one)"
cat > "$WORK/key/make-key.swift" <<'EOF'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let folder = CommandLine.arguments[1]
try key.rawRepresentation.base64EncodedString().write(toFile: folder + "/private.txt", atomically: true, encoding: .utf8)
try key.publicKey.rawRepresentation.base64EncodedString().write(toFile: folder + "/public.txt", atomically: true, encoding: .utf8)
EOF
xcrun swift "$WORK/key/make-key.swift" "$WORK/key"
PUBLIC_KEY="$(cat "$WORK/key/public.txt")"

echo "==> Making A (0.1.0, build 100) and B (0.1.1, build 101) from $(masked <<< "$APP_IN")"
make_copy() {
    local name="$1" version="$2" build="$3" plist
    mkdir -p "$WORK/$name"
    ditto "$APP_IN" "$WORK/$name/sTools.app"
    plist="$WORK/$name/sTools.app/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string "$TEST_ID" "$plist"
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$build" "$plist"
    plutil -replace SUFeedURL -string "$FEED_URL" "$plist"
    plutil -replace SUPublicEDKey -string "$PUBLIC_KEY" "$plist"
    codesign --force --sign "$IDENTITY_HASH" --timestamp=none --options runtime \
        --entitlements "$ROOT/packaging/sTools.entitlements" "$WORK/$name/sTools.app" 2> /dev/null
    codesign --verify --deep --strict "$WORK/$name/sTools.app" || fail "$name is not validly signed"
    echo "    $name: $version (build $build), signed by \"$IDENTITY_NAME\""
}
make_copy A 0.1.0 100
make_copy B 0.1.1 101

echo "==> Packing B with scripts/build-dmg.sh"
"$ROOT/scripts/build-dmg.sh" --app "$WORK/B/sTools.app" --output "$WORK/feed/$DMG_NAME" > "$WORK/build-dmg.log" 2>&1 ||
    { tail -n 20 "$WORK/build-dmg.log" >&2; fail "scripts/build-dmg.sh failed"; }
DMG="$WORK/feed/$DMG_NAME"

echo "==> Signing the DMG with sign_update and the throwaway key"
SIGNED="$("$SPARKLE_BIN/sign_update" --ed-key-file "$WORK/key/private.txt" "$DMG")"
[[ "$SIGNED" =~ sparkle:edSignature=\"([A-Za-z0-9+/=]+)\"\ length=\"([0-9]+)\" ]] || fail "sign_update printed something unexpected"
SIGNATURE="${BASH_REMATCH[1]}"
LENGTH="${BASH_REMATCH[2]}"
[[ "$LENGTH" == "$(stat -f %z "$DMG")" ]] || fail "the signed length does not match the DMG"
"$SPARKLE_BIN/sign_update" --ed-key-file "$WORK/key/private.txt" --verify "$DMG" "$SIGNATURE" > /dev/null ||
    fail "the DMG's signature does not verify"

echo "==> Writing the feeds"
printf 'sTools 0.1.1 (smoke test).\n' > "$WORK/notes.md"
PLACEHOLDER="https://example.invalid/$DMG_NAME"
"$ROOT/scripts/appcast-add-item.sh" "$ROOT/packaging/appcast-template.xml" 0.1.1 101 \
    "$(plutil -extract LSMinimumSystemVersion raw "$WORK/B/sTools.app/Contents/Info.plist")" "$PLACEHOLDER" "$LENGTH" \
    "$SIGNATURE" "$WORK/notes.md" | sed "s#$PLACEHOLDER#http://localhost:$PORT/$DMG_NAME#" > "$WORK/appcast-signed.xml"
"$ROOT/scripts/check-appcast.sh" "$WORK/appcast-signed.xml" | sed 's/^/    /'
grep -qF 'sparkle:edSignature=' "$WORK/appcast-signed.xml" || fail "the feed lost its signature"

# The same DMG with one byte changed where mounting does not notice: the case of one letter of the HFS partition's
# name in the image's resource list. The feed keeps the original signature.
cp "$DMG" "$WORK/feed/one-byte-$DMG_NAME"
python3 -I - "$WORK/feed/one-byte-$DMG_NAME" <<'EOF'
import re, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
match = re.search(rb"<key>Name</key>\s*<string>([A-Za-z][^<]*Apple_HFS)", bytes(data))
assert match, "no HFS partition name found in the DMG"
data[match.start(1)] ^= 0x20
open(path, "wb").write(data)
EOF
[[ "$(cmp -l "$DMG" "$WORK/feed/one-byte-$DMG_NAME" | wc -l | tr -d ' ')" == 1 ]] || fail "the changed DMG differs by more than one byte"
! "$SPARKLE_BIN/sign_update" --ed-key-file "$WORK/key/private.txt" --verify "$WORK/feed/one-byte-$DMG_NAME" "$SIGNATURE" \
    > /dev/null 2>&1 || fail "the changed DMG still verifies"
sed "s#/$DMG_NAME\"#/one-byte-$DMG_NAME\"#" "$WORK/appcast-signed.xml" > "$WORK/appcast-one-byte.xml"
sed 's# sparkle:edSignature="[^"]*"##' "$WORK/appcast-signed.xml" > "$WORK/appcast-unsigned.xml"
! grep -q 'edSignature' "$WORK/appcast-unsigned.xml" || fail "the unsigned feed still has a signature"

echo "==> Serving the feed at http://localhost:$PORT"
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/feed" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsI -o /dev/null "http://localhost:$PORT/$DMG_NAME" 2> /dev/null && break
    sleep 0.5
done
curl -fsI -o /dev/null "http://localhost:$PORT/$DMG_NAME" || fail "the feed server does not answer"

log stream --style compact --predicate "(subsystem == \"org.sparkle-project.Sparkle\" AND (process == \"sTools\" OR process == \"Autoupdate\")) OR (subsystem == \"com.ducky8x.sTools\" AND category == \"updates\")" \
    > "$WORK/sparkle.log" 2>&1 &
LOG_PID=$!

# Settings the copies start with: automatic checks and installs on, an overdue last check, the Prologue done.
printf '{\n  "value" : {\n    "checksAutomatically" : true,\n    "installsAutomatically" : true\n  },\n  "version" : 1\n}\n' \
    > "$WORK/home/Library/Application Support/sTools/updates.json"
printf '{\n  "value" : {\n    "prologueCompleted" : true,\n    "prologueStep" : 0\n  },\n  "version" : 1\n}\n' \
    > "$WORK/home/Library/Application Support/sTools/appState.json"
defaults write "$TEST_ID" SUHasLaunchedBefore -bool YES
defaults write "$TEST_ID" SUEnableAutomaticChecks -bool YES
defaults write "$TEST_ID" SUAutomaticallyUpdate -bool YES
defaults write "$TEST_ID" SUScheduledCheckInterval -int 3600

build_of() { plutil -extract CFBundleVersion raw "$1/Contents/Info.plist"; }

# Starts the app at $1 hidden, with the temporary home and an overdue update check; prints its process id.
launch() {
    local app="$1" pid=""
    defaults write "$TEST_ID" SULastCheckTime -date "2001-01-01 00:00:00 +0000"
    open -g -j -n --env CFFIXED_USER_HOME="$WORK/home" "$app"
    for _ in $(seq 1 40); do
        pid="$(pgrep -f "$app/Contents/MacOS/sTools" | head -n 1 || true)"
        [[ -z "$pid" ]] || break
        sleep 0.25
    done
    [[ -n "$pid" ]] || fail "$(masked <<< "$app") did not start"
    echo "$pid"
}

quit() {
    local pid="$1"
    kill -TERM "$pid" 2> /dev/null || true
    for _ in $(seq 1 40); do
        kill -0 "$pid" 2> /dev/null || return 0
        sleep 0.25
    done
    fail "process $pid did not quit"
}

# Waits up to $2 seconds for a line matching $1 in the Sparkle log after line $3; prints the line.
wait_for_log() {
    local pattern="$1" seconds="$2" after="$3" line
    for _ in $(seq 1 $((seconds * 4))); do
        line="$(tail -n +"$((after + 1))" "$WORK/sparkle.log" | grep -E -m 1 "$pattern" || true)"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

log_lines() { wc -l < "$WORK/sparkle.log" | tr -d ' '; }

PASSED=0
FAILED=0
pass() { echo "    PASS: $*"; PASSED=$((PASSED + 1)); }
miss() { echo "    FAIL: $*"; FAILED=$((FAILED + 1)); }

# Runs one case: a fresh copy of A, the given feed, and what must happen ("installs" or "refuses").
run_case() {
    local name="$1" feed="$2" expect="$3" app pid start line
    echo "==> Case \"$name\": $( [[ "$expect" == installs ]] && echo "A must install B" || echo "A must refuse the update")"
    mkdir -p "$WORK/$name"
    ditto "$WORK/A/sTools.app" "$WORK/$name/sTools.app"
    app="$WORK/$name/sTools.app"
    cp "$WORK/$feed" "$WORK/feed/appcast.xml"
    start="$(log_lines)"
    pid="$(launch "$app")"
    echo "    started A (build $(build_of "$app")), process $pid"
    if [[ "$expect" == installs ]]; then
        if line="$(wait_for_log 'EdDSA signature is correct' 90 "$start")"; then
            echo "    Sparkle: ${line#*Sparkle] }"
        else
            miss "Sparkle did not report a valid signature within 90 seconds"
        fi
        # Sparkle hands the update to its installer, which installs it once the app has quit.
        sleep 3
        quit "$pid"
        for _ in $(seq 1 120); do
            [[ "$(build_of "$app")" != 100 ]] && break
            sleep 0.25
        done
        if [[ "$(build_of "$app")" == 101 ]]; then
            pass "after quitting, the app on disk is B (0.1.1, build 101)"
        else
            miss "after quitting, the app on disk is build $(build_of "$app"), not 101"
        fi
        local signature
        signature="$(codesign -dvv "$app" 2>&1 || true)"
        if codesign --verify --deep --strict "$app" 2> /dev/null && grep -qx "Authority=$IDENTITY_NAME" <<< "$signature"; then
            pass "the installed app's signature is valid and from \"$IDENTITY_NAME\""
        else
            miss "the installed app's signature is not valid or not from \"$IDENTITY_NAME\""
        fi
        start="$(log_lines)"
        local requests
        requests="$(grep -c 'GET /appcast.xml' "$WORK/server.log" || true)"
        pid="$(launch "$app")"
        for _ in $(seq 1 60); do
            [[ "$(grep -c 'GET /appcast.xml' "$WORK/server.log" || true)" -gt "$requests" ]] && break
            sleep 0.25
        done
        sleep 3
        local running
        running="$(lsappinfo info -only version "$(lsappinfo find pid="$pid")" 2> /dev/null | sed -n 's/.*[Vv]ersion="\([^"]*\)".*/\1/p' | head -n 1)"
        if [[ "$(grep -c 'GET /appcast.xml' "$WORK/server.log" || true)" -gt "$requests" ]] &&
            [[ "$(tail -n 1 "$WORK/server.log")" != *"$DMG_NAME"* ]]; then
            pass "B started again (process $pid${running:+, version $running}), checked the feed and found nothing newer"
        else
            miss "B, started again, did not check the feed as expected"
        fi
        quit "$pid"
    else
        if line="$(wait_for_log 'Update check ended' 90 "$start")"; then
            echo "    sTools: ${line#*updates] }"
            if [[ "$line" == *"SUSparkleErrorDomain 4005"* ]]; then
                pass "Sparkle rejected the update as improperly signed"
            else
                miss "the update failed, but not as improperly signed"
            fi
        else
            miss "no rejection within 90 seconds"
        fi
        tail -n +"$((start + 1))" "$WORK/sparkle.log" | grep -E 'EdDSA|signature' | grep -v 'Error: ' | head -n 2 |
            sed 's/^.*Sparkle\] /    Sparkle: /' | cut -c 1-200 | masked
        quit "$pid"
        sleep 2
        if [[ "$(build_of "$app")" == 100 ]] && codesign --verify --deep --strict "$app" 2> /dev/null; then
            pass "the app on disk is still A (build 100) and validly signed"
        else
            miss "the app on disk changed: build $(build_of "$app")"
        fi
    fi
}

run_case signed appcast-signed.xml installs
run_case one-byte appcast-one-byte.xml refuses
run_case unsigned appcast-unsigned.xml refuses

echo
if [[ "$FAILED" -eq 0 ]]; then
    echo "Auto-update smoke test passed ($PASSED checks)."
else
    echo "Auto-update smoke test FAILED: $FAILED of $((PASSED + FAILED)) checks failed."
    exit 1
fi
