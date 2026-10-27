# Windows v0.5 local validation

The Windows port is developed on `windows-parity`. The Swift implementation and
`main` remain unchanged. This is a local build; no release has been published.

## Build

On this machine, from `desktop/src-tauri`, use the Visual Studio environment:

```powershell
cmd /c D:\tmp\devcargo.cmd test
cmd /c D:\tmp\devcargo.cmd clippy --all-targets -- -D warnings
```

From `desktop`, use `D:\NodeJS\node_global\pnpm.cmd test` and
`D:\NodeJS\node_global\pnpm.cmd build`. The standalone release build is
`cmd /c D:\tmp\devtauri.cmd`. Its executable is
`desktop/src-tauri/target/release/openscribe-desktop.exe`.

## Manual recording test

1. Open Settings → Providers & Audio. Apply the speech provider, endpoint and
   model, then save its key. Set the writing provider/key too if using cleanup or
   meeting summaries. Keys go into Windows Credential Manager.
2. Record a short dictation, stop, and check today's daily note. If the provider
   fails, the recovery banner must retain the recording; Retry processes it and
   Discard explicitly removes the saved recovery audio.
3. Start a meeting with microphone and system audio. Play some speech from
   another application and speak into the microphone. Pause/resume and verify
   the two transcript tracks. Take an area screenshot containing visible text.
4. Open the floating meeting-notes window and enter notes. Done or closing the
   window must keep recording. Stop the meeting. A transcript under 80 words
   requires an explicit summary/transcript-only/delete choice.
5. Inspect the screenshot thumbnail and OCR text in today's timeline, and the
   summary citations in the saved meeting. Test Markdown export.
6. Test the seven shortcuts in Settings. Default dictation is Ctrl+Alt+Space;
   hold-to-talk is Ctrl+Alt+H. An early release during microphone startup must
   finish the same capture after startup completes.
7. Closing the workspace hides it. The tray menu can reopen it, reveal the
   Flowbar, or quit when capture and processing have finished.

Calendar automation needs an ICS subscription/file and enabled calendar
watching. Verify explicit start, skip, finish and extend decisions before enabling
automatic start. Locked/disconnected sessions, delayed timers and unavailable
audio must prevent an unattended start. Sleep/lock and live provider behavior
require manual validation on the target machines.

## Shared-profile interoperability check

The example creates synthetic data using the actual Rust profile writers, with
a cited meeting summary, a linked screenshot/OCR entry and an unrelated private
dictation. The destination must be new or empty:

```powershell
cmd /c D:\tmp\devcargo.cmd run --example interop_profile -- D:\tmp\openscribe-check
```

From the context-engine checkout:

```powershell
uv run python -m mahakrushi_context.openscribe_import --profile D:\tmp\openscribe-check --settle 0 --dry-run
```

The integration smoke check also processes the generated meeting and screenshot
through an isolated IntakeStore and confirms no private dictation or duplicate
meeting is imported. It does not upload the fixture to a remote server.

The opt-in native hardware smoke check opens the real microphone and output
loopback for one second, writes only a temporary profile and finalizes both:

```powershell
cmd /c D:\tmp\devcargo.cmd test --test windows_capture -- --ignored --nocapture
```

A silent output may yield no loopback frames. This check verifies opening and
finalization; listening quality and provider transcription need the recording
test above. Ordinary tests never open hardware.
