# Notes and meetings parity implementation checklist

Round ownership: `desktop/src/views/notes/**`, `desktop/src/views/meetings/**`, and this file only. Branch: `windows-parity`. No commits, pushes, Rust builds, frontend builds, or combined type checks were run by this implementation agent. Swift files were read as the behavioral specification and were not edited.

## Notes

- [x] All / Days / Written pill tabs, local-day Today row, Pinned / Today / Yesterday / Previous 7 days / month groups, and latest-capture ordering. Implemented in `NotesView.tsx` and `libraryHelpers.ts`; Swift reference: `NotesView.swift` `NoteLibraryListing`, `groupTitle`, `NoteFilter`; `Models.swift` `lastCapturedAt` / `latestText`. Reuses the existing core `displayText` / `displayTitle` logic, including intentional empty edits.
- [x] Two-line clipped snippet previews and visible entry counts (superseded captures excluded). References: `NotesView.swift` `NoteListRow`, `Models.swift` `visibleCaptures`.
- [x] Context menu Copy / Pin / Delete; native-style destructive confirmation; no optimistic removal on failed deletion. `LibraryContextMenu.tsx`, `NotesView.tsx`. Reference: `NotesView.swift` library context menu / pendingDelete.
- [x] Show older notes, 60 at a time; resets on search/filter. `noteListing` and `NotesView.tsx`. Reference: `NotesView.swift` `displayLimit`.
- [x] Ctrl+N new written note, Ctrl+F search, Ctrl+T today. Suppressed during modal dialogs. Reference: `NotesView.swift` `keyboardActions`.
- [x] Written editor retains drafts, debounces serialized saves at 400 ms, shows save/error status and explicit retry. Body edits set `editedText` and preserve original raw/cleaned text and captures. Pin, Copy, native text export, word count, Note/Original read-only toggle, direct correction form. `NotesView.tsx`, `libraryHelpers.ts`, `TeachCorrection.tsx`. Reference: `NotesView.swift` `NoteEditor`, `bodyText`, `scheduleSave`, `persist`, toolbar / `CorrectionSheet`.
- [x] Text/Markdown exports use the real Tauri save dialog followed by `export_text_file({path,text})`; cancellation writes nothing; native failures surface through `reportUiError`; no clipboard fallback. `exportText.ts`. Reference: `NotesView.swift` `NoteExporter`.
- [x] Daily toolbar counts (dictation, screenshot, meeting, written), Copy / Markdown export / Pin; empty Today placeholder cannot be pinned as a fake persisted note. Reference: `DayNoteView.swift` toolbar / `EntryCounts`.
- [x] Daily Markdown matches the Swift entry format: visible nonempty text, screenshot attachment names, meeting references. OCR is not inserted into the export. `dayMarkdown.ts`. Reference: `DayNoteView.swift` `DayNoteExport.markdown`.
- [x] Quick actions and split screenshot control: main action immediately takes an area screenshot; adjacent menu selects area/window/screen. Uses existing controller intent, retaining root's capture safety checks. Reference: `DayNoteView.swift` quickActions.
- [x] Inline dictation/text editing, 450 ms debounce, serialized `update_capture` writes, visible error/retry, original transcript remains read only. Uses the latest capture metadata to preserve screenshot/OCR/meeting metadata. Backend `NoteCapture.update_capture` / `recompute_from_captures` remains authoritative; does not replace the whole daily note. `EntryTextEditor.tsx`. References: `DayNoteView.swift` `EntryTextEditor`; `Models.swift` `updateCapture` / `recomputeFromCaptures`.
- [x] Meeting entry cards resolve the real meeting, subscribe to changes, show status, first overview/user-notes preview, action count, duration or Open meeting notes, and a visible missing-meeting state. `MeetingEntryCard.tsx`. Reference: `DayNoteView.swift` `MeetingEntryCard`.
- [x] Screenshots double-click into the native viewer, Show in Explorer, copy image / OCR from context menu; validated `attachment_path` precedes native actions. Explicit missing attachment / failed preview state retains OCR visibility. Native permission failures are surfaced. `DayNoteView.tsx`. Reference: `DayNoteView.swift` screenshot content and entry `actions`.
- [x] Timeline context menus include type-specific actions and deletion confirmation; meeting copy uses authoritative Markdown command. `LibraryContextMenu.tsx`, `DayNoteView.tsx`. Reference: `DayNoteView.swift` `TimelineEntry.actions` / `copy`.
- [x] Borderless thought composer; adding to an older note uses that note's local calendar date, and failed writes keep the composer text. Reference: `DayNoteView.swift` composer; existing `captureDateForDay` tests.

