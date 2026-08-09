#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIGURATION:-debug}"
BIN_PATH="$(swift build --show-bin-path -c "$CONFIG" --package-path "$ROOT")"
APP="$ROOT/dist/WhisperFlow.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/WhisperFlow" "$APP/Contents/MacOS/WhisperFlow"
cp "$ROOT/AppInfo.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/WhisperFlow/Resources/Whisperlight.icns" "$APP/Contents/Resources/Whisperlight.icns"

codesign --force --deep --sign - "$APP" >/dev/null
printf '%s\n' "$APP"
