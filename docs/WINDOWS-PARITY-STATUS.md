# Windows parity integration — 2026-10-22

Branch: `windows-parity`. Only `desktop/` and `docs/` are changed. Swift remains the reference implementation.

Integrated in this batch:

- Right Ctrl modifier-only dictation, shortcut recording and registration failure handling; Escape cancels processing as well as recording.
- Flat workspace settings navigation, capture dock with native level meter, setup wizard, theme previews, provider dialogs, application writing styles, permissions readiness, startup registration and privacy counts.
- Grouped/paginated notes, original text, serialized editor saves, correction teaching with persistence acknowledgment, native exports, timeline actions and historical empty-day navigation.
- Meeting notes/summary/transcript tabs, track-name editor, finalized audio inventory, untranscribed audio playback, passage/citation playback and exports.
- Native cancellation drops provider work and blocks late transcription results from saving or pasting. Existing recovery jobs remain intact when another recording is cancelled.
- Tray actions route through the authoritative main capture controller. Windows integrations include source-app discovery, startup and audio readiness.

Detailed implementation notes: `PARITY-LIBRARY.md` and `PARITY-SETTINGS.md`. Floating-window work is tracked separately in `PARITY-FLOATING.md` when its implementation finishes.

## Verification and limits

- Frontend tests: 128 passed in 22 files, including cancellation, source-app tone, correction acknowledgment and historical day selection.
- Rust tests: 103 passed, one OCR desktop test ignored. Strict Rust clippy passed with all targets and warnings denied.
- Release build succeeded at `desktop/src-tauri/target/release/openscribe-desktop.exe`. It predates the last keyboard-hook guard and UI follow-ups; rebuild after the floating implementation settles.
- Browser layout inspection used an in-memory mocked Tauri bridge; it verifies layout only. It does not verify native capture, credentials, startup, shortcuts or permissions.
- Native Computer Use inspection is blocked: `Computer Use native pipe is unavailable: failed to connect native pipe: The system cannot find the file specified. (os error 2)` on both attempts.
- Full macOS parity is not yet claimed. Provider streaming/partial transcripts and the `automaticStreaming` runtime transport remain open; existing finalized meeting chunks and post-stop dictation chunks are not substitutes for streaming.
