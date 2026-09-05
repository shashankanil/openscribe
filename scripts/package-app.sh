#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIGURATION:-debug}"
swift build -c "$CONFIG" --package-path "$ROOT" >/dev/null
BIN_PATH="$(swift build --show-bin-path -c "$CONFIG" --package-path "$ROOT")"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | /usr/bin/awk 'match($0, /"[^"]+"/) { print substr($0, RSTART + 1, RLENGTH - 2); exit }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    print -u2 "No stable code-signing identity found. Set CODESIGN_IDENTITY or install a signing certificate."
    exit 1
fi

OUTPUT_DIR="${PACKAGE_OUTPUT_DIR:-$ROOT/dist}"
APP="$OUTPUT_DIR/OpenScribe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/OpenScribe" "$APP/Contents/MacOS/OpenScribe"
cp "$ROOT/AppInfo.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/OpenScribe/Resources/Whisperlight.icns" "$APP/Contents/Resources/Whisperlight.icns"

codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP" >/dev/null
printf '%s\n' "$APP"
