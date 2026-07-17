#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
GO_BIN="${GO_BIN:-$(command -v go || true)}"

if [[ -z "$GO_BIN" ]]; then
    echo "Go 1.22 or newer is required. Set GO_BIN=/path/to/go and retry." >&2
    exit 1
fi

cd "$ROOT"
"$GO_BIN" test ./...
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 "$GO_BIN" build \
    -trimpath \
    -ldflags "-H=windowsgui -s -w" \
    -o "dist/kong的额度焦虑缓解器.exe" \
    .

echo "$ROOT/dist/kong的额度焦虑缓解器.exe"
