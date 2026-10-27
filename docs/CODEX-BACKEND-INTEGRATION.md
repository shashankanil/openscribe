# Windows backend integration round

Work is limited to the assigned backend modules and this report, on
`windows-parity`. No commits or pushes were made by this agent. `main` remains
`c8a11bff686de68d0ead064833c89b66444b2efc`; `Sources/` matches `main`.
The parent is concurrently integrating frontend, settings, tray and screenshots.

## Dictionary and transcription

- `dictionary::SpeechHints` now re-exports the shared `provider::SpeechHints`;
  its serialized shape remains `{ prompt: string | null, terms: string[] }`.
- Setup calls `integration::install`, installing `SPEECH_HINT_FACTORY` and
  `TRANSCRIPT_FILTER` before calendar boot. The factory reads actual
  `storage::AppSettings`, maps vocabulary/rules/toggles/model settings, and calls
  `dictionary::for_settings`. Invalid individual dictionary entries are skipped.
- `dictionary::apply_local(&str, &DictionarySettings) -> String` is the shared
  synchronous rules, split-word and casing pass. It owns/drops its native
  spellchecker on the calling thread. Meeting chunks invoke it after provider
  transcription and before acquiring the controller for the checkpoint.
- This matches `MeetingController.swift::transcribeChunk`: apply correction rules,
  then DictionaryPass; never run the spoken-correction classifier for meetings.
  No provider/classifier await occurs under a profile/controller mutex.
- `transcribe_recording` now builds default hints from the profile when `hints`
  is omitted, using the supplied provider/model (including recovery-job configs).
  Explicit hints still win. Speech transport functions remain unchanged.

Dictation still explicitly calls `apply_dictionary({ text, settings })`, whose JS
signature/result is unchanged (`{ text, learnedWords }`). Its Tauri registration
moved to `integration::apply_dictionary` so backend activity is tracked. The UI
must merge `learnedWords` into the latest vocabulary and save settings. Snippet
selection/classifier timing remains UI-owned, as in `AppController.swift`.

## Capture/calendar adapter

The installed `Arc<dyn calendar::CalendarCapture>` uses the real meeting backend.

- Start checks the current Windows session, refreshes device/access readiness,
  then calls synchronous `meetings::start_meeting`. The returned ID is the actual
  uppercase record UUID, after both requested recording streams have started.
  The existing calendar policy supplies both audio sources and keeps unattended
  live transcription off; explicit Yes retains the live-transcription setting.
- Finish synchronously stops/finalizes audio, removes the active capture and
  reserves `Controller.busy` for that exact ID. It then spawns the async tail on
  the existing Tauri runtime. It never calls `block_on` or accesses CalendarState.
  Calendar status is updated before finish returns, preventing duplicate end
  prompts. `Some(false)` cancels live work and skips further processing;
  `None` respects the saved summarize preference and lets live uploads checkpoint.
  Deferred processing failures use the existing meeting change/progress events.
- A shared start gate makes meeting and dictation startup mutually exclusive.
  Status includes actual recorder startup/finalization/recording, backend
  transcription/dictionary/cleanup work, UI lifecycle busy, and meeting processing.
  Synchronous meeting transitions hold the controller until the real state is
  known; status reads wait for that transition rather than inventing an ID.
- Windows session readiness requires WTSActive for the process's current session
  and an accessible input desktop named Default. Locked/secure desktops,
  disconnected sessions and API failures return false. Sleep suspends execution;
  the existing calendar tick-gap check cancels stale countdowns after wake.
  A failed WTS query (including an unavailable session service) disables calendar
  automation rather than assuming the session is active.
- Unattended audio readiness initializes real CPAL/WASAPI microphone and render
  loopback input clients, with the configured devices and supported formats.
  It neither plays these probe streams nor saves samples. CPAL 0.16's WASAPI
  implementation calls IAudioClient::Initialize during build_input_stream_raw;
  access/device/format failures therefore veto readiness. Successful probes are
  cached for 30 seconds for policy ticks, keyed by both device selections, and
  always repeated before starting. Actual stream startup can still fail after
  preflight, in which case calendar receives an error and no active ID.
