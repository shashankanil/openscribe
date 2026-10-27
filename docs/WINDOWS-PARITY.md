# Windows parity with macOS v0.5.0: shared contract

This is the single source of truth for every agent working on the `windows-parity`
branch. Read it fully before you change anything. If something here is wrong or
missing, stop and report it. Do not guess.

## Ground rules

- Work only on the local branch `windows-parity` (or the worktree you were given).
  Never check out, commit to, merge into, rebase or push `main`, or any other branch.
  Pushing is disabled. Do not re-enable it.
- Do not change anything outside `desktop/` and `docs/`. The Swift macOS sources are the
  reference implementation of v0.5.0 behaviour and must stay byte-identical to `main`.
- Touch only the files your task owns (see "Ownership"). If you need a change in a file you
  don't own, describe it in your final report rather than making it.
- The macOS source is the spec. When behaviour is unclear, read the named Swift file and
  match it. Do not invent features, and do not drop safety behaviour (backups, blocked
  writes, recovery, retries, validation).
- Every new behaviour needs tests: `cargo test` for Rust and `pnpm test` (vitest) for
  TypeScript. Before you finish, all of these must pass, and your final report must include
  their real output:
  `pnpm test`, `pnpm exec tsc --noEmit`, `cargo build`, `cargo test`, `cargo clippy -- -D warnings`.
- Windows is the primary target. Linux must still compile. Gate Windows-only code with
  `#[cfg(windows)]` and provide a clear "not supported on this platform" error elsewhere.
- Build environment (Windows, this machine): run cargo through `cmd /c D:\tmp\devcargo.cmd <args>`
  (it loads VS 2022 `vcvars64.bat` and puts cargo and pnpm on `PATH`). A plain `cargo` cannot find the MSVC
  linker. `pnpm` lives in `D:\NodeJS\node_global`.

## Profile directory and on-disk formats

The Windows edition stores its data in the same files, with the same layout and JSON as
the macOS profile. That gives one format for every downstream reader, including the
MahaKrushi context-engine importer.

Root: the Tauri `app_data_dir()`, i.e. `%APPDATA%\org.open-source.openscribe\`. On macOS the
equivalent is `~/Library/Application Support/WhisperFlow/`.

```
<root>/
  settings.json                 platform settings (see below)
  notes.json                    [VoiceNote], ISO-8601 dates
  Attachments/Screenshot-<UUID>.png
  Meetings/<UUID>/meeting.json  MeetingRecord, Apple reference-date numbers
  Meetings/<UUID>/<partUUID>/microphone/chunk-00000.wav  (+ chunk-00000.wav.json)
  Meetings/<UUID>/<partUUID>/system/chunk-00000.wav      (+ chunk-00000.wav.json)
  Recovery/                     dictation recovery jobs (desktop-specific, keep existing behaviour)
  openscribe.json               LEGACY v0.4.0 Tauri store; migrate, then keep as a backup
