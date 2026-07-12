#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${1:-0.1.0}"
APP_NAME="AI Quota Bar"

"$ROOT/Scripts/build-app.sh" >/dev/null
mkdir -p "$ROOT/releases"
ARCHIVE="$ROOT/releases/AIQuotaBar-$VERSION-macos.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/$APP_NAME.app" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"

echo "$ARCHIVE"
