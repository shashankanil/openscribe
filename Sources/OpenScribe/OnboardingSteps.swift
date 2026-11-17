import AVFoundation
import AppKit
import AudioToolbox
import OpenScribeObjC
import SwiftUI

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
    let nav: OnboardingNavigator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingPage(step: .welcome, centered: true, spacing: 18) {
            WhisperlightLogo(size: 54)
            OnboardingText.title("Talk. It types.", size: 34)
            Text("Hold a key, say what you mean, and OpenScribe writes it wherever your cursor is. Setup takes about a minute.")
                .font(.system(size: 13.5)).foregroundStyle(FlowTheme.inkMuted)
                .frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Mail — New message").font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint)
                (Text("Hi Priya, thanks for the update — let’s move the review to Thursday at 3.")
                    + Text("|").foregroundColor(FlowTheme.accent))
                    .font(.system(size: 13.5)).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .flowCard(padding: 15, radius: 13)
            .frame(maxWidth: 430)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Example: a sentence typed into a new Mail message")
            OnboardingPill {
                Circle().fill(OnboardingPalette.pillRecording).frame(width: 7, height: 7)
                ListeningSquiggle(still: reduceMotion).frame(width: 46, height: 16)
                Text("Listening")
            }
            .accessibilityHidden(true)
        } leading: {
            Text("Your audio goes only to the provider you choose. Notes stay on this Mac.")
                .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint)
                .frame(maxWidth: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Get started") { nav.next() }
                .buttonStyle(.flow(.primary, size: .large)).keyboardShortcut(.defaultAction)
        }
    }
}

/// A voice-like line for the illustration: it follows a gentle, made-up level. Still with Reduce Motion.
private struct ListeningSquiggle: View {
    let still: Bool

    var body: some View {
        if still {
            FlowSquiggle(color: OnboardingPalette.pillInk, motion: .still, lineWidth: 1.8)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let level = 0.25 + 0.25 * abs(sin(t * 2.1)) + 0.15 * abs(sin(t * 5.3))
                FlowSquiggle(level: level, color: OnboardingPalette.pillInk, motion: .live, lineWidth: 1.8)
            }
        }
    }
}

// MARK: - Microphone

struct OnboardingMicrophoneStep: View {
    @ObservedObject var controller: AppController
    @ObservedObject var permissions: PermissionCenter
    let nav: OnboardingNavigator
    @StateObject private var meter = MicLevelMonitor()
    @State private var requesting = false
    /// macOS had already said no when this screen opened, so a grant means "continue".
    @State private var wasDenied = false

    private var status: AVAuthorizationStatus { permissions.microphoneStatus }