```

Exact rules. These are where cross-platform bugs come from, so follow them literally:

1. **UUIDs are uppercase** with hyphens (`E621E1F8-C36C-495A-93FC-0C247A3E6E5F`). That applies to
   ids inside JSON, meeting directory names and screenshot file names. macOS ignores a meeting
   directory whose name is not exactly `record.id.uuidString`, which is uppercase.
2. **notes.json** uses ISO-8601 **without fractional seconds**, in UTC with `Z`
   (`2026-10-19T10:58:15Z`). Swift's `.iso8601` decoder rejects fractional seconds. Keys are
   written sorted (Swift writes `.sortedKeys`, pretty-printed). Write atomically: temp file,
   then rename.
3. **meeting.json** dates are **numbers: seconds since 2001-01-01T00:00:00Z** (Swift's default
   `Date` encoding), i.e. `unix_seconds - 978307200`. Durations and segment start values are
   seconds as floating point.
4. Segment ids are the relative audio path with **forward slashes**:
   `<partUUID>/microphone/chunk-00003.wav`. Never use backslashes, even on Windows.
5. The chunk descriptor `chunk-NNNNN.wav.json` is `{"filename":"chunk-NNNNN.wav","start":<s>,"duration":<s>}`.
   `start` is relative to the meeting timeline origin. `duration` stays 0 until the chunk is
   closed, so a chunk is final only when duration > 0.
6. Chunks are 16-bit PCM WAV, about 15 seconds each, named with 5-digit zero-padded indexes from 0.
   Uploads are converted to 16 kHz mono (`SpeechUpload.swift`).
7. Unknown JSON keys must be preserved when rewriting a file written by another version, or at
   least never cause a failed load. Missing keys take the Swift defaults.
8. Unreadable `notes.json` or `settings.json`: back it up as `<name>-unreadable-<UUID>.json`
   before starting fresh. If the backup fails, block writes to that file and surface the error
   (`AppStore.swift` `load`/`persist`).

### VoiceNote (notes.json element), from `Models.swift`

```jsonc
{
  "id": "UUID", "createdAt": "ISO", "title": "", "rawText": "", "cleanedText": "",
  "editedText": null,            // omit when null
  "duration": 0.0, "isPinned": false, "tags": [], "source": "Dictation",
  "sourceApplication": "chrome.exe" | null, "sourceBundleIdentifier": "<exe path or AUMID>" | null,
  "captures": [NoteCapture] | null   // present => daily note
}
```

NoteCapture:
`{ "id", "createdAt", "title", "rawText", "text", "duration", "sourceApplication", "sourceBundleIdentifier", "kind": "dictation"|"screenshot"|"meeting"|"text", "attachment": "Screenshot-<UUID>.png"|null, "meetingID": "UUID"|null, "recognizedText": "OCR text"|null, "superseded": true|null }`

Daily-note semantics: one daily note per local calendar day, with append, recompute, merge
and timeline migration. Match `VoiceNote.appendCaptures`, `updateCapture`, `removeCapture`,
`recomputeFromCaptures`, `mergingNewCaptures`, `displayText` and `displayTitle` exactly. Read
`AppStore.swift` for grouping (`addCapture`, `groupExistingDictations`). Manually written notes
stay separate (no `captures`).

### MeetingRecord (meeting.json), from `MeetingModels.swift`

```jsonc
{
  "id": "UUID", "title": "…", "createdAt": 782570000.0, "duration": 0.0,
  "status": "recording"|"paused"|"saved"|"transcribing"|"summarizing"|"ready"|"interrupted"|"failed",
  "summarizeOnStop": true, "liveTranscription": true|null,
  "includesMicrophone": true, "includesSystemAudio": true,
  "settings": { /* ONLY: speechProvider, speechBaseURL, speechModel, languageModelProvider,
                   languageModelBaseURL, languageModel, customVocabulary, correctionRules,
                   speechHints, microphoneDeviceUID: "" — mac key names */ },
  "segments": [{ "id": "<part>/microphone/chunk-00000.wav", "track": "microphone"|"system",
                 "start": 0.0, "duration": 15.0, "text": "…" }],
  "summary": { "overview": [{"text":"…","sources":["segment id"]}], "decisions": [], "actions": [] } | null,
  "recoveryNotice": null, "lastError": null,
  "microphoneLabel": "Microphone", "systemLabel": "System audio",
  "userNotes": "markdown" | null, "summaryNeedsConfirmation": true | null
}
```

Never write desktop-only settings (shortcuts and so on) into `meeting.json.settings`, because
macOS decodes that object as `AppSettings`.

### settings.json

`settings.json` is platform-specific because shortcuts differ. Use the macOS key names for
every shared field (`speechProvider`, `speechBaseURL`, `speechModel`, `languageModelProvider`,
`languageModelBaseURL`, `languageModel`, `writingTone`, `customVocabulary`, `correctionRules`,
`cleanupStrength`, `speechHints`, `spokenCorrections`, `learnSpelledWords`, `correctionModel`,
`dictationLiveTranscription`, `meetingLiveTranscription`, `calendarEnabled`,
`calendarExcludedTitles`, `calendarAutoStart`, `calendarMeetingsOnly`, `calendarSummarize`,
`microphoneDeviceUID`, `interactionSounds`, `snippets`, `appWritingTones`, `cleanupEnabled`,
`pasteIntoFocusedApp`, `saveRawAudio`, `showOverlayWhenIdle`, `theme`, `flowbarPlacement`,
`meetingMicrophone`, `meetingSystemAudio`, `meetingSummarize`).

Desktop-only keys:
- `shortcuts`: `{ "<action>": { "accelerator": "Alt+Space", "display": "Alt Space" } }`
- `systemAudioDeviceId`
- `calendarSources`: `[{ "id", "name", "url"|"file" }]`

Credentials stay in Windows Credential Manager or Secret Service, never in JSON.

### Legacy migration (v0.4.0 desktop store)

On first launch, if `openscribe.json` exists and `notes.json` does not:
1. Copy it to `openscribe-v0.4-backup-<UUID>.json`. If the copy fails, do not migrate and surface an error.
2. Map `state.settings` to `settings.json` (provider ids are identical; `speechBaseUrl` becomes `speechBaseURL`;
   `writingProvider/BaseUrl/Model` becomes `languageModel*`; `corrections[{heard,replacement}]` becomes
   `correctionRules`; `theme "paper"` becomes `"light"`).
3. Notes become VoiceNotes grouped into daily notes the same way `groupExistingDictations` does.
4. Each meeting becomes `Meetings/<UUID>/meeting.json` with `status: "ready"`. Its plain transcript becomes
   one segment with id `legacy/transcript`, track `microphone`, and `summary: null`. Put the old
   plain-text summary into `userNotes` under a `## Previous summary` heading so nothing is lost.
   Keep `audioPath` files where they are.
