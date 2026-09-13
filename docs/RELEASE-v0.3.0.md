OpenScribe v0.3.0 makes first use clearer and puts recording controls where they are always easy to reach.

### What's new

- Three-step guided setup for connecting a transcription provider, granting permissions, and recording a first note.
- Notes-only mode for people who do not want to grant Accessibility access. The global shortcut and pasting remain available when Accessibility is enabled.
- A persistent Record a note / Stop & save control with clearer setup, recording, and meeting states.
- Reorganized navigation with Notes, Meetings, and Calendar in the Library and focused tabs for application settings.
- A dedicated new-meeting sheet with explicit microphone, system-audio, live-transcription, summary, and privacy choices.
- Readable meeting transcript passages with search, audio-source filtering, and timestamp links back to saved audio.
- Short, actionable error notices. Technical provider responses remain available under Details instead of appearing in the transient notice.

### Reliability and installation

- Incomplete setup resumes automatically, while configured users retain their existing settings.
- Practice recordings always save to Notes and never paste into another application.
- Debug builds can use an isolated profile to verify first launch without reading or changing normal user data.
- The installer stages and verifies the signed application before replacing an existing installation, and restores the previous copy if replacement fails.
- Packaging scripts now create release builds by default.

### Requirements and current limits

- Apple silicon Mac running macOS 14 or later.
- A provider API key is required for transcription. Writing cleanup is optional.
- Microphone permission is required for dictation. Accessibility is required only for the global shortcut and pasting into other apps.
- System-audio recording requires Screen & System Audio Recording permission.
- The release is code-signed but not notarized. Follow the local self-signing and Gatekeeper guidance from the v0.2.0 release when distributing outside a trusted development environment.

