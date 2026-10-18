import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var microphones: [MicrophoneDevice] = []
    @State private var showClearConfirmation = false
    var section: WorkspaceSection = .general
    @State private var recordingAction: ShortcutAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowPageHeader(title: section.isSettings ? section.title : "General", subtitle: sectionSubtitle)
                .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 6)
            Group {
                switch section {
                case .connections: connectionsTab
                case .personalize: personalizationTab
                case .shortcuts: shortcutsTab
                case .privacy: privacyTab
                case .permissions: PermissionsView(controller: controller)
                default: generalTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(FlowTheme.background)
        .task { microphones = MicrophoneDevice.available() }
        .onChange(of: section) { _, _ in recordingAction = nil }
        .onChange(of: recordingAction) { _, action in controller.setShortcutCaptureActive(action != nil) }
        .onDisappear { controller.setShortcutCaptureActive(false) }
        .onChange(of: controller.workspaceSection) { _, next in
            if next != .shortcuts { recordingAction = nil }
        }
        .alert("Delete all notes?", isPresented: $showClearConfirmation) {
            Button("Delete all", role: .destructive) { controller.clearNotes(); controller.flash("Note history deleted") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your local notes. Meetings and provider keys are kept.")
        }
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FlowSettingsGroup(title: "Appearance") {
                    HStack(spacing: 12) {
                        ForEach(FlowThemeVariant.allCases) { theme in
                            ThemeChoice(theme: theme, selected: controller.settings.theme == theme) {
                                controller.updateSettings { $0.theme = theme }
                            }
                        }
                    }.padding(14)
                }
                FlowSettingsGroup(title: "Startup", footer: LoginItem.isAvailable
                    ? "OpenScribe stays in your menu bar when you log in."
                    : "Install OpenScribe in Applications to enable launch at login.") {
                    FlowSettingsRow(title: "Launch at login", detail: "Ready whenever inspiration strikes", symbol: "power") {
                        Toggle("Launch at login", isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                            .labelsHidden().toggleStyle(.switch).disabled(!LoginItem.isAvailable)
                    }
                    if controller.loginItemNeedsApproval {
                        FlowRowDivider()
                        FlowSettingsRow(title: "Approval needed", detail: "Allow OpenScribe in Login Items.") {
                            Button("Open System Settings") { LoginItem.openSystemSettings() }.buttonStyle(.flowSecondary)
                        }
                    }
                }
                FlowSettingsGroup(title: "Recording") {
                    FlowSettingsRow(title: "Microphone", symbol: "mic") {
                        Picker("Microphone", selection: settingBinding(\.microphoneDeviceUID)) {
                            Text("System default").tag("")
                            ForEach(microphones) { Text($0.name).tag($0.id) }
                            if !controller.settings.microphoneDeviceUID.isEmpty && !microphones.contains(where: { $0.id == controller.settings.microphoneDeviceUID }) {
                                Text("Selected microphone unavailable").tag(controller.settings.microphoneDeviceUID)
                            }
                        }.labelsHidden().frame(maxWidth: 230)
                        FlowIconButton(symbol: "arrow.clockwise", help: "Refresh microphones") { microphones = MicrophoneDevice.available() }
                    }
                    FlowRowDivider()
                    FlowSettingsRow(title: "Shortcuts", detail: "Dictation, meetings, and screenshots from any app", symbol: "command") {
                        if let hint = controller.settings.dictationHint { FlowKeycaps(shortcut: hint) }
                        Button("Edit") { controller.workspaceSection = .shortcuts }.buttonStyle(.flowSecondary)
                    }
                    FlowRowDivider()
                    toggleRow("Paste into the focused app", detail: "Recordings started here are saved to Notes.", symbol: "text.cursor", key: \.pasteIntoFocusedApp)
                }
                FlowSettingsGroup(title: "Flowbar", footer: "Drag the Flowbar anywhere on screen. It snaps to the center and edges and remembers where you leave it.") {
                    toggleRow("Keep on screen when idle", detail: "Hover it for dictation, meetings, and screenshots.", symbol: "waveform", key: \.showOverlayWhenIdle)
                    FlowRowDivider()
                    FlowSettingsRow(title: "Can’t find it?", symbol: "scope") {
                        Button("Show me") { controller.revealFlowbar() }.buttonStyle(.flow(.secondary, size: .small))
                    }
                    FlowRowDivider()
                    FlowSettingsRow(title: "Position", symbol: "rectangle.bottomthird.inset.filled") {
                        Picker("Position", selection: Binding(
                            get: { controller.settings.flowbarPlacement == nil ? controller.settings.overlayPosition : "custom" },
                            set: { value in
                                guard value != "custom" else { return }
                                controller.updateSettings { $0.overlayPosition = value; $0.flowbarPlacement = nil }
                            })) {
                            Text("Bottom center").tag("bottom-center")
                            Text("Bottom left").tag("bottom-left")
                            Text("Bottom right").tag("bottom-right")
                            Text("Top center").tag("top-center")
                            Text("Top right").tag("top-right")
                            if controller.settings.flowbarPlacement != nil { Text("Where I placed it").tag("custom") }
                        }.labelsHidden().frame(width: 180)
                    }
                    FlowRowDivider()
                    toggleRow("Recording sounds", symbol: "speaker.wave.1", key: \.interactionSounds)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    private func toggleRow(_ title: String, detail: String? = nil, symbol: String, key: WritableKeyPath<AppSettings, Bool>) -> some View {
        FlowSettingsRow(title: title, detail: detail, symbol: symbol) {
            Toggle(title, isOn: settingBinding(key)).labelsHidden().toggleStyle(.switch)
        }
    }

    // MARK: - API & Models

    private var connectionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Transcription")
                    ProviderConnectionCard(controller: controller, purpose: .speech)
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Writing & summaries")
                    ProviderConnectionCard(controller: controller, purpose: .languageModel)
                }
                Text("Each connection has its own model. When both use the same service, you can reuse your saved API key in connection setup.")
                    .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                FlowSettingsGroup(title: "Transcription behavior") {
                    FlowSettingsRow(title: "Live transcription", detail: "Start transcribing before the recording ends.", symbol: "waveform") {
                        Toggle("Live transcription", isOn: settingBinding(\.dictationLiveTranscription)).labelsHidden().toggleStyle(.switch)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(!controller.settings.dictationLiveTranscription ? "Audio is sent after you stop recording." :
                         controller.settings.automaticStreaming && StreamingCapability.resolve(controller.settings) != nil
                         ? "Your current model supports streaming." : "Audio is transcribed in 15-second sections.")
                }.font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                writingBehavior
            }.frame(maxWidth: 760).padding(.horizontal, 32).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var writingBehavior: some View {
        VStack(alignment: .leading, spacing: 14) {
            FlowSettingsGroup(title: "Writing cleanup") {
                FlowSettingsRow(title: "Polish my transcripts", detail: "Clean up speech before it becomes a note.", symbol: "text.badge.checkmark") {
                    Toggle("Polish my transcripts", isOn: settingBinding(\.cleanupEnabled)).labelsHidden().toggleStyle(.switch)
                }
                FlowRowDivider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Cleanup strength").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Picker("Cleanup strength", selection: settingBinding(\.cleanupStrength)) {
                            ForEach(CleanupStrength.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 290)
                    }
                    Text(controller.settings.cleanupStrength.instruction).font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                }.padding(16).disabled(!controller.settings.cleanupEnabled)
                FlowRowDivider()
                FlowSettingsRow(title: "Default tone", detail: "Override this for individual apps in Personalization.") {
                    Picker("Default tone", selection: settingBinding(\.writingTone)) {
                        ForEach(WritingTone.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 170)
                }.disabled(!controller.settings.cleanupEnabled)
            }
            if controller.settings.cleanupEnabled && controller.credential(for: .languageModel).isEmpty {
                Label("Add a writing key to enable cleanup and meeting summaries.", systemImage: "key")
                    .font(.system(size: 12)).foregroundStyle(FlowTheme.warning)
            }
        }
    }

    private var sectionSubtitle: String {
        switch section {
        case .connections: return "Manage your providers, API keys, and models in one place."
        case .personalize: return "Your vocabulary, snippets, and app preferences."
        case .shortcuts: return "Keys for dictation, meetings, and screenshots."
        case .privacy: return "Choose what stays on this Mac."
        case .permissions: return "Manage the access OpenScribe needs."
        default: return "Appearance, recording, and everyday preferences."
        }
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(FlowTheme.inkMuted)
    }

    private var personalizationTab: some View {
        PersonalizationView(controller: controller)
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !controller.hotkeyFailures.isEmpty {
                    FlowBanner(symbol: "exclamationmark.triangle.fill", tint: FlowTheme.warning,
                               title: "Some shortcuts aren’t active",
                               detail: shortcutFailureDetail) {
                        if controller.hotkeyFailures.contains(where: { controller.settings.shortcut(for: $0)?.isGlobe == true }) {
                            Button("Permissions") { controller.workspaceSection = .permissions }.buttonStyle(.flow(.secondary, size: .small))
                        }
                    }
                }
                FlowSettingsGroup(title: "Dictation", footer: "A quick tap of the Dictate shortcut keeps recording until you tap again. Hold it to talk, and release to finish.") {
                    ForEach(Array(ShortcutAction.dictation.enumerated()), id: \.element) { index, action in
                        if index > 0 { FlowRowDivider() }
                        shortcutRow(action)
                    }
                }
                FlowSettingsGroup(title: "Meetings & screenshots", footer: "Screenshots are added to today’s note, and text in them becomes searchable. Screen Recording access is required.") {
                    ForEach(Array(ShortcutAction.capture.enumerated()), id: \.element) { index, action in
                        if index > 0 { FlowRowDivider() }
                        shortcutRow(action)
                    }
                }
                HStack {
                    Text("Shortcuts work in every app and don’t type into it.").font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                    Spacer()
                    Button("Restore defaults") { recordingAction = nil; controller.resetShortcuts(); controller.flash("Shortcuts restored") }
                        .buttonStyle(.flowSecondary)
                }
                HotkeyCaptureView(isRecording: Binding(get: { recordingAction != nil }, set: { if !$0 { recordingAction = nil } })) { keyCode, modifiers, display in
                    guard let action = recordingAction else { return }
                    assign(KeyShortcut(keyCode: keyCode, modifiers: modifiers, display: display), to: action)
                }.frame(width: 0, height: 0)
            }
            .frame(maxWidth: 760).padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shortcutFailureDetail: String {
        let names = controller.hotkeyFailures.map(\.title).joined(separator: ", ")
        return "\(names). Globe needs Accessibility access; other keys may be taken by another app."
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let shortcut = controller.settings.shortcut(for: action)
        let recording = recordingAction == action
        return FlowSettingsRow(title: action.title, detail: recording ? "Press the new shortcut. Escape cancels." : action.detail, symbol: action.symbol) {
            if recording {
                Text("Listening…").font(.system(size: 12, weight: .medium)).foregroundStyle(FlowTheme.accent)
            } else if let shortcut {
                FlowKeycaps(shortcut: shortcut.display)
                    .opacity(controller.hotkeyFailures.contains(action) ? 0.45 : 1)
            } else {
                Text("Not set").font(.system(size: 12)).foregroundStyle(FlowTheme.inkFaint)
            }
            Button(recording ? "Cancel" : shortcut == nil ? "Set" : "Change") { recordingAction = recording ? nil : action }
                .buttonStyle(.flowSecondary)
            Menu {
                if action.usesRelease {
                    Button("Use Globe (fn)") { assign(.globe, to: action) }
                }
                if let fallback = ShortcutDefaults.bindings[action] {
                    Button("Use default (\(fallback.display))") { assign(fallback, to: action) }
                }
                Divider()
                Button("Remove shortcut", role: .destructive) { assign(nil, to: action) }.disabled(shortcut == nil)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More options")
        }
    }

    private func assign(_ shortcut: KeyShortcut?, to action: ShortcutAction) {
        recordingAction = nil
        if let displaced = controller.assignShortcut(shortcut, to: action) {
            controller.flash("Removed from “\(displaced.title)”")
        }
    }

    // MARK: - Privacy

    private var privacyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                FlowSettingsGroup(title: "On this Mac", footer: "Notes and meeting history are kept locally. OpenScribe does not sync your library to a cloud account.") {
                    FlowSettingsRow(title: "Notes", detail: "Saved dictations and written notes", symbol: "doc.text") {
                        Text("\(controller.notes.count)").font(.system(size: 13)).monospacedDigit().foregroundStyle(FlowTheme.inkMuted)
                    }
                    FlowRowDivider()
                    FlowSettingsRow(title: "Meetings", detail: "Recordings, transcripts, and summaries", symbol: "person.2") {
                        Text("\(controller.meetings.meetings.count)").font(.system(size: 13)).monospacedDigit().foregroundStyle(FlowTheme.inkMuted)
                    }
                    FlowRowDivider()
                    FlowSettingsRow(title: "Keep dictation audio", detail: "Keep audio after successful transcription.", symbol: "waveform") {
                        Toggle("Keep dictation audio", isOn: settingBinding(\.saveRawAudio)).labelsHidden().toggleStyle(.switch)
                    }
                }
                FlowSettingsGroup(title: "Your providers") {
                    FlowSettingsRow(title: "Transcription", detail: "Recordings are sent to \(controller.settings.speechProvider.title).", symbol: "mic") {
                        Button("Manage") { controller.workspaceSection = .connections }.buttonStyle(.flowSecondary)
                    }
                    FlowRowDivider()
                    FlowSettingsRow(title: "Writing", detail: controller.settings.cleanupEnabled
                        ? "Cleanup uses \(controller.settings.languageModelProvider.title)." : "Transcript cleanup is off.", symbol: "text.badge.checkmark") {
                        Button("Manage") { controller.workspaceSection = .connections }.buttonStyle(.flowSecondary)
                    }
                }
                Text("Failed or interrupted dictations keep their audio until you retry or discard them. Meeting audio stays with each meeting until you delete it.")
                    .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                FlowSettingsGroup(title: "Delete history") {
                    FlowSettingsRow(title: "Clear all notes", detail: "Permanently remove every note from this Mac.", symbol: "trash") {
                        Button("Delete notes…", role: .destructive) { showClearConfirmation = true }
                            .buttonStyle(.flowSecondary).disabled(controller.notes.isEmpty)
                    }
                }
            }.frame(maxWidth: 760).padding(.horizontal, 32).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private func settingBinding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { value in controller.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }


}

private struct ThemeChoice: View {
    let theme: FlowThemeVariant
    let selected: Bool
    let action: () -> Void
    private var dark: Bool { theme == .dark }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Circle().fill(FlowTheme.accent).frame(width: 7, height: 7)
                        RoundedRectangle(cornerRadius: 2).fill(FlowTheme.accent.opacity(0.3)).frame(height: 5)
                        RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.2)).frame(height: 5)
                        Spacer(minLength: 0)
                    }.padding(8).frame(width: 42).background(Color.gray.opacity(0.12))
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(dark ? Color.white.opacity(0.6) : Color.black.opacity(0.3)).frame(width: 38, height: 5)
                        RoundedRectangle(cornerRadius: 3).fill(dark ? Color.white.opacity(0.08) : Color.white).frame(height: 22)
                        Spacer(minLength: 0)
                    }.padding(10).frame(maxWidth: .infinity)
                }
                .frame(height: 70)
                .background(dark ? Color(white: 0.12) : Color(white: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 5) {
                    if theme == .system { Image(systemName: "circle.lefthalf.filled") }
                    Text(theme.title)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(FlowTheme.accent) }
                }.font(.system(size: 12, weight: .medium))
            }.padding(8).frame(maxWidth: .infinity)
                .background(selected ? FlowTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? FlowTheme.accent : FlowTheme.line, lineWidth: selected ? 1.5 : 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(theme.title + " appearance").accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct HotkeyCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (UInt16, NSEvent.ModifierFlags, String) -> Void

    func makeNSView(context: Context) -> HotkeyCaptureNSView {
        let view = HotkeyCaptureNSView()
        view.onCancel = { isRecording = false }
        view.onCapture = onCapture
        view.isRecording = isRecording
        return view
    }

    func updateNSView(_ nsView: HotkeyCaptureNSView, context: Context) {
        nsView.onCancel = { isRecording = false }
        nsView.onCapture = onCapture
        nsView.isRecording = isRecording
    }

    static func dismantleNSView(_ nsView: HotkeyCaptureNSView, coordinator: ()) {
        nsView.stopRecording()
    }
}

