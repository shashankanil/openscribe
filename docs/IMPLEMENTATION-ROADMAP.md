# OpenScribe implementation roadmap

Prepared 5 September 2026. Implementation in progress: statuses below reflect the local dev build; acceptance criteria remain release checks. The current local source, including the unified workspace changes, is the baseline. Focus: personal macOS dictation first, then optional expansion.

## Verified gaps

Status describes OpenScribe. References describe Wispr Flow's public behavior, not measured quality parity.

| ID | Capability | Status and concrete gap | Batch | Evidence |
| --- | --- | --- | --- | --- |
| R1 | Recovery after quitting | Implemented durable queued audio and transcript checkpoints with restart recovery; remaining: bounded retries, age limits and hardware interruption QA | 1 | [Release notes](https://wisprflow.ai/whats-new) |
| R2 | Microphone selection and fallback | Partial: stable-ID picker, explicit unavailable-device error and interruption save/pause; remaining: seamless fallback, priority list and mic test | 1 | [Microphone guide](https://docs.wisprflow.ai/articles/9192039587-Using-Wispr-Flow-Discreetly:-Microphone-Guide), [release notes](https://wisprflow.ai/whats-new) |
| R3 | Long-session feedback | Partial: chunked files exist; no duration warning, explicit processing progress or measured long-session quality | 1–2 | [Mac long sessions](https://docs.wisprflow.ai/articles/4841123325-longer-dictation-sessions-now-up-to-20-minutes) |
| D1 | Personal dictionary | Partial: vocabulary prompts plus deterministic whole-word correction pairs, including cleanup-off; remaining: recognition hints, learning, search and import | 2 | [Dictionary](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary) |
| D2 | Cleanup strength | Partial: Light/Clear/Concise plus cleanup-off and independent tone; full short-transcript context, bounded long batches; remaining: quality evaluation and immutable revisions | 2 | [Release notes](https://wisprflow.ai/whats-new), [smart formatting](https://docs.wisprflow.ai/articles/5373093536-how-do-i-use-smart-formatting-and-backtrack) |
| D3 | Language controls | Partial: recognition depends on the provider; no explicit language picker or provider capability display | 2 | [Feature overview](https://wisprflow.ai/features) |
| D4 | Context and writing styles | Partial: bundle-ID tone overrides; no site/category routing or surrounding-text context | 2, 5 | [Feature overview](https://wisprflow.ai/features) |
| W1 | Hands-free gestures and shortcuts | Partial: one toggle/hold binding, Globe always holds; paste-latest-note menu action added; no double-tap lock, separate global actions, Escape cancel or mouse buttons | 3 | [Shortcut guide](https://docs.wisprflow.ai/articles/5298382595-route-dictation-directly-to-slack-email-or-calendar-with-keyboard-shortcuts) |
| W2 | Flowbar controls | Partial: waveform and three presets; no persistent drag position, stop button, timer, mic/language switcher or snooze | 3 | [Desktop navigation](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android) |
| W3 | System conveniences | Missing: launch-at-login setting, dock visibility setting, music muting and notification preferences | 3 | [Desktop navigation](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android) |
| P1 | Snippet management and expansion | Partial: add/remove and exact whole-utterance plain text; no editing/search/import, mid-sentence expansion or rich text | 4 | [Snippets](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets), [release notes](https://wisprflow.ai/whats-new) |
| N1 | Notes/scratchpad | Partial: searchable plain-text notes, pins, inline editing and copy; no quick-capture shortcut, versions, rich text, tabs or images | 4 | [Release notes](https://wisprflow.ai/whats-new) |
| N2 | History audio playback | Missing: retained audio is not attached to a note or playable in the UI | 4 | [Release notes](https://wisprflow.ai/whats-new) |
| N3 | Insights | Missing: total words, WPM, streaks, app breakdown and communication insights | 4 | [Desktop navigation](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android), [release notes](https://wisprflow.ai/whats-new) |
| N4 | Retention controls | Partial: delete-all and retain-audio toggles; no never-save mode, timed history deletion or audio retention policy | 1, 4 | [Release notes](https://wisprflow.ai/whats-new) |
| A1 | Reusable transforms | Missing: selected-text rewrite, named custom prompts, prompt polishing, diff and undo | 5 | [Transforms](https://docs.wisprflow.ai/articles/8068950331-how-to-use-transforms-beta) |
| A2 | Command mode | Missing: spoken editing instructions and voice search | 5 | [Command Mode](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode) |
| A3 | Developer integrations | Missing: variable recognition, actual IDE file tagging and terminal-specific paste handling | 5 | [Feature overview](https://wisprflow.ai/features), [release notes](https://wisprflow.ai/whats-new) |
| X1 | Cross-device personalization | Missing: no sync service or identity layer | 6 | [Sync guide](https://docs.wisprflow.ai/articles/5284722493-sync-flow-across-your-devices) |
| X2 | Other platforms and localization | Missing: Windows, iOS, Android clients and translated interface | 6 | [Feature overview](https://wisprflow.ai/features), [release notes](https://wisprflow.ai/whats-new) |
| X3 | Teams | Missing: shared vocabulary/snippets, admin controls, organization analytics and account management | 6 | [Feature overview](https://wisprflow.ai/features) |
| X4 | Meeting assistant and integrations | Partial: mic/system capture, pause/resume, durable recovery, transcript search, cited summaries, chunk playback and Markdown export; calendar prompts and exclusions added; remaining: diarization, live transcript, call detection and direct Google OAuth | 6 | [Release notes](https://wisprflow.ai/whats-new) |
| X5 | MCP access | Missing: no tool server for notes/meetings | 6 | [MCP documentation](https://docs.wisprflow.ai/articles/4759919286-how-to-connect-wispr-flow-to-claude-chatgpt-and-other-ai-tools-mcp) |

Existing foundations: system-wide dictation, provider selection, optional cleanup, hold/toggle capture, configurable sound cues, original/polished text, manual notes, pins, search, per-app metadata, unified settings, and a native status menu. These should be improved in place.

## Current verification

29 automated tests cover persistence, recovery checkpoints, PCM system-audio conversion/timestamps, citation IDs, clipboard restoration, shortcut release, dictionary boundaries and settings migration. Real meeting hardware, sleep/unplug behavior, provider quality and end-to-end recording still need hands-on validation. Source labels distinguish microphone/system audio, not individual speakers.

## Implementation batches

Sizes are relative engineering scope, not calendar promises: S = contained UI/action; M = model plus workflow; L = capture/data pipeline or external integration. Each batch should remain independently reviewable.

### 1. Protect recordings and make the mic predictable — L

- Introduce a persisted recording job with ID, state, chunk paths, completed chunk results, source app, settings snapshot and last error. Use an app-owned recovery directory and atomic manifest writes.
- Save checkpoints as capture progresses. On launch, offer recovery for unfinished jobs; never auto-paste a recovered result. Track successful note IDs so retries cannot duplicate notes.
- Classify transient provider errors, use bounded retries and deadlines, and preserve successful chunks. Authentication failures should point to provider settings immediately.
- Add a microphone picker using stable device IDs, a level test and explicit unavailable-device behavior. First milestone safely ends/saves when an input disappears; seamless switching follows only after format-change tests pass.
- Surface persistence failures, corrupt-file recovery and low-disk errors; fix duplicate-instance behavior, which we observed during dev restarts.
- Explain recovery retention separately from optional permanent audio storage; provide discard and age limits.

Where: AppController, AudioRecorder, AudioChunkStore, AppStore and ProviderClient; new RecordingJobStore and MicrophoneManager. UI: a recoverable row in Notes and controls under General, not a new window.

Acceptance: interrupt capture/processing with quit, simulated crash, unplug and network loss; recover captured data on restart; retry a failed middle chunk without retranscribing completed ones; no duplicate note or surprise paste; no success label on a failed save. Run repeated start/stop/cancel cycles and test sleep/wake on hardware.

### 2. Improve the words that come out — L

- Replace the vocabulary array with structured entries: preferred spelling, optional mistaken phrase and priority. Migrate existing terms without loss. Add search/edit/import preview and “Remember this correction” from a note.
- Pass bounded vocabulary hints to speech providers only where supported. Keep deterministic correction rules available when cleanup is off. Show unsupported options instead of silently ignoring them.
- Offer automatic or explicit dictation language, with a provider capability map. Begin evaluation with English and Hindi/mixed speech; label unsupported combinations honestly.
- Separate cleanup intensity from tone. Proposed modes: Original, Light, Clear and Concise. Preserve an immutable raw transcript and save edited revisions.
- Clean a complete short transcript together. For long sessions, use bounded overlapping context and deterministic reassembly rather than independently polishing every 15-second fragment.
- Build a compact evaluation corpus for names, numbers, negation, “actually…” corrections, lists, code terms and multilingual text. Compare meaning preservation, not just grammatical appearance.

Depends on batch 1's job snapshots and recovery. UI: Writing & cleanup owns language/style decisions; Dictionary is a subpage of Personalization.

Acceptance: correction rules work with cleanup disabled; “meet at two, actually three” preserves only the intended time; numbers/negation survive every mode; boundary-spanning sentences remain intact; original text is always recoverable. Measure latency on 10-second, 1-minute and 20-minute fixtures before choosing release targets.

### 3. Make everyday control effortless — M

- Replace the single hotkey callback with an action registry: hold, toggle/hands-free, cancel, paste-last and quick note. Add double-tap lock using a tested state machine; distinguish a short tap from an intentional double tap without submitting accidental empty clips.
- Add Escape cancel while capture is active, then optional mouse-button bindings and conflict explanations. Suspend global shortcuts during shortcut editing and microphone tests.
- Add Flowbar stop/cancel buttons, elapsed time and plain error/progress text. Persist position per display and clamp it after monitor removal. Expose mic/language controls without opening another window.
- Add launch-at-login and optional dock presence. Music muting must restore only what OpenScribe changed, even after cancellation or failure.

Depends on batch 1 for stable transitions. Paste-last can land first as a small, useful change.

Acceptance: hold/release, rapid double-tap, key-repeat, modifier order and cancel work consistently; no existing clipboard content is overwritten by restoration; paste-last handles an empty history; the Flowbar stays on-screen after display changes.

### 4. Finish personalization and notes — M/L

- Add snippet editing, search, import/export preview and duplicate/conflict handling. Keep whole-utterance expansion as default; make mid-sentence expansion an explicit option with phrase boundaries, longest-match precedence and no recursive replacements. Protect expansions from AI rewriting.
- Add rich-text snippet payloads with a plain-text fallback; verify paste in native and browser editors.
- Make quick note a shortcut into the existing editor. Add autosave status, revisions, export, date grouping and one-click history copy. Rich text/tabs/images are a later sub-batch after plain-text migrations and undo are solid.
- Attach retained audio to notes for playback and reprocessing, governed by explicit retention preferences.
- Show a small Notes overview: dictated words, recording-based WPM and days used. Exclude manual notes and snippet-expanded word counts; label any time-saved estimate with its assumed typing speed.
- Add never-save and timed-delete history choices; separate transient recovery jobs from the permanent note archive.

Depends on batches 1–2 for audio ownership and revisions. UI: all editing stays inline; a compact Notes overview avoids another dashboard window.

Acceptance: import preview changes nothing until applied; undo restores prior text; rich text falls back cleanly; retention removes associated audio; stats remain stable when notes are edited or snippets expand.

### 5. Add intentional AI actions and developer context — L

- Start transforms inside our note editor: shorten, change tone, structure an AI prompt, custom instruction. Display a before/after comparison with Apply, Cancel and Undo.
- Extend to external selected text only after focus identity and replacement safety are tested. Never replace text when the selection has changed while waiting for the model.
- Add a separate spoken-command mode using that same transform pipeline. Keep search as an explicit action; do not interpret normal dictation as commands or execute shell commands.
- Add opt-in surrounding-text context with per-app controls. Begin with selected text; expand context only when its benefit is demonstrated.
- Add developer formatting and then an IDE adapter that resolves actual workspace files. Never fabricate @file references; test native and terminal paste behavior separately.

Depends on revisions, the action registry and safe text delivery. Acceptance: failure/cancel leaves selected text unchanged; undo restores exactly; no source/clipboard text is sent as context when disabled; file tagging selects only real files in the chosen workspace.

### 6. Optional expansion — separate projects

Plan Mac personal use to completion before bundling these into releases: cross-device sync, Windows/mobile clients, shared/team features and meeting capture. Sync needs conflict resolution, deletion semantics and explicit data controls. Meetings need system audio, speaker handling, long-running storage and a separate recording UI. MCP can begin as read-only access to user-selected local notes, but that would be our own scope rather than a clone of Wispr's meeting-only connector.

Optional differentiators: a supported local/offline transcription engine, provider cost/latency comparisons, portable exports and a strict no-account mode. These are product choices, not missing Wispr parity features.

## Product shape

Keep one main window. Notes contains history, recovery and the editor. Personalization contains Dictionary, Snippets and App Styles. Writing contains Cleanup and later Transforms. General contains Microphone, Shortcuts and System preferences. Data & Privacy remains explicit. Do not add a new top-level window for each feature; the only optional floating editor is quick note, backed by the same note model.

## Research limitations

Public docs conflict in several places. The dedicated Mac session article says 20 minutes, while older overview pages still say roughly six; use the dedicated article as the current Mac reference. Dictionary limits and Android availability also conflict, so this plan does not copy their exact limits. Auto Cleanup's help article is unavailable; levels are supported by release notes. A shortcut article's title mentions routing to Slack/email/calendar, but its body documents shortcut binding, so direct destination routing is not counted as verified parity. Wispr says dictation history remains local; cross-device history is not assumed. Its MCP surface exposes meeting content, not general dictation history. Exact recognition quality requires direct comparative evaluation.

## Recommended next increment

Begin R1: persisted recovery jobs plus visible failed/pending rows in Notes. Follow with microphone selection, then dictionary and full-context cleanup. This sequence addresses lost work and transcription quality before widening the feature surface.

## UX follow-up — 5 September 2026

- Main navigation reduced to Notes, Meetings, Personalization and Settings; settings categories stay inside Settings.
- Compact settings cards use direct labels. Dictionary, Snippets and App styles have individual tabs; provider endpoints sit under Advanced connection settings.
- Meeting setup is opened explicitly from New meeting, leaving the library easier to scan.
- Note previews are bounded, with quick copy and click-to-open text. Note detail supports plain-text export and remembering a correction for future dictation.
- Original transcripts are read-only in the editor; deleting a note asks for confirmation. Revision history and undo remain future work.

## Calendar automation — 6 September 2026

Native EventKit integration supports Google calendars synced through macOS. Added calendar selection, opt-in watching, 60-second start/end prompts, optional unanswered auto-start, local-only late declines, 15-minute extensions, per-occurrence skips, reusable title exclusions. Automatic starts require existing microphone/system-audio permissions. See [Calendar meetings](CALENDAR-MEETINGS.md) for setup and limits. Live-call detection and direct Google OAuth remain open.

## Incremental meeting transcription — 6 September 2026

Added in-session transcription of closed audio sections, checkpointed live text, pending-tail processing on stop, a live retry control, bounded transient retries and per-section total deadlines. Original audio continues saving when live transcription fails. Calendar Yes/No prompts are explicit; unanswered auto-starts retain deferred uploads for late declines. Ordinary dictation also transcribes finalized sections during capture, checkpoints partial text, and reuses those sections when assembling/cleaning the final result. Added a Transcribe while recording preference. True provider-native streaming and latency/quality benchmarking on real long meetings remain open.

Removed calendar preview controls and demo-only branches from the app. Verified that the current OpenRouter Voxtral route is file-based; Mistral exposes a separate `voxtral-mini-transcribe-realtime-2602` model through its realtime API. Switching to it requires a realtime client and Mistral credentials, not just a model-name change.
