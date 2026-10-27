# OpenScribe macOS vs Windows Parity Audit

Branch: `windows-parity`. Reference implementation: macOS Swift in `Sources/OpenScribe/`.
Windows port: Tauri 2 (Rust backend in `desktop/src-tauri/src/`, React/TS frontend in `desktop/src/`).

This document records the user-facing parity status between macOS and Windows as of October 23, 2026.
Note: Per instructions, the Flowbar floating pill window (`desktop/src/flowbar/**`) is tracked and implemented separately.

## Summary Counts

| Status | Count |
| :--- | :--- |
| **DONE** | 56 |
| **PARTIAL** | 8 |
| **MISSING** | 8 |
| **N/A on Windows** | 2 |
| **Total Features Audited** | 74 |

---

## Parity Feature Matrix

### 1. Application Lifecycle, Menu Bar & System Tray

| Feature | Swift file:line | Windows file:line | Status | What's missing |
| :--- | :--- | :--- | :--- | :--- |
| Application Settings accelerator (`Cmd+,`) | `Sources/OpenScribe/OpenScribeApp.swift:9-14` | none | MISSING | Windows has no application-level menu or `Ctrl+,` accelerator to open Settings; settings must be opened through the UI or tray context menu. |
| Single-instance enforcement and focus restoration | `Sources/OpenScribe/OpenScribeApp.swift:51-64` | none | MISSING | No `tauri-plugin-single-instance` registered in `desktop/src-tauri/src/lib.rs`. Launching OpenScribe a second time starts a concurrent background instance rather than focusing the existing instance. |
| CLI maintenance & diagnostic flags (`--credential-smoke`, `--provider-smoke`, `--bootstrap-openrouter-key`, `--show-workspace`) | `Sources/OpenScribe/OpenScribeApp.swift:23-49, 71` | none | MISSING | `desktop/src-tauri/src/main.rs:1-3` immediately invokes `run()` without parsing CLI flags or supporting automated smoke tests / key bootstrap. |
| Dynamic system tray indicator (vector wave, recording dot, pause bars) | `Sources/OpenScribe/StatusBarController.swift:28-66` | `desktop/src-tauri/src/tray.rs:25-41` | PARTIAL | Tray icon is a static 16x16 RGBA bitmap rendered once at launch; it does not change appearance during active recording or paused meetings. |
| Left-click QuickPanel popover | `Sources/OpenScribe/StatusBarController.swift:68, 114-120, 142-243` | `desktop/src-tauri/src/tray.rs:43` | MISSING | Tray left-click opens the static context menu (`show_menu_on_left_click(true)`). The macOS QuickPanel (with live audio waveform squiggle, elapsed timer, 1-click recent notes copy, meeting banner, and start/stop controls) is absent on Windows. |
| Dynamic tray context menu actions & status header | `Sources/OpenScribe/StatusBarController.swift:70-112` | `desktop/src-tauri/src/tray.rs:7-24` | PARTIAL | Windows tray menu is static. Missing dynamic recording status header, "Today's note", "Retry failed recording", calendar "Not happening", and Flowbar visibility checkmark state. |

### 2. Workspace Navigation & Layout

| Feature | Swift file:line | Windows file:line | Status | What's missing |
| :--- | :--- | :--- | :--- | :--- |
| Section navigation (Notes, Meetings, Calendar, Settings tabs) | `Sources/OpenScribe/MainWorkspaceView.swift:5-35, 120-142` | `desktop/src/App.tsx:210-230`, `desktop/src/views/settings/SettingsView.tsx:40` | DONE | |
| Library keyboard shortcuts (`Cmd+1` Notes, `Cmd+2` Meetings, `Cmd+3` Calendar) | `Sources/OpenScribe/MainWorkspaceView.swift:195-205` | none | MISSING | `App.tsx` has no keyboard shortcuts for `Ctrl+1`, `Ctrl+2`, or `Ctrl+3` to switch between primary library sections. |
| Persistent page mounting across navigation | `Sources/OpenScribe/MainWorkspaceView.swift:78-86` | `desktop/src/App.tsx:257-268` | PARTIAL | Windows conditionally renders sections (`{section === "notes" && ...}`), destroying and remounting views. Search terms, uncommitted draft inputs, and scroll positions reset on tab change. |
| Global storage error banner with inspection modal | `Sources/OpenScribe/MainWorkspaceView.swift:145-152`, `Sources/OpenScribe/NoticePanel.swift:5-30` | `desktop/src/App.tsx:96-103, 230-240`, `desktop/src/mainController.ts:100` | DONE | |
| Failed dictation recordings banner with Discard all / Retry | `Sources/OpenScribe/MainWorkspaceView.swift:165-188` | `desktop/src/App.tsx:241-255` | DONE | |
| Active calendar meeting banner | `Sources/OpenScribe/MainWorkspaceView.swift:154-164` | `desktop/src/App.tsx:260-275` | DONE | |
| CaptureDock sidebar controls (mic indicator, timer, level meter, stop/cancel) | `Sources/OpenScribe/MainWorkspaceView.swift:239-320` | `desktop/src/views/CaptureDock.tsx:1-95` | DONE | |

