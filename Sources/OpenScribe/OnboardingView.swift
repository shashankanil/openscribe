import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var permissions: PermissionCenter
    @State private var step = 0
    @State private var error: String?
    @State private var working = false
    @State private var attemptedPractice = false
    @State private var launchAtLogin = true

    init(controller: AppController) {
        self.controller = controller
        permissions = controller.permissions
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                WhisperlightLogo(size: 28)
                Text("OpenScribe").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Set up later") { controller.onboardingVisible = false }
                    .buttonStyle(.flowGhost).disabled(controller.isDictationBusy)
            }.padding(.horizontal, 32).padding(.top, 44)
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 7) {
                    ForEach(Array(["Welcome", "Connect", "Access", "Try it"].enumerated()), id: \.offset) { index, title in
                        HStack(spacing: 6) {
                            ZStack {
                                Circle().fill(index <= step ? FlowTheme.accent : FlowTheme.surfaceMuted).frame(width: 20, height: 20)
                                if index < step { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(FlowTheme.primaryText) }
                                else { Text("\(index + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(index == step ? FlowTheme.primaryText : FlowTheme.inkFaint) }
                            }
                            Text(title).font(.system(size: 11.5, weight: index == step ? .semibold : .regular))
                                .foregroundStyle(index == step ? FlowTheme.ink : FlowTheme.inkFaint)
                        }
                        if index < 3 { Rectangle().fill(FlowTheme.line).frame(height: 1) }
                    }
                }
                Group {
                    switch step {
                    case 0: welcome
                    case 1: connection
                    case 2: access
                    default: practice
                    }
                }.frame(maxWidth: .infinity, minHeight: 285, alignment: .topLeading)
                if let error { Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(FlowTheme.recording) }
                Rectangle().fill(FlowTheme.line).frame(height: 1)
                HStack {
                    if step > 0 { Button("Back") { error = nil; step -= 1 }.buttonStyle(.flowGhost).disabled(controller.isDictationBusy) }
                    Spacer()
                    Button(primaryTitle) { advance() }
                        .buttonStyle(.flow(.primary, size: .large)).disabled(primaryDisabled)
                }
            }
            .padding(30).flowCard(padding: 0, radius: 20).frame(maxWidth: 620)
            .padding(.horizontal, 32)
            Spacer(minLength: 20)
            Text("Your voice. Your providers. Your Mac.").font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(FlowTheme.background)
        .tint(FlowTheme.accent)
        .onAppear {
            if keySaved { step = controller.setupReadiness.canDictate ? 3 : 2 }
            launchAtLogin = controller.launchAtLogin || !controller.hasCompletedSetup
        }
        .task {
            while !Task.isCancelled {
                controller.refreshPermissions()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }

    private var keySaved: Bool { !controller.credential(for: .speech).isEmpty }

    private var primaryTitle: String {
        switch step {
        case 0: return "Let’s get started"
        case 1: return "Continue"
        case 2: return "Continue"
        default: return "Start using OpenScribe"
        }
    }
    private var primaryDisabled: Bool {
        controller.isDictationBusy || (step == 1 && !keySaved)
            || (step >= 2 && !controller.setupReadiness.canDictate)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("A thought. A breath.\nThe words are there.").font(.system(size: 32, weight: .bold, design: .rounded)).tracking(-0.7)
            Text("Speak naturally. OpenScribe turns your voice into writing, right where you work.")
                .font(.system(size: 14)).foregroundStyle(FlowTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                feature("waveform", title: "Speak, don’t type", detail: "A shortcut starts dictation in any app.")
                feature("person.2.wave.2", title: "Keep the conversation", detail: "Record calls and get transcripts and summaries.")
                feature("lock.shield", title: "Stay in control", detail: "Bring your own provider keys. Your history stays on this Mac.")
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Connect your voice", detail: "Add a transcription provider to turn recordings into notes.")
            ProviderConnectionCard(controller: controller, purpose: .speech)
            Text("Recordings go directly to the provider you choose. Writing cleanup is optional and can be set up later.")
                .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("A little access. A lot less typing.", detail: "macOS keeps these permissions under your control.")
            FlowSettingsGroup {
                FlowSettingsRow(title: "Microphone", detail: "Hear you only when you record", symbol: "mic") {
                    if permissions.microphoneReady { FlowBadge(text: "Allowed", color: FlowTheme.success, symbol: "checkmark") }
                    else {
                        Button(working ? "Waiting…" : permissions.microphoneStatus == .notDetermined ? "Allow" : "Open Settings") {
                            if permissions.microphoneStatus == .notDetermined {
                                working = true
                                Task { await controller.requestMicrophonePermission(); working = false }
                            } else { controller.openMicrophoneSettings() }
                        }.buttonStyle(.flowSecondary).disabled(working)
                    }
                }
                FlowRowDivider()
                FlowSettingsRow(title: "Accessibility", detail: "Paste into apps and use your shortcut", symbol: "text.cursor") {
                    if permissions.accessibilityTrusted { FlowBadge(text: "Allowed", color: FlowTheme.success, symbol: "checkmark") }
                    else { Button("Open Settings") { controller.openAccessibilitySettings() }.buttonStyle(.flowSecondary) }
                }
            }
            if !permissions.accessibilityTrusted {
                Text("Enable OpenScribe in Accessibility, then return here. This screen updates automatically.")
                    .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                Button(controller.settings.pasteIntoFocusedApp ? "Use Notes only for now" : "Notes-only mode selected") {
                    controller.updateSettings { $0.pasteIntoFocusedApp = false }
                }.buttonStyle(.flowGhost)
            }
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Make your first note", detail: "Try “This is my first note in OpenScribe.” It will be saved in Notes.")
            HStack {
                Button {
                    if controller.capturePhase == .recording { controller.finishCapture() }
                    else { attemptedPractice = true; controller.startCapture() }
                } label: {
                    Label(controller.capturePhase == .recording ? "Stop & save" : "Try a recording", systemImage: controller.capturePhase == .recording ? "stop.fill" : "mic.fill")
                }.buttonStyle(.flowPrimary).disabled(controller.isDictationBusy && controller.capturePhase != .recording)
                if controller.isDictationBusy {
                    Text(controller.captureHint).font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                    FlowIconButton(symbol: "xmark", help: "Cancel recording") { controller.cancelCapture() }
                }
            }
            if attemptedPractice && !controller.currentTranscript.isEmpty {
                Text(controller.currentTranscript).font(.system(size: 13)).textSelection(.enabled).lineLimit(4)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(FlowTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack { FlowKeycaps(shortcut: controller.settings.shortcutDisplay); Text("Your shortcut. Change it in Settings.").font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted) }
            if LoginItem.isAvailable {
                Toggle("Launch OpenScribe when I log in", isOn: $launchAtLogin).toggleStyle(.switch).font(.system(size: 13))
            }
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 25, weight: .bold)).tracking(-0.4)
            Text(detail).font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feature(_ symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(FlowTheme.accent)
                .frame(width: 34, height: 34).background(FlowTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
            }
        }
    }

    private func advance() {
        guard !primaryDisabled else { return }
        if step == 0 { step = 1 }
        else if step == 1 { connect() }
        else if step == 2 { step = 3 }
        else {
            if LoginItem.isAvailable { controller.setLaunchAtLogin(launchAtLogin) }
            controller.finishOnboarding()
        }
    }

    private func connect() {
        guard keySaved else { return }
        if controller.credential(for: .languageModel).isEmpty { controller.updateSettings { $0.cleanupEnabled = false } }
        step = 2; error = nil
    }
}
