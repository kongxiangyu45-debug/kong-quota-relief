#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="AI Quota Bar"
SOURCE_APP="$ROOT/dist/$APP_NAME.app"
TARGET_APP="/Applications/$APP_NAME.app"
BACKUP_ROOT="$HOME/Library/Application Support/AI Quota Bar/Backups"

"$ROOT/Scripts/build-app.sh" >/dev/null

if [[ -d "$TARGET_APP" ]]; then
    mkdir -p "$BACKUP_ROOT"
    BACKUP="$BACKUP_ROOT/$APP_NAME-$(date +%Y%m%d-%H%M%S).app"
    ditto "$TARGET_APP" "$BACKUP"
    echo "Backed up current app to: $BACKUP"
fi

pkill -x "$APP_NAME" 2>/dev/null || true
for _ in {1..30}; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.1
done
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
open -n "$TARGET_APP"

echo "Installed: $TARGET_APP"
