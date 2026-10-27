# Codex-B Windows parity integration

Implements F6, F7 logic, F8 and F9 from WINDOWS-PARITY.md. The Swift reference
sources are unchanged. No UI, meeting capture or profile-storage implementation
is included in this worktree.

## Dictionary

`apply_dictionary(text: String, settings: DictionarySettings) -> Result<Outcome, String>`
is asynchronous. JS arguments are `{ text, settings }`; the result is
`{ text, learnedWords: string[] }`. Settings can be the complete profile settings
object: unknown keys are ignored, missing dictionary fields use Swift defaults.
The caller merges learned words into customVocabulary and saves settings.

The transform applies correctionRules, rejoins split dictionary words, preserves
ordinary English word casing using the OS spelling dictionary, then optionally
classifies spoken corrections. The classifier uses the existing
`writing:<provider>:<baseURL>` credential account, honors correctionModel, and
falls back to local text on missing credentials, timeout, HTTP or JSON failure.
Its instructions are tested against Swift's multiline string, verbatim.
learnSpelledWords controls learning independently of applying spoken corrections.

`dictionary::for_settings(&DictionarySettings, provider: &str, model: &str) -> SpeechHints`
constructs provider hints. Replace the temporary struct in dictionary.rs with
`use crate::provider::SpeechHints` when integrating Codex-A's identically shaped
type. `provider_fields` supplies the exact JSON fragments for OpenRouter options,
Mistral context_bias and AssemblyAI word_boost. Deepgram's array represents
**repeated query parameters**, keyterm for nova-3 models and keywords otherwise.
OpenAI/Groq/custom use the prompt field. The provider owner must call these
helpers from transcription; provider.rs is intentionally untouched here.

On Linux, os-spellcheck has no native backend: conservative common-word checking
keeps existing casing, while split-word rejoining and spoken corrections work.
Windows uses native ISpellChecker; the COM handle is dropped before any await.

## Daily notes

`core/model.ts` contains VoiceNote and NoteCapture with the macOS JSON key names.
`core/dailyNotes.ts` mirrors display text/title, append/update/remove/recompute,
pending-editor merge, timeline migration, local-day grouping, and latest capture
selection for paste-last. These functions do not save files or create backups;
the storage owner must enforce the contract's backup/write rules before using
groupExistingDictations for persistence. Titles count grapheme clusters as Swift
Characters do. Local-day grouping uses the machine's timezone.

## Shortcuts

Commands:

- `register_shortcuts(bindings: BTreeMap<String, Binding>) -> Result<(), String>`;
  JS `{ bindings: { action: { accelerator, display } } }`. Omitted actions are
  unbound, including when bindings is empty. Registration is explicit at profile
  load; no defaults are silently installed by Rust.
- `suspend_shortcuts(suspended: bool) -> Result<(), String>`; JS `{ suspended }`.
  Suspend before editing an accelerator and resume afterward. Changed bindings
  are stored while suspended and installed on resume.

All seven actions emit `shortcut://action` with `{ action, state }`, where state
is pressed or released. Duplicate pressed events are suppressed. Rebinding and
suspending emit releases for held actions. A failed registration rolls back to
the previous bindings; conflicts with other apps return a user-safe error.

Windows defaults in `core/shortcuts.ts`:

- dictate: Ctrl+Alt+Space
- holdToTalk: Ctrl+Alt+H
- meeting: Ctrl+Alt+M
- screenshotArea: Ctrl+Alt+4
- screenshotWindow: Ctrl+Alt+5
- screenshotScreen: Ctrl+Alt+3
- pasteLast: Ctrl+Alt+V

These avoid the Windows key and reserved combinations such as Alt+Space. Other
apps or keyboard layouts can still claim a combination, so registration errors
must be surfaced. `ShortcutInterpreter` returns capture intents: a dictate tap
starts/toggles, holding for at least 350 ms finishes on release; holdToTalk always
finishes on release. The caller treats pending capture startup as recording and
implements a pending finish if release arrives before startup completes, as in
Swift. reset clears input state when replacing the interpreter.

## Calendar

Commands:

- `calendar_refresh() -> Result<Vec<CalendarEvent>, String>` (async).
- `calendar_decision(occurrence_id: String, decision: String) -> Result<(), String>`;
  JS `{ occurrenceId, decision }`.

Decisions are start, decline/skip/notHappening, allow, finish and extend. start is
explicit Yes and may enable live transcription. Decline/skip/notHappening skips
that occurrence and stops its tracked capture without further processing.
finish uses the capture's normal summarize preference. extend changes only the
tracked local end to max(previousEnd, now) + 15 minutes. allow clears handled
only if the occurrence was skipped, preserving the Swift policy.

Events:

- `calendar://prompt-start` and `calendar://prompt-end`: `{ event, kind, deadline,
  automatic, message }`. Dates, including deadline, are ISO strings. Match the
  types in core/calendarPolicy.ts. Both countdowns are 60 seconds.