    var body: some View {
        OnboardingPage(step: .microphone) {
            OnboardingText.eyebrow("Step 1 of 4")
            OnboardingText.title(title)
            OnboardingText.body(detail)
            statusCard
            if status == .authorized {
                HStack(spacing: 4) {
                    Text("Say something — the bars should move. Wrong mic?").foregroundStyle(FlowTheme.inkMuted)
                    inputMenu
                }.font(.system(size: 12))
            }
        } actions: {
            Button("Back") { nav.back() }.buttonStyle(.flowGhost).keyboardShortcut(.cancelAction)
            primary
        }
        .onAppear {
            wasDenied = permissions.microphoneNeedsSettings
            startMeter()
        }
        .onDisappear { meter.stop() }
        .onChange(of: status) { _, status in
            guard status == .authorized else { return }
            AccessibilityNotification.Announcement.say("Microphone allowed")
            if wasDenied { nav.next() } else { startMeter() }
        }
        .onChange(of: controller.settings.microphoneDeviceUID) { _, _ in startMeter() }
        // Returning from System Settings is caught by the app's activation check; this covers a
        // window left open beside System Settings.
        .task {
            guard nav.live else { return }
            while !Task.isCancelled {
                permissions.refresh()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }

    private var title: String {
        switch status {
        case .denied: return "Microphone is off for OpenScribe"
        case .restricted: return "The microphone is blocked on this Mac"
        default: return "Let’s make sure we can hear you"
        }
    }

    private var detail: String {
        switch status {
        case .denied: return "macOS only asks once. Open Privacy & Security › Microphone and switch OpenScribe on. We’ll continue automatically."
        case .restricted: return "Your Mac’s administrator has turned the microphone off for apps. Ask them to allow it for OpenScribe, then come back."
        default: return "OpenScribe listens only while you’re recording. macOS will ask once."
        }
    }

    @ViewBuilder private var statusCard: some View {
        HStack(spacing: 12) {
            switch status {
            case .authorized:
                OnboardingCheck(done: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Microphone allowed").font(.system(size: 13, weight: .semibold))
                    Text(deviceName).font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted).lineLimit(1)
                }
                Spacer(minLength: 12)
                LevelBars(levels: meter.levels).accessibilityHidden(true)
            case .denied, .restricted:
                Image(systemName: "mic.slash").font(.system(size: 14, weight: .semibold)).foregroundStyle(FlowTheme.warning)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status == .restricted ? "Blocked by your administrator" : "Microphone is off").font(.system(size: 13, weight: .semibold))
                    Text("Privacy & Security › Microphone").font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                }
                Spacer(minLength: 12)
                if status == .denied { FlowBadge(text: "Waiting…", color: FlowTheme.warning, pulsing: nav.live) }
            default:
                Image(systemName: "mic").font(.system(size: 14, weight: .semibold)).foregroundStyle(FlowTheme.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Microphone").font(.system(size: 13, weight: .semibold))
                    Text(requesting ? "Answer the macOS dialog to continue." : "Not allowed yet").font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                }
                Spacer(minLength: 12)
                if requesting { FlowBadge(text: "Waiting for macOS…", color: FlowTheme.warning, pulsing: nav.live) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowCard(padding: 0, radius: 13)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var primary: some View {
        switch status {
        case .authorized:
            Button("Continue") { nav.next() }.buttonStyle(.flow(.primary, size: .large)).keyboardShortcut(.defaultAction)
        case .denied:
            Button("Open System Settings") { permissions.openMicrophoneSettings() }
                .buttonStyle(.flow(.primary, size: .large)).keyboardShortcut(.defaultAction)
        case .restricted:
            Button("Continue") {}.buttonStyle(.flow(.primary, size: .large)).disabled(true)
        default:
            Button("Allow microphone") {
                guard nav.live else { return }
                requesting = true
                Task { await controller.requestMicrophonePermission(); requesting = false }
            }
            .buttonStyle(.flow(.primary, size: .large)).keyboardShortcut(.defaultAction).disabled(requesting)
        }
    }

    private var inputMenu: some View {
        Menu("Change input") {
            Button("System default") { controller.updateSettings { $0.microphoneDeviceUID = "" } }
            Divider()
            ForEach(MicrophoneDevice.available()) { device in
                Button(device.name) { controller.updateSettings { $0.microphoneDeviceUID = device.id } }
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(FlowTheme.accent)
    }

    private var deviceName: String {
        let devices = MicrophoneDevice.available()
        let uid = controller.settings.microphoneDeviceUID
        if !uid.isEmpty, let chosen = devices.first(where: { $0.id == uid }) { return chosen.name }
        let defaultID = MicrophoneDevice.defaultDeviceID()
        return devices.first(where: { $0.deviceID == defaultID })?.name ?? "System default input"
    }

    private func startMeter() {
        guard nav.live, status == .authorized else { return }
        meter.start(deviceUID: controller.settings.microphoneDeviceUID)
    }
}

/// A small live meter. Bars that are still quiet are drawn faint.
private struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                let level = CGFloat(max(0, min(1, levels[index])))
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > 0.08 ? FlowTheme.success : FlowTheme.line)
                    .frame(width: 5, height: 6 + level * 20)
            }
        }
        .frame(height: 26, alignment: .bottom)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}

/// Listens to the input only while the Microphone step is open, to show that sound arrives.
@MainActor
final class MicLevelMonitor: ObservableObject {
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 8)
    private var engine: AVAudioEngine?

    func start(deviceUID: String) {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty, let unit = input.audioUnit,
           var device = MicrophoneDevice.available().first(where: { $0.id == deviceUID })?.deviceID {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        let block = Self.tap { [weak self] level in self?.push(level) }
        do {
            try ObjCTry.perform {
                input.installTap(onBus: 0, bufferSize: 2048, format: format, block: block)
                engine.prepare()
                try? engine.start()
            }
        } catch { return }
        guard engine.isRunning else { input.removeTap(onBus: 0); return }
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        levels = Array(repeating: 0, count: levels.count)
    }

    private func push(_ level: Float) {
        levels = Array(levels.dropFirst()) + [level]
    }

    /// Built outside the main actor: the audio thread calls it.
    nonisolated private static func tap(_ deliver: @escaping @MainActor @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            let level = min(1, pow(rms * 12, 0.6))
            Task { @MainActor in deliver(level) }
        }
    }
}

