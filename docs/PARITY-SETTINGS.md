# Settings and setup parity handoff

Implemented on `windows-parity`, without commits. Scope: `desktop/src/views/settings/**`, `desktop/src/views/OnboardingView.tsx`, this document. Existing root-owned changes in `ShortcutsSettings.tsx` were left untouched.

## Parent hookup

`SettingsView` keeps all existing props. `initialSection` now accepts every settings section. New optional props:

- `selectedSection?: SettingsSection` controls the displayed section. Values: `general`, `providers`, `shortcuts`, `personalize`, `calendar`, `privacy`, `permissions`.
- `onSectionChange?: (section: SettingsSection) => void`. Supply alongside controlled `selectedSection` so internal Edit shortcuts / Manage providers / Calendar buttons update the parent's flat sidebar.
- `hideNavigation?: boolean` hides the nested settings sidebar.
- `notesCount?: number`, `meetingsCount?: number`. Missing counts show unavailable, not a fabricated zero.
- `onRefreshInputs?: () => AudioInput[] | void | Promise<AudioInput[] | void>`. Returning devices updates locally; a void callback must update the existing `inputs` prop. Without a callback the refresh uses `native.listInputs()`.

Existing `onUpdateSettings`, `onClearNotesHistory`, `onRevealFlowbar` now accept `void | Promise<void>`. `onRefreshCalendar` also accepts a promise. Return the actual persistence promise and reject on failure: fire-and-forget or swallowed errors cannot tell the UI that a save failed. Provider and personalization editors stay open with their drafts and errors until confirmation of the save. Calendar drafts also clear only after confirmed save. Credential storage and settings are separate native calls: if the credential write succeeds but settings persistence fails, the editor retains its draft for retry; the stored credential is not deleted or exposed.

New `OnboardingView` required props:

```ts
settings: ParitySettings;
onUpdateSettings: (settings: ParitySettings) => void | Promise<void>;
onComplete: () => void | Promise<void>;
onLater: () => void | Promise<void>;
```

Optional onboarding props: `phase?: string` (pass the controller DictationPhase, default `idle`), `transcript?: string`, `captureHint?: string`. Parent must pass phase for correct Start/Stop/Cancel and busy state; pass the latest transcript if available. Root mounts the wizard and persists `hasCompletedSetup` only in `onComplete`. `onLater` dismisses without marking setup complete. Skip practice completes through the same callback. Navigation is disabled during capture. Practice dispatches `sendIntent({ action: 'dictate' })`; cancel uses `cancelDictation`. No local fake recording or transcript. Access continuation rechecks readiness. A saved transcription credential is checked with `hasCredential`, never retrieved into the UI. When continuing Connect with no writing credential, cleanup is disabled through the real settings save.

The exported `PermissionsView` optionally accepts `onReadinessChange?: (readiness: CaptureReadiness | null) => void` and `onOpenCalendar?: () => void`. Checks run on mount, window focus, and manual refresh. Failures clear readiness and show the native error.

## Native commands used

Helpers in `settings/settingsSupport.ts` invoke these real root-provided commands:

- `get_launch_at_login()` / `set_launch_at_login({ enabled })`
- `list_source_apps()` -> `{ id, name, path }[]`
- `capture_readiness()` -> `{ microphone, systemAudio, paste, calendar }`, each `{ ready, detail }`
- `open_windows_settings({ section: 'microphone' | 'sound' })`

Executable selection uses the existing dialog plugin's `open` with the `exe` filter. Selected paths and running-app IDs are lowercased. The editor also accepts an explicit executable identity. Values persist under `settings.appWritingTones`; root resolves the recording's foreground app and applies lowercase full path then executable name.

Credentials reuse the existing `native.hasCredential/saveCredential/copyCredential/removeCredential`, account scoping, and `providerKeys.ts` mismatch validation. Provider cards distinguish a saved key from tested provider access. Endpoints reject missing hosts, example.com, non-HTTP schemes and embedded credentials, matching `ProviderConnection.swift` validation. Model defaults and key-creation links use the existing provider registry / Swift reference URLs. No credential is logged or returned.

## Implemented parity and Windows differences

