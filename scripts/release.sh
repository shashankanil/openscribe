#!/bin/zsh
# Build a signed release and its Sparkle appcast. Nothing is published or pushed: the script ends by
# printing the `gh` commands to run. See docs/UPDATES.md for the full checklist.
#
#   scripts/release.sh 0.6.0
#
# Inputs:   docs/RELEASE-v<version>.md (release notes, embedded in the appcast as Markdown)
# Outputs:  dist/release-v<version>/{OpenScribe-v<version>-macos-arm64.dmg,.zip, SHA256SUMS.txt, appcast.xml}
#
# Environment (optional):
#   CODESIGN_IDENTITY       signing identity (default: first valid identity, same as package-app.sh)
#   SPARKLE_ED_KEY_FILE     sign with a private-key file instead of the login Keychain (CI / tests)
#   RELEASE_FEED_SEED_URL   appcast to extend (default: SUFeedURL from AppInfo.plist; use "none" to start fresh)
#   RELEASE_DOWNLOAD_PREFIX archive URL prefix (default: the GitHub release download URL for this tag)
#   RELEASE_SKIP_DMG=1      build only the ZIP (used by the local update test)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="shashankanil/openscribe"
VERSION="${1:-}"
die() { print -u2 "release: $*"; exit 1; }

[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "usage: scripts/release.sh <major.minor.patch>"
NOTES="$ROOT/docs/RELEASE-v$VERSION.md"
[[ -f "$NOTES" ]] || die "write the release notes first: docs/RELEASE-v$VERSION.md"

SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || swift package resolve --package-path "$ROOT" >/dev/null
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || die "Sparkle tools not found in $SPARKLE_BIN"

PLIST="$ROOT/AppInfo.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
CURRENT_VERSION="$(pb 'Print :CFBundleShortVersionString')"
BUILD="$(pb 'Print :CFBundleVersion')"
[[ "$BUILD" =~ '^[0-9]+$' ]] || die "CFBundleVersion must be an integer build number (found '$BUILD')"
if [[ "$CURRENT_VERSION" != "$VERSION" ]]; then
    BUILD=$((BUILD + 1))
    pb "Set :CFBundleShortVersionString $VERSION"
    pb "Set :CFBundleVersion $BUILD"
    print "Bumped AppInfo.plist: $CURRENT_VERSION -> $VERSION (build $BUILD). Commit this change with the release."
fi

# The app must ship the public half of the key that signs the appcast, or no installed copy can update.
PUBLIC_KEY="$(pb 'Print :SUPublicEDKey')"
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
    KEY_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
else
    KEY_ARGS=()
    KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" || die "no Sparkle signing key in the login Keychain (see docs/UPDATES.md, 'Signing key')"
    [[ "$KEYCHAIN_KEY" == "$PUBLIC_KEY" ]] || die "SUPublicEDKey in AppInfo.plist does not match the Keychain signing key"
fi

OUT="$ROOT/dist/release-v$VERSION"
UPDATES="$OUT/updates"
BASENAME="OpenScribe-v$VERSION-macos-arm64"
rm -rf "$OUT"
mkdir -p "$UPDATES"

if [[ "${RELEASE_SKIP_DMG:-0}" == 1 ]]; then
    APP="$("$ROOT/scripts/package-app.sh" | tail -n 1)" || die "packaging failed; run 'swift build -c release' to see why"
else
    DMG="$("$ROOT/scripts/package-dmg.sh" | tail -n 1)" || die "packaging failed; run 'swift build -c release' to see why"
    cp "$DMG" "$OUT/$BASENAME.dmg"
    APP="$(dirname "$DMG")/OpenScribe.app"
fi
codesign --verify --deep --strict "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD" ]] || die "built app has an unexpected CFBundleVersion"

# Sparkle installs the ZIP. ditto keeps the framework symlinks and code signatures intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPDATES/$BASENAME.zip"
cp "$NOTES" "$UPDATES/$BASENAME.md"

# Extend the published feed so users on older builds still see the full recent history.
FEED_URL="$(pb 'Print :SUFeedURL')"
SEED="${RELEASE_FEED_SEED_URL:-$FEED_URL}"
if [[ "$SEED" != none ]] && curl -fsSL --retry 2 "$SEED" -o "$UPDATES/appcast.xml" 2>/dev/null; then
    LATEST="$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$UPDATES/appcast.xml" | grep -o '[0-9][0-9]*' | sort -n | tail -n 1 || true)"
    if [[ -n "$LATEST" ]] && (( LATEST >= BUILD )); then
        die "published appcast already has build $LATEST; CFBundleVersion must be greater (currently $BUILD)"
    fi
    print "Extending published appcast from $SEED (latest build ${LATEST:-none})"
else
    rm -f "$UPDATES/appcast.xml"
    print "Starting a new appcast"
fi

DOWNLOAD_PREFIX="${RELEASE_DOWNLOAD_PREFIX:-https://github.com/$REPO/releases/download/v$VERSION/}"
"$SPARKLE_BIN/generate_appcast" "${KEY_ARGS[@]}" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --embed-release-notes \
    --full-release-notes-url "https://github.com/$REPO/releases" \
    --link "https://github.com/$REPO" \
    --maximum-deltas 0 \
    "$UPDATES"

mv "$UPDATES/$BASENAME.zip" "$OUT/$BASENAME.zip"
cp "$UPDATES/appcast.xml" "$OUT/appcast.xml"
rm -rf "$UPDATES"
(
    cd "$OUT"
    shasum -a 256 OpenScribe-v*.{dmg,zip}(N) > SHA256SUMS.txt
)

grep -q "<sparkle:version>$BUILD</sparkle:version>" "$OUT/appcast.xml" || die "appcast is missing build $BUILD"
grep -q 'sparkle:edSignature=' "$OUT/appcast.xml" || die "appcast entry is not EdDSA-signed"

print
print "Built OpenScribe $VERSION (build $BUILD) in $OUT:"
ls -1 "$OUT" | sed 's/^/  /'
print
print "Publish (not run). The release must be the repo's latest, non-draft, non-prerelease release,"
print "because installed apps read $FEED_URL:"
print
ASSETS=("$OUT"/OpenScribe-v*.{dmg,zip}(N) "$OUT/SHA256SUMS.txt" "$OUT/appcast.xml")
print "  gh release create v$VERSION -R $REPO --title 'OpenScribe v$VERSION' --notes-file docs/RELEASE-v$VERSION.md --latest \\"
print "    ${(j: \\\n    :)${(q)ASSETS[@]}}"
print
print "Fix a bad appcast or asset on an existing release:"
print "  gh release upload v$VERSION -R $REPO --clobber ${(q)OUT}/appcast.xml"
