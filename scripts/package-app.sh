#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIGURATION:-debug}"
swift build -c "$CONFIG" --package-path "$ROOT" >/dev/null
BIN_PATH="$(swift build --show-bin-path -c "$CONFIG" --package-path "$ROOT")"
APP="$ROOT/dist/OpenScribe.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/OpenScribe" "$APP/Contents/MacOS/OpenScribe"
cp "$ROOT/AppInfo.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/OpenScribe/Resources/Whisperlight.icns" "$APP/Contents/Resources/Whisperlight.icns"

codesign --force --deep --sign - "$APP" >/dev/null
printf '%s\n' "$APP"
