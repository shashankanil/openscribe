# Windows Flowbar parity

Reference: `Sources/OpenScribe/OverlayPanel.swift` (`FlowbarMode`, `FlowbarLayout`,
`OverlayPanel`, `FlowbarView`, `ScreenshotMenu`, `MeetingStopButton`), the overlay
and confirmation lifecycle in `AppController.swift`, `FlowFormat.duration`, and
`ScreenshotKind`. Implementation starts from commit `cd3473e` on
`windows-parity`; the discarded broken patch was not applied. During implementation
the parent added recording-sounds commit `b7da540`; that commit was preserved and
the Flowbar commit follows it.

## Differences found and ported

- Windows did not consume `workspace://confirmation`. It now shows the amber
  checkmark in the native 52 × 32 confirmation pill, with an accessible message.
  `Saved` lasts 1.1 seconds; `Pasted` and other confirmations last 1.6 seconds.
  Screenshot feedback uses “Added to today” / “Added to meeting”. Cancellation
  does not imply success. Active capture/meeting states retain precedence.
- Starting was incorrectly drawn as dictation. It now uses the processing wave
  and “Starting…”, followed by “Transcribing…” / “Polishing…”. Saving a meeting
  uses “Saving meeting…”. Fixed state dimensions match Swift, including the
  140-pixel expanded meeting and 34 × 6 idle sliver.
- Expanded idle lacked the still logo-wave action. Dictation had an extra stop
  square; its single live waveform now finishes recording, with Escape to
  cancel. Meeting controls now match Swift: waveform opens notes; expansion
  adds notes and screenshots; the red stop square saves the meeting. Pause /
  resume lives in the menu. Meeting help includes elapsed time and the configured
  stop shortcut. Icons remain upright, while waveforms rotate with side docking.
- The abbreviated context menu is replaced with the native ordering: Today’s
  note, Open OpenScribe, separator, Position, Keep on screen when idle,
  Shortcuts…, Settings…, followed by capture-appropriate actions. Position
  includes all five native presets and clears the saved drag placement through
  the existing controller intent. Idle visibility persists through the existing
  preference intent. Capture cancellation is red; meeting menu actions include
  notes, pause/resume, and stop/save. No duplicate settings writer was added.
- Screenshot click now captures an area immediately. Hold (500 ms), right click,
  or ArrowDown offers Area / Window / Full screen with configured shortcuts.
- Buttons have explicit accessible names. Menus expose roles and checkbox state,
  focus their first action, support arrows/Home/End, Position back navigation,
  Shift+F10 / Menu key, Escape, Tab, and outside-click/focus-loss dismissal.
  Keyboard focus expands the idle and meeting controls. Focus outlines are
  visible, and CSS transitions respect reduced-motion preferences.
- Hover catches the padded native-window area, rather than requiring the
  pointer to hit a six-pixel sliver. Collapse retains the native 350 ms grace
  period. Pill dimensions animate over 300 ms; native shrinking waits 320 ms.
- The existing snap constants and normalized placement persistence were retained.
  Dragging now also works over buttons, with a three-pixel threshold and click
  suppression. Pointer capture carries the drag outside the pill; physical
  cursor coordinates select the destination display before DPI conversion.
  The grab offset survives mixed-DPI crossings. Dock orientation updates while
  moving; release snaps and persists the final display, normalized anchor and
  side. Native geometry writes are serialized.
- Saved display placement takes priority. Without an available saved display,
  restoration uses the cursor’s display, then the first available display.
  Display/DPI/work-area changes are checked every two seconds. Saved coordinates
  are clamped, and non-finite placement values fall back to a preset.
- Menus and notices now use `companionOrigin`, rather than always appearing
  above/below even when docked. They sit beside side-docked pills, otherwise
  above the pill, or below near the top. Their actual content is measured before
  sizing the transparent window. Its union with the pill is clamped to
  `Monitor.workArea`, excluding taskbars on any edge, without shifting the pill
  anchor. The idle docked sliver hugs the same side as the expanded pill.
- Meeting notes opened from the Flowbar are placed beside the pill on its
  display, with destination-DPI sizing and work-area clamping.

`NoticeBubble` already matched the short-meeting prompt and its
Summarize / Keep / Delete actions; those were preserved. The Flowbar also loads
pending short-meeting prompts on startup, subscribing before reading so a stale
bootstrap response cannot overwrite a newer event. Notice inspection now
uses the existing `inspectNotice` intent to open the actual details rather than
unconditionally opening Settings.

## Verification

- `pnpm.cmd exec tsc --noEmit -p .`: passed.
- `pnpm.cmd exec vitest run`: **145 tests passed across 24 files**. Added mode,
  confirmation, menu, duration, taskbar/work-area, negative-origin, mixed-DPI,
  drag-offset and vertical-wave viewport checks. Placement coverage exercises
  every pill length, both side docks and notice/menu sizes against bottom, top
  and left taskbars.
- `D:\tmp\devcargo.cmd clippy --all-targets -j 2 -- -D warnings`: passed.
- `D:\tmp\devcargo.cmd test -j 2`: **103 passed, 2 ignored** (existing OCR and
  real microphone/WASAPI smoke tests). Both cargo commands ran serially from
  PowerShell with `CARGO_BUILD_JOBS=2`; no release build was run.
- A temporary Vite browser harness mounted the real React Flowbar with mocked
  Tauri IPC. Ten interaction assertions passed: Position submenu, persisted
  position intent, single dictation control, red cancel item, cancel intent,
  Saved checkmark, timed confirmation expiry, vertical pill, rotated waveform,
  and one-click area screenshot. DOM geometry inspection verified the complete
  menu fits its native frame after synchronous content measurement. The harness
  also simulated a drag from a 100% primary display to a 200% display at a
  negative desktop origin, verified the persisted destination/normalized anchor,
  and verified that release did not fire the underlying button. Pointer capture
  itself was stubbed for that synthetic event test. The harness is not part of
  the commit.
- Screenshot capture could not be completed: T3 preview snapshot timed out twice;
  the computer-use fallback reported no available browsers. Browser DOM checks
  are not a substitute for testing the packaged app on actual displays.

## Remaining differences and native verification

- SwiftUI’s spring and AppKit’s 180 ms animated snap are approximated by CSS pill
  easing and immediate native snap. Tauri exposes discrete window positioning;
  exact native animation would require a separate platform animation path.
- macOS uses a nonactivating `NSPanel`, separate notice windows, and native
  context menus. Windows retains a focusable Tauri webview and HTML menus/notices
  within one transparent window. This permits keyboard navigation, but exact
  nonactivation / focus restoration and click-through around companions need
  native Windows work; a blanket `setFocusable(false)` would disable the new
  keyboard interaction. In particular, verify the paste destination when
  dictation starts by clicking the pill rather than a global shortcut.
- Tray “Show Flowbar” still uses its pre-existing native `show()` path, without
  macOS’s persistent idle-visibility update and three-second reveal expansion.
  Completing that requires a tray/controller reveal event outside these Flowbar
  implementation files. No tray, settings view, workspace protocol, git config
  or Rust files were changed.
- Run the parent’s packaged-app smoke check for real pointer capture over
  controls, drag/restart persistence, mixed-DPI monitor crossings, screen removal,
  taskbars on each edge, keyboard focus and paste targeting. These require an
  interactive desktop/native app; the hardware tests remain intentionally ignored.

Only `desktop/src/flowbar/**`, `desktop/flowbar.html`, and this document were
changed. `docs/PARITY-GAPS.md` belongs to the concurrent read-only audit and was
not edited. No push or release build was performed.