## Meetings

- [x] My notes / Summary / Transcript tabs in Swift order; appropriate initial tab based on active state, summary, notes and transcript. Recording tab removed; Audio & track names uses a native modal dialog. `MeetingsView.tsx`, `AudioTrackDialog.tsx`. Reference: `MeetingsView.swift` `MeetingDetail.Tab`, initializer / `audioSheet`.
- [x] Split Start control: immediate main action and adjacent recording preferences. Prevents deselecting the final source and disables Start when a meeting is active or no source is enabled. Uses root controller intent. Reference: `MeetingsView.swift` start button / recordingMenu.
- [x] List snippet, duration and real status; date conversion uses exact Apple reference seconds, with local Today / Yesterday / month grouping. Reference: `MeetingsView.swift` `MeetingRow`, `groupTitle`.
- [x] Native live level meter, recording/paused status, pause/resume/stop, progress, visible live failure / retry, and processing cancellation. Live transcript is explicitly labeled as saved audio sections. Reference: `MeetingsView.swift` live state / `liveDetail`.
- [x] Open day note emits `workspace://open-day` with `{meetingId: string, createdAt: number}`. `createdAt` is the unchanged Apple reference-date number, not milliseconds. Reference: `MeetingsView.swift` toolbar / `controller.openDayNote`.
- [x] Detail export menu uses backend Markdown, real save dialog and native atomic export command. Pending metadata saves are awaited/retried before exporting; failed persistence blocks export visibly. Copy remains a separately labeled action. Reference: `MeetingsView.swift` toolbar / export.
- [x] Transcript Play and summary citation playback request the native-validated `meeting_audio_path`, then `convertFileSrc`; only known, closed `.wav` segments are offered. Audio/load/decode errors visible; no guessed filesystem paths. Citation also opens/highlights the transcript passage. `SegmentAudio.tsx`, `MeetingRecordings.tsx`. Reference: `MeetingsView.swift` passage / citation / `play`.
- [x] Track label edits persist through serialized debounced `update_meeting`, and failed edits remain in local drafts with explicit retry. `withMeetingDraft` overlays metadata only so incoming status, errors and live transcript chunks continue updating while typing. Reference: `MeetingsView.swift` `trackLabel`, `saveNotes`, `updateTitle`.
- [x] Short-meeting decision displays actual transcript word count, Summarize anyway / Keep transcript only / confirmed Delete, with native command errors surfaced. Reference: `MeetingsView.swift` short meeting summaryTab; `MeetingController.swift` short-meeting confirmation.
- [x] Existing failed/interrupted banner, Discard all confirmation, recovery notices, and processing cancellation retained. Reference: `MeetingsView.swift` failed recordings / status state.
- [x] Partial live streaming: not applicable to current API. Only native closed/transcribed chunks are available. No fabricated partials were added. Reference: `MeetingNotesPanel.swift` finished passages vs `streamingPartials`; `api/parity.ts` events.
- [x] Audio modal enumerates all real finalized chunks using root's `list_meeting_audio_chunks({id}) -> MeetingSegment[]`, including empty-text chunks awaiting transcription. Inventory refreshes when meeting status or segments change and on explicit retry. Native listing errors are visible; the labeled fallback shows only transcript-referenced audio and does not claim other audio is absent. Playback continues through validated `meeting_audio_path`. `MeetingRecordings.tsx`. Reference: `MeetingsView.swift` `audioSheet` / `MeetingStore.audioChunks(for:)`. Floating notes window belongs to Antigravity this round.

