# Sourced by the scripts that run Apple's developer tools (swift, actool, dsymutil, swiftc...), not run. It is the one
# place that says which developer folder they use.
#
# use_full_xcode [developer folder...]
#   Leaves DEVELOPER_DIR as it is when it is set and not empty. Otherwise exports the first of the given developer
#   folders that exists, by default the Xcode beta's, then Xcode's. When none exists, DEVELOPER_DIR stays unset and
#   xcrun uses the folder xcode-select chose. Nothing here changes xcode-select.
#
# Why an installed Xcode comes first: xcode-select can point at the Command Line Tools, which have no actool (the app's
# icon needs it) and no Swift Testing. The scripts used to look for the Xcode beta alone, and stopped finding a full
# Xcode once only Xcode itself was installed.

use_full_xcode() {
    [[ -n "${DEVELOPER_DIR:-}" ]] && return 0
    local candidates=("$@") candidate
    if [[ $# -eq 0 ]]; then
        candidates=(/Applications/Xcode-beta.app/Contents/Developer /Applications/Xcode.app/Contents/Developer)
    fi
    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate" ]]; then
            export DEVELOPER_DIR="$candidate"
            return 0
        fi
    done
    return 0
}