// MARK: - Connect

struct OnboardingConnectStep: View {
    @ObservedObject var controller: AppController
    let nav: OnboardingNavigator
    @State private var key = ""
    @State private var verification: Verification = .idle
    @State private var editorOpen = false
    @FocusState private var keyFocused: Bool

    enum Verification: Equatable { case idle, checking, verified, failed(ProviderClient.KeyVerification), saveFailed(String) }

    private static let featured: [SpeechProvider] = [.openRouter, .openAI, .groq]

    private var draft: ProviderConnectionDraft { ProviderConnectionDraft(purpose: .speech, settings: controller.settings) }
    private var provider: SpeechProvider { controller.settings.speechProvider }
    private var title: String { draft.isCustom ? "your server" : draft.title }
    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var savedKey: Bool { !controller.credential(for: .speech).isEmpty }
    /// One key also covers cleanup and summaries when the provider offers both.
    private var sharesKey: Bool { LanguageModelProvider(rawValue: provider.rawValue).map { $0 != .custom } ?? false }

    var body: some View {
        OnboardingPage(step: .connect, spacing: 14) {
            OnboardingText.eyebrow("Step 2 of 4")
            OnboardingText.title("Connect a speech provider")
            OnboardingText.body("OpenScribe sends audio straight to a service you pick — no OpenScribe servers in between. "
                                + (sharesKey ? "One key covers transcription, cleanup and summaries."
                                             : "Cleanup and summaries can use a separate key later."))
            chips
            keyField
            HStack(spacing: 5) {
                Text("Transcription model").foregroundStyle(FlowTheme.inkMuted)
                Text(draft.model).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(FlowTheme.inkMuted)
                    .lineLimit(1).truncationMode(.middle)
                Text("·").foregroundStyle(FlowTheme.inkFaint)
                Button("Advanced") { editorOpen = true }.buttonStyle(.plain).underline().foregroundStyle(FlowTheme.inkMuted)
            }.font(.system(size: 12))
            OnboardingText.note("Stored on this Mac in a permission-restricted file.")
        } actions: {
            Button("Back") { nav.back() }.buttonStyle(.flowGhost).keyboardShortcut(.cancelAction)
                .disabled(verification == .checking)
            Button(verification == .checking ? "Checking…" : "Continue") { submit() }
                .buttonStyle(.flow(.primary, size: .large)).keyboardShortcut(.defaultAction)
                .disabled(verification == .checking || verification == .verified || (trimmedKey.isEmpty && !savedKey))
        }
        .sheet(isPresented: $editorOpen) {
            ProviderConnectionEditor(controller: controller, purpose: .speech) { editorOpen = false }
        }
        .onChange(of: key) { _, _ in if verification != .checking { verification = .idle } }
        .onAppear { if nav.live && !savedKey { keyFocused = true } }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(Self.featured + (Self.featured.contains(provider) ? [] : [provider])) { option in
                ProviderChip(title: option == .custom ? "Custom" : option.title, badge: option == .openRouter ? "EASIEST" : nil,
                             selected: option == provider) {
                    guard option != provider else { return }
                    controller.selectSpeechProvider(option)
                    key = ""; verification = .idle; keyFocused = true
                }
            }
            ProviderChip(title: "More…", badge: nil, selected: false, showsMark: false) { editorOpen = true }
        }
        .disabled(verification == .checking)
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("API key").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let url = ProviderLinks.keyURL(for: draft.providerID) {
                    Link(destination: url) {
                        HStack(spacing: 3) { Text("Get a key"); Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)) }
                    }
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(FlowTheme.accent)
                    .accessibilityLabel("Get a \(draft.title) key")
                }
            }
            HStack(spacing: 8) {
                SecureField(savedKey ? "A key is saved — paste a new one to replace it" : "Paste your \(draft.title) key", text: $key)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($keyFocused)
                    .accessibilityLabel("\(draft.title) API key")
                    .onSubmit { submit() }
                fieldBadge
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(FlowTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(failed ? FlowTheme.recording.opacity(0.6) : keyFocused ? FlowTheme.accent : FlowTheme.line, lineWidth: 1))
            .shadow(color: keyFocused ? FlowTheme.accentSoft : .clear, radius: 0)
            .disabled(verification == .checking)
            failureMessage
        }
        .frame(maxWidth: .infinity)
    }

    private var failed: Bool {
        if case .failed = verification { return true }
        if case .saveFailed = verification { return true }
        return false
    }

    @ViewBuilder private var fieldBadge: some View {
        switch verification {
        case .checking:
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Checking…") }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(FlowTheme.inkMuted)
        case .verified:
            FlowBadge(text: "Key works", color: FlowTheme.success, symbol: "checkmark")
        default:
            if savedKey && trimmedKey.isEmpty { FlowBadge(text: "Saved", color: FlowTheme.success, symbol: "checkmark") }
        }
    }

    @ViewBuilder private var failureMessage: some View {
        switch verification {
        case let .failed(result):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(message(for: result), systemImage: "xmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(failureTint(result)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Save anyway") { save(verified: false) }.buttonStyle(.flow(.secondary, size: .small))
            }
        case let .saveFailed(message):
            Label(message, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(FlowTheme.recording)
        default:
            EmptyView()
        }
    }

    private func message(for result: ProviderClient.KeyVerification) -> String {
        switch result {
        case .ok: return ""
        case let .unauthorized(status):
            return "\(title) rejected this key\(status > 0 ? " (\(status))" : ""). Check it and try again, or get a new key."
        case let .unexpected(status):
            return "\(title) answered with an error (HTTP \(status)), so the key couldn’t be confirmed."
        case .unreachable:
            return "Couldn’t reach \(title). Check your connection, or save the key and it’s checked on your first dictation."
        }
    }

    private func failureTint(_ result: ProviderClient.KeyVerification) -> Color {
        if case .unauthorized = result { return FlowTheme.recording }
        return FlowTheme.warning
    }

    private func submit() {
        guard verification != .checking, verification != .verified else { return }
        if trimmedKey.isEmpty {
            guard savedKey else { keyFocused = true; return }
            configureWriting(with: controller.credential(for: .speech))
            nav.next()
            return
        }
        guard nav.live else { return }
        if let problem = draft.validationMessage { verification = .saveFailed(problem); return }
        verification = .checking
        let settings = controller.settings, candidate = trimmedKey
        Task {
            let result = await controller.providerClient.verify(settings: settings, key: candidate)
            guard verification == .checking else { return }
            if result == .ok { save(verified: true) } else { verification = .failed(result) }
        }
    }

    private func save(verified: Bool) {
        do {
            try controller.saveConnection(draft, key: trimmedKey)
        } catch {
            verification = .saveFailed(error.localizedDescription)
            return
        }
        configureWriting(with: trimmedKey)
        key = ""
        if verified {
            verification = .verified
            AccessibilityNotification.Announcement.say("Key works")
            Task {
                try? await Task.sleep(nanoseconds: 650_000_000)
                nav.next()
            }
        } else {
            nav.next()
        }
    }

    /// Reuses the same key for cleanup and summaries when the provider offers both and no writing key
    /// exists yet; otherwise cleanup waits for its own key instead of failing on every dictation.
    private func configureWriting(with key: String) {
        guard controller.credential(for: .languageModel).isEmpty else { return }
        if sharesKey, !key.isEmpty {
            var writing = ProviderConnectionDraft(purpose: .languageModel, settings: controller.settings)
            writing.select(provider.rawValue)
            if (try? controller.saveConnection(writing, key: key)) != nil { return }
        }
        controller.updateSettings { $0.cleanupEnabled = false }
    }
}

