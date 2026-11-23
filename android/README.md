# OpenScribe for Android (Phone Link companion)

The phone becomes a wireless microphone and clipboard for OpenScribe on your Mac:

- **Hold to talk.** Hold the big button, speak (or whisper), let go. The text is cleaned up and pasted into
  whatever Mac app is focused, exactly as if you had used the Mac's own microphone. When the Mac allows it
  (**Transcribe on the phone**), the phone transcribes while you speak (a realtime socket for OpenAI, Mistral,
  Deepgram and AssemblyAI streaming models; otherwise pieces cut at pauses and uploaded as you go) and sends the
  Mac only text. If that fails, the recorded audio goes to the Mac instead.
- **Clipboard sync.** Copies on the Mac land on the phone's clipboard automatically while linked. Phone → Mac is
  one tap: the in-app button, **Share → OpenScribe**, or the **Send clipboard** Quick Settings tile.

Everything travels over your local network, encrypted with a key created at pairing. The only API key the
phone holds is the Mac's transcription key, and only while that Mac shares it; it is stored per Mac, encrypted
with the Android Keystore, and deleted when the Mac withdraws it, rejects the phone, or is forgotten. Clipboard
images are cached per Mac and encrypted at rest. The wire protocol is specified in [`docs/PHONE-LINK.md`](../docs/PHONE-LINK.md).

## Build

Requirements: JDK 17 and the Android SDK (platform 36). From this directory:

```sh
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties   # if it doesn't exist yet
./gradlew testDebugUnitTest assembleDebug
```

The APK is `app/build/outputs/apk/debug/app-debug.apk`.

Unit tests (JVM, no device needed):

- `LinkProtocolTest`: every test vector in the spec (HKDF keys, sealed frames, base64url, pairing link), plus
  tampered, replayed and out-of-order frames failing to open.
- `LinkClientTest`: the real client against a fake Mac on localhost (handshake, clip and ack, talk, ping,
  reconnect after a drop, `unpaired`).
- `WhisperBoostTest`: quiet input gets louder, nothing clips, silence and hiss stay silent.
- `AudioTest`: pause detection and segment cuts, WAV headers, 16 → 24 kHz resampling, ordered joining.
- `TranscribeTest`: the `speech` message, file requests per provider and chunked uploads (MockWebServer).
- `RealtimeTest`: realtime URLs, auth, setup, framing and event parsing for all four transports, plus a fake
  OpenAI realtime socket.
- `PhoneTalkTest`: text talks, partial throttling, and the fallback to audio.
- `MacSecretsTest`: per-Mac settings stay apart and forgetting a Mac removes only its own.

## Install

Enable USB debugging on the phone, plug it in, then:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.opensource.openscribe/.ui.MainActivity
```

Android 10 (API 29) or newer. QR scanning uses the Google code scanner, so it needs Google Play services. Without
them, paste the link instead.

## Pair

1. On the Mac: **OpenScribe → Phone → Pair a phone**. A QR code appears (it expires after 10 minutes).
2. On the phone: open OpenScribe and tap **Scan QR code**. You can also paste the `openscribe://link?…` text, or
   open the link on the phone, since the app handles `openscribe://link` deep links.
3. The phone stores the link encrypted with an Android Keystore key. It is excluded from backups and device
   transfer, so a new or restored phone has to pair again.

The phone finds the Mac with NSD (`_openscribe._tcp`, matching the TXT `id`). If that finds nothing within
3 seconds, it tries the IP addresses embedded in the pairing link. It reconnects with backoff (up to 30 s), and
reconnects right away when the network changes. Tap the status chip to retry immediately.

## Use

- **Talk:** hold the big button and let go to send, or tap it once to talk hands-free and tap ➤ to send. While
  holding, slide **up** to lock hands-free or **left** to cancel. The ring follows your voice; the status line
  says where the text is going ("Typing into Notes on MacBook Pro"), and the result card shows what was typed,
  with **Copy to phone**.
- **Talk button** (Settings → Talk button): hold a hardware button to talk from any app with the screen on.
  Volume keys work; the Essential Key works if Nothing OS delivers it to apps (the setup screen tells you).
  It needs the **OpenScribe talk button** accessibility service, which only watches the button you pick. Tap the
  button for hands-free, press again to send. While the Mac isn't connected, the button does its usual job.
- **Whisper boost** (Settings, on by default): adaptive gain toward about −20 dBFS, up to +24 dB, with a noise gate
  at −54 dBFS so room hiss isn't amplified, and a soft limiter.
- **Clipboard:** copies on the Mac land on the phone automatically (or only when you press **Send to phone**,
  ⌥⇧P, if automatic sending is off on the Mac). To send from the phone: **Send copied text/image** on the home
  screen, **Share → OpenScribe** from any app, the **Send clipboard** Quick Settings tile, or the notification
  action. **Recent** lists the last items both ways; tap one to copy it again.
- **Images** go both ways when the Mac is signed in to OpenScribe Cloud with Google. They're encrypted on the
  device, kept in R2 for 2 days, and over 10 MB are re-encoded as JPEG.
- **Several Macs:** tap the Mac's name at the top to switch, add another Mac, or forget one. One is connected at
  a time.
- **Away from home:** with the Mac signed in to OpenScribe Cloud, the phone connects through the cloud relay when
  it can't reach the Mac on the local network ("Connected via cloud"). Everything stays end-to-end encrypted.
- **Always on:** the link starts at boot and reconnects when you turn the screen on. Allow background use when
  asked, so battery optimization doesn't cut it while the screen is off.

## Known limitations

| Limitation | Why |
| --- | --- |
| Phone → Mac clipboard is never automatic. | Android 10+ lets only the foreground app (or the default keyboard) read the clipboard. Use the button, Share, the tile or the notification action. Fully automatic sync needs an OpenScribe keyboard. |
| The talk button needs the screen on. | Android doesn't deliver button presses to apps while the screen is off. |
| The Essential Key may not be available. | Nothing OS can keep it for Essential Space; if so, the setup screen hears nothing and a volume key is the fallback. |
| Images and the relay need the Mac signed in with Google. | They use OpenScribe Cloud; the local-network link needs no account. |
| Audio is uncompressed PCM (about 256 kbps). | Fine on Wi-Fi; heavier over the relay on mobile data. Opus is planned. |
| Debug build only. | A signed release (keystore kept outside the repo) and Play testing are planned. |
| Android 17 local network permission. | The app targets API 36. Targeting 37 will need `ACCESS_LOCAL_NETWORK` handling. |
