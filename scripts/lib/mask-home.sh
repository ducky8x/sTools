# Sourced by the release scripts (scripts/build-app.sh, scripts/build-dmg.sh, scripts/smoke-update.sh and
# scripts/check-no-home-paths.sh), not run. It keeps the person's name out of a terminal and a log.
#
# mask_home
#   Copies standard input to standard output, line by line, with
#     - the home folder shortened to ~;
#     - the full name (`id -F`) hidden: as it is, last name first, run together or joined with a dot, an underscore or a
#       hyphen, and each part of it of three letters or more on its own, so a surname alone is hidden too;
#     - the account name (`id -un`) and the home folder's name hidden;
#   in any letter case, whatever stands in their place is "<full name>", "<account name>" or "<home folder name>". A name
#   shorter than six letters is hidden only as a word of its own: hidden inside longer words too, it would show which of
#   their letters it is. What is put in a name's place is never searched again.
#
# mask_output_of "${BASH_SOURCE[0]}" "$@"
#   Called first thing in a script. It runs the script once more with everything it prints, and everything the tools it
#   runs print, passed through mask_home, then exits with the script's own status. The filters ignore Ctrl-C, so what the
#   script prints while it cleans up still gets through. An interactive script must not use it: a prompt without a line
#   break would wait in the filter.
#
# CHECK_NO_HOME_PATHS_EXTRA_NAMES (full names, one per line) adds made-up names to hide, as it adds them for
# scripts/check-no-home-paths.sh, so the masking can be tried without the real name.

MASK_HOME_FILTER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mask-home.awk"

mask_home() {
    MASK_HOME="$HOME" MASK_ACCOUNT="$(id -un)" MASK_FULL_NAME="$(id -F 2>/dev/null || true)" \
        MASK_HOME_NAME="$(basename "$HOME")" MASK_EXTRA_NAMES="${CHECK_NO_HOME_PATHS_EXTRA_NAMES:-}" \
        LC_ALL=C awk -f "$MASK_HOME_FILTER"
}

mask_output_of() {
    local script="$1" status=0
    shift
    [[ "${STOOLS_OUTPUT_MASKED:-}" != 1 ]] || return 0
    export STOOLS_OUTPUT_MASKED=1
    # With pipefail, the script's own status survives the filters, whatever options the calling script has set.
    (
        set -o pipefail
        { "$BASH" "$script" "$@" 2>&1 1>&3 3>&- | (trap '' INT; mask_home) >&2 3>&-; } 3>&1 |
            (trap '' INT; mask_home)
    ) || status=$?
    exit "$status"
}