private struct ProviderChip: View {
    let title: String
    let badge: String?
    let selected: Bool
    var showsMark = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if showsMark {
                    Text(String(title.prefix(1))).font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(FlowTheme.inkMuted)
                        .frame(width: 20, height: 20)
                        .background(FlowTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                if let badge {
                    Text(badge).font(.system(size: 9.5, weight: .bold)).tracking(0.2).foregroundStyle(FlowTheme.accent)
                }
            }
            .foregroundStyle(FlowTheme.ink)
            .frame(minHeight: 20)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(selected ? FlowTheme.accentSoft : hovering ? FlowTheme.surfaceHover : FlowTheme.surface,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? FlowTheme.accent : FlowTheme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Works in every app (Accessibility)

struct OnboardingEveryAppStep: View {
    @ObservedObject var controller: AppController
    @ObservedObject var permissions: PermissionCenter
    let nav: OnboardingNavigator
    @State private var waiting = false
    @State private var offerAlternative = false

    private var trusted: Bool { permissions.accessibilityTrusted }
    private var dictate: KeyShortcut? { controller.settings.shortcut(for: .dictate) }
    /// The Dictate shortcut is one macOS only lets an app watch with Accessibility (⌥ Space on macOS 15+).
    private var dictateNeedsAccess: Bool { dictate?.needsEventTap == true }

    var body: some View {
        OnboardingPage(step: .everyApp, spacing: 14) {
            OnboardingText.eyebrow("Step 3 of 4 · optional")
            OnboardingText.title("Works in every app")
            OnboardingText.body(detail)
            settingsPreview
            status
            if offerAlternative && !trusted, let dictate { alternativeOffer(dictate) }
            if !LoginItem.isAvailable && !trusted {
                OnboardingText.note("Move OpenScribe to the Applications folder first so macOS remembers this permission.")
            }
        } actions: {
            Button("Back") { nav.back() }.buttonStyle(.flowGhost).keyboardShortcut(.cancelAction)
            if trusted {
                Button("Continue") { nav.next() }.buttonStyle(.flow(.primary, size: .large)).keyboardShortcut(.defaultAction)
            } else {
                Button("Skip — keep text in Notes") { skip() }.buttonStyle(.flowGhost)
                Button("Open System Settings") { requestAccess() }
                    .buttonStyle(.flow(.primary, size: .large)).keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: permissions.accessibilityTrusted) { _, granted in
            guard granted else { return }
            // Allowing access means they want text typed where they work.
            controller.updateSettings { $0.pasteIntoFocusedApp = true }
            controller.refreshPermissions()
            AccessibilityNotification.Announcement.say("Accessibility allowed")
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                if permissions.accessibilityTrusted { nav.next() }
            }
        }
        .task(id: waiting) {
            guard nav.live, waiting else { return }
            while !Task.isCancelled {
                permissions.refresh()
                do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            }
        }
    }

    private var detail: String {
        let shortcut = dictate.map { " and hear \($0.display) from any app" } ?? ""
        return dictateNeedsAccess
            ? "Allow Accessibility so OpenScribe can type your words wherever your cursor is — Mail, Slack, your editor —\(shortcut)."
            : "Allow Accessibility so OpenScribe can type your words wherever your cursor is — Mail, Slack, your editor. Without it, they’re saved in Notes."
    }

    private var settingsPreview: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Privacy & Security › Accessibility").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(FlowTheme.inkFaint)
                Spacer()
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            HStack(spacing: 10) {
                WhisperlightLogo(size: 26)
                Text("OpenScribe").font(.system(size: 12.5, weight: .medium))
                Spacer()
                if !trusted {
                    Text("Switch this on").font(.system(size: 11, weight: .semibold)).foregroundStyle(FlowTheme.accent)
                }
                FauxSwitch(on: trusted)
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(trusted ? Color.clear : FlowTheme.accentSoft)
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(FlowTheme.surfaceMuted).frame(width: 26, height: 26)
                Text("Other app").font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkFaint)
                Spacer()
                FauxSwitch(on: false)
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
        }
        .background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trusted ? "OpenScribe is switched on in Accessibility" : "In System Settings, switch on OpenScribe under Privacy & Security, Accessibility")
    }