5. Migration is idempotent and tested with a fixture.

## Feature scope (macOS v0.5.0 → desktop)

| # | Feature | Swift reference | Owner |
|---|---|---|---|
| F1 | Profile, storage and formats above, legacy migration | `AppStore.swift`, `Models.swift`, `MeetingStore.swift` | Codex-A |
| F2 | Meeting capture: mic plus **system audio through WASAPI loopback** (cpal input stream on the default *output* device, no Stereo Mix needed), pause/resume, 15 s chunks with descriptors, crash recovery (`interrupted`), delete | `MeetingController.swift`, `AudioChunkStore.swift`, `SystemAudioRecorder.swift` | Codex-A |
| F3 | Meeting live transcription: serial upload of closed chunks while recording, checkpoint per chunk, pause on failure plus "Retry live", stop processes only missing chunks, retry 408/429/5xx/network up to 3× within 3 min per chunk, no retry on 401/403 | `MeetingController.swift`, `TranscriptionRetry.swift`, `docs/CALENDAR-MEETINGS.md` | Codex-A |
| F4 | Summary: batches ≤18,000 chars, exact system prompt, validation that every point cites known segment ids, merge across batches, attendee notes for emphasis, under 80 words asks first (summarize / transcript only / delete) | `MeetingController.swift` `summarize`, `process` | Codex-A |
| F5 | Markdown export identical to `MeetingRecord.markdown`; passages grouping | `MeetingModels.swift`, `MeetingTranscript.swift` | Codex-A |
| F6 | Smart dictionary: speech hints per provider (OpenAI/Groq/custom `prompt`, Mistral `context_bias`, OpenRouter, Deepgram `keyterm` for nova-3 or `keywords`, AssemblyAI word boost), local split/miscase fixes, spoken-correction classifier with confidence gating and spelling verification, learn spelled words, per-feature toggles and correction model | `SmartDictionary.swift`, `ProviderClient.swift`, `PersonalizationView.swift` | Codex-B |
| F7 | Daily notes: dictation appends to today's note, timeline, paste-last uses latest capture | `Models.swift`, `AppStore.swift`, `DayNoteView.swift` | Codex-B (logic), Antigravity (UI) |
| F8 | Global shortcuts for all 7 actions (`dictate` tap/hold, `holdToTalk`, `meeting`, `screenshotArea`, `screenshotWindow`, `screenshotScreen`, `pasteLast`), press and release events, conflict detection, suspended while editing | `Shortcuts.swift`, `GlobalHotkey.swift` | Codex-B |
| F9 | Calendar automation: subscribe to ICS URLs (Google secret iCal / Outlook published calendar) or files, poll every 5 min, prompt at start ("Do you want to record this meeting?", 60 s, auto-start option, skip occurrence, title exclusions, meetings-only filter with Meet/Zoom/Teams/Webex link validation, ignore all-day/cancelled/declined, only starts in the last 2 min, persisted decisions, end prompt with +15 min) | `CalendarMeetingController.swift`, `CalendarMeetingPolicy.swift`, `docs/CALENDAR-MEETINGS.md` | Codex-B |
| F10 | Screenshots: area (drag-select overlay), window (window under the pointer / click), screen (monitor under the pointer); PNG to `Attachments/Screenshot-<UUID>.png`; append a screenshot capture to today's note; attach `meetingID` while a meeting records or is paused; OCR with **Windows.Media.Ocr** into `recognizedText` (asynchronous, after save); capture sound | `ScreenshotCapture.swift`, `AppController.takeScreenshot` | Grok |
| F11 | Flowbar: always-on-top transparent pill window, idle sliver, hover actions (dictate / meeting / screenshots), click to dictate, live waveform, Escape cancels, drag with snap to centre/edges, vertical when docked left/right, flush with the edge, placement persisted, "Show me the Flowbar", notice bubble that stays on screen; meeting state shows waveform plus stop, hover shows notes/screenshot | `OverlayPanel.swift`, `FlowComponents.swift`, `NoticePanel.swift` | Antigravity |
| F12 | Meeting notes floating window: "My notes" and live "Transcript" tabs; closing keeps recording | `MeetingNotesPanel.swift` | Antigravity |
| F13 | Workspace UI: Notes library with day-note timeline (screenshot thumbnails), Meetings (summary/transcript/recording tabs, short-meeting prompt, failed-recording banner with count and "Discard all"), Settings: Shortcuts page, Personalization → Smart corrections, Calendar sources | `MainWorkspaceView.swift`, `NotesView.swift`, `DayNoteView.swift`, `MeetingsView.swift`, `SettingsView.swift`, `PersonalizationView.swift`, `CalendarSettingsView.swift` | Antigravity |

