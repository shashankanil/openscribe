# Calendar meeting automation

The macOS dev app reads calendars using EventKit. Google calendars must first be added to macOS Internet Accounts with Calendars enabled; direct Google OAuth inside OpenScribe is not implemented. See [Google's Apple Calendar setup](https://support.google.com/calendar/answer/99358).

## Setup

1. Open Settings → Calendar → Add Google account. Add Google and enable Calendars in macOS.
2. Allow calendar access in OpenScribe and select the calendars to watch.
3. Enable Watch calendar meetings. Choose automatic start and automatic transcription independently. Grant microphone and Screen & System Audio Recording permissions before unattended starts.

At the scheduled start, eligible events trigger a floating 60-second prompt. The prompt asks “Do you want to record this meeting?” No skips this occurrence; Yes begins capture. When automatic start is on, no response starts microphone and system-audio recording. Automatic start skips missing permissions instead of leaving an unattended system permission request. Dictation, existing meetings, and processing block new calendar captures.

A small recording control panel remains available, with Not happening, Stop & save and Hide. Unanswered automatic starts keep audio local until stop. After an explicit Yes, live transcription can upload completed audio sections during recording. Not happening stops capture and any further processing; it cannot retract sections already sent by live mode. It is also available in the workspace banner and status-menu quick actions. At the original scheduled end, a 60-second prompt stops/saves automatically unless extended by 15 minutes. Automatic transcription follows the setting captured when recording began. Turning calendar watching off, deselecting the active calendar, or adding an exclusion for the active title also stops its recording locally.

## Opt-outs

- Calendar selection limits eligible accounts/calendars.
- Only events with guests or recognized Google Meet, Zoom, Teams or Webex links is on by default.
- Never record matching titles excludes case-insensitive title substrings, including future recurring occurrences.
- Skip this meeting excludes one event occurrence and persists across restarts. Allow removes that skip; it does not override a title rule.
- All-day, canceled and declined events are excluded.

## Limits and validation

This is schedule-based prompting, not active-call detection. It cannot confirm that a browser call is joined, distinguish participants, or detect an early call ending. Calendar syncing may be delayed. It only considers starts from the past two minutes, so launching late does not record an old meeting. Start decisions are persisted to avoid duplicate prompts after restart. Sleep/session inactivity cancels pending prompts, and a stalled timer never executes an expired countdown. The recording pipeline pauses on sleep; end prompts resume when the session returns. An end-time extension is local to the current app session; recovery never automatically restarts capture. Calendar event edits do not adjust the end time of a recording already started.

Tests cover candidate timing, calendar scope, title exclusions, link host validation, persisted occurrence skips and settings migration. Actual Google synchronization, macOS permission prompts and real-call capture require setup and hands-on validation on the user's Mac. No real calendar access or audio recording was performed by the assistant during development.

## Live transcription

Live transcription after Yes shares its preference with manual meeting capture. Completed WAV sections (about 15 seconds each) are uploaded serially while recording continues; only closed files are eligible. Each result is checkpointed before the next section. The transcript tab shows saved sections and live progress. Local-only mode remains available by disabling live transcription and processing after stop.

Stop finishes the audio immediately, waits for the current transcription request, and processes only missing sections. A live upload failure pauses uploads while audio continues to save; Retry live resumes. Temporary network/408/429/5xx failures retry up to three times within a three-minute per-section deadline. Invalid credentials are not retried. This is incremental file-based transcription across supported providers, not word-by-word WebSocket streaming. Ordinary dictation also transcribes closed sections during capture when Settings → Transcription → Transcribe while recording is enabled. It assembles and cleans the full result before pasting; cancellation stops further requests, but cannot retract already uploaded sections.
