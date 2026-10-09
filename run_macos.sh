#!/bin/bash
# Builds and opens the macOS app. With --install, copies it to /Applications first.
set -euo pipefail
source "$(dirname "$0")/scripts/lib.sh"

case "${1:-}" in
    "" | --install) ;;
    *)
        echo "Usage: $0 [--install]" >&2
        exit 2
        ;;
esac

# The installed copy must be traceable to a commit, so it is never built from uncommitted changes.
if [[ "${1:-}" == "--install" && -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    echo "The working copy has uncommitted changes. Commit or stash them before --install." >&2
    exit 1
fi

load_env
build Release "platform=macOS"
APP="$(built_app Release)"
BUNDLE="$(plist_value CFBundleIdentifier "$APP/Contents/Info.plist")"
PROCESS="$(plist_value CFBundleExecutable "$APP/Contents/Info.plist")"

# Only one copy may run, so stop the previous build before opening the new one.
osascript -e "tell application id \"$BUNDLE\" to quit" >/dev/null 2>&1 || true
for _ in {1..50}; do
    pgrep -qx "$PROCESS" || break
    sleep 0.1
done

if [[ "${1:-}" == "--install" ]]; then
    TARGET="/Applications/$(basename "$APP")"
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    APP="$TARGET"
    echo "Installed $TARGET"
fi

open "$APP"
for _ in {1..100}; do
    if pgrep -qx "$PROCESS"; then
        echo "Running $(plist_value DashboardCommit "$APP/Contents/Info.plist")"
        exit 0
    fi
    sleep 0.1
done
echo "$APP did not start. Try opening it from Finder to see why." >&2
exit 1