- `Sources/OpenScribe/SettingsView.swift` (`generalTab`, `connectionsTab`, `writingBehavior`, `privacyTab`, `ThemeChoice`): graphical System/Light/Dark choices, actual startup state/setter, microphone picker/refresh with unavailable selection retained, shortcuts navigation, remembered custom placement, provider cards/configure dialogs, segmented cleanup descriptions, tone, recording preferences, counts, provider disclosure and confirmed note deletion. Clear failure leaves the confirmation open; meetings and keys are explicitly retained.
- `Sources/OpenScribe/ProviderKeyEditor.swift`: independent transcription/writing connections, key replacement/reuse/removal confirmation, draft settings, default model preset and provider-key links. Save awaits settings persistence before closing.
- `Sources/OpenScribe/PersonalizationView.swift`: vocabulary editor with case-insensitive deduplication; correction/snippet/app-style create/edit/remove dialogs; blank input and duplicate normalized snippet validation; uppercase new IDs; correction replacement semantics; exact snippet internal text; default/app tone. Smart correction controls remain available. Speech hint availability/details follow `SmartDictionary.swift` rather than claiming support for arbitrary models.
- `Sources/OpenScribe/OnboardingView.swift`: Welcome/Connect/Access/Try it, later/skip, real saved credential/readiness checks, Notes-only fallback, practice action, actual startup setting. The four steps are available even for an already-configured profile; root decides when to mount setup.
- `Sources/OpenScribe/PermissionsView.swift`: macOS Accessibility, Screen Recording, Calendar grants, app-bundle selection, Login Items approval, and macOS restart repair are not Windows actions. Windows checks actual microphone/output/input readiness, opens microphone/sound Settings, and uses executable paths. Calendar is labeled **Sources configured**, explicitly not a permission or network check; Calendar refresh validates feed access. No macOS permission buttons pretend to grant access.

## Runtime gaps outside UI ownership

`ProviderKeyEditor.swift` also exposes `automaticStreaming` and streaming model presets (`ProviderConnection.swift`, `StreamingCapability.swift`). The current desktop shared settings contract does not declare `automaticStreaming`, and the dictation runtime has no selectable provider streaming transport. This UI does not offer a nonfunctional streaming switch. Root must decide/implement the shared setting and runtime before this can be called complete parity for that additional feature; ordinary live-transcription settings remain available. Platform permission differences above are intentional; streaming is a runtime gap, not a Windows limitation.

No changes made to App/controller/types/events/native/Rust or Swift. No cargo, full project build, or full suite was run, per task instructions; root owns combined checks. Browser/native runtime visual interaction has not been verified here.

## Focused validation

From `desktop`:

```
pnpm exec vitest run src/views/settings/personalizationDraft.test.ts src/views/settings/providerKeys.test.ts src/views/settings/settingsSupport.test.ts src/views/settings/settingsViews.test.tsx
```

Final result: 4 test files passed, 22 tests passed (vitest v3.2.7, 2026-10-22 18:31:53, duration 3.86s). Coverage includes vocabulary deduplication, normalized snippet duplicates, stable IDs and multiline text, replacement corrections, immutable/lowercase app identities, required fields, Notes-only readiness gating, endpoint validation, controlled navigation, unknown readiness, retained Flowbar placement/unavailable microphones, and setup entry rendering. Settings-support tests also verify exact invoke arguments, propagated errors and speech-hint availability.

## Follow-up polish (2026-10-22)

No parent/shared edits or new props. The mounted onboarding now listens to the existing `workspace://confirmation` payload `{message, id}` and recognizes only controller `Saved` / `Cancelled` messages while a practice attempt is active. Dispatching `dictate`, returning to idle, or receiving an unrelated confirmation never establishes success. A cancelled attempt, dispatch failure, changed controller error notice, or delayed recording error suppresses both the success message and transcript preview. The static practice text describes successful processing rather than claiming every recording has been saved. Confirmed-save text may be the latest note text supplied by the parent.

The transcription credential and capture readiness are rechecked before Access continuation, each practice start, and setup completion (including Skip practice). Try it refreshes on entry and window focus; native failures clear readiness. A device-check error does not falsely report that the saved provider credential has been removed. No microphone/paste readiness is inferred from emitting an intent. Optional calendar and system audio remain optional for dictation. Notes-only mode still bypasses only paste readiness.

Strict UTF-8 and mojibake scanning passed for 21 owned source/test files; no remaining replacement-character or question-mark separator damage was found. Rendered-settings regression coverage checks for common mojibake and damaged separators.

Final focused run: `pnpm exec vitest run src/views/settings` with vitest v3.2.7: **6 test files passed, 36 tests passed**, 2026-10-22 20:10:16, duration 4.67s. Added practice tests cover intent-only/idle states, confirmed saves, cancellation, controller errors (including delayed errors), unrelated confirmations, shortcut starts, retry attempts, and fresh credential/device checks. Scoped `git diff --check` passed. No commit, global build, cargo invocation, or shared edits.
