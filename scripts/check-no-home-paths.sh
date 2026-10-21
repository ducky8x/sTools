#!/bin/bash
# Fails when something that ships carries a home-folder path or the macOS account name.
#
# Usage: scripts/check-no-home-paths.sh <file-or-folder>...
#
# The account name (`id -un`) is often a person's real name, and every path in the home folder
# (/Users/<name>/...) carries it, so neither may appear in an app, a disk image or anything else that ships.
# scripts/build-app.sh runs this on release builds and scripts/build-dmg.sh on the disk image. Checked under
# each argument, without following symbolic links:
#   - the bytes of every file, read binary-safe (executables, property lists, .DS_Store, fonts, disk images);
#   - every file's and folder's name, relative to the argument (where the argument itself sits is not shipped);
#   - every symbolic link's target;
#   - every extended attribute's name and value.
# NUL bytes are dropped before searching, so text stored as UTF-16 (alias records, Finder records, property
# lists) is found as well as ASCII and UTF-8. The account name matches in any letter case; "/Users/" exactly.
# Compressed data (inside PNG and TIFF images, Assets.car, a compressed disk image) is not unpacked, so check a
# disk image before it is compressed.
#
# Each finding is printed with its path relative to the argument and a count. The account name itself is never
# printed: where a name contains it, "<account name>" is shown instead.
#
# Exit status: 0 when nothing was found, 1 when something was, 2 when the check could not run.

set -euo pipefail

readonly HOME_PREFIX="/Users/"
ACCOUNT="$(id -un)"
readonly ACCOUNT

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

# Copies standard input to standard output with the account name, in any letter case, replaced.
mask() {
    LC_ALL=C awk -v account="$ACCOUNT" '
        BEGIN { wanted = tolower(account); width = length(account) }
        {
            rest = $0
            out = ""
            while (width > 0 && (at = index(tolower(rest), wanted)) > 0) {
                out = out substr(rest, 1, at - 1) "<account name>"
                rest = substr(rest, at + width)
            }
            print out rest
        }'
}

# Ends the check without a verdict.
broken() {
    printf 'error: %s\n' "$*" | mask >&2
    exit 2
}

[[ -n "$ACCOUNT" ]] || broken "cannot read the account name"
if [[ $# -eq 0 ]]; then
    usage
    exit 2
fi
case "$1" in
    -h|--help)
        usage
        exit 0
        ;;
esac

LIST="$(mktemp -t check-no-home-paths)" || broken "cannot create a temporary file"
TEXT="$(mktemp -t check-no-home-paths)" || broken "cannot create a temporary file"
trap 'rm -f "$LIST" "$TEXT"' EXIT

# Prints how many times the bytes on standard input hold "/Users/" and the account name, as "<paths> <names>".
# One grep per string: given both at once, BSD grep -o skips some matches.
count() {
    LC_ALL=C tr -d '\000' > "$TEXT"
    printf '%d %d\n' \
        "$(LC_ALL=C grep -a -o -F -e "$HOME_PREFIX" "$TEXT" | wc -l)" \
        "$(LC_ALL=C grep -a -o -i -F -e "$ACCOUNT" "$TEXT" | wc -l)"
}

FINDINGS=0

# Counts the bytes on standard input and reports them as <where> when they hold either. Feed it with a
# redirection, not a pipe: a pipe would run it in a subshell, and the finding would not be counted.
inspect() {
    local where="$1" counts paths names found=""
    counts="$(count)"
    paths="${counts% *}"
    names="${counts#* }"
    [[ "$paths" == 0 && "$names" == 0 ]] && return 0
    if [[ "$paths" != 0 ]]; then
        found="\"$HOME_PREFIX\" $paths $( [[ "$paths" == 1 ]] && echo time || echo times)"
    fi
    if [[ "$names" != 0 ]]; then
        found="${found:+$found, }the account name $names $( [[ "$names" == 1 ]] && echo time || echo times)"
    fi
    printf '    %s: %s\n' "$where" "$found" | mask >&2
    FINDINGS=$((FINDINGS + 1))
}

START="$(pwd -P)"
CHECKED=""
ENTRIES=0
BYTES=0

for target in "$@"; do
    cd "$START"
    [[ -e "$target" || -L "$target" ]] || broken "nothing at $target"
    parent="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || broken "cannot open the folder holding $target"
    base="$(basename "$target")"
    CHECKED="${CHECKED:+$CHECKED, }$base"
    cd "$parent"
    find "$base" -print0 > "$LIST" 2>/dev/null || broken "cannot list everything in $base"
    while IFS= read -r -d '' entry; do
        ENTRIES=$((ENTRIES + 1))
        inspect "$entry (its name)" < <(printf '%s' "$entry")
        if [[ -L "$entry" ]]; then
            link="$(readlink "$entry")" || broken "cannot read the link $entry"
            inspect "$entry (link target)" < <(printf '%s' "$link")
        elif [[ -f "$entry" ]]; then
            [[ -r "$entry" ]] || broken "cannot read $entry"
            inspect "$entry" < "$entry"
            BYTES=$((BYTES + $(stat -f %z "$entry")))
        fi
        attributes="$(xattr -s "$entry" 2>/dev/null)" || broken "cannot list the extended attributes of $entry"
        while IFS= read -r attribute; do
            [[ -n "$attribute" ]] || continue
            inspect "$entry (extended attribute name)" < <(printf '%s' "$attribute")
            value="$(xattr -s -p -x "$attribute" "$entry" 2>/dev/null)" ||
                broken "cannot read the extended attribute $attribute of $entry"
            inspect "$entry (extended attribute $attribute)" < <(printf '%s' "$value" | xxd -r -p)
        done <<< "$attributes"
    done < "$LIST"
done

if [[ "$FINDINGS" -gt 0 ]]; then
    echo "error: \"$HOME_PREFIX\" or the account name is in $FINDINGS place(s) listed above; this must not ship" >&2
    exit 1
fi
printf '    no "%s" and no account name in %s (%d %s, %s MB read)\n' "$HOME_PREFIX" "$CHECKED" "$ENTRIES" \
    "$( [[ "$ENTRIES" == 1 ]] && echo item || echo items)" \
    "$(awk -v bytes="$BYTES" 'BEGIN { printf "%.1f", bytes / 1000000 }')" | mask
