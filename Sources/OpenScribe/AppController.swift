import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let store: AppStore
    let recorder: AudioRecorder
    let hotkey: GlobalHotkey
    let providerClient: ProviderClient
    let permissions: PermissionCenter

    @Published private(set) var capturePhase: CapturePhase = .idle
    @Published private(set) var captureHint = "⌥ Space to speak"
    @Published private(set) var currentTranscript = ""
    @Published private(set) var lastError: String?

    private var permissionsWindow: NSWindow?
    private var overlayPanel: OverlayPanel?
    private var workspaceWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var processingTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var hotkeyStarted = false
    private var hasBooted = false
    private var holdToTalkReleasePending = false
    private var transientErrorTask: Task<Void, Never>?
    private var recordingSourceApplication: String?
    private var recordingSourceBundleIdentifier: String?

    private init() {
        store = AppStore()
        recorder = AudioRecorder()
        permissions = PermissionCenter()
        hotkey = GlobalHotkey()
        providerClient = ProviderClient()
        FlowTheme.apply(store.settings.theme)
    }

    var settings: AppSettings { store.settings }
    var notes: [VoiceNote] { store.notes }
    private var idleHint: String { "\(settings.shortcutDisplay) to speak" }

    private func activeApplicationMetadata() -> (name: String?, bundleIdentifier: String?) {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return (nil, nil)
        }
        return (application.localizedName, application.bundleIdentifier)
    }
    private func applyTheme(_ theme: FlowThemeVariant) {
        FlowTheme.apply(theme)
        NSApp.appearance = NSAppearance(named: theme.appearanceName)
    }

    func boot() {
        guard !hasBooted else { return }
        hasBooted = true
        applyTheme(settings.theme)
        permissions.refresh()
        NSLog("OpenScribe booted")
        if !permissions.hasSeenOnboarding {
            permissions.markOnboardingSeen()
            showPermissions()
        } else {
            startHotkeyIfAllowed()
        }
        if store.settings.showOverlayWhenIdle {
            captureHint = idleHint
            showOverlay()
        }
    }

    func toggleCapture() {
        switch capturePhase {
        case .recording:
            finishCapture()
        case .transcribing, .cleaning:
            return
        case .idle, .ready, .failed:
            startCapture()
        }
    }

    func startCapture() {
        guard startTask == nil, processingTask == nil else { return }
        holdToTalkReleasePending = false
        permissions.refresh()
        guard permissions.microphoneReady else {
            capturePhase = .idle
            captureHint = "Allow microphone access to dictate"
            showPermissions()
            return
        }
        let activeApplication = activeApplicationMetadata()
        recordingSourceApplication = activeApplication.name
        recordingSourceBundleIdentifier = activeApplication.bundleIdentifier

        lastError = nil
        transientErrorTask?.cancel()
        transientErrorTask = nil
        captureHint = "Starting…"
        showOverlay()
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { startTask = nil }
            do {
                try await recorder.start()
                capturePhase = .recording
                captureHint = "Speak naturally"
                showOverlay()
                if holdToTalkReleasePending {
                    holdToTalkReleasePending = false
                    finishCapture()
                }
            } catch {
                recorder.cancel()
                fail(with: error)
            }
        }
    }

    func finishCapture() {
        guard capturePhase == .recording else {
            if settings.dictationMode == .holdToTalk, startTask != nil {
                holdToTalkReleasePending = true
            }
            return
        }
        holdToTalkReleasePending = false
        do {
            let result = try recorder.stop()
            let sourceApplication = recordingSourceApplication
            let sourceBundleIdentifier = recordingSourceBundleIdentifier
            recordingSourceApplication = nil
            recordingSourceBundleIdentifier = nil
            if store.settings.saveRawAudio {
                retainAudio(result.audio)
            }
            capturePhase = .transcribing
            captureHint = "Transcribing…"
            showOverlay()
            processRecording(
                audio: result.audio,
                duration: result.duration,
                sourceApplication: sourceApplication,
                sourceBundleIdentifier: sourceBundleIdentifier
            )
        } catch {
            recordingSourceApplication = nil
            recordingSourceBundleIdentifier = nil
            fail(with: error)
        }
    }

    func cancelCapture() {
        startTask?.cancel()
        startTask = nil
        processingTask?.cancel()
        processingTask = nil
        transientErrorTask?.cancel()
        transientErrorTask = nil
        recorder.cancel()
        holdToTalkReleasePending = false
        recordingSourceApplication = nil
        recordingSourceBundleIdentifier = nil
        currentTranscript = ""
        lastError = nil
        capturePhase = .idle
        captureHint = idleHint
        if !store.settings.showOverlayWhenIdle { hideOverlay() }
    }

    func openWorkspace() {
        if workspaceWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "OpenScribe"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            workspaceWindow = window
            window.contentView = NSHostingView(rootView: WorkspaceView(controller: self))
        }
        NSApp.activate(ignoringOtherApps: true)
        workspaceWindow?.makeKeyAndOrderFront(nil)
    }
    func showPermissions() {
        if permissionsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 650),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "OpenScribe setup"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PermissionsView(controller: self))
            window.center()
            permissionsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        permissionsWindow?.makeKeyAndOrderFront(nil)
    }

    func dismissPermissions() {
        permissions.refresh()
        startHotkeyIfAllowed()
        permissionsWindow?.orderOut(nil)
    }

    func disablePasteInjectionAndDismissPermissions() {
        updateSettings { $0.pasteIntoFocusedApp = false }
        dismissPermissions()
    }

    func refreshPermissions() {
        permissions.refresh()
    }

    func requestMicrophonePermission() async {
        await permissions.requestMicrophonePermission()
    }

    func openMicrophoneSettings() {
        permissions.openMicrophoneSettings()
    }

    func openAccessibilitySettings() {
        permissions.openAccessibilitySettings()
    }
    private func startHotkeyIfAllowed() {
        guard permissions.accessibilityTrusted else { return }
        if !hotkeyStarted {
            hotkeyStarted = true
            configureHotkey()
        }
        primeRecorder()
    }

    private func configureHotkey() {
        let settings = store.settings
        let modifiers = NSEvent.ModifierFlags(rawValue: settings.shortcutModifiers)
        let releaseToSend = settings.dictationMode == .holdToTalk || settings.shortcutKeyCode == 63
        let onPress: () -> Void = releaseToSend
            ? { [weak self] in self?.startCapture() }
            : { [weak self] in self?.toggleCapture() }
        let onRelease: (() -> Void)? = releaseToSend
            ? { [weak self] in self?.finishCapture() }
            : nil

        hotkey.start(
            keyCode: settings.shortcutKeyCode,
            modifiers: modifiers,
            onPress: onPress,
            onRelease: onRelease
        )
    }

    private func primeRecorder() {
        guard permissions.microphoneReady else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await recorder.prepare()
            } catch {
                NSLog("OpenScribe recorder warm-up failed: %@", error.localizedDescription)
            }
        }
    }

    func restartHotkey() {
        guard hotkeyStarted else { return }
        configureHotkey()
    }
    func updateShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, display: String) {
        updateSettings {
            $0.shortcutKeyCode = keyCode
            $0.shortcutModifiers = modifiers.rawValue
            $0.shortcutDisplay = display
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "OpenScribe Settings"
            window.titleVisibility = .visible
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(controller: self))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func saveCredential(_ value: String, for key: CredentialKey) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            CredentialStore.remove(account: key.rawValue)
        } else {
            do {
                try CredentialStore.save(cleaned, account: key.rawValue)
            } catch {
                lastError = error.localizedDescription
            }
        }
        objectWillChange.send()
    }

    func credential(for key: CredentialKey) -> String {
        CredentialStore.read(account: key.rawValue) ?? ""
    }

    func updateSettings(_ update: (inout AppSettings) -> Void) {
        var updated = store.settings
        let previousDictationMode = updated.dictationMode
        let previousShortcutKeyCode = updated.shortcutKeyCode
        let previousShortcutModifiers = updated.shortcutModifiers
        let previousTheme = updated.theme
        update(&updated)
        store.settings = updated
        if previousTheme != updated.theme {
            applyTheme(updated.theme)
        }
        objectWillChange.send()
        if previousDictationMode != updated.dictationMode
            || previousShortcutKeyCode != updated.shortcutKeyCode
            || previousShortcutModifiers != updated.shortcutModifiers {
            restartHotkey()
        }
    }

    func selectSpeechProvider(_ provider: SpeechProvider) {
        store.updateSpeechProvider(provider)
        objectWillChange.send()
    }

    func selectLanguageModelProvider(_ provider: LanguageModelProvider) {
        store.updateLanguageModelProvider(provider)
        objectWillChange.send()
    }

    @discardableResult
    func addManualNote() -> VoiceNote {
        let note = store.addManualNote()
        objectWillChange.send()
        return note
    }

    func updateNote(_ note: VoiceNote) {
        store.updateNote(note)
        objectWillChange.send()
    }

    func deleteNote(_ note: VoiceNote) {
        store.deleteNote(note)
        objectWillChange.send()
    }

    func togglePin(_ note: VoiceNote) {
        store.togglePin(note)
        objectWillChange.send()
    }

    func clearNotes() {
        store.clearNotes()
        objectWillChange.send()
    }
    private func retainAudio(_ data: Data) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = support
            .appendingPathComponent("WhisperFlow", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("OpenScribe-\(UUID().uuidString).wav")
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("OpenScribe audio retention error: %@", error.localizedDescription)
        }
    }

    private func processRecording(
        audio: Data,
        duration: TimeInterval,
        sourceApplication: String?,
        sourceBundleIdentifier: String?
    ) {
        let speechSettings = store.settings
        let speechKey = credential(for: .speech)
        let languageKey = credential(for: .languageModel)
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { processingTask = nil }
            do {
                let raw = try await providerClient.transcribe(audio: audio, settings: speechSettings, apiKey: speechKey)
                try Task.checkCancellation()
                currentTranscript = raw

                var cleaned = raw
                var cleanupFailure: Error?
                if speechSettings.cleanupEnabled {
                    capturePhase = .cleaning
                    captureHint = "Polishing…"
                    showOverlay()
                    do {
                        cleaned = try await providerClient.cleanTranscript(
                            raw,
                            settings: speechSettings,
                            apiKey: languageKey
                        )
                        try Task.checkCancellation()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        cleanupFailure = error
                        cleaned = raw
                        NSLog("OpenScribe cleanup failed: %@", error.localizedDescription)
                    }
                }

                let note = store.addNote(
                    rawText: raw,
                    cleanedText: cleaned,
                    duration: duration,
                    sourceApplication: sourceApplication,
                    sourceBundleIdentifier: sourceBundleIdentifier
                )
                currentTranscript = note.displayText
                capturePhase = .ready
                captureHint = settings.pasteIntoFocusedApp ? "Pasted · saved to notes" : "Saved to notes"
                showOverlay()

                if let cleanupFailure {
                    showTransientError("Transcript saved; cleanup unavailable: \(cleanupFailure.localizedDescription)")
                }

                if settings.pasteIntoFocusedApp {
                    do {
                        try TextInjector.paste(note.displayText)
                    } catch {
                        permissions.refresh()
                        showTransientError("Saved · paste permission needed")
                        if let injectorError = error as? TextInjectorError,
                           case .accessibilityPermissionDenied = injectorError {
                            showPermissions()
                        }
                    }
                }

                if capturePhase == .ready {
                    capturePhase = .idle
                    captureHint = idleHint
                    if !settings.showOverlayWhenIdle {
                        hideOverlay()
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                NSLog("OpenScribe processing failed: %@", error.localizedDescription)
                fail(with: error)
            }
        }
    }

    private func fail(with error: Error) {
        permissions.refresh()
        if let recorderError = error as? RecorderError,
           case .microphonePermissionDenied = recorderError {
            capturePhase = .idle
            captureHint = "Allow microphone access to dictate"
            recorder.cancel()
            showPermissions()
            return
        }

        NSLog("OpenScribe capture failed: %@", error.localizedDescription)
        showTransientError(error.localizedDescription)
    }

    private func showTransientError(_ message: String) {
        transientErrorTask?.cancel()
        lastError = message.isEmpty ? "Something went wrong." : message
        capturePhase = .failed
        captureHint = lastError ?? "Something went wrong."
        recorder.cancel()
        showOverlay()

        transientErrorTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }
            guard let self, self.capturePhase == .failed else { return }
            self.lastError = nil
            self.capturePhase = .idle
            self.captureHint = self.idleHint
            self.transientErrorTask = nil
            self.hideOverlay()
        }
    }

    private func showOverlay() {
        if overlayPanel == nil {
            overlayPanel = OverlayPanel(controller: self)
        }
        overlayPanel?.show()
    }

    private func hideOverlay() {
        overlayPanel?.orderOut(nil)
    }
}

enum CredentialKey: String {
    case speech = "speech-api-key"
    case languageModel = "language-model-api-key"
}