### 3. Notes & Daily Notes (Library)

| Feature | Swift file:line | Windows file:line | Status | What's missing |
| :--- | :--- | :--- | :--- | :--- |
| Daily notes aggregation & entry counter badges | `Sources/OpenScribe/NotesView.swift:269-328` | `desktop/src/core/dailyNotes.ts:1-120`, `desktop/src/views/notes/NotesView.tsx:1-250` | DONE | |
| Pin / unpin daily note | `Sources/OpenScribe/NotesView.swift:117`, `Sources/OpenScribe/DayNoteView.swift:63` | `desktop/src/views/notes/NotesView.tsx:180`, `desktop/src/views/notes/DayNoteView.tsx:55` | DONE | |
| Note deletion with confirmation modal | `Sources/OpenScribe/NotesView.swift:50-55, 119` | `desktop/src/views/notes/NotesView.tsx:60-75` | DONE | |
| Written note composer & rich multiline editor | `Sources/OpenScribe/NotesView.swift:89, 398-550` | `desktop/src/views/notes/NotesView.tsx:120`, `desktop/src/views/notes/DayNoteView.tsx:110` | DONE | |
| Notes search filtering across title, rawText, cleanedText, and OCR | `Sources/OpenScribe/NotesView.swift:135-145` | `desktop/src/views/notes/NotesView.tsx:90-110` | DONE | |
| In-notes keyboard shortcuts (`Cmd+N` new note, `Cmd+F` search, `Cmd+T` today) | `Sources/OpenScribe/NotesView.swift:158-161` | none | MISSING | Windows `NotesView.tsx` does not listen for `Ctrl+N`, `Ctrl+F`, or `Ctrl+T`. |
| Pagination ("Show older notes", 60 notes per page) | `Sources/OpenScribe/NotesView.swift:127` | `desktop/src/views/notes/NotesView.tsx:160` | DONE | |
| Split screenshot quick action (Area default + Window/Screen menu) | `Sources/OpenScribe/DayNoteView.swift:99-108` | `desktop/src/views/notes/DayNoteView.tsx:75-90` | DONE | |
| Day note export as Markdown (formatted with captures) | `Sources/OpenScribe/DayNoteView.swift:68-74` | `desktop/src/views/notes/dayMarkdown.ts:1-40`, `desktop/src/views/notes/DayNoteView.tsx:60` | DONE | |
| Inline capture editing with 450ms debounce persistence | `Sources/OpenScribe/DayNoteView.swift:297-350` | `desktop/src/views/notes/EntryTextEditor.tsx:1-85` | DONE | |
| Toggle original vs cleaned transcript | `Sources/OpenScribe/DayNoteView.swift:230-233` | `desktop/src/views/notes/DayNoteView.tsx:150-165` | DONE | |
| Screenshot attachment preview, native viewer launch & Explorer reveal | `Sources/OpenScribe/DayNoteView.swift:266-267, 357-410` | `desktop/src/views/notes/DayNoteView.tsx:180-210` | DONE | |
| Meeting entry card in day timeline | `Sources/OpenScribe/DayNoteView.swift:417-456` | `desktop/src/views/notes/MeetingEntryCard.tsx:1-65` | DONE | |
| Timeline context menus (copy, delete, copy OCR, open image, reveal in Explorer) | `Sources/OpenScribe/DayNoteView.swift:193-276` | `desktop/src/views/notes/LibraryContextMenu.tsx:1-55`, `desktop/src/views/notes/DayNoteView.tsx:170-220` | DONE | |
| Teach correction dialog | `Sources/OpenScribe/NotesView.swift:560-598` | `desktop/src/views/notes/TeachCorrection.tsx:1-85`, `desktop/src/views/notes/correctionRequest.ts:1-50` | DONE | |

