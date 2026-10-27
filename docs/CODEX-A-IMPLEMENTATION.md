# Codex-A: Windows parity F1–F5

Worktree: `D:\Projects\openscribe-wt\codex-a`; branch: `wp/codex-a`.
All commits are local. Swift sources and files outside this worktree were unchanged.

## Implementation

- Foundation-compatible note dates, uppercase UUIDs, Apple-reference meeting dates,
  recursively sorted pretty JSON, and atomic file replacement.
- Profile settings, notes, daily-note operations, unreadable-file backups and blocked
  writes, unknown-field retention, and idempotent v0.4 migration with its original backup.
- Microphone and Windows WASAPI output-device loopback capture, pause/resume,
  15-second PCM WAV chunks, finalization descriptors, timestamp discontinuities,
  restart recovery, and level events at approximately 20 Hz.
- Serial live transcription, durable per-chunk checkpoints (including silence),
  explicit retry, cancellation, and stop-time processing of missing sections.
  Normal stop allows the current upload to checkpoint; explicit cancellation stops it.
- Three total attempts for transient HTTP/network failures, exponential backoff,
  a 180-second total deadline per chunk, and no retries for 401/403.
- Compact mono WAV uploads, provider-specific speech hint transport and file-model
  fallback for Swift's streaming-only model selections.
- Exact Swift summary prompt, transcript batches of at most 18,000 characters,
  evidence validation, merged batches, attendee-note emphasis, and confirmation below
  80 words. An individually oversized segment is split while retaining its citation ID.
- Swift transcript passage grouping and Markdown body, with a Windows-localized
  date/time header. Meeting links in daily notes are idempotent; deleting a meeting
  keeps its screenshots and removes their meeting association.

## Files

New Rust modules: `apple_time.rs`, `storage.rs`, `notes.rs`, `migrate.rs`,
`meeting_audio.rs`, `meetings.rs`, `summary.rs` under `desktop/src-tauri/src/`.
Modified: `audio.rs`, `provider.rs`, `lib.rs`, `desktop/src-tauri/Cargo.toml`,
`desktop/src-tauri/Cargo.lock`. This report is the only added documentation file.
No TypeScript, UI, shortcuts, dictionary, calendar, screenshot, or Swift code was changed.

`lib.rs` only declares the modules, manages `ProfileState`/`MeetingState`, registers
the commands, passes the app handle for dictation level events, and forwards the
optional dictation speech-hints argument. Formatting orders module declarations.

Exact new/expanded dependency declarations:

```toml
tokio = { version = "1", features = ["rt-multi-thread", "macros", "sync", "time", "fs"] }
chrono = { version = "0.4", features = ["serde"] }
tempfile = "3"
```

`chrono` and `tempfile` are the added direct crates; Tokio already existed.
No plugin, window, or capability additions are required.

## Native interface

These are the callable signatures, with injected Tauri `AppHandle` and `State`
arguments omitted. Every command returns `Result<T, String>`; `()` resolves to
JavaScript `null`. Argument names below are the exact JavaScript camelCase names.

```text
load_profile() -> Profile { settings: AppSettings, notes: VoiceNote[], storageError?: string }
save_settings(settings: AppSettings) -> ()
save_note(note: VoiceNote) -> ()
delete_note(id: UUID) -> ()
add_capture(capture: NoteCapture) -> VoiceNote
update_capture(capture: NoteCapture, noteId: UUID) -> ()
remove_capture(captureId: UUID, noteId: UUID) -> ()
attachment_path(name: string) -> string

list_meetings() -> MeetingRecord[]
start_meeting(title: string, microphone: boolean, systemAudio: boolean,
              summarizeOnStop: boolean, liveTranscription: boolean) -> MeetingRecord
pause_meeting() -> ()
resume_meeting() -> ()
finish_meeting(summarize?: boolean) -> () [async]
process_meeting(id: UUID) -> () [async]
summarize_short_meeting(id: UUID) -> () [async]
skip_summary(id: UUID) -> ()
retry_live_transcription() -> ()
cancel_processing() -> ()
update_meeting(record: MeetingRecord) -> ()
delete_meeting(id: UUID) -> ()
export_meeting_markdown(id: UUID) -> string
meeting_audio_path(id: UUID, segmentId: string) -> string

transcribe_recording(path: string, config: ProviderConfig, hints?: SpeechHints) -> ProviderResult [async]
```