- `calendar://prompt-closed`: `{ occurrenceId, kind }`. This supplemental event
  lets UI dismiss prompts on sleep/inactivity, stalled timers, settings changes,
  refresh cancellation, decisions and automatic actions. Subscribe alongside
  the two prompt events. A change to automatic emits a close followed by the
  revised prompt with the original deadline.
- `calendar://error`: a user-safe string for background refresh/policy failures.

The lib.rs setup starts a 5-minute subscription poll and 1-second policy tick.
calendarSources are selected subscriptions, each with id, name and exactly one
of url/file. Refresh returns a one-day horizon, including starts in the last
two minutes, even if watching is disabled. Source errors clear stale start
candidates/prompts; they do not stop an already tracked local capture.

**Required meeting integration:** install an `Arc<dyn CalendarCapture>` with
`calendar::set_capture_adapter(app.handle(), adapter)` during setup after managing
CalendarState. The adapter supplies synchronous status, start and finish:

- status.active_id is the actual active meeting ID; dictation_busy includes
  startup and processing, and meeting_busy includes asynchronous transitions.
- status.session_active must be false while sleeping, locked or inactive.
- status.unattended_ready is true only when microphone/system audio capture can
  start without requesting permission. Automatic starts must fail if false.
- start receives title, microphone=true, system_audio=true, summarize_on_stop
  and live_transcription; it returns the actual started ID, or an error. It must
  reserve/set the active capture before returning and must not reenter calendar.
- finish receives Some(false) for decline/disable/exclusion, or None for normal
  stop. Busy captures defer finish. Update status before returning so the policy
  cannot issue another end prompt while stopping.

There is intentionally no dummy audio recorder or permissive permission default.
Without this adapter calendar sources can be refreshed, but automation cannot
prompt or start recording. The meeting owner/integrator must wire the adapter
and session/permission state; those files are outside Codex-B ownership.

Unattended starts always keep liveTranscription=false. Decisions are persisted
atomically in app_data_dir/calendar-decisions.json before showing a start prompt,
pruned after seven days and restored at boot. Unreadable history is backed up and
automation remains blocked; failed writes never show the unpersisted prompt.
Restart after repairing a damaged decision file. Sleep or a tick gap over ten
seconds cancels a missed start countdown. Recovery never restarts capture.
Disabling watching, removing its source or excluding its title stops a tracked
recording with summarize=false, including after a busy transition finishes.

Parsing uses [ical 0.11](https://docs.rs/ical/0.11.0/ical/) for RFC5545 property
unfolding/parameters and [rrule 0.14](https://docs.rs/rrule/0.14.0/rrule/) for
validated timezone-aware recurrence expansion. This avoids hand-writing RRULE
semantics. Supports RRULE, RDATE, EXDATE and single RECURRENCE-ID moved/cancelled
overrides; moved overrides inherit missing metadata/duration. Occurrence IDs
combine source, UID and original recurrence time so a moved occurrence retains
its decision. Expansion is bounded to 4096 results and subscriptions to 8 MB.

ICS-specific limits (EventKit supplies these details natively on macOS):

- IANA TZIDs, standard Windows TZIDs (via windows-timezones' CLDR mapping) and
  floating/local dates are supported, including DST and X-WR-TIMEZONE.
  Arbitrary VTIMEZONE definitions and
  RANGE=THISANDFUTURE overrides return explicit errors rather than wrong times.
- ICS lacks EventKit's isCurrentUser. When an exported calendar name/ID identifies
  its owner email, only that attendee's decline excludes the event. Otherwise
  any declined attendee conservatively excludes it; this can hide an event with
  a declined guest. No user identity is guessed from credentials.
- Agenda/month UI, native lock/sleep observers and real capture live in the
  other agents' files; the adapter and prompt events are their integration seam.

## Shared-file additions

lib.rs only adds module declarations, ShortcutManager/CalendarState managed state,
calendar boot and the five commands. No capabilities or tauri.conf.json edits.
Rust-side shortcut registration uses the existing global-shortcut plugin.

Cargo.toml additions (Cargo.lock updated):

```toml
chrono = { version = "0.4", features = ["serde"] }
ical = { version = "0.11", default-features = false, features = ["ical"] }
rrule = "0.14"
regex = "1"
fancy-regex = "0.16"
os-spellcheck = "0.2"
chrono-tz = "0.10"
windows-timezones = { version = "0.5", default-features = false, features = ["std"] }
```

Tests exercise Swift dictionary fixtures and prompt equality, request encoding
without contacting providers, toggle/learning behavior, shortcut validation and
tap/hold, daily-note/timeline/local-day behavior, ICS recurrence/timezones/declines,
persisted decisions, local subscriptions, and the calendar state transitions with
mock capture status. No real audio recording, calendar credentials or remote
classifier calls were used during these checks.
