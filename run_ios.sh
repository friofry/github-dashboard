#!/bin/bash
# Builds the app and runs it in the iOS Simulator.
# Usage: ./run_ios.sh ["iPhone 17 Pro"]   (defaults to IOS_SIMULATOR from .env, then the first iPhone)
set -euo pipefail
source "$(dirname "$0")/scripts/lib.sh"

load_env
NAME="${1:-${IOS_SIMULATOR:-iPhone}}"
UDID="$(xcrun simctl list devices available | grep -F "$NAME" | grep -Eo '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1 || true)"
if [[ -z "$UDID" ]]; then
    echo "No available simulator matches \"$NAME\". See: xcrun simctl list devices available" >&2
    exit 1
fi

build Debug "id=$UDID"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/$APP_NAME"

xcrun simctl bootstatus "$UDID" -b >/dev/null
open -a Simulator
xcrun simctl install "$UDID" "$APP"

# The simulator has no GitHub CLI, so hand the token to this one launch through the environment.
# It is never written into the app bundle; you can also paste a token in the app's Settings instead.
TOKEN="${GH_TOKEN:-}"
if [[ -z "$TOKEN" ]] && command -v gh >/dev/null; then
    TOKEN="$(gh auth token 2>/dev/null || true)"
    [[ -n "$TOKEN" ]] && echo "Using the GitHub CLI token for this launch."
fi

SIMCTL_CHILD_GH_TOKEN="$TOKEN" xcrun simctl launch --terminate-running-process "$UDID" "$(bundle_id "$APP/Info.plist")" >/dev/null
echo "Running in simulator $UDID"
