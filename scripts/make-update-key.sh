#!/bin/bash
# Creates sTools' update signing key (Sparkle's EdDSA key) in the login keychain, once, and writes its public half
# to packaging/sparkle-public-key.txt, which scripts/build-app.sh puts in Info.plist as SUPublicEDKey.
#
# Usage: scripts/make-update-key.sh
#
# The private key stays in the login keychain, under the account "sTools" of Sparkle's item ("Private key for signing
# Sparkle updates" in Keychain Access); this script never prints it or writes it to a file. When the keychain already
# holds a key for that account, it is kept and its public key is written again, so running this twice is harmless.
#
# Back the private key up somewhere safe outside the repository (a password manager, an encrypted disk): without it,
# copies of sTools already out there can never be updated again. Sparkle's tool exports it when you ask it to:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account sTools -x <file outside the repository>
# and on a new Mac it goes back into the keychain with -f <that file>.
#
# The script stops before Sparkle's generate_keys runs when the login keychain is locked, so no password prompt
# appears; unlock it (log in, or open Keychain Access) and run it again.
#
# Environment:
#   DEVELOPER_DIR  Defaults to the Xcode beta when it is installed.

set -euo pipefail

readonly ACCOUNT="sTools"
readonly XCODE_BETA="/Applications/Xcode-beta.app/Contents/Developer"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly KEY_FILE="$ROOT/packaging/sparkle-public-key.txt"
readonly GENERATE_KEYS="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys"

fail() {
    echo "error: $*" >&2
    exit 1
}

case "${1:-}" in
    "") ;;
    -h|--help)
        sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
        exit 0
        ;;
    *) fail "unknown argument \"$1\"" ;;
esac

if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_BETA" ]]; then
    export DEVELOPER_DIR="$XCODE_BETA"
fi

# Sparkle's tools come with the SwiftPM dependency.
if [[ ! -x "$GENERATE_KEYS" ]]; then
    echo "==> Fetching Sparkle (swift package resolve)"
    (cd "$ROOT" && swift package resolve)
fi
[[ -x "$GENERATE_KEYS" ]] || fail "Sparkle's generate_keys is not at .build/artifacts/sparkle/Sparkle/bin"

# Whether the default keychain is unlocked, asked without any prompt.
KEYCHAIN_CHECK="$(mktemp -d -t sTools-keychain)"
trap 'rm -rf "$KEYCHAIN_CHECK"' EXIT
cat > "$KEYCHAIN_CHECK/check.swift" <<'EOF'
import Security
var keychain: SecKeychain?
var status: SecKeychainStatus = 0
guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain,
      SecKeychainGetStatus(keychain, &status) == errSecSuccess else {
    print("unknown")
    exit(0)
}
print(status & UInt32(kSecUnlockStateStatus) != 0 ? "unlocked" : "locked")
EOF
LOCK_STATE="$(xcrun swift "$KEYCHAIN_CHECK/check.swift" 2>/dev/null || echo unknown)"
case "$LOCK_STATE" in
    unlocked) ;;
    locked) fail "the login keychain is locked; unlock it (open Keychain Access) and run this again" ;;
    *) fail "cannot tell whether the login keychain is unlocked; nothing was changed" ;;
esac

if PUBLIC_KEY="$("$GENERATE_KEYS" --account "$ACCOUNT" -p 2>/dev/null)"; then
    echo "==> The keychain already holds sTools' update key (account \"$ACCOUNT\"); keeping it"
else
    echo "==> Creating sTools' update key in the login keychain (account \"$ACCOUNT\")"
    # Its output is only the public key and how to use it; nothing secret.
    "$GENERATE_KEYS" --account "$ACCOUNT" > /dev/null || fail "Sparkle's generate_keys could not create the key"
    PUBLIC_KEY="$("$GENERATE_KEYS" --account "$ACCOUNT" -p)" || fail "cannot read back the key that was just created"
fi
PUBLIC_KEY="$(tr -d '[:space:]' <<< "$PUBLIC_KEY")"
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ && "$(printf '%s' "$PUBLIC_KEY" | base64 -D | wc -c | tr -d ' ')" == 32 ]] ||
    fail "generate_keys did not print a public key (base64 of 32 bytes)"

if [[ -f "$KEY_FILE" && "$(head -n 1 "$KEY_FILE" | tr -d '[:space:]')" != "$PUBLIC_KEY" ]]; then
    fail "packaging/sparkle-public-key.txt holds a different public key; copies of sTools built with it only" \
        "accept updates signed by its private key. Restore that key into the keychain (generate_keys -f) instead" \
        "of replacing it, or delete the file first if a new key is really meant."
fi
printf '%s\n' "$PUBLIC_KEY" > "$KEY_FILE"
echo "Wrote the public key to packaging/sparkle-public-key.txt: $PUBLIC_KEY"
echo "Commit that file. Back the private key up outside the repository (see the top of this script)."
