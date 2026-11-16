# Over-the-air updates

OpenScribe updates itself with [Sparkle 2](https://sparkle-project.org) (pinned to 2.10.1 in `Package.swift`). Each update is a signed ZIP listed in an EdDSA-signed appcast. The appcast is published as an asset on the latest GitHub release.

| | |
|---|---|
| Feed URL (`SUFeedURL`) | `https://github.com/shashankanil/openscribe/releases/latest/download/appcast.xml` |
| Public key (`SUPublicEDKey`) | `POg+akMVrC76in+cor5L6c1UMGR9y655zKPIdkzAbJ0=` (in `AppInfo.plist`) |
| Private key | Login Keychain, item "Private key for signing Sparkle updates" (account `ed25519`). Never in the repo or on disk. |
| Check interval | Every 4 hours (`SUScheduledCheckInterval` = 14400) |
| Version Sparkle compares | `CFBundleVersion`, an integer build number that increases with every release |

## What users see

- OpenScribe checks for updates every 4 hours. It doesn't ask first, because `SUEnableAutomaticChecks` is on.
- New versions download and verify silently in the background (`SUAutomaticallyUpdate`).
- When an update is ready, OpenScribe does not restart by itself. It offers **Install and relaunch** in three places:
  - the menu-bar menu: **Install Update and Relaunch (x.y.z)**
  - an **Update ready** banner in the quick panel
  - Settings → Updates
- The button is disabled while you are dictating or recording a meeting. Relaunching quits through the normal path, so in-progress work is finalized first.
- If you just quit OpenScribe, Sparkle installs the update on the way out. The next launch is the new version.
- **Check for Updates…** in the menu-bar menu shows Sparkle's standard window: progress, release notes, or "You're up to date".
- Settings → Updates also has two toggles: **Check automatically** and **Download in the background**. With background downloads off, Sparkle shows its standard update alert instead. OpenScribe can run without a Dock icon, so the alert never takes focus.
- Settings, provider keys, notes, and Accessibility and Microphone permissions carry over. macOS ties those permissions to the code-signing identity, and every update is signed with the same identity.

The updater is off in DEBUG builds, under `swift run` and `swift test`, and in any process that isn't an `.app` bundle with `SUFeedURL` and `SUPublicEDKey` (see `UpdateController.bundleSupportsUpdates`).

## Release checklist

1. Write `docs/RELEASE-v<version>.md`. It becomes both the GitHub release notes and the Markdown notes Sparkle shows in the update window.
2. Run `scripts/release.sh <version>`, for example `scripts/release.sh 0.6.0`. The script:
   - bumps `CFBundleShortVersionString` in `AppInfo.plist` and increments `CFBundleVersion` by one if the version changed. Commit that change.
   - checks that `SUPublicEDKey` matches the Keychain key (`generate_keys -p`).
   - builds and signs the app and DMG with `scripts/package-dmg.sh`, then zips the app with `ditto` (keeps framework symlinks and signatures).
   - downloads the currently published `appcast.xml` and adds the new item, so older builds keep a valid history. It refuses to continue if the published feed already has an equal or higher build.
   - runs Sparkle's `generate_appcast`, which signs the ZIP with the Keychain key. The first time, macOS may ask to let `generate_appcast` use the key. Click **Always Allow**.
   - writes `dist/release-v<version>/`: the DMG, the ZIP, `SHA256SUMS.txt`, and `appcast.xml`.
   - prints the `gh release create` command. It never publishes or pushes anything itself.
3. Check `dist/release-v<version>/appcast.xml`: `sparkle:version` is the new build, the enclosure URL points at `releases/download/v<version>/…zip`, and `sparkle:edSignature` is present.
4. Run the printed `gh release create … --latest` command. The release must be published (not a draft) and not a prerelease. Installed apps read `releases/latest/download/appcast.xml`, which GitHub serves from the latest release only.
5. Check the published feed with `curl -sL https://github.com/shashankanil/openscribe/releases/latest/download/appcast.xml | head`. Then click **Check for Updates…** in an installed older build.

To fix a feed that is already published, edit and re-sign it by rerunning `generate_appcast` on the release folder. Then replace the asset with `gh release upload v<version> --clobber dist/release-v<version>/appcast.xml`.

## Signing key

`generate_keys` created the key pair once and stored the private key in the login Keychain. **Back it up now.** If the key is lost, no installed copy can verify a future update, and every user has to reinstall manually.

```sh
# Export to an encrypted location (password manager, encrypted disk image). Do not commit or leave it on disk.
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/secure/openscribe-sparkle-private-key
# Restore on a new Mac:
.build/artifacts/sparkle/Sparkle/bin/generate_keys -f ~/secure/openscribe-sparkle-private-key
# Print the public key (must equal SUPublicEDKey in AppInfo.plist):
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p
```

The tools come from Sparkle's Swift package artifact. Run `swift package resolve` if `.build/artifacts/sparkle` is missing. For CI, pass the key on stdin (`--ed-key-file -`) or set `SPARKLE_ED_KEY_FILE` for `release.sh`.

**Rotation rule.** Sparkle accepts an update if either the EdDSA signature matches the installed app's key, or the update's Apple code signature satisfies the installed app's designated requirement. Never change the EdDSA key and the signing certificate in the same release.

## How verification works

The following comes from Sparkle 2.10.1 source (`.build/checkouts/Sparkle`) and the [Sparkle docs](https://sparkle-project.org/documentation/).

**EdDSA.** The app requires an EdDSA key. Without one, Sparkle refuses to update (`SPUUpdater.m`: "updates need to be signed with an EdDSA key"). The `Autoupdate` installer checks the downloaded archive against the public key of the *installed* app (`SUUpdateValidator.m`, `validateUpdateForHost:`). A tampered signature is rejected; this was tested locally, see below.

**Apple code signature.** When the installed app is code-signed, Sparkle also checks the update with `SecStaticCodeCheckValidityWithErrors` against the old app's designated requirement (`SUCodeSigningVerifier.m`). For OpenScribe that requirement is:

```
identifier "org.open-source.openscribe" and anchor apple generic
  and certificate leaf[subject.CN] = "Apple Development: … (3BNFP2VQ73)"
  and certificate 1[field.1.2.840.113635.100.6.2.1]
```

Sparkle accepts the update if EdDSA passes or the designated requirement passes. If the update is code-signed but its signature is broken, Sparkle rejects it even when EdDSA passes. Sparkle does not require a Developer ID certificate on this path. The Developer-ID-only check (`andMatchesDeveloperIDTeam…`) is used only with `SUVerifyUpdateBeforeExtraction`, which OpenScribe does not set. An Apple Development certificate works.

**Quarantine and Gatekeeper.** Sparkle downloads with `URLSession`, which does not add `com.apple.quarantine` because OpenScribe doesn't set `LSFileQuarantineEnabled`. The installer also strips quarantine from the new bundle explicitly (`SUPlainInstaller.m`, `releaseItemFromQuarantineAtRootURL:`). When it can swap the bundle atomically on macOS 14.4 or later, it also runs `gktool scan` to pre-warm Gatekeeper. With no quarantine flag, Gatekeeper never assesses the replaced app, so an unnotarized update relaunches without the "unidentified developer" prompt. This was verified locally, see below.

**Bundle layout.** `scripts/package-app.sh` copies `Sparkle.framework` into `Contents/Frameworks` and adds the `@executable_path/../Frameworks` rpath. SwiftPM only sets `@loader_path`. The script signs Sparkle's helpers inside-out with the same identity, following [Sparkle's code-signing steps](https://sparkle-project.org/documentation/sandboxing/#code-signing):

1. `Installer.xpc`
2. `Downloader.xpc` (`--preserve-metadata=entitlements`)
3. `Autoupdate`
4. `Updater.app`
5. the framework itself

The script then signs the app *without* `--deep`, because `--deep` would re-sign Sparkle's helpers and drop their flags. OpenScribe is not sandboxed, so the XPC services are unused, but they are shipped and signed anyway.

## Local end-to-end update test

This test never touches `/Applications/OpenScribe.app` or the real profile. The test builds use a separate bundle ID and a throwaway EdDSA key. `--update-smoke` is a maintenance mode, like `--credential-smoke`. It starts only the updater, never the rest of the app, and prints one line.

```sh
S=$(mktemp -d)                      # scratch dir
# 1. Throwaway key: base64 32-byte Ed25519 seed (private) + base64 public key, e.g. via CryptoKit:
#    Curve25519.Signing.PrivateKey().rawRepresentation / .publicKey.rawRepresentation
export OPENSCRIBE_BUNDLE_ID=org.open-source.openscribe.updatetest \
       OPENSCRIBE_FEED_URL=http://127.0.0.1:8765/latest/appcast.xml \
       OPENSCRIBE_ED_PUBLIC_KEY=<test public key>
OPENSCRIBE_VERSION=0.5.90 OPENSCRIBE_BUILD=900 PACKAGE_OUTPUT_DIR=$S/N  scripts/package-app.sh
OPENSCRIBE_VERSION=0.5.91 OPENSCRIBE_BUILD=901 PACKAGE_OUTPUT_DIR=$S/N1 scripts/package-app.sh
# 2. Feed: zip N+1, sign it, serve it (a 302 from /latest/ to /files/ mimics GitHub's redirect)
ditto -c -k --sequesterRsrc --keepParent $S/N1/OpenScribe.app $S/feed/OpenScribe-v0.5.91-macos-arm64.zip
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --ed-key-file $S/test-private.key \
    --download-url-prefix http://127.0.0.1:8765/files/ --embed-release-notes --maximum-deltas 0 $S/feed
# 3. Install N into a temp folder and run it
ditto $S/N/OpenScribe.app $S/install/OpenScribe.app
$S/install/OpenScribe.app/Contents/MacOS/OpenScribe --update-smoke
#   update-smoke downloaded version=0.5.91 build=901; quitting to install
open -n -W --stdout /dev/stdout $S/install/OpenScribe.app --args --update-smoke
#   update-smoke up-to-date version=0.5.91 build=901
# Cleanup
defaults delete org.open-source.openscribe.updatetest; rm -rf ~/Library/Caches/org.open-source.openscribe.updatetest
```

Sparkle refuses an *immediate* install while relaunching is disabled. So the smoke test takes the install-on-quit path, which uses the same installer and validation. The in-app **Install and relaunch** button uses Sparkle's immediate-install handler with relaunching on. Test it by hand with a real build.

## Limits

- **First install is still manual.** Users on v0.5.0 or earlier have no updater. They must install the first Sparkle-enabled release by hand, including the usual unnotarized-app steps: right-click → Open, or System Settings → Privacy & Security → Open Anyway. Every later release arrives over the air.
- **Not notarized.** Updates avoid Gatekeeper because Sparkle strips quarantine. Fresh downloads from GitHub are still quarantined and blocked. Signing with a Developer ID certificate and notarizing would remove that first-install friction. Sparkle's docs also recommend it, because some code-signing policies "may otherwise not take effect … when updating from/to non-notarized builds".
- **Apple Development certificates expire after a year.** A renewed certificate for the same developer keeps the same `subject.CN`, so the designated requirement and the TCC grants still match. If the identity ever changes, EdDSA still validates the update, but users have to grant Accessibility and Microphone again.
- **Write access.** Sparkle replaces the app in place. If the app sits somewhere the user can't write, such as `/Applications` owned by another admin, Sparkle asks for an administrator password. If the app runs from a read-only disk image or a translocated path, Sparkle won't update it.
- **Apple silicon and macOS 14+ only.** `generate_appcast` records `arm64` and `minimumSystemVersion` 14.0 in each item.
- **The feed depends on GitHub's "latest release".** A draft, a prerelease, or a later release without `appcast.xml` breaks the feed URL until fixed. Because the repository is public, no other hosting is needed. GitHub Pages or a Worker route could serve the same file if that ever changes.
