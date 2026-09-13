# Installation and everyday use

The first launch opens a three-step setup: connect a transcription provider, enable permissions, and optionally record a practice note. Setup resumes if a required key or permission is missing. Existing configured users keep their settings. Notes-only mode requires a microphone and provider key; Accessibility is optional until the user wants the global shortcut or pasting into other apps. A visible Record a note / Stop & save control makes this mode usable. Setup can be reopened from the sidebar.

Practice recordings save to Notes and never paste into another app. Cleanup remains optional, so a missing second provider key does not block first use. Keys remain scoped to the selected provider and endpoint.

The installer stages and verifies the signed bundle before replacing the existing app. A failed copy or verification leaves the existing installation intact. It requests administrator access only when the destination requires it, then launches setup through the logged-in user's workspace. A running OpenScribe must be closed before updating. Downloaded builds still need notarization for a completely frictionless Gatekeeper experience; local self-signing instructions are in the release notes.

Errors use a short, nonactivating bubble that disappears after six seconds. Technical service details are available on demand. Showing a notice never cancels recording or changes the capture phase. Meeting errors retain expandable details for later troubleshooting.

Meeting upload boundaries no longer define the reading layout. Consecutive text from each audio input forms paragraphs, with breaks for pauses and longer passages. Search and source filtering work on these passages. Original audio references remain available from timestamps and summary citations. Markdown exports use the same grouped text. Source labels are audio inputs, not speaker diarization; overlapping voices cannot be reliably ordered from coarse chunk timestamps alone.

## Design references

The focused setup and first-recording flow were informed by Wispr Flow's [setup guide](https://docs.wisprflow.ai/articles/3152211871-setup-guide) and [first dictation guide](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation). The meeting reader follows the emphasis on a coherent transcript and separate summary in its [meeting notes documentation](https://docs.wisprflow.ai/articles/9406970664-meeting-notes-and-the-editor-in-notetaker-beta). OpenScribe retains its own provider configuration and local recovery model.

## Verification

Automated checks cover fresh/incomplete setup, Notes-only readiness, transcript grouping and source preservation, export consistency, and concise error text, alongside the existing capture/recovery/provider tests. A synthetic meeting reader is rendered using an isolated store; no user recording is created. The setup screens and sidebar controls are checked in the packaged dev app. Installer staging is exercised against a temporary destination with both a valid signed bundle and an invalid replacement.

A separately identified debug app was launched with an empty isolated profile and no onboarding argument: setup opened automatically, blocked continuation without a key, and resumed after skipping and relaunching. `OPENSCRIBE_TEST_PROFILE` redirects debug-build storage only; release builds always use the normal application data directory. macOS permission grants were not reset or accepted during verification. Gatekeeper behavior for downloaded, unnotarized releases remains subject to the installation instructions.
