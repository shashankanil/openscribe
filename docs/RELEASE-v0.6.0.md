OpenScribe v0.6.0 brings your notes and meetings to Claude, ChatGPT and other AI apps, updates itself, and makes shortcuts, the Flowbar and setup feel a lot less fiddly.

### Use your notes in AI

- **On this Mac:** Settings → AI & MCP adds OpenScribe to Claude Desktop in one click, and gives you a command for Claude Code and a config for Cursor and other MCP apps. It works offline, needs no account, and is read-only.
- **Anywhere, with OpenScribe Cloud:** sign in with Google to keep a private copy of your notes and meetings, then add the connector URL to claude.ai or ChatGPT. Nothing is uploaded until you sign in, only changed items sync, and **Delete cloud data** removes everything from the server.
- AI apps can search, read a note or meeting, list recent items, get a meeting's summary and transcript, and list action items. They can't change or delete anything.

### Updates without reinstalling

- OpenScribe checks for new versions every few hours and downloads them in the background. When one is ready, choose **Install and relaunch** from the menu bar, the quick panel or Settings → General, or just quit and it installs on the way out. It never restarts while you're recording.
- This is the last release you need to install by hand.

### Shortcuts that work

- Shortcuts now work on macOS 15 and later, including the ⌥ Space and ⌥⇧ defaults, once Accessibility is allowed.
- Use any key combination, an F-key, or a single modifier on its own such as Right ⌘, Right ⌥ or Globe.
- Give an action several shortcuts. Click a shortcut to change it, × to remove it, or + to add another.
- **Push to talk:** hold to talk, or double-tap to keep going hands-free and press once more to finish.
- Taps shorter than half a second, and a few seconds of silence, are ignored instead of showing an error.

### Flowbar and notices

- In a meeting, the stop button stays exactly where it is when you hover. The notes and screenshot buttons slide in from the other end.
- Notices are larger and easier to read, with a close button that's always visible, and they stay open while you hover them.

### Calendar meetings

- Automatic meeting starts no longer get lost when the Mac is busy or the app is in the background.
- If a meeting starts while you're dictating, it starts right after instead of being skipped.
- If system audio isn't allowed, OpenScribe records your microphone and tells you, instead of skipping the meeting.
- Opening your Mac up to 10 minutes into a meeting asks whether to record it.

### Setup

- A new, shorter setup in its own window: allow the microphone, connect a speech provider (the key is checked right away), choose whether OpenScribe works in every app, then try your shortcut. Only the microphone and a key are required.
- Setup never takes over the window again once it's done. If something goes missing later, a banner explains how to fix it.
- A refreshed app icon.

### Install

Download the DMG for the app and installer, or the ZIP for the app alone. Quit OpenScribe after finishing any recording, then replace the app in Applications. Existing settings, provider keys, notes and meeting history stay in their local profile. SHA-256 checksums are included.

Requires an Apple silicon Mac running macOS 14 or later. The app is signed with the same Apple Development identity as earlier releases and is not notarized. Local signing guidance is available in the [v0.2.0 release notes](https://github.com/shashankanil/openscribe/releases/tag/v0.2.0).
