import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var microphones: [MicrophoneDevice] = []
    @State private var showClearConfirmation = false
    var section: WorkspaceSection = .general
    @State private var recordingAction: ShortcutAction?
    /// The shortcut being changed, or nil when adding another one.
    @State private var replacingShortcut: KeyShortcut?
    /// Feedback while recording, such as "Add a modifier".
    @State private var captureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowPageHeader(title: section.isSettings ? section.title : "General", subtitle: sectionSubtitle)
                .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 6)
            Group {
                switch section {
                case .connections: connectionsTab
                case .ai: ContextAccessView(controller: controller, cloud: controller.cloud)
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
                UpdateSettingsSection()
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
        case .ai: return "Give Claude, ChatGPT and other AI tools your notes and meetings as context."
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
                shortcutBanner
                FlowSettingsGroup(title: "Dictation", footer: "Taps shorter than half a second are ignored, so a stray press never creates a note.") {
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
                    Text("Each action can have several shortcuts. Click one to change it, or + to add another.")
                        .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                    Spacer()
                    Button("Restore defaults") { recordingAction = nil; controller.resetShortcuts(); controller.flash("Shortcuts restored") }
                        .buttonStyle(.flowSecondary)
                }
                HotkeyCaptureView(isRecording: Binding(get: { recordingAction != nil }, set: { if !$0 { recordingAction = nil } }),
                                  onInvalid: { captureMessage = $0 }) { shortcut in
                    guard let action = recordingAction else { return }
                    add(shortcut, to: action, replacing: replacingShortcut)
                }.frame(width: 0, height: 0)
            }
            .frame(maxWidth: 760).padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: recordingAction) { _, _ in captureMessage = nil }
    }

    @ViewBuilder private var shortcutBanner: some View {
        let reasons = controller.hotkeyFailureReasons
        if reasons.values.contains(.needsAccessibility) {
            FlowBanner(symbol: "lock.shield", tint: FlowTheme.warning, title: "Some shortcuts need Accessibility access",
                       detail: "macOS only lets OpenScribe watch \(Self.list(reasons.filter { $0.value == .needsAccessibility }.map(\.key.display))) with Accessibility access.") {
                Button("Allow access") { controller.permissions.openAccessibilitySettings() }.buttonStyle(.flow(.secondary, size: .small))
            }
        } else if !reasons.isEmpty {
            FlowBanner(symbol: "exclamationmark.triangle.fill", tint: FlowTheme.warning, title: "Some shortcuts aren’t active",
                       detail: "\(Self.list(reasons.map(\.key.display))) \(reasons.count == 1 ? "is" : "are") already used by another app or by macOS. Pick a different key.") { EmptyView() }
        }
    }

    private static func list(_ items: [String]) -> String {
        let sorted = items.sorted()
        guard sorted.count > 1 else { return sorted.first ?? "" }
        return sorted.dropLast().joined(separator: ", ") + " and " + sorted.last!
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let shortcuts = controller.settings.shortcuts(for: action)
        let recording = recordingAction == action
        let detail = recording ? (captureMessage ?? (action.usesRelease
            ? "Press a key combination, or tap a single modifier such as Right ⌘. Escape cancels."
            : "Press the new key combination. Escape cancels.")) : action.detail
        return FlowSettingsRow(title: action.title, detail: detail, symbol: action.symbol) {
            HStack(spacing: 6) {
                ForEach(shortcuts, id: \.self) { shortcut in
                    ShortcutChip(shortcut: shortcut, problem: controller.shortcutProblem(shortcut),
                                 listening: recording && replacingShortcut == shortcut,
                                 edit: { startRecording(action, replacing: shortcut) },
                                 remove: { recordingAction = nil; controller.removeShortcut(shortcut, from: action) })
                }
                if recording && replacingShortcut == nil {
                    Text("Listening…").font(.system(size: 12, weight: .medium)).foregroundStyle(FlowTheme.accent)
                        .padding(.horizontal, 8).frame(height: 23)
                        .background(FlowTheme.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if shortcuts.isEmpty {
                    Text("Not set").font(.system(size: 12)).foregroundStyle(FlowTheme.inkFaint)
                }
                if recording {
                    Button("Cancel") { recordingAction = nil }.buttonStyle(.flow(.secondary, size: .small))
                } else {
                    FlowIconButton(symbol: "plus", help: "Add a shortcut for \(action.title)") { startRecording(action, replacing: nil) }
                }
                Menu {
                    if action.usesRelease {
                        Section("Add a single key") {
                            ForEach(ShortcutDefaults.holdPresets, id: \.self) { preset in
                                Button(preset.display) { add(preset, to: action, replacing: nil) }
                                    .disabled(shortcuts.contains(preset))
                            }
                        }
                    }
                    if let fallback = ShortcutDefaults.bindings[action] {
                        Button("Use only the default (\(fallback.display))") { assign(fallback, to: action) }
                    }
                    Divider()
                    Button("Remove all", role: .destructive) { assign(nil, to: action) }.disabled(shortcuts.isEmpty)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More options")
            }
        }
    }

    private func startRecording(_ action: ShortcutAction, replacing: KeyShortcut?) {
        replacingShortcut = replacing
        captureMessage = nil
        // Re-trigger the capture view even when switching between two chips of the same action.
        if recordingAction == action { recordingAction = nil; DispatchQueue.main.async { recordingAction = action } }
        else { recordingAction = action }
    }

    private func add(_ shortcut: KeyShortcut, to action: ShortcutAction, replacing: KeyShortcut?) {
        recordingAction = nil
        replacingShortcut = nil
        if let displaced = controller.addShortcut(shortcut, to: action, replacing: replacing) {
            controller.flash("\(shortcut.display) moved from “\(displaced.title)”")
        }
    }

    private func assign(_ shortcut: KeyShortcut?, to action: ShortcutAction) {
        recordingAction = nil
        replacingShortcut = nil
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
    let onInvalid: (String) -> Void
    let onCapture: (KeyShortcut) -> Void

    func makeNSView(context: Context) -> HotkeyCaptureNSView {
        let view = HotkeyCaptureNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: HotkeyCaptureNSView, context: Context) {
        nsView.onCancel = { isRecording = false }
        nsView.onCapture = onCapture
        nsView.onInvalid = onInvalid
        nsView.isRecording = isRecording
    }

    static func dismantleNSView(_ nsView: HotkeyCaptureNSView, coordinator: ()) {
        nsView.stopRecording()
    }
}

/// Records the next shortcut typed while the Shortcuts page is listening. Global hotkeys are
/// suspended meanwhile, so existing bindings can be re-recorded.
///
/// Accepts a key with modifiers, a function key on its own, or a single modifier pressed and
/// released on its own (recorded with its side, such as Right ⌘).
final class HotkeyCaptureNSView: NSView {
    var onCapture: ((KeyShortcut) -> Void)?
    var onInvalid: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var isRecording = false {
        didSet {
            guard isRecording != oldValue || (isRecording && monitor == nil) else { return }
            if isRecording { startRecording() } else { stopRecording() }
        }
    }

    private var monitor: Any?
    /// A modifier that went down on its own; it becomes the shortcut if it is released untouched.
    private var loneModifier: UInt16?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isRecording { startRecording() }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        loneModifier = nil
    }

    private func startRecording() {
        guard monitor == nil else { return }
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Returns true when the event was used.
    func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            let code = event.keyCode
            guard let key = KeyShortcut.modifierKeys[code] else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
            let down = UInt64(event.modifierFlags.rawValue) & key.device != 0 || (code == 63 && flags.contains(.function))
            if down {
                // Only a modifier pressed alone can become a single-key shortcut.
                loneModifier = flags.subtracting(key.generic).subtracting(.function).isEmpty ? code : nil
            } else if loneModifier == code {
                loneModifier = nil
                capture(KeyShortcut(keyCode: code, modifiers: []))
            }
            return true
        }
        loneModifier = nil
        if event.keyCode == 53 { stopRecording(); onCancel?(); return true }
        let modifiers = event.modifierFlags.intersection(ShortcutFormatter.supportedModifiers)
        let display = ShortcutFormatter.display(keyCode: event.keyCode, modifiers: modifiers, characters: event.charactersIgnoringModifiers)
        let shortcut = KeyShortcut(keyCode: event.keyCode, modifiers: modifiers, display: display)
        guard shortcut.isUsable else {
            onInvalid?("Add a modifier such as ⌘, ⌥ or ⌃ so typing “\(display)” still works, or use an F-key.")
            return true
        }
        capture(shortcut)
        return true
    }

    private func capture(_ shortcut: KeyShortcut) {
        stopRecording()
        onCapture?(shortcut)
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// One shortcut in a row: click to change it, × to remove it.
private struct ShortcutChip: View {
    let shortcut: KeyShortcut
    let problem: String?
    let listening: Bool
    let edit: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if listening {
                Text("Listening…").font(.system(size: 12, weight: .medium)).foregroundStyle(FlowTheme.accent).padding(.horizontal, 4)
            } else {
                if problem != nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(FlowTheme.warning)
                }
                FlowKeycaps(shortcut: shortcut.display).opacity(problem == nil ? 1 : 0.5)
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(FlowTheme.inkMuted)
                        .frame(width: 16, height: 16).background(FlowTheme.surfaceMuted, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Remove \(shortcut.display)")
                .accessibilityLabel("Remove \(shortcut.display)")
            }
        }
        .padding(.leading, 3).padding(.trailing, 2).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering || listening ? FlowTheme.surfaceMuted : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: edit)
        .help(problem ?? "Click to change")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
