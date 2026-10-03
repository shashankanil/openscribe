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
    let meetings: MeetingController
    let calendar: CalendarMeetingController
    private var calendarSubscription: AnyCancellable?
    private var meetingSubscription: AnyCancellable?
    private var noticeSubscriptions = Set<AnyCancellable>()
    let permissions: PermissionCenter

    @Published private(set) var capturePhase: CapturePhase = .idle {
        didSet {
            if capturePhase != .recording { captureStartedAt = nil }
            else if oldValue != .recording { captureStartedAt = Date() }
        }
    }
    @Published private(set) var captureStartedAt: Date?
    @Published private(set) var toast: String?
    @Published private(set) var launchAtLogin = LoginItem.isRequested
    @Published private(set) var captureHint = "⌥ Space to speak"
    @Published private(set) var currentTranscript = ""
    @Published private(set) var lastError: String?

    @Published var onboardingVisible = false
    @Published var noticeDetailsVisible = false
    private var noticePanel: NoticePanel?
    private let setupCompletedKey = "setup-completed-v3"
    @Published var workspaceSection: WorkspaceSection = .notes
    private var overlayPanel: OverlayPanel?
    private var workspaceWindow: NSWindow?
    private var processingTask: Task<Void, Never>?
    private var captureGeneration = UUID()
    private let sounds = CaptureSounds()
    private var startTask: Task<Void, Never>?
    private var hotkeyStarted = false
    private var shortcutCaptureActive = false
    private var hasBooted = false
    private var holdToTalkReleasePending = false
    private var transientErrorTask: Task<Void, Never>?
    @Published private(set) var hasFailedRecording = false
    private let recovery: DictationRecoveryStore
    private let dataRoot: URL
    private var activeRecoveryJob: DictationJob?
    private var dictationStreaming: LiveAudioPipeline?
    private var dictationLive: DictationLiveTranscriber?
    private var recordingSourceApplication: String?
    private var recordingSourceBundleIdentifier: String?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var toastTask: Task<Void, Never>?
    private var readyTask: Task<Void, Never>?

    var hasCompletedSetup: Bool { UserDefaults.standard.bool(forKey: setupCompletedKey) }
    var storageRoot: URL { dataRoot }

    init(rootURL: URL? = nil) {
        let root = rootURL ?? AppPaths.root
        dataRoot = root
        store = AppStore(rootURL: root)
        meetings = MeetingController(store: MeetingStore(root: root.appendingPathComponent("Meetings")), credentialRootURL: root)
        calendar = CalendarMeetingController()
        recovery = DictationRecoveryStore(root: root.appendingPathComponent("DictationRecovery"))
        recorder = AudioRecorder()
        permissions = PermissionCenter()
        hotkey = GlobalHotkey()
        providerClient = ProviderClient()
        recorder.onInterruption = { [weak self] error in
            guard let self, self.capturePhase == .recording else { return }
            self.finishCapture()
            self.showTransientError("Recording stopped because the microphone was interrupted. Captured audio is kept for transcription or recovery.\n\n\(error.localizedDescription)")
        }
        meetingSubscription = meetings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        calendarSubscription = calendar.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        Publishers.Merge(meetings.$error, calendar.$error)
            .removeDuplicates()
            .sink { [weak self] message in
                guard let message, !message.isEmpty else { return }
                self?.showTransientError(message)
            }.store(in: &noticeSubscriptions)
        hasFailedRecording = !recovery.jobs.isEmpty
        store.$storageError.removeDuplicates().sink { [weak self] message in
            if let message { self?.showTransientError(message) }
        }.store(in: &noticeSubscriptions)
        if let error = recovery.error { lastError = error }
        do { try CredentialStore.migrateLegacy(settings: store.settings, rootURL: root) }
        catch { lastError = "Could not migrate provider credentials: \(error.localizedDescription)" }
        lastExternalApplication = NSWorkspace.shared.frontmostApplication.flatMap(Self.external)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                if let application = application.flatMap(Self.external) { self?.lastExternalApplication = application }
            }
        }
    }

    private static func external(_ application: NSRunningApplication) -> NSRunningApplication? {
        application.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : application
    }

    private func refreshRecoveryState() {
        hasFailedRecording = !recovery.jobs.isEmpty
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
        NSApp.appearance = theme.appearance
    }

    func boot() {
        guard !hasBooted else { return }
        hasBooted = true
        calendar.boot(app: self)
        applyTheme(settings.theme)
        permissions.refresh()
        NSLog("OpenScribe booted")
        let completed = UserDefaults.standard.bool(forKey: setupCompletedKey)
            || (permissions.hasSeenOnboarding && setupReadiness.canDictate)
        if setupReadiness.shouldPresent(completed: completed, explicitlyRequested: CommandLine.arguments.contains("--onboarding")) {
            showOnboarding()
        }
        startHotkeyIfAllowed()
        if store.settings.showOverlayWhenIdle {
            captureHint = idleHint
            showOverlay()
        }
    }

    private var pasteLastTask: Task<Void, Never>?
    var canPasteLast: Bool { !(store.latestText ?? "").isEmpty && !isDictationBusy && pasteLastTask == nil }

    func pasteLastDictation() {
        guard canPasteLast, let text = store.latestText,
              let target = activeApplicationMetadata().bundleIdentifier else { return }
        pasteLastTask = Task { @MainActor in
            defer { pasteLastTask = nil; objectWillChange.send() }
            do { try await TextInjector.paste(text, into: target) }
            catch { lastError = error.localizedDescription; showTransientError("Paste failed · transcript is still saved") }
        }
    }

    func pasteLastFromQuickPanel() {
        guard canPasteLast, let target = lastExternalApplication, !target.isTerminated,
              let bundleID = target.bundleIdentifier, let text = store.latestText else { return }
        pasteLastTask = Task { @MainActor in
            defer { pasteLastTask = nil; objectWillChange.send() }
            do { try await TextInjector.paste(text, into: bundleID) }
            catch { showTransientError("Paste failed · transcript is still saved.\n\n\(error.localizedDescription)") }
        }
    }

    /// The menu bar panel makes OpenScribe frontmost, so dictation returns to the app used before it.
    func toggleCaptureFromQuickPanel() {
        guard capturePhase != .recording, startTask == nil else { toggleCapture(); return }
        let target = lastExternalApplication.flatMap { $0.isTerminated ? nil : $0 }
        target?.activate()
        startCapture(target: target)
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

    func startCapture(target: NSRunningApplication? = nil) {
        guard !meetings.occupiesCapture else {
            showTransientError("Finish the meeting recording before starting dictation.")
            return
        }
        guard startTask == nil, processingTask == nil, pasteLastTask == nil, capturePhase != .recording else { return }
        readyTask?.cancel()
        readyTask = nil
        let generation = UUID()
        captureGeneration = generation
        holdToTalkReleasePending = false
        permissions.refresh()
        guard !credential(for: .speech).isEmpty else {
            showOnboarding()
            return
        }
        guard permissions.microphoneReady else {
            capturePhase = .idle
            captureHint = "Allow microphone access to dictate"
            showPermissions()
            return
        }
        let activeApplication = target.map { (name: $0.localizedName, bundleIdentifier: $0.bundleIdentifier) }
            ?? activeApplicationMetadata()
        recordingSourceApplication = activeApplication.name
        recordingSourceBundleIdentifier = activeApplication.bundleIdentifier

        lastError = nil
        currentTranscript = ""
        noticePanel?.orderOut(nil)
        transientErrorTask?.cancel()
        transientErrorTask = nil
        captureHint = "Starting…"
        showOverlay()
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if captureGeneration == generation { startTask = nil } }
            do {
                var captureSettings = settings
                if onboardingVisible { captureSettings.pasteIntoFocusedApp = false }
                let job = DictationJob(settings: captureSettings, sourceApplication: recordingSourceApplication,
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
            if case RecorderError.emptyRecording = error, let job = activeRecoveryJob { try? recovery.remove(job.id) }
            activeRecoveryJob = nil
            refreshRecoveryState()
            fail(with: error)
        }
    }

    func cancelCapture() {
        readyTask?.cancel()
        readyTask = nil
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
        refreshRecoveryState()
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
                refreshRecoveryState()
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
        refreshRecoveryState()
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
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "OpenScribe"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 900, height: 620)
            window.setFrameAutosaveName("OpenScribeWorkspace")
            window.center()
            workspaceWindow = window
            window.contentView = NSHostingView(rootView: MainWorkspaceView(controller: self))
        }
        NSApp.activate(ignoringOtherApps: true)
        workspaceWindow?.makeKeyAndOrderFront(nil)
    }
    var setupReadiness: SetupReadiness {
        SetupReadiness(microphone: permissions.microphoneReady, accessibility: permissions.accessibilityTrusted,
                       speechKey: !credential(for: .speech).isEmpty, pasteEnabled: settings.pasteIntoFocusedApp)
    }

    func showOnboarding() {
        onboardingVisible = true
        openMainWindow()
    }

    func finishOnboarding() {
        permissions.refresh()
        guard setupReadiness.canDictate else { return }
        UserDefaults.standard.set(true, forKey: setupCompletedKey)
        permissions.markOnboardingSeen()
        onboardingVisible = false
        startHotkeyIfAllowed()
        workspaceSection = .notes
    }

    func showPermissions() {
        workspaceSection = .permissions
        openMainWindow()
    }

    func refreshPermissions() {
        permissions.refresh()
        if launchAtLogin != LoginItem.isRequested { launchAtLogin = LoginItem.isRequested }
        startHotkeyIfAllowed()
        objectWillChange.send()
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
        guard permissions.accessibilityTrusted, !shortcutCaptureActive else { return }
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
    func setShortcutCaptureActive(_ active: Bool) {
        shortcutCaptureActive = active
        if active { hotkey.stop(); hotkeyStarted = false }
        else { startHotkeyIfAllowed() }
    }
    func updateShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, display: String) {
        updateSettings {
            $0.shortcutKeyCode = keyCode
            $0.shortcutModifiers = modifiers.rawValue
            $0.shortcutDisplay = display
        }
    }

    func open(_ section: WorkspaceSection) {
        workspaceSection = section
        openMainWindow()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do { try LoginItem.setEnabled(enabled) }
        catch { showTransientError(error.localizedDescription) }
        launchAtLogin = LoginItem.isRequested
    }

    /// Short confirmation inside the main window.
    func flash(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_800_000_000) } catch { return }
            self?.toast = nil
        }
    }

    func report(_ error: Error) { showTransientError(error.localizedDescription) }

    func dismissNotice() {
        transientErrorTask?.cancel()
        transientErrorTask = nil
        noticePanel?.orderOut(nil)
    }

    func openSettings() {
        workspaceSection = .general
        openMainWindow()
    }

    func credential(for key: CredentialKey, settings configuration: AppSettings? = nil) -> String {
        CredentialStore.read(for: key, settings: configuration ?? settings, rootURL: dataRoot) ?? ""
    }

    func saveSpeechCredential(_ value: String) throws {
        try CredentialStore.save(value, account: CredentialScope(.speech, settings: settings).account, rootURL: dataRoot)
        objectWillChange.send()
    }

    @discardableResult
    func updateSettings(_ update: (inout AppSettings) -> Void) -> Bool {
        var updated = store.settings
        let previousDictationMode = updated.dictationMode
        let previousShortcutKeyCode = updated.shortcutKeyCode
        let previousShortcutModifiers = updated.shortcutModifiers
        let previousTheme = updated.theme
        update(&updated)
        guard store.saveSettings(updated) else { objectWillChange.send(); return false }
        if previousTheme != updated.theme {
            applyTheme(updated.theme)
        }
        if updated.showOverlayWhenIdle || isDictationBusy { showOverlay() }
        else { hideOverlay() }
        objectWillChange.send()
        if previousDictationMode != updated.dictationMode
            || previousShortcutKeyCode != updated.shortcutKeyCode
            || previousShortcutModifiers != updated.shortcutModifiers {
            restartHotkey()
        }
        return true
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

    @discardableResult
    func updateNote(_ note: VoiceNote) -> Bool {
        let saved = store.updateNote(note)
        objectWillChange.send()
        return saved
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
                refreshRecoveryState()
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
                guard !rawChunks.isEmpty else {
                    throw ProviderClient.ClientError.provider(message: "No speech was detected. Your recording is kept in Notes so you can retry.")
                }
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
                let captureID = job?.id ?? UUID()
                store.addNote(
                    id: captureID,
                    createdAt: job?.createdAt ?? Date(),
                    rawText: raw,
                    cleanedText: cleaned,
                    duration: recording.duration,
                    sourceApplication: sourceApplication,
                    sourceBundleIdentifier: sourceBundleIdentifier
                )
                guard store.hasPersistedNote(captureID) else {
                    throw ProviderClient.ClientError.provider(message: "The transcript could not be saved. Your audio is retained for recovery.")
                }
                if let job { try recovery.remove(job.id) }
                currentTranscript = cleaned
                capturePhase = .ready
                captureHint = "Saved to notes"
                showOverlay()

                if let cleanupFailure {
                    showTransientError("Transcript saved; cleanup unavailable: \(cleanupFailure.localizedDescription)")
                }

                if speechSettings.pasteIntoFocusedApp && pasteResult && !onboardingVisible && sourceBundleIdentifier != nil {
                    do {
                        try await TextInjector.paste(cleaned, into: sourceBundleIdentifier)
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
                    readyTask = Task { @MainActor [weak self] in
                        do { try await Task.sleep(nanoseconds: 1_100_000_000) } catch { return }
                        guard let self, self.captureGeneration == generation, self.capturePhase == .ready else { return }
                        self.capturePhase = .idle
                        self.captureHint = self.idleHint
                        if !self.settings.showOverlayWhenIdle { self.hideOverlay() }
                        self.readyTask = nil
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard captureGeneration == generation, !Task.isCancelled else { return }
                refreshRecoveryState()
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
        capturePhase = .idle
        captureHint = idleHint
        if !settings.showOverlayWhenIdle { hideOverlay() }
        showTransientError(error.localizedDescription)
    }

    private func showTransientError(_ message: String) {
        transientErrorTask?.cancel()
        lastError = message.isEmpty ? "Something went wrong." : message
        if noticePanel == nil { noticePanel = NoticePanel(controller: self) }
        noticePanel?.show()
        transientErrorTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
            self?.noticePanel?.orderOut(nil)
            self?.transientErrorTask = nil
        }
    }

    func inspectNotice(_ message: String? = nil) {
        if let message { lastError = message }
        noticePanel?.orderOut(nil)
        openMainWindow()
        noticeDetailsVisible = true
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
