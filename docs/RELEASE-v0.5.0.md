OpenScribe v0.5.0 turns the Flowbar into a quiet companion for dictation, meetings, and screenshots, and adds a smart dictionary that keeps names and terms spelled right.

### Flowbar

- When idle, the Flowbar is a small translucent sliver. Hover it for dictation, meetings, and screenshots; click it to start dictating.
- Drag it anywhere. It snaps to the center and edges, stands up vertically against the left or right side, and sits flush with the screen edge.
- Can't find it? Use **Show me the Flowbar** from the menu bar, or **Show me** in Settings → General → Flowbar.
- While dictating, the pill is a single live waveform: click to finish, Escape to cancel.
- Notices appear in a small bubble beside the pill and always fit on screen.

### Meetings

- A recording meeting shows a live waveform and a stop button in the pill. Hover for notes and screenshot buttons.
- Click the pill for a floating meeting-notes window with **My notes** and a live **Transcript**. Closing it keeps the meeting recording.
- Screenshots taken during a meeting, from the pill or a shortcut, are attached to that meeting.
- Meetings under 80 words aren't summarized automatically. OpenScribe asks whether to summarize, keep the transcript only, or delete the meeting.

### Smart dictionary

- Your vocabulary and replacement words are sent as hints to providers that support them: OpenAI (file and realtime), Mistral/Voxtral, OpenRouter, Deepgram, and AssemblyAI.
- Split or miscased forms of dictionary words ("open scribe" → "OpenScribe") are fixed locally.
- Spoken corrections are understood. "Shashunk, that's S H A S H A N K" becomes "Shashank", and "Friday, no wait, Thursday" becomes "Thursday". A small classifier model only applies confident, verifiable edits. Words you spell out are added to your dictionary.
- Each feature can be turned off under Personalization → Smart corrections, and you can choose the correction model.

### Also new

- Global shortcuts for dictation, push to talk, meetings, three screenshot modes, and paste last, all configurable under Shortcuts.
- Screenshots go straight into today's note.
- Recordings are converted to compact 16 kHz mono before upload, about six times smaller with the same accuracy.
- When several recordings fail to transcribe, the banner shows how many, and **Discard all** clears them in one step. Recordings already saved as notes are cleaned up automatically.

### Install

Download the DMG for the app and installer, or the ZIP for the app alone. Quit OpenScribe after finishing any recording, then replace the app in Applications. Existing settings, provider keys, notes, and meeting history stay in their existing local profile. SHA-256 checksums are included.

Requires an Apple silicon Mac running macOS 14 or later. The app is signed with the same Apple Development identity as earlier releases and is not notarized. Local signing guidance is available in the [v0.2.0 release notes](https://github.com/shashankanil/openscribe/releases/tag/v0.2.0).

### Validation

113 automated tests pass in the release configuration (4 manual live-provider probes skipped). They cover dictionary hints and spoken-correction rules, short-meeting confirmation, meeting screenshots, Flowbar rendering, and capture recovery. Speech hints were checked live against OpenAI and OpenRouter/Voxtral, and the correction classifier against eight real and look-alike phrases. Deepgram and AssemblyAI hints were not tested live.
