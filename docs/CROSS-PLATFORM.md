# OpenScribe on Windows and Linux

The Windows/Linux desktop application lives in `desktop/`. It uses a Tauri 2 native shell, a React/TypeScript interface, and Rust adapters for audio, credential storage, provider requests, and paste injection. The existing Swift application remains the native macOS edition and is not built or changed by this release pipeline.

## Development

Prerequisites are Node.js, pnpm, Rust stable, and the platform prerequisites from the Tauri documentation.

```sh
cd desktop
pnpm install
pnpm test
pnpm desktop:dev
```

Build native installers on the target operating system:

```sh
cd desktop
pnpm desktop:build
```

Windows produces NSIS and MSI installers. Linux produces Debian and AppImage packages. GitHub Actions builds x64 Windows plus x64 and ARM64 Linux artifacts when a `desktop-v*` tag is pushed. The release is created as a draft so artifacts can be smoke-tested before publication.

## Platform adapters

- Microphone and selectable capture inputs use CPAL and are written as 16-bit WAV before upload.
- Provider credentials use Windows Credential Manager, Linux Secret Service, or the native macOS keychain when the desktop shell is run on macOS.
- The global shortcut uses Tauri's desktop global-shortcut plugin.
- Paste uses the Tauri clipboard and a native Ctrl+V/Command+V injection, then restores the previous clipboard text when it is unchanged.
- System audio uses an operating-system capture input. Enable Stereo Mix or install a loopback device on Windows; select a PipeWire/Pulse monitor source on Linux.
- Calendar events are imported from standard `.ics` files. This keeps the implementation provider-neutral because Windows and Linux do not share a native calendar database equivalent to EventKit.

## Security and privacy

Notes, meetings, settings, and imported calendar events are stored in the application data directory. Provider keys are not written to that JSON store. Audio is uploaded only when the user stops a recording and transcription begins. Failed recordings remain in a visible recovery queue for retry or deletion. Meeting audio is retained with its transcript; successful dictation audio is deleted unless retention is enabled. Deleting an item also deletes its retained recording.

Windows code signing should be configured in the release workflow before publishing broadly. Linux packages can be signed separately by the distribution channel. Unsigned installers are appropriate only for controlled testing because operating systems will display trust warnings.
