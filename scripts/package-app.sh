#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIGURATION:-release}"
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
# Local MCP server (read-only stdio), registered by users as <app>/Contents/MacOS/openscribe-mcp.
cp "$BIN_PATH/openscribe-mcp" "$APP/Contents/MacOS/openscribe-mcp"
cp "$ROOT/AppInfo.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/OpenScribe/Resources/Whisperlight.icns" "$APP/Contents/Resources/Whisperlight.icns"

# Optional Info.plist overrides, used by the local end-to-end update test (docs/UPDATES.md). Releases leave these unset.
PLIST="$APP/Contents/Info.plist"
[[ -n "${OPENSCRIBE_VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $OPENSCRIBE_VERSION" "$PLIST"
[[ -n "${OPENSCRIBE_BUILD:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $OPENSCRIBE_BUILD" "$PLIST"
[[ -n "${OPENSCRIBE_BUNDLE_ID:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $OPENSCRIBE_BUNDLE_ID" "$PLIST"
[[ -n "${OPENSCRIBE_FEED_URL:-}" ]] && /usr/libexec/PlistBuddy -c "Set :SUFeedURL $OPENSCRIBE_FEED_URL" "$PLIST"
[[ -n "${OPENSCRIBE_ED_PUBLIC_KEY:-}" ]] && /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $OPENSCRIBE_ED_PUBLIC_KEY" "$PLIST"

# Sparkle (over-the-air updates): embed the framework and let the executable find it in Contents/Frameworks.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_PATH/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/OpenScribe" | grep -q "path @executable_path/../Frameworks "; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/OpenScribe"
fi

# Sign nested code inside-out (the helper first), then the bundle; verify the helper is signed.
# Sparkle's helpers follow https://sparkle-project.org/documentation/sandboxing/#code-signing (no --deep:
# Downloader.xpc keeps its own entitlements). The app itself is then signed without --deep for the same reason.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGNING_IDENTITY" -o runtime "$SPARKLE/Versions/B/XPCServices/Installer.xpc" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" -o runtime --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" -o runtime "$SPARKLE/Versions/B/Autoupdate" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" -o runtime "$SPARKLE/Versions/B/Updater.app" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" -o runtime "$SPARKLE" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/openscribe-mcp" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" "$APP" >/dev/null
codesign --verify --strict "$APP/Contents/MacOS/openscribe-mcp"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
