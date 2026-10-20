#!/bin/bash
# Creates the self-signed code-signing identity "ducky8x" that scripts/build-app.sh signs with.
#
# Usage: scripts/make-signing-identity.sh [--backup <file.p12>] [--keychain <path>]
#
#   --backup    Where to write the password-protected backup of the certificate and private key
#               (default: ~/ducky8x-signing-backup.p12). Must be outside this repository.
#   --keychain  Import into this keychain instead of the login keychain. For testing with a
#               throwaway keychain; the keychain must already exist and be unlocked.
#
# Environment:
#   STOOLS_P12_PASSPHRASE  Passphrase for the backup file. Prompted for when unset.
#
# One identity, kept forever: macOS ties permission grants (Screen Recording, Accessibility, Microphone,
# ...) to the signature, so every build and every release must be signed by this same certificate.
# Run this once. It refuses to run when a "ducky8x" identity already exists.

set -euo pipefail

readonly IDENTITY_NAME="ducky8x"
readonly VALID_DAYS=3650
# LibreSSL ships with macOS and writes PKCS#12 files that `security import` always accepts; a Homebrew
# OpenSSL 3 would default to ciphers the system importer rejects.
readonly OPENSSL="/usr/bin/openssl"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

fail() {
    echo "error: $*" >&2
    exit 1
}

KEYCHAIN=""
BACKUP="$HOME/ducky8x-signing-backup.p12"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keychain)
            [[ $# -ge 2 ]] || fail "--keychain needs a path"
            KEYCHAIN="$2"
            shift
            ;;
        --backup)
            [[ $# -ge 2 ]] || fail "--backup needs a path"
            BACKUP="$2"
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

IMPORT_TARGET="$KEYCHAIN"
if [[ -z "$KEYCHAIN" ]]; then
    IMPORT_TARGET="$HOME/Library/Keychains/login.keychain-db"
fi
[[ -f "$IMPORT_TARGET" ]] || fail "keychain not found: $IMPORT_TARGET"

# The backup must never land inside the repository, where it could be committed.
BACKUP_DIR="$(dirname "$BACKUP")"
[[ -d "$BACKUP_DIR" ]] || fail "backup folder does not exist: $BACKUP_DIR"
BACKUP="$(cd "$BACKUP_DIR" && pwd -P)/$(basename "$BACKUP")"
case "$BACKUP/" in
    "$ROOT"/*) fail "the backup must be outside the repository ($ROOT); choose another --backup path" ;;
esac
[[ ! -e "$BACKUP" ]] || fail "refusing to overwrite an existing file: $BACKUP"
CERT_COPY="${BACKUP%.p12}.crt"
[[ ! -e "$CERT_COPY" ]] || fail "refusing to overwrite an existing file: $CERT_COPY"

# Refuse when the identity already exists, matching the quoted common name exactly.
if [[ -n "$KEYCHAIN" ]]; then
    EXISTING="$(security find-identity -p codesigning "$KEYCHAIN")"
else
    EXISTING="$(security find-identity -p codesigning)"
fi
if grep -Fq "\"$IDENTITY_NAME\"" <<< "$EXISTING"; then
    fail "a \"$IDENTITY_NAME\" identity already exists; nothing was changed. Creating a second one would change the signature and make macOS forget every permission grant."
fi

PASSPHRASE="${STOOLS_P12_PASSPHRASE:-}"
if [[ -z "$PASSPHRASE" ]]; then
    [[ -t 0 ]] || fail "set STOOLS_P12_PASSPHRASE or run this in a terminal to be asked for a backup passphrase"
    read -rsp "Choose a passphrase for the backup file (at least 8 characters): " PASSPHRASE
    echo
    read -rsp "Repeat the passphrase: " CONFIRM
    echo
    [[ "$PASSPHRASE" == "$CONFIRM" ]] || fail "the passphrases do not match"
fi
[[ ${#PASSPHRASE} -ge 8 ]] || fail "the passphrase must be at least 8 characters"

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/stools-identity.XXXXXX")"
cleanup() {
    if [[ -n "${WORK:-}" && -d "$WORK" ]]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> Generating a 2048-bit RSA key and a self-signed certificate valid for $VALID_DAYS days"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days "$VALID_DAYS" -config "$WORK/openssl.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

export P12_PASSPHRASE="$PASSPHRASE"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$IDENTITY_NAME" \
    -passout env:P12_PASSPHRASE -out "$WORK/identity.p12"

# Write the backup first so the identity can never exist without one.
cp "$WORK/identity.p12" "$BACKUP"
cp "$WORK/cert.pem" "$CERT_COPY"
chmod 600 "$BACKUP"

echo "==> Importing into $IMPORT_TARGET"
# The passphrase is briefly visible to other processes of this user in the process list.
if ! security import "$WORK/identity.p12" -k "$IMPORT_TARGET" -P "$PASSPHRASE" -T /usr/bin/codesign >/dev/null; then
    rm -f "$BACKUP" "$CERT_COPY"
    fail "importing into $IMPORT_TARGET failed; nothing was changed"
fi

if [[ -n "$KEYCHAIN" ]]; then
    CREATED="$(security find-identity -p codesigning "$KEYCHAIN")"
else
    CREATED="$(security find-identity -p codesigning)"
fi
HASH="$(grep -F "\"$IDENTITY_NAME\"" <<< "$CREATED" | head -n 1 | awk '{print $2}')"
[[ -n "$HASH" ]] || fail "the identity was imported but is not listed by security find-identity"

cat <<EOF

Created the code-signing identity "$IDENTITY_NAME" (SHA-1 $HASH) in
$IMPORT_TARGET

Next steps

1. Back up the identity NOW. Without it you could never sign an update that macOS recognizes as the
   same app. The password-protected backup is here, outside the repository:
       $BACKUP
   Move it to a password manager or an encrypted drive, and keep the passphrase somewhere else:
       mv "$BACKUP" /Volumes/<your-encrypted-drive>/
   If you ever need it on a new Mac:
       security import /path/to/$(basename "$BACKUP") -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign

2. Build: scripts/build-app.sh debug
   macOS may ask once whether codesign may use the new key. Choose Always Allow. To stop it asking
   again, enter your login password in this command (it only touches the "$IDENTITY_NAME" key):
       security set-key-partition-list -S apple-tool:,apple: -s -l $IDENTITY_NAME -k '<login password>' "$IMPORT_TARGET"

3. Optional: mark the certificate as trusted for code signing. Signing and permission grants work
   without it, but until you do, Keychain Access shows the certificate as "not trusted" and
   \`security find-identity -v\` does not list it. macOS asks for your password:
       security add-trusted-cert -r trustRoot -p codeSign -k "$IMPORT_TARGET" "$CERT_COPY"

The public certificate was also written next to the backup ($CERT_COPY). It holds no secret.
EOF