    @ViewBuilder private var status: some View {
        if trusted {
            HStack(spacing: 8) {
                FlowBadge(text: "Allowed", color: FlowTheme.success, symbol: "checkmark")
                Text("OpenScribe can type into other apps.").font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
            }
        } else if waiting {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    FlowBadge(text: "Waiting…", color: FlowTheme.warning, pulsing: nav.live)
                    Text("We’ll notice the moment you switch it on.").font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                }
                DisclosureGroup("Switched on but not working?") {
                    HStack(alignment: .top, spacing: 10) {
                        Text("Remove OpenScribe from the list with −, add it again with +, then restart the app.")
                            .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                        Button("Restart OpenScribe") { controller.restartApplication() }.buttonStyle(.flow(.secondary, size: .small))
                    }.padding(.top, 6)
                }
                .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
            }
        } else {
            OnboardingText.note("macOS shows its own dialog first. You can change this any time in Settings › Permissions.")
        }
    }

    private func alternativeOffer(_ shortcut: KeyShortcut) -> some View {
        FlowBanner(symbol: "keyboard", tint: FlowTheme.warning, title: "\(shortcut.display) needs this access",
                   detail: "Use \(OnboardingShortcuts.fallback.display) instead? It works without Accessibility.") {
            Button("Keep \(shortcut.display)") { nav.next() }.buttonStyle(.flow(.ghost, size: .small))
            Button("Use \(OnboardingShortcuts.fallback.display) instead") {
                controller.assignShortcut(OnboardingShortcuts.fallback, to: .dictate)
                nav.next()
            }
            .buttonStyle(.flow(.secondary, size: .small))
        }
    }

    private func requestAccess() {
        waiting = true
        guard nav.live else { return }
        permissions.requestAccessibilityPrompt()
    }

    private func skip() {
        controller.updateSettings { $0.pasteIntoFocusedApp = false }
        if dictateNeedsAccess && !offerAlternative {
            withAnimation(FlowTheme.spring) { offerAlternative = true }
        } else {
            nav.next()
        }
    }
}

