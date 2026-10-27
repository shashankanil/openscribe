# OpenScribe Desktop v0.4.0

OpenScribe is now available as a native desktop application for Windows and Linux. The existing Swift edition for macOS is unchanged and outside this release.

## Included

- Guided provider and microphone setup with a safe practice recording.
- Local, searchable notes with editing, tags, copy, raw transcript preservation, and optional source-audio retention.
- Global shortcut dictation and clipboard-preserving paste into the focused application.
- OpenAI, OpenRouter, Groq, Mistral, Deepgram, AssemblyAI, Anthropic, Gemini, and custom compatible provider routing.
- Secure provider keys through the operating system credential store.
- Optional cleanup strength, writing tone, vocabulary, exact correction rules, and whole-utterance voice snippets.
- Meeting recording from a selected microphone or OS loopback/monitor source, with transcript and optional summary.
- Local ICS calendar import for Outlook, Google Calendar, and CalDAV exports.
- Friendly user notices that keep raw provider diagnostics behind Details.
- Retry or discard recovery for recordings interrupted by a provider or network failure.
- Paper and dark themes using the same warm, focused OpenScribe visual language.

## Downloads

- Windows x64: NSIS setup executable or MSI installer.
- Linux x64: AppImage or Debian package.
- Linux ARM64: AppImage or Debian package.

The GitHub workflow creates a draft release first. Test each generated installer on a clean machine before publishing the draft.

## Platform notes

- Windows system audio requires Stereo Mix or another loopback capture input.
- Linux system audio requires a PipeWire/Pulse monitor source and desktop support for global shortcuts/input injection. Wayland compositors may require explicit permission or an XWayland session for automatic paste.
- Calendar support is ICS import rather than native account aggregation.
- This first cross-platform release processes audio after the recording stops. The macOS edition's provider-specific low-latency streaming is not yet enabled in this shell.
- Windows signing credentials are not configured in the repository. Unsigned test builds will show Microsoft SmartScreen warnings.