- No permission prompt, dummy recorder, permissive readiness default or new
  dependency/features were added. Non-Windows automatic system-audio capture is
  explicitly unsupported and session readiness is false.

Native API references: [current session query](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtsquerysessioninformationw),
[input desktop](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openinputdesktop),
[desktop object information](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getuserobjectinformationw).
The readiness implementation also follows CPAL 0.16's installed WASAPI source
(`src/host/wasapi/device.rs::build_input_stream_raw_inner`).

## Exact interfaces and window wiring

New command:

```text
set_dictation_busy({ busy: boolean }) -> null | rejection string
```

Await `true` before dictation startup; clear with `false` in the main controller's
finally path after recording/transcription/dictionary/cleanup/save or cancellation.
Setting true rejects while a meeting records, pauses or processes. Clearing this
flag never overrides a real recorder/backend operation's busy state. Record-start
and provider commands also independently check actual meeting state.

New/changed Rust interfaces:

```rust
meetings::active_meeting_id(&tauri::AppHandle) -> Option<String>;
meetings::capture_status(&tauri::AppHandle) -> Result<(Option<apple_time::Id>, bool), String>;
meetings::finish_in_background(tauri::AppHandle, Option<bool>) -> Result<(), String>;
integration::dictation_busy(&tauri::AppHandle) -> bool;
integration::hints_for_provider(&storage::AppSettings, &str, &str) -> provider::SpeechHints;
dictionary::apply_local(&str, &dictionary::DictionarySettings) -> String;
```

The screenshot accessor returns an uppercase string only while recording/paused,
None during processing/idle or if state cannot be read. Status does not initialize
storage. The parent-owned storage_hooks adapter can call it directly.

`lib.rs` manages ActivityState and intercepts CloseRequested for `main` and
`meeting-notes`: prevent_close + hide preserves capture and the main controller.
Other window labels, including `region-select`, retain normal close behavior.
The requested parent-owned `tray::install(app.handle())?` is declared/called in
setup. The tray supplies workspace reopening and its own guarded Quit action;
no additional tray exit implementation is required from this agent.

The parent expanded the settings defaults during this round; the combined
`serde_json::json!` exceeded Rust's default macro recursion limit. `lib.rs` now
sets `#![recursion_limit = "256"]`; no storage implementation was changed here.

## Validation

Seven added unit tests cover installed hooks/settings conversion, local-only
meeting correction, nested/UI dictation busy lifetimes, contended recorder state,
actual meeting IDs and synchronous finish reservation/stop modes.

All Rust commands use `cmd /c D:\tmp\devcargo.cmd` from `desktop/src-tauri`.
The wrapper prints its existing nonfatal `vswhere.exe` warning.

Final output tails (all exit codes 0; the parent added one migration test during
this round, bringing the combined unit suite to 77):

```text
cmd /c D:\tmp\devcargo.cmd test
    Finished `test` profile [unoptimized + debuginfo] target(s) in 1m 14s
test result: ok. 77 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 2.00s
     Running tests\windows_capture.rs (target\debug\deps\windows_capture-195acd57a3b9dc39.exe)
test microphone_and_wasapi_loopback_open_and_finalize ... ignored, opens the real microphone and WASAPI loopback for one second
test result: ok. 0 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.00s
   Doc-tests openscribe_desktop_lib
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

cmd /c D:\tmp\devcargo.cmd build
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 22.51s

cmd /c D:\tmp\devcargo.cmd clippy -- -D warnings
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.79s
```

Hardware recording, lock/unlock/RDP/suspend transitions and paid provider calls
were not exercised by this agent. The normal cargo suite reports the parent-owned
one-second real microphone/WASAPI test as ignored. Linux compilation was not run.
No frontend files were changed by this agent; frontend checks belong to the
parent's concurrent integration pass.