private struct FauxSwitch: View {
    let on: Bool
    var body: some View {
        Capsule().fill(on ? FlowTheme.success : FlowTheme.line)
            .frame(width: 32, height: 19)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 15, height: 15).shadow(color: .black.opacity(0.3), radius: 1, y: 1).padding(2)
            }
    }
}

/// Shortcuts that work without Accessibility, offered when the chosen one can't be used.
enum OnboardingShortcuts {
    /// ⌃⌥ Space: Control keeps it out of the Option-only combinations macOS 15 reserves for event taps.
    static let fallback = KeyShortcut(keyCode: 49, modifiers: [.control, .option])
    static let alternatives: [KeyShortcut] = [fallback, KeyShortcut(keyCode: 49, modifiers: [.control, .shift])]
}

// MARK: - Try it

struct OnboardingTryItStep: View {
    @ObservedObject var controller: AppController
    @ObservedObject var permissions: PermissionCenter
    let nav: OnboardingNavigator
    @State private var held = false
    @State private var tappedHandsFree = false
    @State private var pending: DictationGestureEvent.Kind?
    @State private var attempted = false
    @State private var succeeded = false
    @State private var tooShort = false
    @State private var failure: String?

    private var phase: CapturePhase { controller.capturePhase }
    private var dictate: KeyShortcut? { controller.settings.shortcut(for: .dictate) }
    private var shortcut: KeyShortcut? { dictate ?? controller.settings.shortcut(for: .holdToTalk) }
    private var problem: String? { shortcut.flatMap { controller.shortcutProblem($0) } }

