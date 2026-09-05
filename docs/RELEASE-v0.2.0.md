OpenScribe v0.2.0 adds meeting capture, a full calendar view, live transcription routing, and a redesigned settings workflow.

### Install and self-sign locally

1. Download the DMG or ZIP from this release. Optionally verify the download against `SHA256SUMS.txt` before extracting it.
2. Copy **OpenScribe.app** into **Applications**. Quit OpenScribe before changing its signature. Work on the installed copy, not the app inside the mounted DMG.
3. In Terminal, apply a local ad-hoc signature and verify it:

   ```sh
   codesign --force --sign - "/Applications/OpenScribe.app"
   codesign --verify --deep --strict --verbose=2 "/Applications/OpenScribe.app"
   ```

   The `-` means ad-hoc signing: no Apple Developer account or certificate is required. This replaces the release signature for your local copy; it does not notarize the app or establish developer trust.

4. Open the app:

   ```sh
   open "/Applications/OpenScribe.app"
   ```

   If macOS blocks this unnotarized download, use **System Settings → Privacy & Security → Open Anyway** after attempting to open it. See [Apple's instructions](https://support.apple.com/en-gb/guide/mac-help/mh40616/mac).

   For a copy you downloaded from this release and trust, you can alternatively remove its download-quarantine attribute, limited to this app:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/OpenScribe.app"
   open "/Applications/OpenScribe.app"
   ```

If a command reports **Permission denied**, run that command again with `sudo` only if you installed the app in `/Applications` and need administrator access. Do not disable Gatekeeper system-wide.

**Permissions after re-signing:** macOS may treat the changed signature as a different app. Re-enable OpenScribe under Privacy & Security → Accessibility; if pasting still fails, remove its old Accessibility entry and add the installed app again. Allow microphone, calendar, and screen/system-audio recording access when requested for the features you use. Ad-hoc signing can require these grants again after future updates.

For a stable personal signing identity you already have in Keychain, list it with `security find-identity -v -p codesigning`, then replace `-` in the signing command with its quoted identity name. [Apple's code-signing guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html) explains certificate-based signing.

### What's new

- Calendar month view and day agenda, with calendar filtering, meeting links, and per-occurrence recording exclusions. Google calendars sync through macOS Calendar.
- Scheduled meeting prompts, configurable unanswered-start behavior, end-of-meeting controls, and title-based exclusions. Calendar timing does not detect whether a call is connected.
- Meeting recording with microphone and system audio, pause/resume, incremental transcription, and summaries with transcript references.
- Automatic live-audio routing for mapped direct-provider configurations: OpenAI, Mistral, Deepgram, and AssemblyAI. Other configurations, including OpenRouter, use 15-second file sections.
- Provider credentials isolated by provider, endpoint, and purpose, with one-time migration of existing keys and explicit save, replace, remove, and reuse controls.
- Unified sidebar navigation, simpler transcription and writing settings, focused key-management dialogs, and a monochrome menu-bar icon.
- Microphone selection, subtle recording sounds, correction rules, snippets, and app-specific writing tones.

### Reliability

- Durable recording recovery, incremental transcript checkpoints, bounded transcription retries, and file fallback after stream failure.
- All chunks of a dictation use one session note; retries reuse its ID and preserve its timestamp, pin, and tags.
- Globe-key handling ignores unrelated modifier events that could end a capture.
- Improved focus restoration and clipboard-preserving paste.

### Requirements and current limits

- Apple silicon Mac running macOS 14 or later. The app and installer are code-signed; this release is not notarized.
- Provider API keys are required. Credentials remain in a permission-restricted local file, not Keychain.
- Live connections renew at approximately 15-second recovery boundaries. Real-provider acceptance and quality depend on account access and configuration; transport tests use simulated sockets.
- OpenRouter currently uses uploaded audio sections. Its API key cannot be reused for a direct provider.
- This calendar integration reads events; it does not create or edit calendar events.

### Validation

59 automated tests passed, including calendar date boundaries, credential isolation and migration, streaming/fallback behavior, and multi-chunk session history. App bundles and distribution assets were built with the release configuration.

Download the DMG for the app and installer, or the ZIP for the app alone. SHA-256 checksums are provided in SHA256SUMS.txt.
