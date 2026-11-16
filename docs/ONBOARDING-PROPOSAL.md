# Onboarding proposal

Status: research + design only. No app code was changed. Mockup: `/private/tmp/claude-501/-Users-shashank-Documents-OpenScribe/2bbc529d-29fc-49cd-8e98-920b7ef0aa2b/scratchpad/onboarding/mockup.html` (light/dark toggle).

Evidence note: current-state findings come from reading the code and from rendering the Welcome step (the other steps can't be rendered today because `step` is private `@State`; see Implementation §7). Competitor claims cite sources at the end; I could not find verifiable first-run documentation for Arc, Linear, Bartender or CleanShot X, so none of them is relied on.

## 1. What is wrong today

| # | Problem | Where |
|---|---|---|
| 1 | **The first thing a new user does is read.** Welcome is a headline plus three generic bullets (“Speak, don’t type”, “Stay in control”…). The third bullet leads with “Bring your own provider keys”, i.e. the biggest hurdle, before any value. | `OnboardingView.swift:99-110` |
| 2 | **Wrong container.** Onboarding replaces the workspace inside the 1080×720 / 900×620-min window. A 620pt card floats in a large empty window; stepper pills, tagline and “Set up later” add chrome around very little content. | `MainWorkspaceView.swift:44-45,58`; `OnboardingView.swift:25,59,62` |
| 3 | **The key step is the heaviest screen and is front-loaded.** “Connect provider…” opens a 675×552 sheet with a 195pt provider sidebar, model ID field, endpoint and an Advanced disclosure. Users must understand providers, models and endpoints before they have heard their own words recognized. | `OnboardingView.swift:112-119`; `ProviderKeyEditor.swift:84-158` |
| 4 | **The key is never checked.** “Saving stores the key. Provider access is checked when you use it.” A mistyped key unlocks Continue, then fails at the first practice recording. | `ProviderKeyEditor.swift:187`; `OnboardingView.swift:95` |
| 5 | **Accessibility is mis-explained and over-required.** Row says “Paste into apps and use your shortcut”, but the default shortcut is a Carbon hot key that needs no Accessibility (`Shortcuts.swift` registration comment); only paste (`TextInjector.swift:10`) and the Globe key need it. Yet `canDictate` blocks on it whenever `pasteEnabled` (default true), so users can’t finish without either granting it or finding the ghost button “Use Notes only for now / Notes-only mode selected”, whose label describes state, not action. | `OnboardingView.swift:135,147-149`; `SetupReadiness.swift:8`; `Models.swift:350` |
| 6 | **Permission UX is bare.** “Open Settings” with a sentence of text; no visual of what to toggle; the prompt for Accessibility is never requested (`prompt: false`), so on a fresh install OpenScribe may not even be in the list and users must click “+”. The “enabled but still not working?” recovery exists only in the Permissions page, not here. | `PermissionCenter.swift:36,67-70`; `PermissionsView.swift:48-54` |
| 7 | **The first win doesn’t teach the product.** Practice is a button; the shortcut is a run-on 12pt line (“tap to start and stop, or hold to talk”). The user never presses the hotkey, never sees the Flowbar, and the result is a note in Notes rather than text appearing where they type. | `OnboardingView.swift:154-185` |
| 8 | **Flowbar is never introduced**, though it is the primary surface in v0.5.0 (“Can’t find it? Use Show me the Flowbar”). Launch-at-login is a bare toggle at the bottom of the practice step. | `OnboardingView.swift:181-183`; `docs/RELEASE-v0.5.0.md` |
| 9 | **Re-onboarding is a full-window takeover.** Any launch where `!canDictate` (e.g. mic revoked, key removed) reopens onboarding; a dictation attempt with no key also calls `showOnboarding()`. “Set up later” doesn’t persist anything, so it nags again next launch. | `AppController.swift:160-164,~205-210`; `SetupReadiness.swift:9-11`; `OnboardingView.swift:23` |
| 10 | **Meetings, screenshots, calendar and (new) MCP/cloud are invisible** until the user finds Settings → Permissions. | `PermissionsView.swift:56-70` |
| 11 | **Copy is vague.** Step titles “Access” and “Try it” say nothing; “A little access. A lot less typing.” is cute rather than informative. | `OnboardingView.swift:29,123` |

What is already good and should be kept: live permission detection (`didBecomeActive` + 700ms poll, `PermissionCenter.swift:22-24`, `OnboardingView.swift:71-77`), the 60s mic-prompt timeout, resume-from-facts (`onAppear`, `OnboardingView.swift:67`), practice never pasting into other apps (`AppController` `onboardingVisible`), launch at login on by default, and the `FlowTheme` look.

## 2. What the best apps do (and what it means here)

| Pattern | Evidence | Take-away |
|---|---|---|
| Few steps, one job each. Wispr Flow Mac: install → sign in → Microphone + Accessibility → questions → mic test → shortcut → practice demos. Superwhisper: 4 steps (permissions → mic/shortcut → first dictation). Granola: sign in → calendar → audio → 2-min demo meeting. | [Wispr setup](https://docs.wisprflow.ai/articles/3152211871-setup-guide), [Superwhisper quickstart](https://superwhisper.com/docs/get-started/quickstart), [Granola setup](https://docs.granola.ai/help-center/getting-started/setting-up-granola-for-the-first-time) | Target 4 working steps. Wispr’s 8 is the ceiling, not the goal. |
| Core permissions in-flow, optional ones labelled optional/deferred. Superwhisper lists System audio as “optional” in the same step; Granola asks audio only after sign-in; Raycast asks Calendar/Contacts at first use of the feature. | Superwhisper, Granola (above); [Raycast manual / guides](https://manual.raycast.com/troubleshooting.md) | Mic (+ Accessibility, optional) at setup; Screen & System Audio and Calendar just-in-time. |
| Skipping Accessibility is allowed but costs paste. Wispr: “Accessibility permission is required to insert text”; setup still continues. | [Wispr setup](https://docs.wisprflow.ai/articles/3152211871-setup-guide) | Let users finish without it; degrade to Notes + explain what they lose. |
| Reassuring wording for Screen & System Audio. Limitless: permission is for audio, “we do not capture anything on your screen”, and macOS names it differently by version (Screen Recording / Screen & System Audio / System Audio Recording Only). Granola: “Granola does not record your screen.” | [Limitless](https://help.limitless.ai/en/articles/9123953-what-permissions-does-limitless-need-in-the-mac-app), Granola (above) | Use the plain-English primer; match the current pane name. macOS may re-prompt periodically ([MacRumors](https://www.macrumors.com/2024/08/15/macos-sequoia-screen-recording-app-permissions/)); say so. |
| Apple: don’t ask at launch unless required; give context, optionally with a custom screen before the system alert. | [Apple HIG – Privacy / Accessing private data](https://developer.apple.com/design/human-interface-guidelines/privacy.md) | Pre-prime with one sentence + one button, then fire the real prompt. |
| Hotkey is learned by doing: Wispr’s step 8 has you press the shortcut and speak; Superwhisper ends with “hold your shortcut, speak, and let go”. | Wispr, Superwhisper (above) | Practice must use the real global shortcut. |
| Hold vs hands-free: Wispr — hold to talk, or double-tap within 0.5s for hands-free; taps under 0.5s don’t paste; Esc cancels. | [Wispr hands-free](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free), [first dictation](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation) | OpenScribe already has tap = hands-free toggle, hold ≥ 0.35s = push-to-talk (`AppController.swift:569`). Teach both as two check-offs; mention Esc. |
| Hosted default vs BYO key. Wispr, Granola and Superwhisper all use a hosted model so users never see a key; MacWhisper’s AI features require your own OpenAI key. | Setup pages above; [MacWhisper docs](https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature) | OpenScribe is BYO-key, so the key step is the biggest friction: make it one inline field, verify it, explain cost, and keep a slot for a future hosted default. |
| Sign-in is part of setup only when the product is hosted (Wispr: “Dictation cannot start while signed out”; Granola requires it). | Wispr, Granola | OpenScribe works without an account, so sign-in belongs to the optional cloud/MCP feature, not first run. |
| Resume safely. Wispr: “reopen Flow to resume where you left off.” Superwhisper: skipped permissions are fixed later in System Settings. | Wispr, Superwhisper | Resume by facts (already how `onAppear` works); add in-app repair, not just a pointer to System Settings. |
| Raycast’s default is also ⌥ Space, and macOS won’t let two apps share a hotkey. | [Raycast hotkey guides](https://manual.raycast.com/settings) | Our default `.optionSpace` will collide with many target users. Detect and offer an alternative on the Try-it step. |

Not found / unverified: MacWhisper’s own permission wizard, Notion Calendar’s first-run screens (only third-party guides), Rewind/Limitless onboarding beyond the permissions article, Arc, Linear, Bartender, CleanShot X.

## 3. Proposed flow

Principles: first win before configuration where possible; only mic + key are required; one idea per screen; everything else is deferred and explained at the moment of need; no re-onboarding modals later.

Window: a dedicated **760×560** non-resizable panel (hidden title bar, same `FlowTheme` chrome), centered, separate from the workspace. Progress is four dots, not labelled pills. Footer: Back (ghost) left, primary button right.

### Screen 1 — Welcome  *(no action)*
- Title: **Talk. It types.**
- Body: “Hold a key, say what you mean, and OpenScribe writes it wherever your cursor is. Setup takes about a minute.”
- Visual: faux mail field with typed sentence + Flowbar “Listening” pill (animated `RecorderSquiggle`).
- Footer note: “Your audio goes only to the provider you choose. Notes stay on this Mac.”
- Button: **Get started**. No “Set up later” here; the window close button is the exit.

### Screen 2 — Microphone  *(required)*
- Eyebrow: “Step 1 of 4”. Title: **Let’s make sure we can hear you**.
- Body: “OpenScribe listens only while you’re recording. macOS will ask once.”
- Before grant: one primary button **Allow microphone** (fires `requestMicrophonePermission()`).
- After grant: green check, device name, **live level meter**, “Say something — the bars should move. Wrong mic? Change input” (`MicrophoneDevice.swift`). Continue enabled.
- Denied earlier (`microphoneNeedsSettings`): title becomes “Microphone is off for OpenScribe”; body “macOS only asks once. Open Privacy & Security › Microphone and switch OpenScribe on. We’ll continue automatically.”; button **Open System Settings**; badge “Waiting…”. Auto-advance when `didBecomeActive` sees `.authorized`.

### Screen 3 — Connect  *(required)*
- Title: **Connect a speech provider**.
- Body: “OpenScribe sends audio straight to a service you pick — no OpenScribe servers in between. One key covers transcription, cleanup and summaries.” (true for OpenRouter and OpenAI, which exist in both `SpeechProvider` and `LanguageModelProvider`; for other providers show “Cleanup and summaries can use a separate key later.”)
- Provider chips: **OpenRouter (EASIEST)**, OpenAI, Groq, More… (More opens the existing editor sheet). Default selection = current default (`speechProvider = .openRouter`, `Models.swift:290`).
- API key field (secure) with “Get a key ↗” (`ProviderLinks.keyURL`).
- On Continue: verify with a real lightweight request. States: *Checking…* → “✓ Key works” and auto-advance; 401/403 → “OpenRouter rejected this key (401). Check it and try again, or get a new key.”; offline → “Couldn’t reach OpenRouter. Save anyway?” (button **Save anyway**).
- Below: model name + “Advanced” (opens `ProviderConnectionEditor`). Footnote: “Stored on this Mac in a permission-restricted file. Typical cost: a few cents per hour of speech.” (confirm the figure per provider before shipping; omit if unsure).
- Future slot: a second card “Use OpenScribe Cloud — sign in with Google” if a hosted transcription default ever ships. Not now.

### Screen 4 — Try it  *(the first win)*
- Title: **Now say something**. Body: “Hold ⌥ Space, speak, let go. This works in every app.” (keycaps from `settings.dictationHint`; text adapts to the user’s binding.)
- Field “Your first dictation” fills with the transcript (in-window, so no Accessibility needed; reuses today’s behavior where `onboardingVisible` forces `pasteIntoFocusedApp = false`, `AppController.swift:255`).
- Two check-offs: **Hold to talk — release to finish** (✓ when a recording ≥ 0.35s completes), **Tap for hands-free — tap to start, tap to stop** (✓ on a short tap start + second tap stop). Second is optional; Continue enables after the first.
- Footer tip: “Esc cancels a recording.”
- Click-to-record button remains as a fallback below the keycaps (“No keyboard handy? **Record**”).
- Hotkey conflict (`hotkeyFailures.contains(.dictate)`): inline warning “⌥ Space is already used by another app (Raycast uses it by default).” with one-tap alternatives (⌃ Space, Globe if available) and “Record my own…” (existing recorder in Shortcuts settings).
- Failure (bad key/network): reuse `NoticeBubble` text and a **Check my key** button that goes back to Screen 3.

### Screen 5 — Paste into any app  *(optional, skippable)*
- Eyebrow: “Step 4 of 4 · optional”. Title: **Paste into any app**.
- Body: “Right now your words land here. Allow Accessibility and OpenScribe types them wherever your cursor is — Mail, Slack, your editor.”
- Visual: mini System Settings list with the OpenScribe row toggled.
- Primary **Open System Settings** → calls `AXIsProcessTrustedWithOptions(prompt: true)` once (adds OpenScribe to the list and shows Apple’s own dialog), then `openAccessibilitySettings()` + existing polling. Status: “Waiting… We’ll notice the moment you switch it on.” On grant: ✓, then auto-advance.
- Ghost **Skip — keep text in Notes**: sets `pasteIntoFocusedApp = false`, no scolding. Footnote under the skip: “You can turn this on any time in Permissions.”
- Disclosure “Switched on but not working?”: reuse the remove/re-add + **Restart OpenScribe** text from `PermissionsView.swift:48-54`.

### Screen 6 — Done / Meet the Flowbar  *(no action)*
- Title: **You’re set. Meet the Flowbar.**
- Illustration: desktop with the idle sliver; callouts “Hover for actions” (dictate · meeting · screenshot) and “Drag it anywhere” (from `docs/RELEASE-v0.5.0.md`).
- Toggle: “Launch OpenScribe at login so the Flowbar is always there” (default on, as today; hidden when `!LoginItem.isAvailable`).
- Three “next” cards (links, not steps): **Meetings** — “Record calls, get summaries. Asks for system audio the first time.” · **Screenshots** — “⌥⇧4 sends them to today’s note.” · **Use your notes in AI** — “Claude, ChatGPT, Cursor via MCP.”
- Footer: “Lost it? Menu bar › Show me the Flowbar”. Button **Open OpenScribe**.
- Also trigger `revealFlowbar()` (`AppController.swift:1010`) on arrival so the pill visibly appears.

### Required vs deferred

| Item | When | Why |
|---|---|---|
| Microphone, speech key | Setup (required) | Dictation can’t work without them. |
| Accessibility | Setup, skippable | Only needed to paste into other apps (and Globe). |
| Launch at login | Done screen | Keep existing default. |
| Cleanup / summary key | Later; auto-reuses same key when provider matches | Already optional (`OnboardingView.swift:218`). |
| Screen & System Audio | First meeting or first screenshot | Biggest “why does it want this?” permission; explain in context. |
| Calendar | First time user opens Calendar or enables meeting prompts | Already requested on demand (`PermissionsView.swift:65`). |
| Dictionary / personalization | First correction, or Personalization tab | No need up front. |
| Cloud sign-in / MCP | “Use your notes in AI” card + Settings | Optional; see below. |

### Just-in-time primers (deferred permissions)
One reusable sheet, `PermissionPrimer`, shown the first time a feature needs a missing permission:
- **Screen & System Audio** — Title “Capture the other side of your calls”. Body: “macOS lists this as *Screen & System Audio Recording*. OpenScribe uses it for call audio and for screenshots you take with a shortcut — it never records your screen in the background. macOS may ask you to re-confirm it from time to time.” Buttons: **Allow** / Not now. First time → `CGRequestScreenCaptureAccess()`; if already denied → open `Privacy_ScreenCapture`.
- **Calendar** — “See your meetings and get a prompt before they start. OpenScribe only reads events; it never changes them.” Button **Allow** → `calendar.requestAccess()`.
- Naming differs by macOS version (Limitless documents the variants); use pane text from `ProcessInfo` OS version if it matters, otherwise “Screen & System Audio Recording”.

### Optional sign-in (cloud + MCP)
Not in first run: the app works fully without an account, and sync is off by default per `docs/CONTEXT-API.md`. The “Use your notes in AI” card opens a two-option sheet:
1. **On this Mac** — local MCP: “Local MCP server. No account, nothing leaves your Mac.” Button **Copy config** (path to `openscribe-mcp`, per `docs/CONTEXT-API.md`).
2. **From anywhere** — remote MCP: “Sync to a private remote MCP. Sign in with Google. Off until you turn it on.” Button **Continue with Google** → `/app/login?redirect_uri=openscribe://auth&state=…` (already specified in the API contract). Show signed-in email, document count, **Sign out** and **Delete synced data**.

## 4. Edge cases

| Case | Behavior |
|---|---|
| **Returning user** (`setup-completed-v3`, or `permission-onboarding-seen-v2` + can dictate) | Never shown. Optionally a one-time dismissible “New: use your notes in AI” banner after the MCP release. |
| **Quit mid-setup** | Resume by facts, not by index: first unmet required item among mic → key; if both met and setup flag unset, resume at Try it. Persist `onboarding-v4-step` only for Try it / Paste screens. |
| **Mic denied / restricted** | Mic screen switches to the “open Settings” variant; auto-advances on activation. `.restricted` (MDM): “Your Mac’s administrator has blocked the microphone” with no button. |
| **Mic prompt dismissed with no answer** | Existing 60s timeout (`PermissionCenter.swift:57`) re-enables the button. |
| **Key invalid / offline** | Inline error + **Save anyway**; failure on first dictation shows **Check my key**. |
| **Hotkey collides (Raycast ⌥ Space)** | Inline warning and alternatives on Try it. |
| **Accessibility skipped** | `pasteIntoFocusedApp = false`; dictation saves to Notes. Settings → Permissions and the Flowbar notice offer **Enable paste into other apps**. First dictation attempt while paste is on but access missing shows a one-line notice (“Paste is off — Accessibility isn’t allowed. Text was saved to Notes.” + **Fix**). |
| **Accessibility granted but not working** | “Switched on but not working?” disclosure + **Restart OpenScribe**. |
| **Not installed in /Applications** | Hide launch-at-login; add note “Move OpenScribe to Applications first so permissions stick” on the Accessibility screen (`LoginItem.isAvailable`). |
| **Permission revoked later** | No takeover at launch. Workspace shows a `FlowBanner` (“Microphone access was turned off — Dictation is paused. [Open System Settings]”); the Flowbar shows a notice; `startCapture` goes straight to the Permissions page (already the case for mic). |
| **Key removed later** | Same banner pattern (“Add a speech key to dictate”) linking to Settings → Connections; no onboarding takeover. Hotkey press shows a notice instead of `showOnboarding()`. |
| **Screen & System Audio denied or monthly re-confirm** | Primer re-appears only at point of use; Permissions page shows current state. If a grant requires relaunch on the user’s macOS version, show **Restart OpenScribe** (verify on macOS 14, 15 and 26; I did not confirm this). |
| **`--onboarding` flag / debug** | Still forces the flow for testing; ignore persisted step. |
| **Reduce Motion** | Replace pulsing/animation with static states (mockup respects `prefers-reduced-motion`). |
| **VoiceOver / keyboard** | Return = primary, Esc = Back on screens 2-5; all status changes announced (“Microphone allowed”, “Waiting for Accessibility”). |

## 5. Implementation notes (mapped to the code)

1. **Window.** Add `AppController.showOnboarding()` → new `onboardingWindow` (760×560, `[.titled, .closable, .fullSizeContentView]`, transparent title bar like `openMainWindow`, `AppController.swift:446-465`), hosting `OnboardingView`. Remove the `onboardingVisible` branch from `MainWorkspaceView.swift:44-45` (or keep it only for tests). `finishOnboarding()` closes it and opens the workspace. Keep `onboardingVisible` since `startCapture` relies on it (`AppController.swift:255`).
2. **Steps as data.** `enum OnboardingStep { welcome, microphone, connect, tryIt, paste, done }` with `static func resume(from: SetupReadiness, completed: Bool) -> OnboardingStep`. `OnboardingView` gains `init(controller:, initialStep:)` for previews and tests. Replace the stepper (`OnboardingView.swift:28-41`) with a 4-dot `OnboardingProgress` view.
3. **Readiness split.** In `SetupReadiness.swift`: `canDictate = microphone && speechKey`; new `canPasteAnywhere = accessibility`; `shouldPresent(completed:explicitlyRequested:)` returns `explicitlyRequested || !completed`. Anything missing after completion becomes a banner/notice, fixing problem 9. Update tests in `ExperienceTests.swift` (fresh/incomplete/Notes-only cases listed in `docs/EXPERIENCE.md`).
4. **Permissions.** In `PermissionCenter.swift`:
   - `requestAccessibilityPrompt()` → `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` then existing `beginAccessibilityMonitoring()`.
   - Add `screenRecordingGranted` (`CGPreflightScreenCaptureAccess`) and `calendarStatus` as `@Published`, refreshed in the same `didBecomeActive` hook; delete the duplicated polling in `PermissionsView.swift:80-85,100-110`.
   - `requestScreenRecording()` → `CGRequestScreenCaptureAccess()` then open `Privacy_ScreenCapture` if still denied.
5. **Connect step.** New `OnboardingConnectStep` using `ProviderConnectionDraft` + `controller.saveConnection(draft, key:, reuseKey:)` (already used by `ProviderConnectionEditor.save()`, `ProviderKeyEditor.swift:223-228`). For providers present in both enums, save the language-model credential too via the existing `reuseKey` path. Add `ProviderClient.verify(settings:key:)` (a minimal authenticated request per provider: list models for OpenAI-compatible endpoints; the provider’s cheapest auth’d GET for Deepgram/AssemblyAI) returning `.ok / .unauthorized / .unreachable`. Keep the old `ProviderConnectionCard` for Settings → Connections.
6. **Try-it step.** Observe `controller.capturePhase`, `currentTranscript`, `captureHint` and `hotkeyFailures` (all `@Published` on `AppController`). To check off hold vs tap, expose the gesture in `AppController`: in `shortcutReleased(.dictate)` (`:593-597`) set `lastDictateGesture = .held` when `>= holdThreshold`, and `.tapped` otherwise; `OnboardingView` reads it. Reuse `FlowKeycaps`, `FlowBadge`, `RecorderSquiggle` (`OverlayPanel.swift:795`), `FlowSettingsRow`, `FlowBanner`. Add a `LevelMeter` (bars from `AudioRecorder` level) for the mic step.
7. **Preview/test coverage.** The existing render test only captures step 0 (`ExperienceTests.swift:82`; `step` is private `@State`). With `initialStep`, render all six steps × light/dark; add unit tests for `OnboardingStep.resume`, the readiness split, and key-verification states using a stubbed `URLProtocol` (pattern already in `ProviderClientTests`).
8. **Primers.** New `PermissionPrimer` sheet used from `MeetingsView.swift:~151`, `ScreenshotCapture.swift:44-45` (today it silently calls `CGRequestScreenCaptureAccess`), and `CalendarSettingsView.swift:~26`. Persist “primer seen” per permission in `UserDefaults`.
9. **Flowbar reveal.** Call `revealFlowbar()` on the Done screen; if the Flowbar is hidden by the user’s settings, the card text becomes “Turn it on in Settings → General → Flowbar”.
10. **Copy ownership.** Put strings in one `OnboardingCopy` enum so the doc, mockup and view stay in sync; fix inaccurate Permissions copy at the same time (`PermissionsView.swift:23,33` also say Accessibility enables “your global shortcut”).
11. **Docs.** Update `docs/EXPERIENCE.md` (“four-step setup… practice note”) and the verification section once built; keep the isolated-profile launch check (`OPENSCRIBE_TEST_PROFILE`).

Suggested build order: (3) readiness split → (1) window → (2) steps skeleton → (5) connect + verify → (6) try-it + gesture → (4) accessibility/primers → (8) deferred primers → copy and tests. Items 3 and 1 alone remove the most annoying behaviors.

## 6. Success measures
- Fresh install to first successful dictation: under 90 seconds with a key already copied.
- No path where the primary button is disabled without an on-screen reason.
- No full-window re-onboarding after first completion.
- Zero “where do I enable this?” dead ends: every permission screen has a button that goes to the right pane and detects the grant live.

## Sources
- Wispr Flow: [setup guide](https://docs.wisprflow.ai/articles/3152211871-setup-guide), [first dictation](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation), [hands-free](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free), [re-verify permissions](https://docs.wisprflow.ai/articles/5510622673-re-verify-wispr-flow-permissions-after-updating)
- Superwhisper: [quickstart](https://superwhisper.com/docs/get-started/quickstart)
- Granola: [setting up for the first time](https://docs.granola.ai/help-center/getting-started/setting-up-granola-for-the-first-time)
- MacWhisper: [dictation](https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature) (no permission details found)
- Limitless: [permissions in the Mac app](https://help.limitless.ai/en/articles/9123953-what-permissions-does-limitless-need-in-the-mac-app)
- Raycast: [manual](https://manual.raycast.com/settings), [troubleshooting](https://manual.raycast.com/troubleshooting.md) (hotkey and permissions, partly third-party reports)
- Apple: [HIG – Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy.md)
- macOS screen-recording re-confirmation: [MacRumors](https://www.macrumors.com/2024/08/15/macos-sequoia-screen-recording-app-permissions/), [9to5Mac](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/) (2024 beta-era reporting; current behavior not re-verified)
- Notion Calendar: only third-party guides found; not relied on.
