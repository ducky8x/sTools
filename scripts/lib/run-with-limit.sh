# Sourced by scripts/build-dmg.sh, not run.
#
# run_with_limit <seconds> <what the command does> <command> [arguments...]
#   Runs the command and stops it when it has run for longer than <seconds>: SIGTERM, and SIGKILL five seconds later if
#   it is still there. It returns the command's own status, or 124 after printing, on standard error,
#   "error: <what the command does> did not finish within <seconds> seconds, so it was stopped." The command's output
#   goes where the caller's does.
#
# macOS has no timeout command, and hdiutil can hang for good when the disk image helper behind it is stuck.

run_with_limit() {
    local limit="$1" what="$2" pid watcher flag status=0
    shift 2
    flag="$(mktemp -t sTools-limit)"
    rm -f "$flag"
    "$@" &
    pid=$!
    # Looks once a second instead of sleeping the whole time, so nothing is left sleeping when the command finishes first.
    (
        waited=0
        while kill -0 "$pid" 2>/dev/null; do
            if [[ "$waited" -ge "$limit" ]]; then
                : > "$flag"
                kill -TERM "$pid" 2>/dev/null || true
                sleep 5
                kill -KILL "$pid" 2>/dev/null || true
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
    ) &
    watcher=$!
    wait "$pid" 2>/dev/null || status=$?
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    if [[ -e "$flag" ]]; then
        rm -f "$flag"
        echo "error: $what did not finish within $limit seconds, so it was stopped." >&2
        return 124
    fi
    return "$status"
}
