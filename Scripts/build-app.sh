#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="AI Quota Bar"
APP="$ROOT/dist/$APP_NAME.app"

cd "$ROOT"
swift build -c release --product AIQuotaBar

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/release/AIQuotaBar" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "$APP"
