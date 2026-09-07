import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var permissions: PermissionCenter
    @State private var step = 0
    @State private var key = ""
    @State private var error: String?
    @State private var working = false
    @State private var keySaved = false
    @State private var attemptedPractice = false

    init(controller: AppController) {
        self.controller = controller
        permissions = controller.permissions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                WhisperlightLogo(size: 38)
                Text("Welcome to OpenScribe").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Set up later") { controller.onboardingVisible = false }.buttonStyle(.plain).font(.caption).disabled(controller.isDictationBusy)
            }
            HStack(spacing: 8) {
                ForEach(Array(["Connect", "Permissions", "Try it"].enumerated()), id: \.offset) { index, title in
                    Text("\(index + 1)  \(title)").font(.system(size: 12, weight: .medium))
                        .padding(.vertical, 8).padding(.horizontal, 14)
                        .background(index == step ? FlowTheme.lavender.opacity(0.5) : .clear, in: Capsule())
                }
            }
            Group {
                switch step {
                case 0: connection
                case 1: access
                default: practice
                }
            }.frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.disabled(controller.isDictationBusy) }
                Spacer()
                if step == 0 {
                    Button(keySaved ? "Continue" : "Save & continue") { connect() }
                        .buttonStyle(.borderedProminent).disabled(!keySaved && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if step == 1 {
                    Button("Continue") { step = 2 }.buttonStyle(.borderedProminent).disabled(!controller.setupReadiness.canDictate)
                } else {
                    Button("Start using OpenScribe") { controller.finishOnboarding() }
                        .buttonStyle(.borderedProminent).disabled(!controller.setupReadiness.canDictate || controller.isDictationBusy)
                }
            }
        }.padding(40).frame(maxWidth: 660).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlowTheme.paper).tint(FlowTheme.lavenderDeep)
            .onAppear { keySaved = !controller.credential(for: .speech).isEmpty }
            .onChange(of: CredentialScope(.speech, settings: controller.settings).account) { _, _ in key = ""; keySaved = !controller.credential(for: .speech).isEmpty; error = nil }
            .task {
                while !Task.isCancelled {
                    controller.refreshPermissions()
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose what transcribes your voice.").font(.system(size: 25, weight: .semibold))
            Text("OpenScribe uses your own provider account. Add one API key to get started.").font(.callout).foregroundStyle(.secondary)
            Picker("Provider", selection: Binding(get: { controller.settings.speechProvider }, set: { controller.selectSpeechProvider($0) })) {
                ForEach(SpeechProvider.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
            if keySaved { Label("Key saved for \(controller.settings.speechProvider.title)", systemImage: "checkmark.circle").font(.callout) }
            else { SecureField("Paste your API key", text: $key).textFieldStyle(.roundedBorder).controlSize(.large) }
            if controller.settings.speechProvider == .custom {
                TextField("Base URL", text: Binding(get: { controller.settings.speechBaseURL }, set: { value in controller.updateSettings { $0.speechBaseURL = value } }))
                TextField("Model ID", text: Binding(get: { controller.settings.speechModel }, set: { value in controller.updateSettings { $0.speechModel = value } }))
            }
            Text("Audio goes to the provider you select. Writing cleanup is optional; configure it later in Settings.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Two permissions. Then you’re ready.").font(.system(size: 25, weight: .semibold))
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("Microphone").font(.headline); Text("Hear you only when you start recording.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if permissions.microphoneReady { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else {
                    Button(permissions.microphoneStatus == .notDetermined ? "Allow microphone" : "Open microphone settings") {
                        if permissions.microphoneStatus == .notDetermined {
                            working = true
                            Task { await controller.requestMicrophonePermission(); working = false }
                        } else { controller.openMicrophoneSettings() }
                    }.disabled(working)
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("Type into other apps").font(.headline); Text("Accessibility enables pasting and the global shortcut.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if permissions.accessibilityTrusted { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else { Button("Enable Accessibility") { controller.openAccessibilitySettings() } }
            }
            if !permissions.accessibilityTrusted {
                Text("Enable OpenScribe in the settings window, then return here. This screen updates automatically.").font(.callout).foregroundStyle(.secondary)
                Button("Use Notes only for now") { controller.updateSettings { $0.pasteIntoFocusedApp = false } }.buttonStyle(.link)
                if !controller.settings.pasteIntoFocusedApp { Text("Notes-only mode selected. Start recordings using the app controls.").font(.caption) }
            }
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Try a sentence.").font(.system(size: 25, weight: .semibold))
            Text("Say “This is my first note in OpenScribe.” Your recording will be saved in Notes.").font(.callout).foregroundStyle(.secondary)
            Button(controller.capturePhase == .recording ? "Stop recording" : "Record a test note") {
                if controller.capturePhase == .recording { controller.finishCapture() } else { attemptedPractice = true; controller.startCapture() }
            }.buttonStyle(.bordered).disabled(controller.isDictationBusy && controller.capturePhase != .recording)
            if controller.isDictationBusy { Text(controller.captureHint).font(.caption).foregroundStyle(.secondary) }
            if attemptedPractice && !controller.currentTranscript.isEmpty {
                Text(controller.currentTranscript).textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(FlowTheme.paperMuted, in: RoundedRectangle(cornerRadius: 12))
            }
            Text("Your shortcut: \(controller.settings.shortcutDisplay). Change it any time in Settings → General.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func connect() {
        do {
            if !keySaved {
                let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return }
                try CredentialStore.save(cleaned, account: CredentialScope(.speech, settings: controller.settings).account)
                key = ""; keySaved = true
            }
            // Cleanup is optional and must not make a first dictation fail for a second missing key.
            if controller.credential(for: .languageModel).isEmpty { controller.updateSettings { $0.cleanupEnabled = false } }
            step = 1; error = nil
        } catch { self.error = "Could not save the key: \(error.localizedDescription)" }
    }
}