    var body: some View {
        OnboardingPage(step: .tryIt, spacing: 13) {
            OnboardingText.eyebrow("Step 4 of 4")
            OnboardingText.title("Now say something")
            instruction
            if let shortcut, problem != nil { shortcutProblem(shortcut) }
            else if shortcut == nil { missingShortcut }
            transcriptCard
            HStack(spacing: 9) {
                checkOff(done: held, title: "Hold to talk", detail: "Release to finish")
                checkOff(done: tappedHandsFree, title: "Tap to go hands-free", detail: "Tap again to finish")
            }
            HStack(spacing: 8) {
                Text("No keyboard handy?").font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                Button {
                    if phase == .recording { controller.finishCapture() } else { attempted = true; controller.startCapture() }
                } label: {
                    Label(phase == .recording ? "Stop" : "Record", systemImage: phase == .recording ? "stop.fill" : "mic.fill")
                }
                .buttonStyle(.flow(.secondary, size: .small))
                .disabled(!nav.live || (controller.isDictationBusy && phase != .recording))
                Spacer()
                Text("Esc cancels a recording.").font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint)
            }
        } actions: {
            Button("Back") { nav.back() }.buttonStyle(.flowGhost).keyboardShortcut(.cancelAction).disabled(controller.isDictationBusy)
            if !succeeded {
                Button("Skip") { nav.next() }.buttonStyle(.flowGhost).disabled(controller.isDictationBusy)
            }
            Button("Continue") { nav.next() }
                .buttonStyle(.flow(.primary, size: .large)).keyboardShortcut(.defaultAction)
                .disabled(!succeeded || controller.isDictationBusy)
        }
        .onChange(of: controller.lastDictationGesture) { _, event in pending = event?.kind }
        .onChange(of: controller.capturePhase) { old, new in phaseChanged(from: old, to: new) }
    }

    private var instruction: some View {
        HStack(spacing: 0) {
            if let shortcut {
                Text("Hold ")
                FlowKeycaps(shortcut: shortcut.display)
                Text(", speak, let go. " + (permissions.accessibilityTrusted ? "This works in every app." : "Your words are saved in Notes."))
            } else {
                Text("Use the Record button below, speak, then stop.")
            }
        }
        .font(.system(size: 13.5)).foregroundStyle(FlowTheme.inkMuted)
        .accessibilityElement(children: .combine)
    }

    private func shortcutProblem(_ shortcut: KeyShortcut) -> some View {
        let needsAccess = controller.hotkeyFailureReasons[shortcut] == .needsAccessibility
        let options = OnboardingShortcuts.alternatives.filter { $0 != shortcut && controller.hotkeyFailureReasons[$0] == nil }.prefix(needsAccess ? 1 : 2)
        return FlowBanner(symbol: "exclamationmark.triangle.fill", tint: FlowTheme.warning,
                          title: needsAccess ? "\(shortcut.display) needs Accessibility on this Mac" : "\(shortcut.display) is already used by another app",
                          detail: needsAccess ? "Allow access, or switch to a shortcut that works without it."
                                              : "Apps like Raycast use it by default. Pick another, or use Record below.") {
            if needsAccess {
                Button("Allow access") { nav.go(.everyApp) }.buttonStyle(.flow(.ghost, size: .small))
            } else {
                Button("More…") { controller.open(.shortcuts) }.buttonStyle(.flow(.ghost, size: .small))
            }
            ForEach(Array(options), id: \.self) { option in
                Button("Use \(option.display)") { controller.assignShortcut(option, to: .dictate) }
                    .buttonStyle(.flow(.secondary, size: .small))
            }
        }
    }

    private var missingShortcut: some View {
        FlowBanner(symbol: "keyboard", tint: FlowTheme.warning, title: "No Dictate shortcut is set",
                   detail: "Add one to dictate from any app.") {
            Button("Use \(OnboardingShortcuts.fallback.display)") { controller.assignShortcut(OnboardingShortcuts.fallback, to: .dictate) }
                .buttonStyle(.flow(.secondary, size: .small))
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Your first dictation").font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint)
                Spacer()
                if succeeded && !controller.isDictationBusy {
                    FlowBadge(text: "Saved to Notes", color: FlowTheme.success, symbol: "checkmark")
                }
            }
            transcriptContent
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .flowCard(padding: 0, radius: 13)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var transcriptContent: some View {
        let text = controller.currentTranscript
        switch phase {
        case .recording:
            HStack(spacing: 10) {
                Circle().fill(FlowTheme.recording).frame(width: 7, height: 7)
                RecorderSquiggle(recorder: controller.recorder, color: FlowTheme.recording).frame(width: 90, height: 18)
                Text(text.isEmpty ? "Listening…" : text).font(.system(size: 13.5)).lineLimit(2)
                    .foregroundStyle(text.isEmpty ? FlowTheme.inkMuted : FlowTheme.ink)
            }
        case .transcribing, .cleaning:
            HStack(spacing: 10) {
                FlowSquiggle(color: FlowTheme.accent, motion: .flowing).frame(width: 40, height: 16)
                Text(phase == .cleaning ? "Polishing…" : "Transcribing…").font(.system(size: 13.5)).foregroundStyle(FlowTheme.inkMuted)
            }
        default:
            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(failure).font(.system(size: 13)).foregroundStyle(FlowTheme.recording).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Check my key") { nav.go(.connect) }.buttonStyle(.flow(.secondary, size: .small))
                }
            } else if tooShort {
                Text("That was too short to keep. Hold the keys while you say a full sentence.")
                    .font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted)
            } else if attempted && !text.isEmpty {
                Text(text).font(.system(size: 14)).lineLimit(3).textSelection(.enabled)
            } else {
                Text("Try “This is my first note in OpenScribe.”").font(.system(size: 14)).foregroundStyle(FlowTheme.inkFaint)
            }
        }
    }

    private func checkOff(done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OnboardingCheck(done: done)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .flowCard(padding: 0, radius: 13)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "Not yet")
    }

    private func phaseChanged(from old: CapturePhase, to new: CapturePhase) {
        switch new {
        case .recording:
            attempted = true; tooShort = false; failure = nil
        case .ready:
            succeeded = true
            switch pending {
            case .hold: held = true; AccessibilityNotification.Announcement.say("Hold to talk, done")
            case .handsFree: tappedHandsFree = true; AccessibilityNotification.Announcement.say("Hands-free, done")
            case nil: break
            }
            pending = nil
        case .idle:
            if old == .recording, pending != nil { tooShort = true }
            if old == .transcribing || old == .cleaning, let error = controller.lastError { failure = UserNotice.summary(error) }
            pending = nil
        default:
            break
        }
    }
}

