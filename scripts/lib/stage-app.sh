# Sourced by scripts/build-app.sh, not run.
#
# A build is made in a staging folder, and the finished app replaces build/<App>.app only once every step and check has
# passed. So a build that fails never leaves a half-made app under the real name, and the app from the last good build
# stays where it was, usable. What a failed build says is that it did not replace that app, and what that app is.
#
# stage_describe <app>
#   Prints "version 0.2.0, build 773, made Oct 27 22:10" for an app, or nothing when it has no Info.plist.
#
# stage_commit <staged app> <final app> <staging folder>
#   Puts the staged app in the final app's place. The old one is renamed aside first, inside the staging folder (the same
#   volume, so a rename and not a copy), and is put back if the move fails. The caller removes the staging folder.
#
# stage_report_failure <final app> <staged app was committed: 0 or 1>
#   For a build that ended with an error: says whether the final app was replaced and, if not, what it is.

stage_describe() {
    local plist="$1/Contents/Info.plist" version build made
    [[ -f "$plist" ]] || return 0
    version="$(plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || echo "?")"
    build="$(plutil -extract CFBundleVersion raw -o - "$plist" 2>/dev/null || echo "?")"
    made="$(stat -f '%Sm' -t '%b %e %H:%M' "$plist" 2>/dev/null | sed 's/  */ /g' || true)"
    printf 'version %s, build %s, made %s' "$version" "$build" "$made"
}

stage_commit() {
    local staged="$1" final="$2" stage="$3" aside=""
    mkdir -p "$(dirname "$final")"
    if [[ -e "$final" ]]; then
        aside="$stage/replaced-$(basename "$final")"
        rm -rf "$aside"
        mv "$final" "$aside"
    fi
    if ! mv "$staged" "$final"; then
        [[ -z "$aside" ]] || mv "$aside" "$final"
        echo "error: could not move the finished app into ${final#"${ROOT:-}/"}" >&2
        return 1
    fi
}

stage_report_failure() {
    local final="$1" committed="$2" shown description
    [[ "$committed" -eq 0 ]] || return 0
    shown="${final#"$ROOT/"}"
    if [[ -e "$final" ]]; then
        description="$(stage_describe "$final")"
        echo "error: the build failed, so $shown was not replaced. It is still the app from an earlier build" \
            "(${description:-no Info.plist}), not one made by this run." >&2
    else
        echo "error: the build failed, and there is no $shown." >&2
    fi
}
