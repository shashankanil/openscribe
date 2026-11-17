OpenScribe v0.6.2 fixes meeting summaries.

### Meeting summaries

- Summaries use the language model chosen in Settings → AI → API & Models. Before, a meeting kept using the model that was selected when it was recorded, so changing the model didn't help when you summarized it again.
- Summaries no longer fail when the model formats its answer loosely. OpenScribe now keeps every point it can tie to the transcript, with its timestamps, instead of discarding the whole summary.
- If a summary still can't be read, the message suggests trying again or choosing a different model.

### Install

OpenScribe 0.6.0 and later update themselves: choose **Install and relaunch** when it's offered, or quit the app to install on the way out. On older versions, download the DMG or ZIP below and replace the app in Applications. Settings, keys, notes and meetings stay where they are.

Requires an Apple silicon Mac running macOS 14 or later. The app is signed with the same Apple Development identity as earlier releases and is not notarized.