### 4. Meetings

| Feature | Swift file:line | Windows file:line | Status | What's missing |
| :--- | :--- | :--- | :--- | :--- |
| Meeting list grouping (Today, Yesterday, Month) & duration formatting | `Sources/OpenScribe/MeetingsView.swift:178-220` | `desktop/src/views/meetings/MeetingsView.tsx:120-160` | DONE | |
| Split Start Meeting button with audio source preferences | `Sources/OpenScribe/MeetingsView.swift:111, 142-162` | `desktop/src/views/meetings/MeetingsView.tsx:90-115` | DONE | |
| Meeting search & filter | `Sources/OpenScribe/MeetingsView.swift:130-140` | `desktop/src/views/meetings/MeetingsView.tsx:75-88` | DONE | |
| Detail tabs (My notes, Summary, Transcript) | `Sources/OpenScribe/MeetingsView.swift:439-530` | `desktop/src/views/meetings/MeetingsView.tsx:210-250` | DONE | |
| Realtime WebSocket streaming partials during meeting | `Sources/OpenScribe/MeetingController.swift:82-95`, `Sources/OpenScribe/LiveAudioPipeline.swift:1-120` | none | MISSING | Windows has no WebSocket live-streaming transport. Only closed ~15s chunks are transcribed post-capture. In-flight words are not streamed. |
| Finalized audio chunk background transcription loop | `Sources/OpenScribe/MeetingController.swift:303-330` | `desktop/src-tauri/src/meetings.rs:242-290` | DONE | |
| Audio & track names modal dialog (speaker labeling & chunk audio playback) | `Sources/OpenScribe/MeetingsView.swift:590-620` | `desktop/src/views/meetings/AudioTrackDialog.tsx:1-45`, `desktop/src/views/meetings/MeetingRecordings.tsx:1-90` | DONE | |
| Transcript passage and summary citation audio playback | `Sources/OpenScribe/MeetingsView.swift:539-575` | `desktop/src/views/meetings/SegmentAudio.tsx:1-40`, `desktop/src/views/meetings/MeetingsView.tsx:340-380` | DONE | |
| Short meeting resolution (< 30 words: Summarize anyway, keep transcript, delete) | `Sources/OpenScribe/MeetingsView.swift:475-480` | `desktop/src/views/meetings/MeetingsView.tsx:280-310`, `desktop/src-tauri/src/meetings.rs:320-350` | DONE | |
| Floating meeting notes window during recording | `Sources/OpenScribe/MeetingNotesPanel.swift:5-80` | `desktop/src/meetingNotes/MeetingNotesApp.tsx:1-120` | DONE | |
| Meeting export to Markdown file & copy as Markdown | `Sources/OpenScribe/MeetingsView.swift:316-329` | `desktop/src/views/meetings/MeetingsView.tsx:295-320`, `desktop/src-tauri/src/meetings.rs:410-440` | DONE | |

### 5. Calendar Integration & Auto-Start

