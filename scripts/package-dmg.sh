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
APP="$ROOT/dist/OpenScribe.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/AppInfo.plist")"
DMG="$ROOT/dist/OpenScribe-v${VERSION}-macos-arm64.dmg"
STAGING="$(mktemp -d)"

cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT
CODESIGN_IDENTITY="$SIGNING_IDENTITY" "$ROOT/scripts/package-app.sh" >/dev/null
BIN_PATH="$(swift build --show-bin-path --package-path "$ROOT")"
INSTALLER="$ROOT/dist/OpenScribe Installer.app"
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

hdiutil attach -nobrowse "$DMG" >/dev/null
osascript <<'APPLESCRIPT' || true
tell application "Finder"
    tell disk "OpenScribe"
        open
        delay 1
        set current view of container window to icon view
        set icon size of icon view options of container window to 128
        set position of item "OpenScribe.app" to {160, 190}
        set position of item "Applications" to {500, 190}
        set position of item "OpenScribe Installer.app" to {330, 370}
        set bounds of container window to {100, 100, 700, 560}
        close container window
    end tell
end tell
APPLESCRIPT
hdiutil detach /Volumes/OpenScribe >/dev/null || true

printf '%s\n' "$DMG"