// MARK: - Done

struct OnboardingDoneStep: View {
    @ObservedObject var controller: AppController
    let nav: OnboardingNavigator
    @State private var launchAtLogin = true

    var body: some View {
        OnboardingPage(step: .done, spacing: 13) {
            OnboardingText.title("You’re set. Meet the Flowbar.")
            desk
            if LoginItem.isAvailable {
                Toggle("Launch OpenScribe at login so the Flowbar is always there", isOn: $launchAtLogin)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
            }
            HStack(alignment: .top, spacing: 9) {
                nextCard(title: "Meetings", detail: "Record calls, get summaries. Asks for system audio the first time.", section: .meetings)
                nextCard(title: "Screenshots", detail: nil, section: .shortcuts) {
                    HStack(spacing: 5) {
                        if let shortcut = controller.settings.shortcut(for: .screenshotArea) { FlowKeycaps(shortcut: shortcut.display) }
                        Text("sends them to today’s note.")
                    }
                }
                nextCard(title: "Use your notes in AI", detail: "Claude, ChatGPT and Cursor, through MCP.", section: .ai)
            }
        } leading: {
            Text("Lost it? Menu bar › Show me the Flowbar").font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint)
        } actions: {
            Button("Back") { nav.back() }.buttonStyle(.flowGhost).keyboardShortcut(.cancelAction)
            Button("Open OpenScribe") { finish(.notes) }
                .buttonStyle(.flow(.primary, size: .large)).keyboardShortcut(.defaultAction)
        }
        .onAppear {
            launchAtLogin = controller.launchAtLogin || !controller.hasCompletedSetup
            if nav.live { controller.revealFlowbar() }
        }
    }

    private var desk: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [FlowTheme.accent.opacity(0.22), FlowTheme.surfaceMuted], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "waveform").font(.system(size: 9, weight: .semibold))
                    Image(systemName: "wifi").font(.system(size: 9, weight: .semibold))
                    Text("9:41").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(FlowTheme.inkMuted)
                .padding(.horizontal, 10).frame(height: 20)
                .background(FlowTheme.surface.opacity(0.8))
                Rectangle().fill(FlowTheme.line).frame(height: 1)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Any app").font(.system(size: 11, weight: .medium)).foregroundStyle(FlowTheme.inkMuted)
                Text("Your words appear here.").font(.system(size: 11)).foregroundStyle(FlowTheme.inkFaint)
            }
            .padding(10)
            .frame(width: 300, height: 56, alignment: .topLeading)
            .background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
            .padding(.top, 31)
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    callout("Hover for actions")
                    Spacer()
                    OnboardingPill {
                        Image(systemName: "mic.fill")
                        Image(systemName: "person.2.wave.2.fill")
                        Image(systemName: "camera.viewfinder")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    callout("Drag it anywhere")
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The Flowbar sits at the bottom of your screen. Hover it for dictation, meeting and screenshot actions, and drag it anywhere.")
    }

    private func callout(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(FlowTheme.ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
    }

    private func nextCard(title: String, detail: String?, section: WorkspaceSection) -> some View {
        nextCard(title: title, detail: detail, section: section) { EmptyView() }
    }

    private func nextCard<Extra: View>(title: String, detail: String?, section: WorkspaceSection, @ViewBuilder extra: () -> Extra) -> some View {
        Button { finish(section) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(FlowTheme.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(FlowTheme.inkFaint)
                }
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                extra().font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted)
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .flowHoverHighlight(radius: 13)
        .accessibilityHint("Finishes setup and opens \(section.title)")
    }

    private func finish(_ section: WorkspaceSection) {
        guard nav.live else { return }
        if LoginItem.isAvailable { controller.setLaunchAtLogin(launchAtLogin) }
        controller.finishOnboarding(opening: section)
    }
}