| Feature | Swift file:line | Windows file:line | Status | What's missing |
| :--- | :--- | :--- | :--- | :--- |
| Event source management | `Sources/OpenScribe/CalendarMeetingController.swift:75-95` | `desktop/src-tauri/src/calendar.rs:18-40`, `desktop/src/views/settings/CalendarSettings.tsx:1-150` | DONE | Platform-adapted: EventKit is macOS-only; Windows parses ICS web feeds and local files. |
| Month calendar & Day agenda views | `Sources/OpenScribe/CalendarSettingsView.swift:50-145` | `desktop/src/views/settings/CalendarAgenda.tsx:1-75` | DONE | |
| Join meeting button for video conference links (Meet, Zoom, Teams, Webex) | `Sources/OpenScribe/CalendarSettingsView.swift:125` | `desktop/src/views/settings/CalendarAgenda.tsx:65-70` | DONE | |
| Agenda event "Skip recording" / "Undo skip" action | `Sources/OpenScribe/CalendarSettingsView.swift:127-130`, `Sources/OpenScribe/CalendarMeetingController.swift:125-140` | `desktop/src-tauri/src/calendar.rs:780-810` | PARTIAL | Rust backend implements `calendar_decision` for "skip" and "allow", but `CalendarAgenda.tsx` has no button or UI action to skip or unskip an event. |
| Floating countdown prompt for meeting auto-start and auto-stop | `Sources/OpenScribe/CalendarMeetingController.swift:234-295` | `desktop/src/App.tsx:328-420`, `desktop/src-tauri/src/calendar.rs:507-532` | PARTIAL | On macOS, a dedicated floating `NSPanel` appears on top of any active window with a 60s countdown. On Windows, prompts are only rendered inside the main workspace window; if the window is hidden in the tray, no prompt window is shown. |
| Standalone floating calendar recording controller ("Not happening", "Stop & save") | `Sources/OpenScribe/CalendarMeetingController.swift:280-295` | `desktop/src/App.tsx:260-275` | PARTIAL | Only available as an in-workspace banner in `App.tsx`; no floating controls exist when workspace is minimized or closed. |

### 6. Dictation, Audio Processing & Personalization

| Feature | Swift file:line | Windows file:line | Status | What's missing |
| :--- | :--- | :--- | :--- | :--- |
| Microphone device capture & level metering | `Sources/OpenScribe/AudioRecorder.swift:1-120`, `Sources/OpenScribe/MicrophoneDevice.swift:1-75` | `desktop/src-tauri/src/audio.rs:1-250`, `desktop/src/views/settings/SettingsView.tsx:60` | DONE | |
| System audio loopback recording | `Sources/OpenScribe/SystemAudioRecorder.swift:1-120` | `desktop/src-tauri/src/meeting_audio.rs:1-350` | DONE | Platform-adapted: macOS uses ScreenCaptureKit; Windows uses WASAPI loopback. |
| Audio cues / earcons on dictation start & stop | `Sources/OpenScribe/CaptureSounds.swift:1-45`, `Sources/OpenScribe/AppController.swift:284, 334, 1062` | `desktop/src/captureSounds.ts:1-55`, `desktop/src/mainController.ts:40, 51, 106` | DONE | Synthesized 80ms swept sine cues matched to macOS. |
| Realtime WebSocket streaming transcripts for dictation | `Sources/OpenScribe/RealtimeTranscription.swift:1-120`, `Sources/OpenScribe/StreamingCapability.swift:1-150` | none | MISSING | Windows has no WebSocket streaming transport. All dictation is uploaded as whole WAV files post-stop; in-flight streaming words are missing. |
| Multi-provider transcription (OpenRouter, OpenAI, Groq, Mistral, Deepgram, AssemblyAI, Custom) | `Sources/OpenScribe/ProviderClient.swift:1-350` | `desktop/src-tauri/src/provider.rs:1-550`, `desktop/src/views/settings/ProvidersSettings.tsx:1-150` | DONE | |
| Writing cleanup with configurable strength and default tone | `Sources/OpenScribe/SettingsView.swift:160-185`, `Sources/OpenScribe/ProviderClient.swift:cleanTranscript` | `desktop/src/views/settings/ProvidersSettings.tsx:105-120`, `desktop/src-tauri/src/provider.rs:153-220` | DONE | |
| Per-application writing tones | `Sources/OpenScribe/PersonalizationView.swift:app-tones`, `Sources/OpenScribe/AppController.swift:activeApplicationMetadata` | `desktop/src/views/settings/PersonalizationSettings.tsx:15-80`, `desktop/src-tauri/src/desktop_integration.rs:16-40` | DONE | Foreground application discovery via Win32 API. |
| Custom vocabulary & speech hints biasing | `Sources/OpenScribe/SmartDictionary.swift:1-60` | `desktop/src-tauri/src/dictionary.rs:40-100` | DONE | |
| Snippets (exact multiline text expansion, skips cleanup) | `Sources/OpenScribe/AppController.swift:processRecording` | `desktop/src/core/shortcuts.ts:expandSnippet`, `desktop/src/mainController.ts:61`, `desktop/src/views/settings/PersonalizationSettings.tsx:20` | DONE | |
| Spoken corrections & verbal editing ("no wait", "scratch that") | `Sources/OpenScribe/SmartDictionary.swift`, `Sources/OpenScribe/AppController.swift:723` | `desktop/src-tauri/src/dictionary.rs:100-350`, `desktop/src/mainController.ts:57` | DONE | |
| Learn spelled words (auto-learn into custom vocabulary) | `Sources/OpenScribe/AppController.swift:737-743` | `desktop/src/mainController.ts:58-60`, `desktop/src-tauri/src/dictionary.rs:404` | DONE | |
| Paste into focused application | `Sources/OpenScribe/TextInjector.swift:1-65` | `desktop/src/native.ts:40-46`, `desktop/src-tauri/src/platform.rs:3-17` | PARTIAL | `native.ts` only backs up plain text before paste; if the user had rich text, an image, or file handles on the clipboard, restoring clobbers the clipboard. Does not reactivate the origin window before keystroke. |
| "Paste last dictation" shortcut and tray action | `Sources/OpenScribe/AppController.swift:173-193` | `desktop/src/mainController.ts:249-253`, `desktop/src/core/dailyNotes.ts:110` | DONE | |
| Offline / crash recovery store | `Sources/OpenScribe/DictationRecoveryStore.swift:1-90` | `desktop/src/recovery.ts:1-60`, `desktop/src/dictation.ts:1-120`, `desktop/src-tauri/src/storage.rs:Recovery` | DONE | |

