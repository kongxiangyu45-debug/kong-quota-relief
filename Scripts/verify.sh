#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

SELF_TEST_BIN="$(mktemp -d)/ai-quota-bar-core-test"
swiftc \
    "$ROOT/Sources/AIQuotaBarCore/UsageAttribution.swift" \
    "$ROOT/Tests/CoreSelfTest/main.swift" \
    -o "$SELF_TEST_BIN"
"$SELF_TEST_BIN"
APP_PATH=$("$ROOT/Scripts/build-app.sh" | tail -1)
plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict "$APP_PATH"
test -x "$APP_PATH/Contents/MacOS/AI Quota Bar"

echo "Verification passed: $APP_PATH"
