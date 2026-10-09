#!/bin/bash
# Installs the pr-review skill for your own Claude Code sessions, so `/pr-review owner/repo#123` works anywhere.
# The app does not need this: it carries its own copy.
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")/.." && pwd)/skills/pr-review"
TARGET="$HOME/.claude/skills/pr-review"

mkdir -p "$HOME/.claude/skills"
rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"
echo "Installed $TARGET"