private final class HotkeyCaptureNSView: NSView {
    var onCapture: ((UInt16, NSEvent.ModifierFlags, String) -> Void)?
    var onCancel: (() -> Void)?
    var isRecording = false {
        didSet {
            if isRecording {
                startRecording()
            } else {
                stopRecording()
            }
        }
    }

    private var monitor: Any?
    private var functionIsDown = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isRecording {
            startRecording()
        }
    }

    func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        functionIsDown = false
    }

    private func startRecording() {
        guard monitor == nil else { return }
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }

            if event.type == .flagsChanged {
                let functionDown = event.modifierFlags.contains(.function)
                defer { self.functionIsDown = functionDown }
                if functionDown && !self.functionIsDown {
                    self.capture(
                        keyCode: 63,
                        modifiers: event.modifierFlags.intersection(ShortcutFormatter.supportedModifiers),
                        characters: nil
                    )
                    return nil
                }
                return event
            }

            if event.keyCode == 53 { self.stopRecording(); self.onCancel?(); return nil }
            let modifiers = event.modifierFlags.intersection(ShortcutFormatter.supportedModifiers)
            guard !modifiers.isEmpty else { return event }
            self.capture(keyCode: event.keyCode, modifiers: modifiers, characters: event.charactersIgnoringModifiers)
            return nil
        }
    }

    private func capture(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) {
        let display = ShortcutFormatter.display(keyCode: keyCode, modifiers: modifiers, characters: characters)
        stopRecording()
        onCapture?(keyCode, modifiers, display)
    }

    deinit {
        stopRecording()
    }
}
