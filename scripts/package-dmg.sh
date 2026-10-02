#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | /usr/bin/awk 'match($0, /"[^"]+"/) { print substr($0, RSTART + 1, RLENGTH - 2); exit }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    print -u2 "No stable code-signing identity found. Set CODESIGN_IDENTITY or install a signing certificate."
    exit 1
fi
CONFIG="${CONFIGURATION:-release}"
OUTPUT_DIR="${PACKAGE_OUTPUT_DIR:-$ROOT/dist}"
APP="$OUTPUT_DIR/OpenScribe.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/AppInfo.plist")"
DMG="$OUTPUT_DIR/OpenScribe-v${VERSION}-macos-arm64.dmg"
STAGING="$(mktemp -d)"

cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT
CODESIGN_IDENTITY="$SIGNING_IDENTITY" "$ROOT/scripts/package-app.sh" >/dev/null
BIN_PATH="$(swift build --show-bin-path -c "$CONFIG" --package-path "$ROOT")"
INSTALLER="$OUTPUT_DIR/OpenScribe Installer.app"
rm -rf "$INSTALLER"
mkdir -p "$INSTALLER/Contents/MacOS"
cp "$BIN_PATH/OpenScribeInstaller" "$INSTALLER/Contents/MacOS/OpenScribeInstaller"
cp "$ROOT/InstallerInfo.plist" "$INSTALLER/Contents/Info.plist"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$INSTALLER" >/dev/null

rm -f "$DMG"
cp -R "$APP" "$STAGING/OpenScribe.app"
cp -R "$INSTALLER" "$STAGING/OpenScribe Installer.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "OpenScribe" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

printf '%s\n' "$DMG"
