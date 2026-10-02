OpenScribe v0.4.0 rebuilds the native Mac workspace around a persistent note library, a focused editor, and simpler provider setup.

### What's new

- Browse and edit notes side by side. Titles, previews, search, date groups, and pinned notes keep the library easy to scan.
- Create a note with Command-N and start typing immediately. Notes save automatically; abandoned empty drafts do not create history entries. Original dictation transcripts remain available separately.
- Configure a provider, API key, model, and server address in one screen. Browsing and cancelling preserve the active connection. Save activates a connection only after its settings reach disk.
- Use focused add/edit forms for dictionary corrections, vocabulary, snippets, and app-specific writing styles.
- Navigate settings from the sidebar. System, Light, and Dark appearances use warm neutrals, graphite, and restrained amber accents.
- Open recording controls and recent notes from the menu bar. The Flowbar shows recording time, stop/cancel controls, processing state, and save feedback.
- Launch at login through macOS Login Items, with approval status shown in General settings.
- Guided first-run setup connects a transcription provider, explains permissions, and offers a practice note. Notes-only mode does not require Accessibility access.

### Reliability

- Unreadable history and settings are backed up before new files replace them. Failed reads or backups block writes to protect the original data.
- Save failures remain visible and can be retried. Clearing an edited note preserves the original transcript.
- Microphone startup and teardown translate audio-engine exceptions into recoverable errors.
- Recording recovery retains audio after interruption or transcription failure. Provider diagnostics stay in Details, with concise error messages in the workspace.
- Existing notes, settings, provider keys, and meeting recordings keep their compatible local storage paths.

### Install

Download the DMG for the app and installer, or the ZIP for the app alone. Quit OpenScribe after finishing any recording, then install the new app in Applications. SHA-256 checksums are included in SHA256SUMS.txt.

Requirements: Apple silicon Mac running macOS 14 or later. This release is code-signed with an Apple Development identity and is not notarized. Downloaded copies may need macOS approval before opening; local signing guidance is available in the [v0.2.0 release notes](https://github.com/shashankanil/openscribe/releases/tag/v0.2.0).

Provider API keys are required for transcription and optional writing cleanup. Keys remain in a permission-restricted local file, not Keychain. Calendar access is read-only. Audio sources distinguish microphone and system audio, not individual speakers.

### Validation

77 automated tests pass in the release configuration, covering capture and recovery, credential isolation, connection validation and cancellation behavior, draft persistence, failed-save recovery, original transcripts, calendar and streaming behavior, and both-appearance rendering.

Native UI checks verify note editing, autosave across navigation and relaunch, Command-N focus, empty-draft cleanup, provider cancellation, and correction forms. Hardware disconnects and live provider recording are not part of the automated validation.
