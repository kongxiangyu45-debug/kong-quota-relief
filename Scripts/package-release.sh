#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${1:-0.3.0}"
APP_NAME="AI Quota Bar"

"$ROOT/Scripts/build-app.sh" >/dev/null
mkdir -p "$ROOT/releases"
ARCHIVE="$ROOT/releases/kong-quota-relief-macos-arm64.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$ROOT/dist/$APP_NAME.app" "$ARCHIVE"
ARCHIVE_HASH="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
printf "%s  %s\n" "$ARCHIVE_HASH" "${ARCHIVE:t}" > "$ARCHIVE.sha256"

echo "$ARCHIVE"
