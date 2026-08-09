import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var speechKey = ""
    @State private var languageModelKey = ""
    @State private var credentialsSaved = false
    @State private var lmCredentialsSaved = false
    @State private var showClearConfirmation = false
    @State private var selectedTab = 0
    @State private var recordingShortcut = false

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tabItem {
                Label("General", systemImage: "gearshape")
            }.tag(0)

            speechTab.tabItem {
                Label("Speech to Text", systemImage: "mic")
            }.tag(1)

            languageModelTab.tabItem {
                Label("Punctuation", systemImage: "text.badge.checkmark")
            }.tag(2)

            privacyTab.tabItem {
                Label("Privacy", systemImage: "lock.shield")
            }.tag(3)
        }
        .frame(width: 620, height: 520)
        .background(FlowTheme.paperMuted)
        .task { await loadCredentials() }
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
                    title: "How you talk to your Mac."
                ) {
                    HStack(spacing: 10) {
                        WhisperlightLogo(size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Whisperlight")
                                .flowUIFont(size: 14, weight: .semibold)
                                .foregroundStyle(FlowTheme.ink)
                            Text("A warm signal for thoughtful dictation.")
                                .flowUIFont(size: 10)
                                .foregroundStyle(FlowTheme.inkMuted)
                        }
                        Spacer(minLength: 0)
                    }
                    Picker("Theme", selection: settingBinding(\.theme)) {
                        ForEach(FlowThemeVariant.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(controller.settings.theme.detail)
                        .flowUIFont(size: 11)
                        .foregroundStyle(FlowTheme.inkMuted)

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
                SettingsCard(
                    eyebrow: "SPEECH TO TEXT",
                    title: "Choose the ear."
                ) {
                    Picker("Provider", selection: Binding(
                        get: { controller.settings.speechProvider },
                        set: { controller.selectSpeechProvider($0) }
                    )) {
                        ForEach(SpeechProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .flowFieldRow()

                    labeledField("Model", text: settingBinding(\.speechModel), placeholder: controller.settings.speechProvider.defaultModel)
                    labeledField("Base URL", text: settingBinding(\.speechBaseURL), placeholder: controller.settings.speechProvider.defaultBaseURL)
                    credentialField(title: "API key", placeholder: "Stored in app credentials file", text: $speechKey)

                    HStack {
                        Text("OpenAI and Groq use the whisper transcription route. Deepgram and AssemblyAI use their native APIs.")
                            .flowUIFont(size: 11)
                            .foregroundStyle(FlowTheme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if credentialsSaved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .flowUIFont(size: 11, weight: .semibold)
                                .foregroundStyle(.green)
                        }
                        Button("Save key") { saveSpeechCredential() }
                            .buttonStyle(FlowPrimaryButtonStyle(tint: FlowTheme.mint))
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Language Model

    private var languageModelTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsCard(
                    eyebrow: "PUNCTUATION + CLEANUP",
                    title: "Choose the editing brain.",
                    detail: "The punctuation model restores sentence boundaries and removes filler without changing your meaning."
                ) {
                    Toggle("Polish every transcript", isOn: settingBinding(\.cleanupEnabled))
                        .toggleStyle(.switch)

                    Picker("Writing tone", selection: settingBinding(\.writingTone)) {
                        ForEach(WritingTone.allCases) { tone in
                            Text(tone.title).tag(tone)
                        }
                    }
                    .pickerStyle(.segmented)

                    labeledField("Vocabulary", text: vocabularyBinding, placeholder: "Custom names and terms, comma-separated")

                    Divider()
                        .overlay(FlowTheme.ink.opacity(0.12))
                        .padding(.vertical, 4)

                    Picker("Punctuation provider", selection: Binding(
                        get: { controller.settings.languageModelProvider },
                        set: { controller.selectLanguageModelProvider($0) }
                    )) {
                        ForEach(LanguageModelProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .flowFieldRow()

                    labeledField("Punctuation model", text: settingBinding(\.languageModel), placeholder: controller.settings.languageModelProvider.defaultModel)
                    labeledField("Base URL", text: settingBinding(\.languageModelBaseURL), placeholder: controller.settings.languageModelProvider.defaultBaseURL)
                    credentialField(title: "API key", placeholder: "Stored in app credentials file", text: $languageModelKey)

                    HStack {
                        Text("OpenRouter, OpenAI, Groq, Anthropic, and Gemini are supported.")
                            .flowUIFont(size: 11)
                            .foregroundStyle(FlowTheme.inkMuted)
                        Spacer()
                        if lmCredentialsSaved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .flowUIFont(size: 11, weight: .semibold)
                                .foregroundStyle(.green)
                        }
                        Button("Save key") { saveLMCredential() }
                            .buttonStyle(FlowPrimaryButtonStyle(tint: FlowTheme.mint))
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Privacy

    private var privacyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsCard(
                    eyebrow: "LOCAL BY DEFAULT",
                    title: "Your notes stay on this Mac.",
                    detail: "Credentials live in the app's private credentials file. Notes are stored as JSON. Audio is discarded after transcription unless you opt in."
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

    private func credentialField(title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .flowUIFont(size: 12, weight: .semibold)
                .frame(width: 90, alignment: .leading)
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .flowUIFont(size: 12)
        }
    }

    private var vocabularyBinding: Binding<String> {
        Binding(
            get: { controller.settings.customVocabulary.joined(separator: ", ") },
            set: { value in
                let words = value
                    .split(separator: ",")
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

    private func loadCredentials() async {
        let credentials = await Task.detached(priority: .utility) {
            (
                CredentialStore.read(account: CredentialKey.speech.rawValue),
                CredentialStore.read(account: CredentialKey.languageModel.rawValue)
            )
        }.value
        speechKey = credentials.0 ?? ""
        languageModelKey = credentials.1 ?? ""
    }

    private func saveSpeechCredential() {
        controller.saveCredential(speechKey, for: .speech)
        credentialsSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { credentialsSaved = false }
    }

    private func saveLMCredential() {
        controller.saveCredential(languageModelKey, for: .languageModel)
        lmCredentialsSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { lmCredentialsSaved = false }
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
                Text(eyebrow)
                    .flowUIFont(size: 10, weight: .semibold)
                    .tracking(1.3)
                    .foregroundStyle(FlowTheme.lavenderDeep)
                Text(title)
                    .flowDisplayFont(size: 25)
                if !detail.isEmpty {
                    Text(detail)
                        .flowUIFont(size: 12)
                        .foregroundStyle(FlowTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .flowCard(inset: 22)
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
