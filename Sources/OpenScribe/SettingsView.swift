import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var personalizationTab = "Dictionary"
    @State private var microphones: [MicrophoneDevice] = []
    @State private var correctionHeard = ""
    @State private var correctionReplacement = ""
    @State private var snippetTrigger = ""
    @State private var snippetReplacement = ""
    @State private var appBundleID = ""
    @State private var appTone: WritingTone = .natural
    @State private var showClearConfirmation = false
    var section: WorkspaceSection = .general
    @State private var recordingShortcut = false

    var body: some View {
        Group {
            switch section {
            case .calendar: CalendarSettingsView(app: controller, calendar: controller.calendar)
            case .speech: speechTab
            case .cleanup: languageModelTab
            case .personalize: shortcutsTab
            case .privacy: privacyTab
            default: generalTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowTheme.paperMuted)
        .task { microphones = MicrophoneDevice.available() }
        .onChange(of: section) { _, _ in recordingShortcut = false }
        .alert("Delete all notes?", isPresented: $showClearConfirmation) {
            Button("Delete all", role: .destructive) { controller.clearNotes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local note history. Provider credentials are stored in the app's private credentials file.")
        }
    }

    // MARK: - General

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsCard(
                    eyebrow: "GENERAL",
                    title: "General"
                ) {
                    Picker("Theme", selection: settingBinding(\.theme)) {
                        ForEach(FlowThemeVariant.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(controller.settings.theme.detail)
                        .flowUIFont(size: 11)
                        .foregroundStyle(FlowTheme.inkMuted)

                    Picker("Microphone", selection: settingBinding(\.microphoneDeviceUID)) {
                        Text("System default").tag("")
                        ForEach(microphones) { Text($0.name).tag($0.id) }
                        if !controller.settings.microphoneDeviceUID.isEmpty && !microphones.contains(where: { $0.id == controller.settings.microphoneDeviceUID }) {
                            Text("Selected microphone unavailable").tag(controller.settings.microphoneDeviceUID)
                        }
                    }
                    Button("Refresh microphones") { microphones = MicrophoneDevice.available() }
                        .buttonStyle(FlowQuietButtonStyle())

                    Picker("Dictation mode", selection: settingBinding(\.dictationMode)) {
                        ForEach(DictationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(controller.settings.dictationMode.detail)
                        .flowUIFont(size: 11)
                        .foregroundStyle(FlowTheme.inkMuted)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Global shortcut")
                                .flowUIFont(size: 13, weight: .semibold)
                            Text(recordingShortcut ? "Press a key combination, or press Globe." : "Use any modifier plus a key.")
                                .flowUIFont(size: 10)
                                .foregroundStyle(FlowTheme.inkMuted)
                        }
                        Spacer()
                        if !recordingShortcut {
                            Text(controller.settings.shortcutDisplay)
                                .flowUIFont(size: 14, weight: .semibold)
                                .flowPill()
                        }
                        Button("Use Globe") {
                            controller.updateShortcut(
                                keyCode: 63,
                                modifiers: .function,
                                display: "Globe"
                            )
                            recordingShortcut = false
                        }
                        .buttonStyle(FlowQuietButtonStyle())
                        Button(recordingShortcut ? "Cancel" : "Change") {
                            recordingShortcut.toggle()
                        }
                        .buttonStyle(FlowQuietButtonStyle())
                    }

                    HotkeyCaptureView(isRecording: $recordingShortcut) { keyCode, modifiers, display in
                        controller.updateShortcut(keyCode: keyCode, modifiers: modifiers, display: display)
                        recordingShortcut = false
                    }
                    .frame(width: 1, height: 1)

                    Picker("Flowbar position", selection: settingBinding(\.overlayPosition)) {
                        Text("Bottom center").tag("bottom-center")
                        Text("Bottom left").tag("bottom-left")
                        Text("Bottom right").tag("bottom-right")
                    }
                    .pickerStyle(.menu)

                    Toggle("Subtle recording sounds", isOn: settingBinding(\.interactionSounds))
                        .toggleStyle(.switch)

                    Toggle("Show Flowbar when idle", isOn: settingBinding(\.showOverlayWhenIdle))
                        .toggleStyle(.switch)

                    Toggle("Paste polished text into focused app", isOn: settingBinding(\.pasteIntoFocusedApp))
                        .toggleStyle(.switch)
            }
                }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Speech to Text

    private var speechTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsHeading("Transcription", subtitle: "Turn your voice into text.")
                SettingsCard(eyebrow: "", title: "While you speak") {
                    Toggle(isOn: settingBinding(\.dictationLiveTranscription)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start transcribing as I speak").font(.system(size: 13, weight: .medium))
                            Text("Your text is ready sooner when you stop.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch).accessibilityLabel("Start transcribing as I speak")
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").foregroundStyle(FlowTheme.lavenderDeep)
                        Text(!controller.settings.dictationLiveTranscription ? "Audio is sent after you stop." :
                             controller.settings.automaticStreaming && StreamingCapability.resolve(controller.settings) != nil ? "Live transcription available" : "Transcribes in 15-second sections")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SettingsCard(eyebrow: "", title: "Transcription service") {
                    Picker("Provider", selection: Binding(
                        get: { controller.settings.speechProvider },
                        set: { controller.selectSpeechProvider($0) }
                    )) {
                        ForEach(SpeechProvider.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu)
                    ProviderKeyEditor(scope: CredentialScope(.speech, settings: controller.settings),
                                      reuseScope: CredentialScope(.languageModel, settings: controller.settings))
                        .id(CredentialScope(.speech, settings: controller.settings).account)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Model").font(.caption).foregroundStyle(.secondary)
                            Text(controller.settings.speechModel).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                        }
                        Spacer()
                        if !StreamingCapability.models(for: controller.settings.speechProvider).isEmpty {
                            Menu("Change") {
                                Button(controller.settings.speechProvider.defaultModel) {
                                    settingBinding(\.speechModel).wrappedValue = controller.settings.speechProvider.defaultModel
                                }
                                Divider()
                                ForEach(StreamingCapability.models(for: controller.settings.speechProvider).filter { $0 != controller.settings.speechProvider.defaultModel }, id: \.self) { model in
                                    Button(model) { settingBinding(\.speechModel).wrappedValue = model }
                                }
                            }.fixedSize()
                        }
                    }
                    DisclosureGroup("Advanced") {
                        VStack(alignment: .leading, spacing: 14) {
                            labeledField("Model ID", text: settingBinding(\.speechModel), placeholder: controller.settings.speechProvider.defaultModel)
                            labeledField("Base URL", text: settingBinding(\.speechBaseURL), placeholder: controller.settings.speechProvider.defaultBaseURL)
                            Toggle("Use streaming when available", isOn: settingBinding(\.automaticStreaming))
                            Text(StreamingCapability.description(for: controller.settings)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: 680).padding(32).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 25, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(.bottom, 4)
    }

    // MARK: - Language Model

    private var languageModelTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsHeading("Writing & cleanup", subtitle: "Make your words read the way you intended.")
                SettingsCard(eyebrow: "", title: "Your writing style") {
                    Toggle("Polish every transcript", isOn: settingBinding(\.cleanupEnabled))
                        .toggleStyle(.switch)

                    Picker("Cleanup strength", selection: settingBinding(\.cleanupStrength)) {
                        ForEach(CleanupStrength.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Text(controller.settings.cleanupStrength.instruction)
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("Writing tone", selection: settingBinding(\.writingTone)) {
                        ForEach(WritingTone.allCases) { tone in
                            Text(tone.title).tag(tone)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                SettingsCard(eyebrow: "", title: "Writing service") {
                    Picker("Writing provider", selection: Binding(
                        get: { controller.settings.languageModelProvider },
                        set: { controller.selectLanguageModelProvider($0) }
                    )) {
                        ForEach(LanguageModelProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .flowFieldRow()

                    ProviderKeyEditor(scope: CredentialScope(.languageModel, settings: controller.settings),
                                      reuseScope: CredentialScope(.speech, settings: controller.settings))
                        .id(CredentialScope(.languageModel, settings: controller.settings).account)
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model").font(.caption).foregroundStyle(.secondary)
                        Text(controller.settings.languageModel).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    }
                    DisclosureGroup("Advanced") {
                        VStack(spacing: 14) {
                            labeledField("Model ID", text: settingBinding(\.languageModel), placeholder: controller.settings.languageModelProvider.defaultModel)
                            labeledField("Base URL", text: settingBinding(\.languageModelBaseURL), placeholder: controller.settings.languageModelProvider.defaultBaseURL)
                        }.padding(.top, 12)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 680)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func appName(for identifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return identifier }
        return url.deletingPathExtension().lastPathComponent
    }

    private var shortcutsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Personalization", selection: $personalizationTab) {
                    ForEach(["Dictionary", "Snippets", "App styles"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                if personalizationTab == "Dictionary" {
                SettingsCard(eyebrow: "CORRECTION DICTIONARY", title: "Dictionary",
                             detail: "Correct words and phrases automatically, even with cleanup off.") {
                    labeledField("Vocabulary", text: vocabularyBinding, placeholder: "Names and terms, comma-separated")
                    Text("Vocabulary guides AI cleanup. Correction pairs also work with cleanup off.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(controller.settings.correctionRules) { rule in
                        HStack {
                            Text(rule.heard)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(rule.replacement).fontWeight(.medium)
                            Spacer()
                            Button("Remove") { controller.updateSettings { $0.correctionRules.removeAll { $0.id == rule.id } } }
                        }
                    }
                    TextField("Usually transcribed as", text: $correctionHeard)
                    TextField("Replace with", text: $correctionReplacement)
                    Button("Save correction") {
                        let heard = correctionHeard.trimmingCharacters(in: .whitespacesAndNewlines)
                        let replacement = correctionReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
                        controller.updateSettings {
                            $0.correctionRules.removeAll { $0.heard.caseInsensitiveCompare(heard) == .orderedSame }
                            $0.correctionRules.append(CorrectionRule(heard: heard, replacement: replacement))
                        }
                        correctionHeard = ""; correctionReplacement = ""
                    }
                    .disabled(correctionHeard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || correctionReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                }
                if personalizationTab == "Snippets" {
                SettingsCard(eyebrow: "SNIPPETS", title: "Snippets",
                             detail: "Say a trigger as your entire dictation to insert its exact text. Snippets skip AI cleanup.") {
                    ForEach(controller.settings.snippets) { snippet in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(snippet.trigger).fontWeight(.medium)
                                Text(snippet.replacement).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Remove") { controller.updateSettings { $0.snippets.removeAll { $0.id == snippet.id } } }
                        }
                    }
                    TextField("Trigger, e.g. my signature", text: $snippetTrigger)
                    TextField("Text to insert", text: $snippetReplacement, axis: .vertical).lineLimit(3...6)
                    Button("Add snippet") {
                        controller.updateSettings { $0.snippets.append(VoiceSnippet(trigger: snippetTrigger.trimmingCharacters(in: .whitespacesAndNewlines), replacement: snippetReplacement)) }
                        snippetTrigger = ""
                        snippetReplacement = ""
                    }
                    .disabled(snippetTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || snippetReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || VoiceSnippet.expansion(for: snippetTrigger, snippets: controller.settings.snippets) != nil)
                }
                }
                if personalizationTab == "App styles" {
                SettingsCard(eyebrow: "APP STYLES", title: "App styles",
                             detail: "Override your default writing tone when cleanup is enabled. Uses the app where recording begins.") {
                    ForEach(controller.settings.appWritingTones.keys.sorted(), id: \.self) { bundleID in
                        HStack {
                            Text(appName(for: bundleID))
                            Spacer()
                            Text(controller.settings.appWritingTones[bundleID]?.title ?? "")
                            Button("Remove") { controller.updateSettings { $0.appWritingTones.removeValue(forKey: bundleID) } }
                        }
                    }
                    HStack {
                        Button("Choose app…") {
                            let panel = NSOpenPanel()
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            panel.allowedContentTypes = [.applicationBundle]
                            if panel.runModal() == .OK, let url = panel.url,
                               let identifier = Bundle(url: url)?.bundleIdentifier { appBundleID = identifier }
                        }
                        Text(appBundleID.isEmpty ? "No app selected" : appName(for: appBundleID))
                            .foregroundStyle(.secondary)
                    }
                    Picker("Tone", selection: $appTone) {
                        ForEach(WritingTone.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Save app style") {
                        controller.updateSettings { $0.appWritingTones[appBundleID.trimmingCharacters(in: .whitespacesAndNewlines)] = appTone }
                        appBundleID = ""
                    }.disabled(appBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                }
            }.padding(32)
        }
    }

    // MARK: - Privacy

    private var privacyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsCard(
                    eyebrow: "LOCAL BY DEFAULT",
                    title: "Data & privacy",
                    detail: "Credentials live in the app's private credentials file. Notes are stored as JSON. Audio is discarded after successful transcription unless you opt in. Interrupted dictations stay on this Mac until recovered or discarded, including after quitting. Meeting recordings remain with their meeting until you delete it."
                ) {
                    Toggle("Keep temporary audio files", isOn: settingBinding(\.saveRawAudio))
                        .toggleStyle(.switch)

                    HStack {
                        Button("Delete local note history", role: .destructive) { showClearConfirmation = true }
                            .buttonStyle(FlowQuietButtonStyle())
                        Spacer()
                        Text("\(controller.notes.count) note\(controller.notes.count == 1 ? "" : "s")")
                            .flowUIFont(size: 11, weight: .medium)
                            .foregroundStyle(FlowTheme.inkMuted)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private func labeledField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .flowUIFont(size: 12, weight: .semibold)
                .frame(width: 90, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .flowUIFont(size: 12)
        }
    }


    private var vocabularyBinding: Binding<String> {
        Binding(
            get: { controller.settings.customVocabulary.joined(separator: ", ") },
            set: { value in
                let words = value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                controller.updateSettings { $0.customVocabulary = words }
            }
        )
    }

    private func settingBinding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { value in controller.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }


}

// MARK: - SettingsCard

private struct SettingsCard<Content: View>: View {
    let eyebrow: String
    let title: String
    var detail: String = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).flowUIFont(size: 18, weight: .semibold)
                if !detail.isEmpty {
                    Text(detail)
                        .flowUIFont(size: 12)
                        .foregroundStyle(FlowTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(FlowTheme.paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(FlowTheme.line, lineWidth: 1))
    }
}

private struct HotkeyCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (UInt16, NSEvent.ModifierFlags, String) -> Void

    func makeNSView(context: Context) -> HotkeyCaptureNSView {
        let view = HotkeyCaptureNSView()
        view.onCapture = onCapture
        view.isRecording = isRecording
        return view
    }

    func updateNSView(_ nsView: HotkeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.isRecording = isRecording
    }

    static func dismantleNSView(_ nsView: HotkeyCaptureNSView, coordinator: ()) {
        nsView.stopRecording()
    }
}

private final class HotkeyCaptureNSView: NSView {
    var onCapture: ((UInt16, NSEvent.ModifierFlags, String) -> Void)?
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