### 7. Keyboard Shortcuts & Global Hotkeys

| Feature | Swift file:line | Windows file:line | Status | What's missing |
| :--- | :--- | :--- | :--- | :--- |
| Global hotkey registration for 7 actions (dictate, holdToTalk, meeting, 3 screenshots, pasteLast) | `Sources/OpenScribe/Shortcuts.swift:5-50`, `Sources/OpenScribe/SettingsView.swift:205-285` | `desktop/src/core/shortcuts.ts:1-150`, `desktop/src-tauri/src/shortcuts.rs:10-70`, `desktop/src/views/settings/ShortcutsSettings.tsx:1-140` | DONE | |
| Right Ctrl modifier-only hold-to-talk (macOS Fn/Globe equivalent) | `Sources/OpenScribe/GlobalHotkey.swift:65-80` | `desktop/src-tauri/src/modifier_hold.rs:1-150`, `desktop/src-tauri/src/shortcuts.rs:75-120` | DONE | Low-level Win32 keyboard hook for Right Ctrl press/release. |
| Shortcut collision detection & external failure indication | `Sources/OpenScribe/Shortcuts.swift:conflicts`, `Sources/OpenScribe/AppController.swift:assignShortcut` | `desktop/src/core/shortcuts.ts:assignShortcut`, `desktop/src-tauri/src/shortcuts.rs:failures`, `desktop/src/views/settings/ShortcutsSettings.tsx:50` | DONE | |
| Escape key cancellation during dictation and processing | `Sources/OpenScribe/AppController.swift:cancelCapture` | `desktop/src-tauri/src/shortcuts.rs:Registration::escape`, `desktop/src/mainController.ts:145-147` | DONE | |
| In-app shortcut key recorder (with global hotkey suspension) | `Sources/OpenScribe/SettingsView.swift:377-470` | `desktop/src/views/settings/ShortcutsSettings.tsx:65-95` | DONE | |

### 8. Screenshots & OCR

| Feature | Swift file:line | Windows file:line | Status | What's missing |
| :--- | :--- | :--- | :--- | :--- |
| Screenshot modes (Area, Window, Full Screen) | `Sources/OpenScribe/ScreenshotCapture.swift:5-75` | `desktop/src-tauri/src/screenshot.rs:1-250`, `desktop/src-tauri/src/region_select.rs:1-150`, `desktop/src/region/main.ts:1-50` | DONE | |
| OCR text extraction from screenshots | `Sources/OpenScribe/ScreenshotCapture.swift:80-95` | `desktop/src-tauri/src/ocr.rs:1-100` | DONE | Windows `Media::Ocr::OcrEngine` integration. |
| Shutter sound on capture | `Sources/OpenScribe/ScreenshotCapture.swift:45` | `desktop/src-tauri/src/storage_hooks.rs:73-84` | DONE | Platform-adapted: Windows uses `MessageBeep(0x40)`. |
| Copy screenshot image, copy OCR, open in viewer, reveal in Explorer | `Sources/OpenScribe/DayNoteView.swift:266-270` | `desktop/src/views/notes/DayNoteView.tsx:180-220` | DONE | |