Out of scope: macOS permission flows, launch at login (keep existing behaviour), and the
installer. Do not touch them.

## Ownership (files)

- **Codex-A**: `desktop/src-tauri/src/{storage.rs, notes.rs, meetings.rs, meeting_audio.rs, summary.rs, migrate.rs, apple_time.rs}`, `audio.rs`, `provider.rs` (transcription and generation only: add a `hints` parameter but leave its construction to Codex-B), plus their tests.
- **Codex-B**: `desktop/src-tauri/src/{dictionary.rs, shortcuts.rs, calendar.rs}`, `desktop/src/core/{dictionary.ts, dailyNotes.ts, shortcuts.ts, calendarPolicy.ts}` and tests. Codex-B adds `hints::for_settings()` in `dictionary.rs`, which Codex-A's provider calls.
- **Grok**: `desktop/src-tauri/src/{screenshot.rs, ocr.rs, region_select.rs}`, `desktop/region.html`, `desktop/src/region/*`, plus tests.
- **Antigravity**: `desktop/src/**` UI files (`App.tsx`, `views/*`, `flowbar/*`, `meetingNotes/*`, `styles.css`), `desktop/flowbar.html`, `desktop/meeting-notes.html`, `vite.config.ts` (multi-page inputs). Do not edit `desktop/src/core/*` or `native.ts` (except to fill in bodies already declared there).
- **Integrator (Claude)**: `lib.rs`, `Cargo.toml`, `tauri.conf.json`, `capabilities/*`, `desktop/src/native.ts`, `desktop/src/types.ts`, and merging.

If your task needs a crate, a Tauri plugin, a window or a capability, list it in your
report with the exact `Cargo.toml` line or JSON, and add it in your worktree so your build
passes. The integrator reconciles these.

## Native interface (Tauri commands and events)

Commands are `snake_case` in Rust and camelCase arguments in JS (the Tauri default). Every
command returns `Result<T, String>`, and error strings are user-safe (see `friendlyError`).

Storage and notes (Codex-A):
- `load_profile() -> { settings, notes, storageError? }`
- `save_settings(settings)`, `save_note(note)` (merging new captures, as in `mergingNewCaptures`), `delete_note(id)`
- `add_capture(capture) -> VoiceNote` (appends to today's daily note or creates it), `update_capture(capture, noteId)`, `remove_capture(captureId, noteId)`
- `attachment_path(name) -> absolute path` (only inside Attachments)

Meetings (Codex-A):
- `list_meetings() -> MeetingRecord[]`
- `start_meeting({ title, microphone, systemAudio, summarizeOnStop, liveTranscription }) -> MeetingRecord`
- `pause_meeting()`, `resume_meeting()`, `finish_meeting({ summarize?: boolean })`
- `process_meeting(id)`, `summarize_short_meeting(id)`, `skip_summary(id)`, `retry_live_transcription()`, `cancel_processing()`
- `update_meeting(record)` (title, labels, userNotes), `delete_meeting(id)`, `export_meeting_markdown(id) -> string`
- `meeting_audio_path(id, segmentId) -> absolute path` (validated inside the meeting dir, `.wav` only)
- Events: `meeting://changed` (MeetingRecord), `meeting://progress` ({ id, message }), `meeting://level` ({ level: 0..1 }, about 20 Hz while recording)

Dictation (Codex-A keeps the existing commands working; the waveform needs `dictation://level` { level } at about 20 Hz).

Dictionary, shortcuts and calendar (Codex-B):
- `apply_dictionary(text, settings) -> { text, learnedWords: string[] }` (local fixes, plus classifier if enabled)
- `register_shortcuts(bindings)`, `suspend_shortcuts(bool)`; event `shortcut://action` ({ action, state: "pressed"|"released" })
- `calendar_refresh() -> CalendarEvent[]`, `calendar_decision(occurrenceId, decision)`; events `calendar://prompt-start`, `calendar://prompt-end`

Screenshots (Grok):
- `take_screenshot(kind: "area"|"window"|"screen") -> NoteCapture | null` (null when cancelled; meetingID filled when a meeting is recording or paused)
- Event `capture://ocr` ({ captureId, noteId }) after `recognizedText` is saved

Windows (integrator wires them): `main`, `flowbar` (transparent, always on top, no taskbar entry, not focusable on idle), `meeting-notes`, `region-select` (full-screen transparent overlay).