## Root/native integration contract

- `workspace://teach-correction` targets `main`, payload `{requestId: string, heard: string, replacement: string}` (phrases trimmed and nonempty). UI installs a `workspace://correction-result` listener before emitting. Root persists current `correctionRules`, then acknowledges `{requestId, error?: string}`. The dialog stays busy until its matching acknowledgment; failure keeps phrases/dialog open with a visible error and retry; only confirmed success closes it. Cancellation/unmount removes the listener and ignores stale replies. `correctionRequest.ts` implements this contract; no shared event file was edited.
- `workspace://open-day` targets `main`, payload `{meetingId: string, createdAt: number}`. Root converts Apple seconds to a date and opens/selects that local day's note. When no saved note exists, root selects `day:YYYY-MM-DD`; NotesView resolves it to an empty daily placeholder at local noon for that exact date. A refreshed saved daily note takes precedence for the same day. No shared event file was edited.
- Native export command is root-provided: `export_text_file({path: string, text: string}) -> void`, .txt/.md only, atomic replacement. Uses existing `dialog:allow-save`.
- Root has supplied `clipboard-manager:allow-write-image` and `opener:allow-reveal-item-in-dir`; screenshot copy/reveal use those real native permissions. `opener:allow-open-path` was already present. Capability files remain root-owned and were not edited here.
- Root has supplied `list_meeting_audio_chunks({id}) -> MeetingSegment[]` (empty text, real finalized inventory, native directory validation). The modal now invokes this command directly. Existing native path validation and asset URLs remain authoritative. No remaining requested library native seam is known.

## Validation

Focused run (2026-10-22):

```text
pnpm exec vitest run src/views/notes/libraryHelpers.test.ts src/views/notes/dayNoteHelpers.test.ts src/views/meetings/meetingEditorHelpers.test.ts src/views/meetings/transcriptHelpers.test.ts
Test Files  4 passed (4)
     Tests  16 passed (16)
```

Owned TypeScript/TSX files parsed/transpiled in memory with TypeScript `transpileModule`: zero syntax diagnostics. This is a syntax check, not a combined type check or frontend build. `git diff --check` on owned directories passed. Root must run combined `pnpm test`, `pnpm exec tsc --noEmit`, frontend build, and required Rust build/test/clippy serially after all agents finish. Native desktop interaction, save dialogs, Windows image viewer/Explorer, microphone capture and playback require integration testing by root; no UI runtime verification is claimed here.


## Root-seam follow-up validation

`pnpm exec vitest run src/views/notes/correctionRequest.test.ts`: 1 test file passed, 6 tests passed. Covers delivery vs persistence acknowledgment, immediate acknowledgment after subscription, unrelated/stale request ids, failed writes with retry, listener/delivery errors, and cleanup when cancelled during listener registration. Fixed the deferred subscription mock to explicitly return `Promise<() => void>` after root reported its combined TypeScript diagnostic.

Repaired malformed ellipses in `TeachCorrection.tsx`, `EntryTextEditor.tsx`, and `SegmentAudio.tsx`; owned TypeScript/TSX files were checked for common mojibake, C1 controls, replacement characters and invalid UTF-8. No global builds or commits were run in this follow-up.

## Historical empty-day navigation

Implemented `day:YYYY-MM-DD` selection in `NotesView.tsx` using `selectedDayNote` in `dayNoteHelpers.ts`. The strict calendar-date parser constructs local noon and rejects invalid dates rather than rolling them into another day. Composer submissions keep using `add_capture` with `captureDateForDay`, so the first thought creates the actual historical daily note; subsequent refreshes resolve the same day selection to that saved note. Pin and Delete are disabled and guarded for both `today-placeholder` and every synthetic `day:` id; synthetic ids never reach save/delete native commands.

Focused validation: `pnpm exec vitest run src/views/notes/dayNoteHelpers.test.ts` passed 1 file / 7 tests, including local-noon construction, historical capture date, saved-note adoption (ignoring written notes on the same date), strict invalid-date rejection, and synthetic-id guards. Changed-file syntax check passed. No global builds or commits.