### 9. Settings & Preferences

| Feature | Swift file:line | Windows file:line | Status | What's missing |
| :--- | :--- | :--- | :--- | :--- |
| Theme selection (System, Light, Dark) | `Sources/OpenScribe/SettingsView.swift:340-375` | `desktop/src/views/settings/SettingsView.tsx:25-35`, `desktop/src/theme.ts:1-60` | DONE | |
| Launch at login (Windows Run Registry integration) | `Sources/OpenScribe/LoginItem.swift:1-40`, `Sources/OpenScribe/SettingsView.swift:59-66` | `desktop/src-tauri/src/desktop_integration.rs:198-230`, `desktop/src/views/settings/SettingsView.tsx:36` | DONE | |
| Microphone selection & device refresh | `Sources/OpenScribe/SettingsView.swift:71-80` | `desktop/src/views/settings/SettingsView.tsx:37`, `desktop/src-tauri/src/audio.rs:inputs` | DONE | |
| Permissions / System readiness view | `Sources/OpenScribe/PermissionsView.swift:1-45` | `desktop/src/views/settings/PermissionsView.tsx:1-45`, `desktop/src-tauri/src/desktop_integration.rs:capture_readiness` | DONE | |
| macOS TCC permissions panes deep links | `Sources/OpenScribe/PermissionsView.swift:50-80` | none | N/A on Windows | macOS-specific TCC privacy panes (Accessibility, Screen Recording). Windows uses `open_windows_settings` for microphone and sound. |
| Privacy tab (counts, retain raw audio toggle, provider disclosures, purge notes) | `Sources/OpenScribe/SettingsView.swift:287-327` | `desktop/src/views/settings/SettingsView.tsx:50-65` | DONE | |

### 10. Onboarding & First-Run Setup

| Feature | Swift file:line | Windows file:line | Status | What's missing |
| :--- | :--- | :--- | :--- | :--- |
| 4-step setup wizard (Welcome, Connect Provider, Access Readiness, Try It) | `Sources/OpenScribe/OnboardingView.swift:1-180` | `desktop/src/views/OnboardingView.tsx:1-250` | DONE | |
| Practice dictation with live confirmation & error feedback | `Sources/OpenScribe/OnboardingView.swift:140-175` | `desktop/src/views/OnboardingView.tsx:120-180`, `desktop/src/views/settings/practiceFeedback.ts:1-60` | DONE | |
| Set up later / skip option | `Sources/OpenScribe/OnboardingView.swift:19` | `desktop/src/views/OnboardingView.tsx:40` | DONE | |

---

## Recommended Next Work Packages

The following 5 work packages are ordered by user impact. Each package targets a strictly disjoint set of Windows files, allowing multiple sub-agents to implement them in parallel without file conflicts or git merge issues.

### Work Package 1: System Tray Dynamic Status & QuickPanel Popover
- **User Impact:** High. On macOS, clicking the menu bar icon is the primary lightweight interface when the main workspace is closed. Windows users currently only see a static context menu and a static icon.
- **Scope:**
  1. Add dynamic icon generation in `tray.rs` that renders a recording dot or paused bars based on live capture state.
  2. Implement dynamic context menu items in `tray.rs` (live status header, "Today's note", "Retry failed recording", calendar "Not happening", Flowbar idle checkmark).
  3. Create a lightweight `quickpanel` window in Tauri (`desktop/src/quickpanel/QuickPanelApp.tsx` and `main.tsx`) showing the audio squiggle, timer, start/stop button, and recent notes with 1-click copy.
- **Files Owned (Disjoint Set):**
  - `desktop/src-tauri/src/tray.rs`
  - `desktop/src-tauri/tauri.conf.json`
  - `desktop/src/quickpanel/main.tsx`
  - `desktop/src/quickpanel/QuickPanelApp.tsx`

