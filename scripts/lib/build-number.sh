# Sourced by scripts/build-app.sh and scripts/publish-update.sh, not run. It is the one place that says what a build's
# number is, so the app's CFBundleVersion and the update feed's sparkle:version cannot differ.
#
# build_number <checkout folder>
#   Prints the number of the build: $BUILD_NUMBER when that is set and not empty; otherwise the number of commits on
#   HEAD of the checkout plus 1000, which is 1001 when the folder is not a git checkout. Fails, after saying so on
#   standard error, when $BUILD_NUMBER is not a whole number.
#
# Why 1000 is added: Sparkle and Install from DMG... take a build as an update only when its number is higher than the
# one installed, and the number used to be the plain commit count. The history was rewritten on 2026-10-29 and lost
# more than 200 commits, so the count fell below the numbers of builds already handed out (the 0.2.0 beta is build
# 773). With 1000 added, every build made from the rewritten history numbers above every build made before it, and
# the count only grows from there. Do not remove the offset or lower it.

BUILD_NUMBER_OFFSET=1000

build_number() {
    local checkout="$1" count
    if [[ -n "${BUILD_NUMBER:-}" ]]; then
        if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
            echo "error: BUILD_NUMBER must be a whole number, got \"$BUILD_NUMBER\"" >&2
            return 1
        fi
        printf '%s\n' "$BUILD_NUMBER"
        return 0
    fi
    count="$(git -C "$checkout" rev-list --count HEAD 2>/dev/null)" || count=1
    printf '%s\n' "$((count + BUILD_NUMBER_OFFSET))"
}
