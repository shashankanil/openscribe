OpenScribe v0.2.0 adds meeting capture, a full calendar view, live transcription routing, and a redesigned settings workflow.

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
