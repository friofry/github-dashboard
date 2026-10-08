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

load_env
build Release "platform=macOS"
APP="$DERIVED/Build/Products/Release/$APP_NAME"

# Only one copy may run, so stop the previous build before opening the new one.
osascript -e "tell application id \"$(bundle_id "$APP/Contents/Info.plist")\" to quit" >/dev/null 2>&1 || true

if [[ "${1:-}" == "--install" ]]; then
    TARGET="/Applications/$APP_NAME"
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    APP="$TARGET"
    echo "Installed $TARGET"
fi

open "$APP"
