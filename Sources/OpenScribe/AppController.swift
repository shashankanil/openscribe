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
    let meetings = MeetingController()
    let calendar = CalendarMeetingController()
    private var calendarSubscription: AnyCancellable?
    private var meetingSubscription: AnyCancellable?
    let permissions: PermissionCenter

    @Published private(set) var capturePhase: CapturePhase = .idle
    @Published private(set) var captureHint = "⌥ Space to speak"
    @Published private(set) var currentTranscript = ""
    @Published private(set) var lastError: String?

    @Published var workspaceSection: WorkspaceSection = .notes
    private var overlayPanel: OverlayPanel?
    private var workspaceWindow: NSWindow?
    private var processingTask: Task<Void, Never>?
    private var captureGeneration = UUID()
    private let sounds = CaptureSounds()
    private var startTask: Task<Void, Never>?
    private var hotkeyStarted = false
    private var hasBooted = false
    private var holdToTalkReleasePending = false
    private var transientErrorTask: Task<Void, Never>?
    @Published private(set) var hasFailedRecording = false
    private let recovery = DictationRecoveryStore()
    private var activeRecoveryJob: DictationJob?
    private var dictationStreaming: LiveAudioPipeline?
    private var dictationLive: DictationLiveTranscriber?
    private var recordingSourceApplication: String?
    private var recordingSourceBundleIdentifier: String?

    private init() {
        store = AppStore()
        recorder = AudioRecorder()
        permissions = PermissionCenter()
        hotkey = GlobalHotkey()
        providerClient = ProviderClient()
        recorder.onInterruption = { [weak self] error in
            guard let self, self.capturePhase == .recording else { return }
            self.finishCapture()
        }
        meetingSubscription = meetings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        calendarSubscription = calendar.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        hasFailedRecording = !recovery.jobs.isEmpty
        if let error = recovery.error { lastError = error }
        do { try CredentialStore.migrateLegacy(settings: store.settings) }
        catch { lastError = "Could not migrate provider credentials: \(error.localizedDescription)" }
        FlowTheme.apply(store.settings.theme)
    }

    var isDictationBusy: Bool { startTask != nil || processingTask != nil || capturePhase == .recording }

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
        calendar.boot(app: self)
        applyTheme(settings.theme)
        permissions.refresh()
        NSLog("OpenScribe booted")
        if !permissions.hasSeenOnboarding {
            showPermissions()
        } else {
            startHotkeyIfAllowed()
        }
        if store.settings.showOverlayWhenIdle {
            captureHint = idleHint
            showOverlay()
        }
    }

    private var pasteLastTask: Task<Void, Never>?
    var canPasteLast: Bool { !notes.isEmpty && !isDictationBusy && pasteLastTask == nil }

    func pasteLastDictation() {
        guard canPasteLast, let note = notes.first,
              let target = activeApplicationMetadata().bundleIdentifier else { return }
        pasteLastTask = Task { @MainActor in
            defer { pasteLastTask = nil; objectWillChange.send() }
            do { try await TextInjector.paste(note.displayText, into: target) }
            catch { lastError = error.localizedDescription; showTransientError("Paste failed · transcript is still saved") }
        }
    }

    func toggleCapture() {
        if startTask != nil {
            holdToTalkReleasePending = true
            return
        }
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
        guard !meetings.occupiesCapture else {
            showTransientError("Finish the meeting recording before starting dictation.")
            return
        }
        guard startTask == nil, processingTask == nil, pasteLastTask == nil, capturePhase != .recording else { return }
        let generation = UUID()
        captureGeneration = generation
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
            defer { if captureGeneration == generation { startTask = nil } }
            do {
                let job = DictationJob(settings: settings, sourceApplication: recordingSourceApplication,
                                       sourceBundleIdentifier: recordingSourceBundleIdentifier)
                try recovery.save(job)
                activeRecoveryJob = job
                dictationStreaming?.cancel()
                dictationStreaming = nil
                if job.settings.dictationLiveTranscription, job.settings.automaticStreaming,
                   let capability = StreamingCapability.resolve(job.settings) {
                    dictationStreaming = LiveAudioPipeline(capability: capability, apiKey: credential(for: .speech, settings: job.settings), onPartial: { [weak self] url, partial in
                        Task { @MainActor in
                            guard let self, self.captureGeneration == generation, self.capturePhase == .recording,
                                  let latest = self.recovery.jobs.first(where: { $0.id == job.id }),
                                  latest.transcripts[url.lastPathComponent] == nil else { return }
                            let saved = latest.transcripts.keys.sorted().compactMap { latest.transcripts[$0] }.joined(separator: " ")
                            self.currentTranscript = [saved, partial].filter { !$0.isEmpty }.joined(separator: " ")
                            self.captureHint = "Streaming transcription"
                        }
                    }, onFallback: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.captureGeneration == generation, self.capturePhase == .recording else { return }
                            self.captureHint = "Streaming unavailable · using saved audio sections"
                        }
                    })
                }
                try await recorder.start(directoryURL: recovery.audioDirectory(job.id), deviceUID: settings.microphoneDeviceUID,
                                         liveSink: dictationStreaming?.makeSink())
                try Task.checkCancellation()
                guard captureGeneration == generation else { return }
                if settings.interactionSounds { sounds.play(.start) }
                capturePhase = .recording
                captureHint = "Speak naturally"
                if job.settings.dictationLiveTranscription {
                    let key = credential(for: .speech, settings: job.settings)
                    let client = providerClient
                    let streaming = dictationStreaming
                    let live = DictationLiveTranscriber(store: recovery) { url, settings in
                        if let text = try await streaming?.result(for: url) { return text }
                        return try await client.transcribeReliably(audioFile: url, settings: settings, apiKey: key)
                    }
                    live.onProgress = { [weak self] text, count in
                        guard let self, self.captureGeneration == generation, self.capturePhase == .recording else { return }
                        self.currentTranscript = text
                        self.captureHint = "Recording · \(count) sections ready"
                    }
                    live.onFailure = { [weak self] error in
                        guard let self, self.captureGeneration == generation, self.capturePhase == .recording else { return }
                        self.captureHint = "Recording locally · transcription will retry after stop"
                    }
                    dictationLive = live
                    live.start(job.id)
                }
                showOverlay()
                if holdToTalkReleasePending {
                    holdToTalkReleasePending = false
                    finishCapture()
                }
            } catch {
                guard captureGeneration == generation, !Task.isCancelled else { return }
                dictationStreaming?.cancel()
                dictationStreaming = nil
                recorder.cancel()
                if let job = activeRecoveryJob { try? recovery.remove(job.id) }
                activeRecoveryJob = nil
                fail(with: error)
            }
        }
    }

    func finishCapture() {
        guard capturePhase == .recording else {
            if startTask != nil {
                holdToTalkReleasePending = true
            }
            return
        }
        holdToTalkReleasePending = false
        do {
            let result = try recorder.stop()
            if settings.interactionSounds { sounds.play(.stop) }
            let sourceApplication = recordingSourceApplication
            let sourceBundleIdentifier = recordingSourceBundleIdentifier
            recordingSourceApplication = nil
            recordingSourceBundleIdentifier = nil
            if store.settings.saveRawAudio {
                retainAudio(result)
            }
            capturePhase = .transcribing
            captureHint = "Transcribing…"
            showOverlay()
            processRecording(
                recording: result,
                sourceApplication: sourceApplication,
                sourceBundleIdentifier: sourceBundleIdentifier,
                job: activeRecoveryJob
            )
            activeRecoveryJob = nil
        } catch {
            dictationStreaming?.cancel()
            dictationStreaming = nil
            dictationLive?.cancel()
            dictationLive = nil
            recordingSourceApplication = nil
            recordingSourceBundleIdentifier = nil
            activeRecoveryJob = nil
            hasFailedRecording = !recovery.jobs.isEmpty
            fail(with: error)
        }
    }

    func cancelCapture() {
        captureGeneration = UUID()
        dictationStreaming?.cancel()
        dictationStreaming = nil
        dictationLive?.cancel()
        dictationLive = nil
        startTask?.cancel()
        startTask = nil
        processingTask?.cancel()
        processingTask = nil
        transientErrorTask?.cancel()
        transientErrorTask = nil
        recorder.cancel()
        if let job = activeRecoveryJob { try? recovery.remove(job.id) }
        activeRecoveryJob = nil
        hasFailedRecording = !recovery.jobs.isEmpty
        holdToTalkReleasePending = false
        recordingSourceApplication = nil
        recordingSourceBundleIdentifier = nil
        currentTranscript = ""
        lastError = nil
        capturePhase = .idle
        captureHint = idleHint
        if !store.settings.showOverlayWhenIdle { hideOverlay() }
    }

    func retryFailedRecording() {
        guard !isDictationBusy, !meetings.occupiesCapture, let job = recovery.jobs.first else { return }
        do {
            // Stable note IDs make recovery safe even if the process died after saving the note.
            if store.hasPersistedNote(job.id) {
                try recovery.remove(job.id)
                hasFailedRecording = !recovery.jobs.isEmpty
                return
            }
            let recording = try recovery.recording(job.id)
            captureGeneration = UUID()
            transientErrorTask?.cancel()
            lastError = nil
            capturePhase = .transcribing
            captureHint = "Recovering…"
            showOverlay()
            processRecording(recording: recording, sourceApplication: job.sourceApplication,
                             sourceBundleIdentifier: job.sourceBundleIdentifier, pasteResult: false, job: job)
        } catch { showTransientError(error.localizedDescription) }
    }

    func discardFailedRecording() {
        guard !isDictationBusy, let job = recovery.jobs.first else { return }
        do { try recovery.remove(job.id) } catch { showTransientError(error.localizedDescription) }
        hasFailedRecording = !recovery.jobs.isEmpty
    }

    func prepareDictationToQuit() async {
        dictationStreaming?.cancel()
        dictationStreaming = nil
        dictationLive?.cancel()
        await dictationLive?.finish()
        dictationLive = nil
        startTask?.cancel()
        await startTask?.value
        if recorder.isRecording { _ = try? recorder.stop() }
        activeRecoveryJob = nil
        processingTask?.cancel()
        await processingTask?.value
        store.flush()
    }

    func openWorkspace() {
        workspaceSection = .notes
        openMainWindow()
    }

    func openMainWindow() {
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
            window.minSize = NSSize(width: 940, height: 700)
            window.setFrameAutosaveName("OpenScribeWorkspace")
            window.center()
            workspaceWindow = window
            window.contentView = NSHostingView(rootView: MainWorkspaceView(controller: self))
        }
        NSApp.activate(ignoringOtherApps: true)
        workspaceWindow?.makeKeyAndOrderFront(nil)
    }
    func showPermissions() {
        workspaceSection = .permissions
        openMainWindow()
    }

    func dismissPermissions(markOnboardingComplete: Bool = true) {
        permissions.refresh()
        if markOnboardingComplete {
            permissions.markOnboardingSeen()
        }
        startHotkeyIfAllowed()
        workspaceSection = .notes
    }

    func disablePasteInjectionAndDismissPermissions() {
        updateSettings { $0.pasteIntoFocusedApp = false }
        dismissPermissions(markOnboardingComplete: true)
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
    func restartApplication() {
        guard let executableURL = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executableURL
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            showTransientError("OpenScribe could not restart: \(error.localizedDescription)")
        }
    }
    private func startHotkeyIfAllowed() {
        guard permissions.accessibilityTrusted else { return }
        if !hotkeyStarted {
            hotkeyStarted = true
            configureHotkey()
        }
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
        workspaceSection = .general
        openMainWindow()
    }

    func credential(for key: CredentialKey, settings configuration: AppSettings? = nil) -> String {
        CredentialStore.read(for: key, settings: configuration ?? settings) ?? ""
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
    private func retainAudio(_ recording: RecordedAudio) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let audioRoot = support
            .appendingPathComponent("WhisperFlow", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
        let directory = audioRoot.appendingPathComponent("OpenScribe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, chunkURL) in recording.chunkURLs.enumerated() {
                let filename = String(format: "chunk-%05d.wav", index)
                let destination = directory.appendingPathComponent(filename)
                try FileManager.default.copyItem(at: chunkURL, to: destination)
            }
        } catch {
            NSLog("OpenScribe audio retention error: %@", error.localizedDescription)
        }
    }

    private func processRecording(
        recording: RecordedAudio,
        sourceApplication: String?,
        sourceBundleIdentifier: String?,
        pasteResult: Bool = true,
        job: DictationJob? = nil
    ) {
        let generation = captureGeneration
        var speechSettings = job?.settings ?? store.settings
        if let sourceBundleIdentifier, let tone = speechSettings.appWritingTones[sourceBundleIdentifier] {
            speechSettings.writingTone = tone
        }
        let speechKey = credential(for: .speech, settings: speechSettings)
        let languageKey = credential(for: .languageModel, settings: speechSettings)
        let liveTranscriber = dictationLive
        let streaming = dictationStreaming
        processingTask = Task { @MainActor [weak self] in
            guard let self else {
                if job == nil { recording.cleanup() }
                return
            }
            var checkpoint = job
            defer {
                streaming?.cancel()
                if job == nil { recording.cleanup() }
                hasFailedRecording = !recovery.jobs.isEmpty
                if captureGeneration == generation { self.processingTask = nil }
            }
            do {
                try Task.checkCancellation()
                await liveTranscriber?.finish()
                try Task.checkCancellation()
                if captureGeneration == generation { dictationLive = nil }
                if let job { checkpoint = recovery.jobs.first { $0.id == job.id } ?? job }
                var rawChunks: [String] = []
                for url in recording.chunkURLs {
                    try Task.checkCancellation()
                    let key = url.lastPathComponent
                    let text: String
                    if let cached = checkpoint?.transcripts[key] { text = cached }
                    else {
                        if let streamed = try await streaming?.result(for: url) { text = streamed }
                        else { text = try await providerClient.transcribeReliably(audioFile: url, settings: speechSettings, apiKey: speechKey) }
                        try Task.checkCancellation()
                        checkpoint?.transcripts[key] = text
                        if let checkpoint { try recovery.save(checkpoint) }
                    }
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rawChunks.append(text) }
                }
                guard !rawChunks.isEmpty else { throw ProviderClient.ClientError.malformedResponse }
                try Task.checkCancellation()
                let raw = rawChunks.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentTranscript = raw

                let snippet = VoiceSnippet.expansion(for: raw, snippets: speechSettings.snippets)
                let corrected = CorrectionRule.apply(to: raw, rules: speechSettings.correctionRules)
                var cleaned = snippet ?? corrected
                var cleanupFailure: Error?
                if speechSettings.cleanupEnabled && snippet == nil {
                    capturePhase = .cleaning
                    captureHint = "Polishing…"
                    showOverlay()
                    var cleanedChunks: [String] = []
                    let editingBatches = TranscriptEditing.batches(corrected)
                    cleanedChunks.reserveCapacity(editingBatches.count)
                    for (index, rawChunk) in editingBatches.enumerated() {
                        do {
                            let cleanedChunk = try await providerClient.cleanTranscript(
                                rawChunk,
                                settings: speechSettings,
                                apiKey: languageKey
                            )
                            cleanedChunks.append(cleanedChunk.isEmpty ? rawChunk : cleanedChunk)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            cleanupFailure = error
                            cleanedChunks.append(contentsOf: editingBatches[index...])
                            break
                        }
                    }
                    cleaned = cleanedChunks.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                }

                try Task.checkCancellation()
                guard captureGeneration == generation else { return }
                let note = store.addNote(
                    id: job?.id ?? UUID(),
                    createdAt: job?.createdAt ?? Date(),
                    rawText: raw,
                    cleanedText: cleaned,
                    duration: recording.duration,
                    sourceApplication: sourceApplication,
                    sourceBundleIdentifier: sourceBundleIdentifier
                )
                guard store.hasPersistedNote(note.id) else {
                    throw ProviderClient.ClientError.provider(message: "The transcript could not be saved. Your audio is retained for recovery.")
                }
                if let job { try recovery.remove(job.id) }
                currentTranscript = note.displayText
                capturePhase = .ready
                captureHint = "Saved to notes"
                showOverlay()

                if let cleanupFailure {
                    showTransientError("Transcript saved; cleanup unavailable: \(cleanupFailure.localizedDescription)")
                }

                if speechSettings.pasteIntoFocusedApp && pasteResult {
                    do {
                        try await TextInjector.paste(note.displayText, into: sourceBundleIdentifier)
                    } catch {
                        guard captureGeneration == generation, !Task.isCancelled else { return }
                        permissions.refresh()
                        let needsPermission = (error as? TextInjectorError).map {
                            if case .accessibilityPermissionDenied = $0 { return true }
                            return false
                        } ?? false
                        NSLog("OpenScribe paste failed: %@", error.localizedDescription)
                        showTransientError(needsPermission ? "Saved · paste permission needed" : "Saved · paste failed")
                        if needsPermission {
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
                guard captureGeneration == generation, !Task.isCancelled else { return }
                hasFailedRecording = !recovery.jobs.isEmpty
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
            if !self.settings.showOverlayWhenIdle { self.hideOverlay() }
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
