OpenScribe v0.7.0 adds OpenScribe for Android: dictate into your Mac from your phone, and share the clipboard both ways.

### OpenScribe for Android

- **Hold to talk.** Hold the button on the phone (or tap once for hands-free) and speak, even in a whisper. The text is typed into the app that's focused on your Mac, after your dictionary, snippets and cleanup.
- **Faster, live dictation.** The phone transcribes as you speak, with your Mac's transcription provider, and sends the Mac text. Streaming providers show words as you say them; others transcribe at each pause, so the text arrives about a second after you let go. Turn this off under Phone → Transcribe on the phone to send audio to the Mac instead.
- **Talk button.** Hold a volume key (or another button the phone allows) to talk from any app without opening OpenScribe.
- **Clipboard both ways.** Copies on the Mac land on the phone. Copies on the phone go to the Mac automatically once OpenScribe is turned on in the phone's Accessibility settings, or with Send, Share or the Quick Settings tile. Passwords marked sensitive are never sent.
- **Send to phone** (⌥⇧P by default, in Settings → Shortcuts) puts the selected text or image on your phone's clipboard.
- **Images** go both ways when the Mac is signed in to OpenScribe Cloud. They're encrypted on the device and deleted from the server after 2 days.
- **Away from home.** Signed in to OpenScribe Cloud with Google, the phone connects through the cloud when it can't reach the Mac on the local network. Audio and text stay end-to-end encrypted.
- **Several Macs.** Pair the phone with more than one Mac and switch between them; one is connected at a time.

Get it from the Download for Android button under Settings → Phone (scan the code with your phone), or download `OpenScribe-Android.apk` below. Android 10 or later.

### Settings → API & Models

- **Test key** checks your API key with the provider and loads the models it offers, filtered to transcription or writing. Pick one from the list, or type a model ID.

### Privacy

Phone Link works on your local network with no account. Each phone has its own key, and everything between phone and Mac is encrypted. Only the transcription key is shared with a phone, and only while Transcribe on the phone is on; removing a phone deletes it. On the phone, settings and cached images are encrypted and kept separately for each Mac.

### Install

OpenScribe 0.6.0 and later update themselves: choose **Install and relaunch** when it's offered, or quit the app to install on the way out. On older versions, download the DMG or ZIP below and replace the app in Applications. Settings, keys, notes and meetings stay where they are. macOS asks to allow local network access the first time you turn on Phone Link.

Requires an Apple silicon Mac running macOS 14 or later. The app is signed with the same Apple Development identity as earlier releases and is not notarized.

On Android, if you installed a test build of OpenScribe, uninstall it first: this release is signed with the release key, and Android won't install it over a test build.