### Work Package 2: Realtime WebSocket Streaming Transcripts
- **User Impact:** High. Live partials provide immediate visual feedback while speaking during dictation and meetings. Currently Windows only supports post-chunk transcription.
- **Scope:**
  1. Port `StreamingCapability` and `RealtimeTranscription` WebSocket client to Rust in `desktop/src-tauri/src/provider.rs` for Mistral, Deepgram, AssemblyAI, and OpenAI Realtime.
  2. Add `automaticStreaming` setting in `desktop/src/views/settings/ProvidersSettings.tsx`.
  3. Hook live partial streams into meeting transcription in `desktop/src-tauri/src/meetings.rs`.
- **Files Owned (Disjoint Set):**
  - `desktop/src-tauri/src/provider.rs`
  - `desktop/src-tauri/src/meetings.rs`
  - `desktop/src/views/settings/ProvidersSettings.tsx`
  - `desktop/src/api/parityTypes.ts`

### Work Package 3: Calendar Auto-Start Floating Prompt & Agenda Skip Action
- **User Impact:** Medium-High. Without a floating prompt, calendar auto-start fails to notify the user if OpenScribe is hidden in the tray.
- **Scope:**
  1. Create a dedicated top-right floating prompt window (`desktop/src/calendarPrompt/`) that triggers on `calendar://prompt-start` and `calendar://prompt-end`.
  2. Implement "Skip recording" and "Undo skip" buttons in `desktop/src/views/settings/CalendarAgenda.tsx` hooked to `calendar_decision`.
  3. Connect prompt window display in `desktop/src-tauri/src/calendar.rs`.
- **Files Owned (Disjoint Set):**
  - `desktop/src-tauri/src/calendar.rs`
  - `desktop/src/calendarPrompt/main.tsx`
  - `desktop/src/calendarPrompt/CalendarPromptApp.tsx`
  - `desktop/src/views/settings/CalendarAgenda.tsx`

### Work Package 4: Process Lifecycle, Single Instance & CLI Diagnostics
- **User Impact:** Medium. Prevents accidental duplicate processes and provides automated test harnesses (`--credential-smoke`, `--provider-smoke`).
- **Scope:**
  1. Add `tauri-plugin-single-instance` to `Cargo.toml` and configure instance focus in `lib.rs`.
  2. Implement CLI argument parsing in `desktop/src-tauri/src/main.rs` for `--credential-smoke`, `--provider-smoke`, `--bootstrap-openrouter-key`, and `--show-workspace`.
- **Files Owned (Disjoint Set):**
  - `desktop/src-tauri/Cargo.toml`
  - `desktop/src-tauri/src/main.rs`
  - `desktop/src-tauri/src/lib.rs`

### Work Package 5: Clipboard MIME Fidelity & Window Activation on Paste
- **User Impact:** Medium. Prevents clobbering non-text clipboard items (images, files) when pasting and ensures the target application window receives focus.
- **Scope:**
  1. In `desktop/src-tauri/src/platform.rs`, implement full Win32 clipboard format backup (using `GetClipboardData` across formats) and restoration, plus `SetForegroundWindow` targeting the active window where dictation started.
  2. Refactor `desktop/src/native.ts` to delegate the complete paste transaction to the native Rust backend.
- **Files Owned (Disjoint Set):**
  - `desktop/src-tauri/src/platform.rs`
  - `desktop/src/native.ts`

### Work Package 6: In-App Keyboard Shortcuts & Persistent Page Mounting
- **User Impact:** Low-Medium. Improves keyboard efficiency and preserves UI search and draft state across navigation tabs.
- **Scope:**
  1. In `desktop/src/App.tsx`, preserve page mounting via CSS `display: none` / `visibility` rather than conditional unmounting, and bind `Ctrl+1` / `Ctrl+2` / `Ctrl+3` to switch library tabs.
  2. In `desktop/src/views/notes/NotesView.tsx`, register `Ctrl+N` (new note), `Ctrl+F` (focus search), and `Ctrl+T` (jump to today).
- **Files Owned (Disjoint Set):**
  - `desktop/src/App.tsx`
  - `desktop/src/views/notes/NotesView.tsx`
