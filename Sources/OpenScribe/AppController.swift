import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let store: AppStore
    let recorder: AudioRecorder
    let hotkeys = HotkeyCenter()
    let providerClient: ProviderClient
    let meetings: MeetingController
    let calendar: CalendarMeetingController
    let cloud: CloudSyncController
    private var calendarSubscription: AnyCancellable?
    private var meetingSubscription: AnyCancellable?
    private var noticeSubscriptions = Set<AnyCancellable>()
    let permissions: PermissionCenter

    @Published private(set) var capturePhase: CapturePhase = .idle {
        didSet {
            if capturePhase != .recording { captureStartedAt = nil }
            else if oldValue != .recording { captureStartedAt = Date() }
            hotkeys.setEscapeActive(capturePhase == .recording)
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
    /// A short notice is popping out of the Flowbar.
    @Published private(set) var noticeVisible = false
    /// Cached because the system's login-item lookup is too slow to call from views.
    @Published private(set) var loginItemNeedsApproval = LoginItem.needsApproval
    private let setupCompletedKey = "setup-completed-v3"
    @Published var workspaceSection: WorkspaceSection = .notes
    /// Requests from outside a page (Flowbar, menu bar) to show a particular item.
    @Published var noteFocus: NoteFocus?
    @Published var focusedMeetingID: UUID?
    /// A short confirmation shown in the Flowbar, such as after a screenshot.
    @Published private(set) var flowbarMessage: String?
    @Published private(set) var screenshotInProgress = false
    @Published private(set) var hotkeyFailures: [ShortcutAction] = []
    private var flowbarMessageTask: Task<Void, Never>?
    private var dictatePressedAt: Date?
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
    /// Push to talk: hold to record, or double-tap to keep recording hands-free until the next press.
    private enum TalkKeyState: Equatable { case idle, holding(Date), awaitingSecondTap, locked }
    private var talkKey: TalkKeyState = .idle
    private var talkTapTask: Task<Void, Never>?
    /// Recording continues without holding the key; the next press finishes it.
    @Published private(set) var handsFree = false
    /// How the latest shortcut dictation was finished, so onboarding can check off each gesture.
    @Published private(set) var lastDictationGesture: DictationGestureEvent?
    private var onboardingWindow: NSWindow?
    private var onboardingCloseObserver: NSObjectProtocol?
    private var transientErrorTask: Task<Void, Never>?
    @Published private(set) var hasFailedRecording = false
    @Published private(set) var failedRecordingCount = 0
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

    /// Setup was finished once (this version, or the earlier permission onboarding, which could only be
    /// finished with dictation working). After that, onboarding never reopens by itself.
    var hasCompletedSetup: Bool { UserDefaults.standard.bool(forKey: setupCompletedKey) || permissions.hasSeenOnboarding }
    var storageRoot: URL { dataRoot }

    init(rootURL: URL? = nil) {
        let root = rootURL ?? AppPaths.root
        dataRoot = root
        store = AppStore(rootURL: root)
        meetings = MeetingController(store: MeetingStore(root: root.appendingPathComponent("Meetings")), credentialRootURL: root)
        calendar = CalendarMeetingController()
        cloud = CloudSyncController(dataRoot: root)
        recovery = DictationRecoveryStore(root: root.appendingPathComponent("DictationRecovery"))
        recorder = AudioRecorder()
        permissions = PermissionCenter()
        providerClient = ProviderClient()
        recorder.onInterruption = { [weak self] error in
            guard let self, self.capturePhase == .recording else { return }
            self.finishCapture()
            self.showTransientError("Recording stopped because the microphone was interrupted. Captured audio is kept for transcription or recovery.\n\n\(error.localizedDescription)")
        }
        meetings.currentSettings = { [weak self] in self?.store.settings }
        meetingSubscription = meetings.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            Task { @MainActor in self?.meetingStateChanged() }
        }
        calendarSubscription = calendar.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        cloud.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &noticeSubscriptions)
        permissions.onChange = { [weak self] in self?.refreshPermissions() }
        Publishers.Merge(meetings.$error, calendar.$error)
            .removeDuplicates()
            .sink { [weak self] message in
                guard let message, !message.isEmpty else { return }
                self?.showTransientError(message)
            }.store(in: &noticeSubscriptions)
        // Recordings whose note was saved before the app stopped are already done.
        for job in recovery.jobs where store.hasPersistedNote(job.id) { try? recovery.remove(job.id) }
        refreshRecoveryState()
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
        failedRecordingCount = recovery.jobs.count
    }

    var isDictationBusy: Bool { startTask != nil || processingTask != nil || capturePhase == .recording }

    var settings: AppSettings { store.settings }
    var notes: [VoiceNote] { store.notes }
    private var idleHint: String { settings.dictationHint.map { "\($0) to speak" } ?? "Click to dictate" }

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
        cloud.boot(app: self)
        applyTheme(settings.theme)
        permissions.refresh()
        NSLog("OpenScribe booted")
        let forced = CommandLine.arguments.contains("--onboarding")
        if setupReadiness.shouldPresent(completed: hasCompletedSetup, explicitlyRequested: forced) {
            showOnboarding(force: forced)
        }
        startHotkeyIfAllowed()
        captureHint = idleHint
        refreshOverlay()
        // After setup, something missing is a notice and a workspace banner, never the full flow again.
        if hasCompletedSetup && !forced, let missing = setupReadiness.missingRequirement {
            notify(Self.setupNotice(for: missing))
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
            setupMissing(.speechKey)
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
        noticeVisible = false
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
        resetTalkKey()
        // Taps shorter than half a second, or a few seconds of silence, aren't dictation.
        if recorder.duration < Self.minimumRecording
            || (recorder.duration < Self.quietDiscardDuration && recorder.peakLevel < Self.speechLevel) {
            discardShortCapture()
            return
        }
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
            if case RecorderError.emptyRecording = error {
                if let job = activeRecoveryJob { try? recovery.remove(job.id) }
                activeRecoveryJob = nil
                refreshRecoveryState()
                capturePhase = .idle
                captureHint = idleHint
                refreshOverlay()
                return
            }
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
        resetTalkKey()
        recordingSourceApplication = nil
        recordingSourceBundleIdentifier = nil
        currentTranscript = ""
        lastError = nil
        capturePhase = .idle
        captureHint = idleHint
        refreshOverlay()
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

    /// Deletes every recording that is waiting to be transcribed.
    func discardFailedRecordings() {
        guard !isDictationBusy else { return }
        for job in recovery.jobs where activeRecoveryJob?.id != job.id {
            do { try recovery.remove(job.id) } catch { showTransientError(error.localizedDescription) }
        }
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

    /// Opens setup in its own window. Once setup has been completed, requests from the menu bar or the
    /// workspace go to the page that fixes what's missing instead; `force` (the `--onboarding` flag)
    /// always shows the flow from the start.
    func showOnboarding(force: Bool = false) {
        if hasCompletedSetup && !force {
            open(setupReadiness.missingRequirement == .microphone ? .permissions : .connections)
            return
        }
        onboardingVisible = true
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: OnboardingView.windowSize.width, height: OnboardingView.windowSize.height),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Set up OpenScribe"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView(controller: self, restart: force))
            window.center()
            onboardingCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onboardingWindowClosed() }
            }
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    /// Completes setup and opens the workspace, on Notes or on a page a "next" card points to.
    func finishOnboarding(opening section: WorkspaceSection = .notes) {
        permissions.refresh()
        guard setupReadiness.canDictate else { return }
        UserDefaults.standard.set(true, forKey: setupCompletedKey)
        permissions.markOnboardingSeen()
        OnboardingStep.clearSaved()
        onboardingVisible = false
        onboardingWindow?.close()
        startHotkeyIfAllowed()
        open(section)
    }

    /// The close button is the way out of setup; progress is kept and resumes next time.
    private func onboardingWindowClosed() {
        if let onboardingCloseObserver { NotificationCenter.default.removeObserver(onboardingCloseObserver) }
        onboardingCloseObserver = nil
        onboardingWindow?.contentView = nil
        onboardingWindow = nil
        onboardingVisible = false
    }

    /// Dictation or a meeting needs something setup provides. Before setup is finished that means setup;
    /// afterwards a notice explains it and the workspace opens on the page with the fix and its banner.
    private func setupMissing(_ requirement: SetupReadiness.Requirement) {
        guard hasCompletedSetup else { showOnboarding(); return }
        notify(Self.setupNotice(for: requirement))
        open(requirement == .microphone ? .permissions : .connections)
    }

    static func setupNotice(for requirement: SetupReadiness.Requirement) -> String {
        switch requirement {
        case .microphone: return "Microphone access is off, so dictation is paused. Turn it on in Settings › Permissions."
        case .speechKey: return "Add a speech key to dictate. Your notes are safe."
        }
    }

    func showPermissions() {
        workspaceSection = .permissions
        openMainWindow()
    }

    func refreshPermissions() {
        permissions.refresh()
        let requested = LoginItem.isRequested, approval = LoginItem.needsApproval
        if launchAtLogin != requested { launchAtLogin = requested }
        if loginItemNeedsApproval != approval { loginItemNeedsApproval = approval }
        startHotkeyIfAllowed()
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
    // With Accessibility, an event tap handles every kind of shortcut. Without it, key combinations
    // fall back to Carbon hot keys; the rest are re-registered once access is granted.
    private var hotkeysHaveAccessibility = false
    @Published private(set) var hotkeyFailureReasons: [KeyShortcut: HotkeyCenter.FailureReason] = [:]

    private func startHotkeyIfAllowed() {
        guard !shortcutCaptureActive else { return }
        if !hotkeyStarted || hotkeysHaveAccessibility != permissions.accessibilityTrusted {
            hotkeyStarted = true
            configureHotkey()
        }
    }

    private func configureHotkey() {
        hotkeysHaveAccessibility = permissions.accessibilityTrusted
        var bindings: [ShortcutAction: [KeyShortcut]] = [:]
        for action in ShortcutAction.allCases { bindings[action] = settings.shortcuts(for: action) }
        hotkeys.onEscape = { [weak self] in self?.cancelCapture() }
        hotkeys.start(bindings: bindings, accessibility: hotkeysHaveAccessibility,
                      onPress: { [weak self] in self?.shortcutPressed($0) },
                      onRelease: { [weak self] in self?.shortcutReleased($0) },
                      onInterrupt: { [weak self] in self?.shortcutInterrupted($0) })
        hotkeyFailures = hotkeys.failures
        hotkeyFailureReasons = hotkeys.failedShortcuts
    }

    func restartHotkey() {
        guard hotkeyStarted else { return }
        configureHotkey()
    }

    func setShortcutCaptureActive(_ active: Bool) {
        shortcutCaptureActive = active
        if active { hotkeys.stop(); hotkeyStarted = false }
        else { startHotkeyIfAllowed() }
    }

    /// Returns the action that lost this shortcut, if it was already in use.
    @discardableResult
    func assignShortcut(_ shortcut: KeyShortcut?, to action: ShortcutAction) -> ShortcutAction? {
        var displaced: ShortcutAction?
        updateSettings { displaced = $0.assign(shortcut, to: action) }
        return displaced
    }

    /// Adds a shortcut to an action (or swaps `existing` for it). Returns the action that lost it, if any.
    @discardableResult
    func addShortcut(_ shortcut: KeyShortcut, to action: ShortcutAction, replacing existing: KeyShortcut? = nil) -> ShortcutAction? {
        var displaced: ShortcutAction?
        updateSettings { displaced = $0.add(shortcut, to: action, replacing: existing) }
        return displaced
    }

    func removeShortcut(_ shortcut: KeyShortcut, from action: ShortcutAction) {
        updateSettings { $0.remove(shortcut, from: action) }
    }

    func resetShortcuts() {
        updateSettings { $0.resetShortcutBindings() }
    }

    /// Why a particular shortcut isn't active, if it isn't.
    func shortcutProblem(_ shortcut: KeyShortcut) -> String? {
        switch hotkeyFailureReasons[shortcut] {
        case .needsAccessibility: return shortcut.isModifierOnly
            ? "Needs Accessibility access to watch \(shortcut.display) on its own."
            : "macOS only allows this key with Accessibility access."
        case .unavailable: return "Another app or macOS is already using this key."
        case nil: return nil
        }
    }

    // A quick tap of the dictate key keeps recording; holding it records until release.
    private static let holdThreshold: TimeInterval = 0.35
    /// Time allowed between the two taps of a double-tap.
    private static let doubleTapWindow: TimeInterval = 0.32
    /// Anything shorter is a stray tap, never sent for transcription.
    static let minimumRecording: TimeInterval = 0.5
    /// Recordings this short are discarded without a notice when they contain no speech.
    static let quietDiscardDuration: TimeInterval = 3
    /// Meter level (0–1) that counts as someone speaking.
    static let speechLevel: Float = 0.12

    private func resetTalkKey() {
        talkTapTask?.cancel()
        talkTapTask = nil
        talkKey = .idle
        if handsFree { handsFree = false }
    }

    /// Ends a recording that was too short to be meant, without an error or a saved note.
    private func discardShortCapture() {
        guard capturePhase == .recording || startTask != nil else { resetTalkKey(); return }
        cancelCapture()
    }

    private func shortcutPressed(_ action: ShortcutAction) {
        switch action {
        case .dictate:
            if capturePhase == .recording || startTask != nil {
                // A press while recording ends a hands-free (tapped) dictation.
                if dictatePressedAt == nil, capturePhase == .recording { lastDictationGesture = DictationGestureEvent(kind: .handsFree) }
                dictatePressedAt = nil
                toggleCapture()
            } else if capturePhase != .transcribing && capturePhase != .cleaning {
                dictatePressedAt = Date()
                startCapture()
            }
        case .holdToTalk: talkKeyPressed()
        case .meeting: toggleMeeting()
        case .screenshotArea: takeScreenshot(.area)
        case .screenshotWindow: takeScreenshot(.window)
        case .screenshotScreen: takeScreenshot(.screen)
        case .pasteLast: pasteLastDictation()
        }
    }

    private func shortcutReleased(_ action: ShortcutAction) {
        switch action {
        case .dictate:
            guard let pressed = dictatePressedAt else { return }
            dictatePressedAt = nil
            if Date().timeIntervalSince(pressed) >= Self.holdThreshold {
                lastDictationGesture = DictationGestureEvent(kind: .hold)
                finishCapture()
            }
        case .holdToTalk: talkKeyReleased()
        default: break
        }
    }

    /// A lone modifier (Right ⌘, Globe…) turned out to be part of a key combination.
    private func shortcutInterrupted(_ action: ShortcutAction) {
        switch action {
        case .dictate:
            guard dictatePressedAt != nil else { return }
            dictatePressedAt = nil
            discardShortCapture()
        case .holdToTalk:
            switch talkKey {
            case .holding, .awaitingSecondTap: discardShortCapture()
            case .idle, .locked: break
            }
        default: break
        }
    }

    private func talkKeyPressed() {
        switch talkKey {
        case .locked:
            lastDictationGesture = DictationGestureEvent(kind: .handsFree)
            finishCapture()
        case .awaitingSecondTap:
            // Second tap: keep recording without holding the key.
            talkTapTask?.cancel()
            talkTapTask = nil
            talkKey = .locked
            handsFree = true
            captureHint = "Hands-free · press again to finish"
            if settings.interactionSounds { sounds.play(.start) }
        case .idle, .holding:
            if capturePhase == .recording || startTask != nil {
                finishCapture() // Started some other way; this press ends it.
                return
            }
            guard capturePhase != .transcribing && capturePhase != .cleaning else { return }
            talkKey = .holding(Date())
            startCapture()
        }
    }

    private func talkKeyReleased() {
        guard case let .holding(pressed) = talkKey else { return }
        if Date().timeIntervalSince(pressed) >= Self.holdThreshold {
            lastDictationGesture = DictationGestureEvent(kind: .hold)
            finishCapture()
            return
        }
        // A tap: wait briefly for a second tap; a single tap on its own is discarded.
        talkKey = .awaitingSecondTap
        talkTapTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(Self.doubleTapWindow * 1_000_000_000)) } catch { return }
            guard let self, self.talkKey == .awaitingSecondTap else { return }
            self.talkTapTask = nil
            self.discardShortCapture()
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
        loginItemNeedsApproval = LoginItem.needsApproval
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

    /// A short notice beside the Flowbar from other parts of the app, such as the calendar.
    func notify(_ message: String) { showTransientError(message) }

    /// Hovering a notice keeps it open; it fades a moment after the pointer leaves.
    func holdNotice(_ hovering: Bool) {
        guard noticeVisible else { return }
        transientErrorTask?.cancel()
        transientErrorTask = nil
        guard !hovering else { return }
        let info = infoNotice != nil
        transientErrorTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 2_500_000_000) } catch { return }
            self?.noticeVisible = false
            if info { self?.infoNotice = nil }
            self?.transientErrorTask = nil
            self?.refreshOverlay()
        }
    }

    func dismissNotice() {
        transientErrorTask?.cancel()
        transientErrorTask = nil
        noticeVisible = false
        refreshOverlay()
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
        let previous = updated
        update(&updated)
        guard store.saveSettings(updated) else { objectWillChange.send(); return false }
        if previous.theme != updated.theme {
            applyTheme(updated.theme)
        }
        if previous.showOverlayWhenIdle != updated.showOverlayWhenIdle || previous.overlayPosition != updated.overlayPosition
            || previous.flowbarPlacement != updated.flowbarPlacement {
            refreshOverlay(reposition: true)
        }
        if capturePhase == .idle { captureHint = idleHint }
        objectWillChange.send()
        if previous.shortcutBindings != updated.shortcutBindings { restartHotkey() }
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

    /// Asks the classifier about a possible spoken correction. Any failure keeps the transcript as it was.
    private func resolveSpokenCorrections(_ text: String, settings: AppSettings, apiKey: String) async -> SpokenCorrection.Outcome {
        let unchanged = SpokenCorrection.Outcome(text: text, learned: [])
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return unchanged }
        let client = providerClient
        let edits: [SpokenCorrection.Edit]? = await withTaskGroup(of: [SpokenCorrection.Edit]?.self) { group in
            group.addTask { try? await SpokenCorrection.classify(text, vocabulary: settings.customVocabulary, settings: settings, apiKey: apiKey, client: client) }
            group.addTask { try? await Task.sleep(nanoseconds: 8_000_000_000); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        return edits.map { SpokenCorrection.apply($0, to: text) } ?? unchanged
    }

    /// Adds spelled-out words to the vocabulary. Returns what to tell the user.
    private func learn(_ words: [String]) -> String? {
        let new = words.filter { word in !settings.customVocabulary.contains { $0.caseInsensitiveCompare(word) == .orderedSame } }
        guard !new.isEmpty else { return nil }
        updateSettings { $0.customVocabulary += new }
        return "Added " + new.map { "“\($0)”" }.joined(separator: ", ") + " to your dictionary"
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
                    // A brief recording with nothing in it was almost certainly a stray press: drop it quietly.
                    if recording.duration < Self.quietDiscardDuration {
                        if let job { try? recovery.remove(job.id) }
                        guard captureGeneration == generation else { return }
                        capturePhase = .idle
                        captureHint = idleHint
                        refreshOverlay()
                        return
                    }
                    throw ProviderClient.ClientError.provider(message: "No speech was detected. Your recording is kept in Notes so you can retry.")
                }
                try Task.checkCancellation()
                let raw = rawChunks.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentTranscript = raw

                let snippet = VoiceSnippet.expansion(for: raw, snippets: speechSettings.snippets)
                var corrected = DictionaryPass.apply(to: CorrectionRule.apply(to: raw, rules: speechSettings.correctionRules),
                                                     vocabulary: speechSettings.customVocabulary, isCommonWord: DictionaryPass.systemKnows)
                var learned: [String] = []
                if snippet == nil, speechSettings.spokenCorrections, SpokenCorrection.mightContainCorrection(corrected) {
                    capturePhase = .cleaning
                    captureHint = "Checking corrections…"
                    showOverlay()
                    let outcome = await resolveSpokenCorrections(corrected, settings: speechSettings, apiKey: languageKey)
                    try Task.checkCancellation()
                    corrected = outcome.text
                    learned = outcome.learned
                }
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
                } else if speechSettings.learnSpelledWords, let message = learn(learned) {
                    showInfoNotice(message)
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
                        self.refreshOverlay()
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
        refreshOverlay()
        showTransientError(error.localizedDescription)
    }

    private func showTransientError(_ message: String) {
        transientErrorTask?.cancel()
        infoNotice = nil
        lastError = message.isEmpty ? "Something went wrong." : message
        noticeVisible = true
        refreshOverlay()
        transientErrorTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 7_000_000_000) } catch { return }
            self?.noticeVisible = false
            self?.transientErrorTask = nil
            self?.refreshOverlay()
        }
    }

    /// Good news from the pill, such as a word added to the dictionary. Clicking it opens Personalization.
    @Published private(set) var infoNotice: String?

    func showInfoNotice(_ message: String) {
        transientErrorTask?.cancel()
        infoNotice = message
        noticeVisible = true
        refreshOverlay()
        transientErrorTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            self?.noticeVisible = false
            self?.infoNotice = nil
            self?.transientErrorTask = nil
            self?.refreshOverlay()
        }
    }

    func inspectNotice(_ message: String? = nil) {
        if message == nil, infoNotice != nil {
            infoNotice = nil
            dismissNotice()
            open(.personalize)
            return
        }
        if let message { lastError = message }
        noticeVisible = false
        refreshOverlay()
        openMainWindow()
        noticeDetailsVisible = true
    }

    private func showOverlay() {
        if overlayPanel == nil {
            overlayPanel = OverlayPanel(controller: self)
        }
        overlayPanel?.show()
    }

    /// The Flowbar is visible while anything is happening, and when idle if the user keeps it on screen.
    var flowbarNeeded: Bool {
        settings.showOverlayWhenIdle || isDictationBusy || capturePhase == .ready || meetings.occupiesCapture || flowbarMessage != nil
            || noticeVisible || meetings.shortMeeting != nil
    }

    /// Answers to "this meeting was very short; was it a mistake?", asked from the pill.
    func resolveShortMeeting(summarize: Bool? = nil, delete: Bool = false) {
        guard let id = meetings.shortMeeting else { return }
        if delete {
            do { try deleteMeeting(id) } catch { showTransientError(error.localizedDescription) }
        } else if summarize == true {
            meetings.summarizeShortMeeting(id)
        } else {
            meetings.skipSummary(id)
        }
        refreshOverlay()
    }

    func refreshOverlay(reposition: Bool = false) {
        guard !screenshotInProgress else { return }
        if flowbarNeeded {
            if reposition { overlayPanel?.resetPlacement() }
            showOverlay()
        } else {
            overlayPanel?.orderOut(nil)
        }
    }

    /// Keeps the Flowbar on screen and opens it briefly so it's easy to find.
    func revealFlowbar() {
        if !settings.showOverlayWhenIdle { updateSettings { $0.showOverlayWhenIdle = true } }
        refreshOverlay()
        overlayPanel?.model.reveal()
    }

    func hideFlowbar() {
        updateSettings { $0.showOverlayWhenIdle = false }
        refreshOverlay()
    }

    func saveFlowbarPlacement(_ placement: FlowbarPlacement?) {
        var updated = store.settings
        updated.flowbarPlacement = placement
        _ = store.saveSettings(updated)
        objectWillChange.send()
    }

    private func flashFlowbar(_ message: String) {
        flowbarMessageTask?.cancel()
        flowbarMessage = message
        refreshOverlay()
        flowbarMessageTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_600_000_000) } catch { return }
            self?.flowbarMessage = nil
            self?.refreshOverlay()
        }
    }

    // MARK: - Meetings

    var canStartMeeting: Bool { meetings.activeID == nil && !meetings.isBusy && !isDictationBusy }

    func toggleMeeting() {
        if meetings.activeID != nil { meetings.finish() } else { startMeeting() }
    }

    /// Starts immediately with the saved sources. The meeting can be renamed afterwards.
    func startMeeting(title: String = "") {
        guard !isDictationBusy else {
            showTransientError("Finish your dictation before starting a meeting.")
            return
        }
        guard meetings.activeID == nil, !meetings.isBusy else { return }
        permissions.refresh()
        guard !credential(for: .speech).isEmpty || !(settings.meetingLiveTranscription || settings.meetingSummarize) else {
            setupMissing(.speechKey)
            return
        }
        meetings.start(title: title, microphone: settings.meetingMicrophone || !settings.meetingSystemAudio,
                       systemAudio: settings.meetingSystemAudio, settings: settings,
                       summarizeOnStop: settings.meetingSummarize, liveTranscription: settings.meetingLiveTranscription)
        if meetings.activeID != nil, settings.interactionSounds { sounds.play(.start) }
    }

    // MARK: - Meeting notes window

    private var meetingNotesPanel: MeetingNotesPanel?

    /// A small floating notes window for the running meeting. Closing it leaves the meeting recording.
    func showMeetingNotes() {
        guard let id = meetings.activeID else { return }
        if let panel = meetingNotesPanel, panel.meetingID == id {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        meetingNotesPanel?.close()
        let panel = MeetingNotesPanel(controller: self, meetingID: id)
        panel.onClose = { [weak self, weak panel] in
            if self?.meetingNotesPanel === panel { self?.meetingNotesPanel = nil }
        }
        meetingNotesPanel = panel
        if let origin = overlayPanel?.companionOrigin(for: panel.frame.size, gap: 10) { panel.setFrameOrigin(origin) } else { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    func closeMeetingNotes() {
        meetingNotesPanel?.close()
    }

    func openMeeting(_ id: UUID?) {
        focusedMeetingID = id
        open(.meetings)
    }

    func openDayNote(_ date: Date = Date()) {
        noteFocus = Calendar.current.isDateInToday(date) ? NoteFocus(target: .today) : store.dayNote(for: date).map { NoteFocus(target: .note($0.id)) }
        open(.notes)
    }

    func openNote(_ id: UUID) {
        noteFocus = NoteFocus(target: .note(id))
        open(.notes)
    }

    private var linkedMeetingID: UUID?

    /// Keeps the Flowbar in step with meetings and links each new meeting into its day note.
    private func meetingStateChanged() {
        if let id = meetings.activeID, linkedMeetingID != id {
            linkedMeetingID = id
            let linked = store.notes.contains { $0.captures?.contains { $0.meetingID == id && $0.entryKind == .meeting } == true }
            if !linked, let record = meetings.store.record(id) {
                store.addCapture(NoteCapture(id: UUID(), createdAt: record.createdAt, title: record.title, rawText: "", text: "",
                                             duration: 0, sourceApplication: nil, sourceBundleIdentifier: nil,
                                             kind: .meeting, meetingID: id))
            }
        } else if meetings.activeID == nil {
            linkedMeetingID = nil
            closeMeetingNotes()
        }
        refreshOverlay()
    }

    func deleteMeeting(_ id: UUID) throws {
        if meetings.shortMeeting == id { meetings.skipSummary(id); dismissNotice() }
        try meetings.store.delete(id)
        store.removeMeetingEntries(id)
        objectWillChange.send()
    }

    // MARK: - Screenshots

    func takeScreenshot(_ kind: ScreenshotKind) {
        guard !screenshotInProgress else { return }
        let source = activeApplicationMetadata()
        // During a meeting, screenshots also join that meeting's notes.
        let meetingID = meetings.isRecording || meetings.isPaused ? meetings.activeID : nil
        let name = "Screenshot-\(UUID().uuidString).png"
        let url = store.attachmentURL(name)
        screenshotInProgress = true
        overlayPanel?.orderOut(nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { screenshotInProgress = false; refreshOverlay() }
            do {
                // Let the Flowbar leave the screen before a full-screen capture.
                if kind == .screen { try? await Task.sleep(nanoseconds: 120_000_000) }
                guard try await ScreenshotCapture.capture(kind, to: url, playSound: settings.interactionSounds) else { return }
                var capture = NoteCapture(id: UUID(), createdAt: Date(), title: "", rawText: "", text: "", duration: 0,
                                          sourceApplication: source.name, sourceBundleIdentifier: source.bundleIdentifier,
                                          kind: .screenshot, attachment: name, meetingID: meetingID)
                let note = store.addCapture(capture)
                objectWillChange.send()
                flashFlowbar(meetingID == nil ? "Added to today" : "Added to meeting")
                if let text = await ScreenshotCapture.recognizeText(in: url) {
                    capture.recognizedText = text
                    store.updateCapture(capture, in: note.id)
                    objectWillChange.send()
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                showTransientError(error.localizedDescription)
                if case ScreenshotError.permissionNeeded = error { showPermissions() }
            }
        }
    }

    func updateCapture(_ capture: NoteCapture, in noteID: UUID) -> Bool {
        let saved = store.updateCapture(capture, in: noteID)
        objectWillChange.send()
        return saved
    }

    func removeCapture(_ captureID: UUID, from noteID: UUID) {
        store.removeCapture(captureID, from: noteID)
        objectWillChange.send()
    }

    /// Adds a written entry to a day's timeline.
    @discardableResult
    func addDayEntry(_ text: String, on date: Date = Date()) -> VoiceNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let createdAt = Calendar.current.isDateInToday(date) ? Date() : (store.dayNote(for: date)?.lastCapturedAt ?? date)
        let note = store.addCapture(NoteCapture(id: UUID(), createdAt: createdAt, title: "", rawText: "", text: trimmed, duration: 0,
                                                sourceApplication: nil, sourceBundleIdentifier: nil, kind: .text))
        objectWillChange.send()
        return note
    }
}

/// A one-off request to show something in Notes. Each request is distinct, even for the same target.
struct NoteFocus: Equatable {
    enum Target: Equatable { case today, note(UUID) }
    let id = UUID()
    var target: Target
}

enum CredentialKey: String {
    case speech = "speech-api-key"
    case languageModel = "language-model-api-key"
}


/// One finished shortcut dictation. Each event is distinct, so the same gesture twice still registers.
struct DictationGestureEvent: Equatable {
    enum Kind: Equatable {
        /// Held past the hold threshold and released to finish.
        case hold
        /// Started hands-free (a tap, or a double-tap of the push-to-talk key) and finished with another press.
        case handsFree
    }
    let kind: Kind
    let id = UUID()
}