The existing dictation/credential/cleanup commands keep their previous names and
arguments. `transcribe_recording` gains only its optional `hints` argument.
`SpeechHints` is `{ prompt: string | null, terms: string[] }`.

Events: `meeting://changed` carries `MeetingRecord`; `meeting://progress` carries
`{ id, message }`; `meeting://level` and `dictation://level` carry `{ level }` in `[0, 1]`.

Public Rust transport signatures:

```rust
pub async fn transcribe(path: &Path, config: &ProviderConfig,
                        hints: Option<&SpeechHints>) -> Result<ProviderResult, String>;
pub async fn transcribe_reliably(path: &Path, config: &ProviderConfig,
                                 hints: Option<&SpeechHints>) -> Result<ProviderResult, String>;
pub async fn generate(text: &str, config: &ProviderConfig,
                       system: &str) -> Result<ProviderResult, String>;
pub fn active_meeting_id(app: &tauri::AppHandle) -> Result<Option<Id>, String>;
```

## Integration and limits

Codex-B owns hint construction and dictionary fixes. During integration, install
`dictionary::hints::for_settings` (or a signature adapter) into
`provider::SPEECH_HINT_FACTORY`, a `OnceLock<fn(&AppSettings) -> SpeechHints>`.
Install the meeting-only local correction/dictionary pass into
`provider::TRANSCRIPT_FILTER`, a `OnceLock<fn(&str, &AppSettings) -> String>`.
Meeting filtering must exclude the spoken-correction classifier, matching Swift.
Dictation callers may pass constructed hints directly to `transcribe_recording`.
No dictionary behavior is implemented in Codex-A's files.

Grok can call `meetings::active_meeting_id` when attaching screenshots; storage
models and `ProfileState`/`with_profile` are public for the other feature modules.
The frontend/native bridge remains integrator-owned and must use the signatures above.

No command-name or storage-layout deviations. The extra split of a single segment
over 18,000 characters enforces the brief's bound more strictly than Swift's loop.
As in `SpeechUpload.swift`, already-compact 16-bit mono files at or below 16 kHz
can be uploaded unchanged. Markdown's date/time header uses the Windows user's
locale; the body and citation formatting match Swift.

Actual audio devices and paid provider endpoints were not exercised. Windows
compilation validates the capture code; no Linux build environment was available.

## Validation

All five required checks passed on the final implementation. Rust: 32 tests; TypeScript: 5 tests. Exit codes were all 0. Literal output tails follow. The supplied devcargo wrapper emits a nonfatal vswhere.exe warning before running Cargo.


cmd /c D:\tmp\devcargo.cmd build

```text
   Compiling openscribe-desktop v0.4.0 (D:\Projects\openscribe-wt\codex-a\desktop\src-tauri)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 1m 45s
```

cmd /c D:\tmp\devcargo.cmd test

```text
test meetings::tests::restart_marks_stale_and_preserves_completed_segments ... ok
test meeting_audio::tests::descriptors_closed_chunks_recovery_and_upload ... ok

test result: ok. 32 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.22s

     Running unittests src\main.rs (target\debug\deps\openscribe_desktop-b98e4fa241fab808.exe)

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

   Doc-tests openscribe_desktop_lib

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

```

cmd /c D:\tmp\devcargo.cmd clippy -- -D warnings

```text
    Checking openscribe-desktop v0.4.0 (D:\Projects\openscribe-wt\codex-a\desktop\src-tauri)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 3.09s
```

D:\NodeJS\node_global\pnpm.cmd test

```text
 ✓ src/core.test.ts (5 tests) 21ms

 Test Files  1 passed (1)
      Tests  5 passed (5)
   Start at  18:34:13
   Duration  9.46s (transform 5.89s, setup 0ms, collect 5.93s, tests 21ms, environment 1ms, prepare 1.04s)

```

D:\NodeJS\node_global\pnpm.cmd exec tsc --noEmit: no output; exit 0.

## Implementation commits

- 598654a Port macOS profile formats, daily notes, and v0.4 migration
- 3f5d0f0 Add durable meeting WAV chunks, WASAPI loopback, and level events
- b4c0482 Add speech hints, bounded transcription retries, and cited summaries
- 4202cc7 Wire meeting capture, recovery, processing, and profile commands
- c0fb8ff Preserve unknown editor fields and test migration backup failures
- 2b9ab86 Keep chunk timestamps aligned across audio gaps
- 0ef449e Protect finish checkpoints and match Swift speech fallback behavior
- 57777e4 Retain migrated meeting precision and preserve daily meeting links
