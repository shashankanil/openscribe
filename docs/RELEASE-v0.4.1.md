OpenScribe v0.4.1 makes frequent dictation easier to browse and simplifies how the menu bar and API settings work.

### Changes

- Dictations from the same local calendar day join one editable daily note. New captures append as paragraphs, preserving your edits and custom note title. Manually written notes stay separate.
- Daily notes show capture count, total recorded time, time range, and source apps. Activity details retain each capture's timestamp, original transcript, duration, and source, with a copy action for individual captures.
- Existing dictations are grouped automatically. An exact backup of the original history is saved before migration; failed backups block writes to protect existing data. Pins, tags, edits, original titles, and capture identities are retained.
- The menu bar icon opens its popup without activating the main workspace. Home opens Notes in the full app, and Settings opens the full settings workspace.
- Transcription and Writing now share one API & Models destination. Both providers, keys, models, and related behaviors are managed there; existing connections are preserved.
- Paste latest and automatic pasting use the latest capture, so a full day's note is never pasted by a single dictation.

### Reliability

Pending editor saves merge newly arrived captures instead of overwriting them. Recovery remains idempotent per capture, and a recovery job completes only after that specific capture reaches disk. Intentionally cleared text stays cleared when subsequent dictations arrive.

### Install

Download the DMG for the app and installer, or the ZIP for the app alone. Quit OpenScribe after finishing any recording, then replace the app in Applications. Existing settings, provider keys, notes, and meeting history stay in their existing local profile. SHA-256 checksums are included.

Requires an Apple silicon Mac running macOS 14 or later. The app uses the same Apple Development signing identity as v0.4.0 and is not notarized. Local signing guidance is available in the [v0.2.0 release notes](https://github.com/shashankanil/openscribe/releases/tag/v0.2.0).

### Validation

84 automated tests pass in the release configuration, including daily grouping and midnight boundaries, legacy migration and backup preservation, stale-editor merging, capture recovery, latest-capture selection, and light/dark rendering at standard and compact window sizes. Native checks cover the daily editor, activity details, unified API settings, and autosave across navigation and relaunch. Live provider recording and hardware disconnects are outside this validation.
