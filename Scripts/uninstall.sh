#!/bin/zsh
set -euo pipefail

APP_NAME="AI Quota Bar"
TARGET_APP="/Applications/$APP_NAME.app"

pkill -x "$APP_NAME" 2>/dev/null || true
for _ in {1..30}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.1
done

rm -rf "$TARGET_APP"
echo "Removed: $TARGET_APP"
echo "Usage history was kept in: $HOME/Library/Application Support/AI Quota Bar"
