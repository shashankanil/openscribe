# OpenScribe feature review

Reviewed 5 September 2026 against Wispr Flow's public product pages. This is a feature inventory, not a claim of equivalent recognition quality or exhaustive parity with undocumented experiments.

## Current architecture

Native macOS 14+ SwiftUI menu-bar application, Swift Package Manager, no third-party dependencies. AppController coordinates global shortcuts, permission setup, AVAudioEngine recording, provider transcription, optional cleanup, JSON note history, and clipboard-based paste. AudioChunkStore writes bounded WAV chunks. ProviderClient uploads them sequentially and cleans complete short transcripts and bounded long-transcript batches. Credentials use a local private file; notes/settings use the historical `WhisperFlow` Application Support directory. Branding mixes OpenScribe and Whisperlight; existing data paths remain compatible.

The workspace supports search, manual notes, pinning, editing raw/polished text and source-app metadata. The floating waveform has three preset positions. Speech and cleanup providers can be configured independently. No account or cloud synchronization layer exists.

## Comparison

The [Wispr Flow feature page](https://wisprflow.ai/features) advertises the following:

| Capability | OpenScribe after this change | Remaining work |
| --- | --- | --- |
| Dictation into other apps | Existing macOS paste, hardened clipboard handling | Real-app compatibility matrix |
| Cleanup, punctuation, self-correction, lists | Optional Light/Clear/Concise cleanup | Evaluate correction/list quality across providers |
| Personal dictionary | Vocabulary prompts and deterministic correction pairs | Speech-provider vocabulary hints; opt-in correction learning |
| Voice snippets | Added exact whole-utterance expansion | Import/export and editing workflows |
| App-dependent style | Added per-app tone overrides | Browser/site-level styles |
| Multilingual and quiet speech | Depends on selected provider | Explicit language controls and quality evaluation |
| Developer syntax and IDE file tagging | No dedicated integration | IDE context adapter and syntax evaluation |
| Team dictionary, snippets, analytics | Absent | Separate shared-data service |
| Windows and mobile | Absent | Separate clients |

The [desktop help overview](https://docs.wisprflow.ai/articles/2772472373-what-is-flow) also describes hands-free activation, stats, scratchpad, paste-last, music muting, command mode and bulk import. OpenScribe has toggle/hold recording and editable notes; double-press hands-free, dedicated scratchpad, paste-last shortcut, music controls, voice editing/search, imports, and usage insights remain unimplemented. Durable dictation recovery now persists audio and completed transcript chunks across restarts; retries never auto-paste. A paste-latest-note status-menu action is available; a dedicated global binding is still pending.

## Implemented reliability work

- Always observe shortcut release, including toggle mode. Previously toggle latched after one press. Remove time-based suppression that lost rapid deliberate presses while continuing to ignore key repeats.
- Handle stop/release while microphone startup is pending, including Globe.
- Check cancellation after permission suspension and isolate task cleanup by capture generation, preventing an older task from resetting a newer one.
- Transfer finished audio ownership out of the recorder so cancellation/reset cannot delete audio still being processed.
- Persist queued recording jobs and per-chunk transcript checkpoints. Retry saves to notes without pasting into an old app; stable note IDs prevent duplicate recovery results. Quit saves active audio. Unreadable or corrupt files are preserved and reported.
- Preserve clipboard formats and restore only while the app still owns the clipboard. Await target activation and reject missing/inactive targets before posting paste. macOS does not confirm that the destination accepted text.
- Keep raw chunk text when cleanup returns whitespace; preserve raw text alongside snippet expansion.
- Remove the menu's hardcoded Option-Space shortcut, which could conflict with the configurable global handler.
- Add quiet 80 ms rising/falling recording cues with a persisted off switch. Start confirms recorder startup; stop plays after capture ends.

See [the detailed implementation roadmap](IMPLEMENTATION-ROADMAP.md) for the refreshed gap inventory, dependencies, acceptance criteria and research caveats.

## Next implementation priorities

1. Durable recovery queue, partial-chunk progress, explicit network deadlines, microphone disconnect/sleep handling, and visible persistence failures.
2. Full-transcript cleanup with bounded context, language selection, and provider-specific dictionary hints. Current 15-second cleanup chunks can lose context across boundaries.
3. Paste-last hotkey, hands-free double-press, usage insights, and snippet import/export.
4. Selected-text command mode with preview, opt-in contextual vocabulary, and IDE file tagging.
5. Separate product decisions for mobile, team accounts, synchronization and meeting capture.

## Verification

Automated regression coverage includes legacy settings migration, new preferences round-trip, whole-utterance snippet matching, multi-format clipboard restoration/new-copy protection, rapid toggle presses/repeats, and finished audio ownership. Provider upload tests use mock responses and do not establish live provider availability.

Manual acceptance: try repeated toggle and hold/Globe presses; cancel during startup and transcription; unplug the microphone; compare sounds on speakers/headphones; copy rich text during processing; close/switch the target app; fail transcription then retry/discard; select an app style; dictate a snippet and a longer sentence containing its trigger. Hardware audio, accessibility delivery and subjective sound level require this real-device pass.

## Unified workspace follow-up

Notes, inline note editing, settings and setup now share one window and sidebar. Settings shortcuts and quick-menu actions route to that window. Left-clicking the status icon opens the workspace; right-click/Control-click exposes the native quick-action menu. Search and settings drafts remain mounted while navigating. The dev build supports `--show-workspace` for review.

Validated live: sidebar notes/settings navigation, inline editor/back navigation, Cmd-comma settings routing, and the General page layout. Native status-icon mouse behavior still needs a direct click check.

## Meeting mode in the dev build

Microphone and/or system-audio recording, pause/resume, durable local manifests, timestamped transcription, evidence-linked summaries/decisions/actions, transcript search, per-chunk playback, editable source labels and Markdown export are implemented. Processing can resume from completed chunks. System audio uses ScreenCaptureKit without storing screen video. Automatic processing is an explicit option in the capture UI. Individual speaker diarization, live transcription, calendar context and MCP access remain open. Synthetic audio and mocked provider tests pass; actual meeting capture and provider output quality still need hands-on validation.
