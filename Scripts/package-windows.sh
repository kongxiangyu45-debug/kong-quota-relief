#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${1:-0.3.0}"
GO_BIN="${GO_BIN:-$(command -v go || true)}"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    if [[ -z "$GO_BIN" ]]; then
        echo "Go 1.22 or newer is required. Set GO_BIN=/path/to/go and retry." >&2
        exit 1
    fi
    GO_BIN="$GO_BIN" "$ROOT/windows/QuotaRelief/build-windows.sh" >/dev/null
fi

if [[ ! -x "$ROOT/windows/QuotaRelief/dist/kong的额度焦虑缓解器.exe" ]]; then
    echo "Windows executable not found. Build it first or run without SKIP_BUILD=1." >&2
    exit 1
fi

mkdir -p "$ROOT/releases"
ARCHIVE="$ROOT/releases/kong-quota-relief-windows-x64.zip"
STAGE_ROOT="$(mktemp -d)"
PACKAGE_DIR="$STAGE_ROOT/kong的额度焦虑缓解器-Windows-x64-v$VERSION"
trap 'rm -rf "$STAGE_ROOT"' EXIT

mkdir -p "$PACKAGE_DIR"
ditto "$ROOT/windows/QuotaRelief/dist/kong的额度焦虑缓解器.exe" "$PACKAGE_DIR/kong的额度焦虑缓解器.exe"
ditto "$ROOT/Distribution/kong的额度焦虑缓解器-Windows使用说明.html" "$PACKAGE_DIR/使用说明.html"
ditto "$ROOT/Distribution/kong的额度焦虑缓解器-Windows使用说明.md" "$PACKAGE_DIR/使用说明.md"

EXE_HASH="$(shasum -a 256 "$PACKAGE_DIR/kong的额度焦虑缓解器.exe" | awk '{print $1}')"
printf "%s  kong的额度焦虑缓解器.exe\n" "$EXE_HASH" > "$PACKAGE_DIR/SHA256校验码.txt"

rm -f "$ARCHIVE" "$ARCHIVE.sha256"
(cd "$STAGE_ROOT" && /usr/bin/zip -r -X -q "$ARCHIVE" "${PACKAGE_DIR:t}")
ARCHIVE_HASH="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
printf "%s  %s\n" "$ARCHIVE_HASH" "${ARCHIVE:t}" > "$ARCHIVE.sha256"

echo "$ARCHIVE"
