import AppKit
import SwiftUI

struct PermissionsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var permissions: PermissionCenter
    @State private var requestingMicrophone = false
    @State private var step: SetupStep = .welcome

    init(controller: AppController) {
        self.controller = controller
        permissions = controller.permissions
    }

    private enum SetupStep: Int, CaseIterable {
        case welcome
        case microphone
        case accessibility
        case ready

        var number: Int { rawValue + 1 }

        var eyebrow: String {
            switch self {
            case .welcome: return "WELCOME"
            case .microphone: return "STEP 1 OF 2"
            case .accessibility: return "STEP 2 OF 2"
            case .ready: return "ALL SET"
            }
        }

        var title: String {
            switch self {
            case .welcome: return "Replace typing with your voice."
            case .microphone: return "Let OpenScribe hear you."
            case .accessibility: return "Let OpenScribe type for you."
            case .ready: return "You're ready to speak."
            }
        }

        var detail: String {
            switch self {
            case .welcome:
                return "Two permissions unlock the full flow: speak naturally, then let OpenScribe place polished words wherever you work."
            case .microphone:
                return "OpenScribe records only after you start dictation. macOS keeps microphone access under your control."
            case .accessibility:
                return "Accessibility lets OpenScribe paste the finished transcript and listen for your keyboard shortcut."
            case .ready:
                return "Use the Globe shortcut whenever you want to replace a typing pass with your voice."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                WhisperlightLogo(size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text("OPENSCRIBE / SETUP")
                        .flowUIFont(size: 10, weight: .semibold)
                        .tracking(1.4)
                        .foregroundStyle(FlowTheme.lavenderDeep)
                    Text(step.eyebrow)
                        .flowUIFont(size: 10, weight: .medium)
                        .foregroundStyle(FlowTheme.inkMuted)
                }
                Spacer()
                Text("\(step.number)/4")
                    .flowUIFont(size: 10, weight: .semibold)
                    .foregroundStyle(FlowTheme.inkMuted)
                    .flowPill()
            }

            ProgressView(value: Double(step.rawValue), total: 3)
                .tint(FlowTheme.lavenderDeep)
                .padding(.top, 18)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(step.title)
                            .flowDisplayFont(size: 31)
                            .foregroundStyle(FlowTheme.ink)
                        Text(step.detail)
                            .flowUIFont(size: 13)
                            .foregroundStyle(FlowTheme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    stepContent
                }
                .padding(.top, 24)
                .padding(.bottom, 12)
            }

            Divider()
                .overlay(FlowTheme.ink.opacity(0.12))
                .padding(.top, 10)

            HStack(spacing: 8) {
                if step != .welcome {
                    Button("Back") { step = previousStep }
                        .buttonStyle(FlowQuietButtonStyle())
                }
                Spacer()
                if step != .ready {
                    Button("Set up later") {
                        controller.disablePasteInjectionAndDismissPermissions()
                    }
                    .buttonStyle(FlowQuietButtonStyle())
                }
                Button(primaryActionTitle, action: advance)
                    .buttonStyle(FlowPrimaryButtonStyle())
                    .disabled(primaryActionDisabled)
                    .opacity(primaryActionDisabled ? 0.55 : 1)
            }
            .padding(.top, 14)
        }
        .padding(34)
        .frame(width: 560, height: 650)
        .background(FlowTheme.paper)
        .onAppear {
            controller.refreshPermissions()
            synchronizeStep()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissions()
            synchronizeStep()
        }
        .onChange(of: permissions.accessibilityTrusted) { _, trusted in
            if trusted, step == .accessibility {
                step = .ready
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 12) {
                setupFeature(icon: "waveform", title: "Speak naturally", detail: "Turn a thought into a transcript without reaching for the keyboard.")
                setupFeature(icon: "text.cursor", title: "Paste anywhere", detail: "With Accessibility enabled, polished text goes straight into the focused app.")
                setupFeature(icon: "lock.shield.fill", title: "Stay in control", detail: "Nothing is uploaded until you start a recording. Provider keys stay private on this Mac.")
            }
        case .microphone:
            permissionCard(
                symbol: "mic.fill",
                title: "Microphone",
                detail: "Needed to turn your voice into text.",
                status: microphoneStatusTitle,
                statusColor: microphoneStatusColor,
                actionTitle: microphoneActionTitle,
                action: microphoneAction
            )
            Text("You can change this later in System Settings → Privacy & Security → Microphone.")
                .flowUIFont(size: 11)
                .foregroundStyle(FlowTheme.inkMuted)
        case .accessibility:
            permissionCard(
                symbol: "rectangle.on.rectangle",
                title: "Accessibility",
                detail: "Needed to paste polished text and enable the global shortcut.",
                status: permissions.accessibilityTrusted ? "Granted" : "Not enabled",
                statusColor: permissions.accessibilityTrusted ? .green : FlowTheme.coral,
                actionTitle: permissions.accessibilityTrusted ? "Granted" : "Open System Settings",
                action: permissions.accessibilityTrusted ? nil : accessibilityAction
            )
            VStack(alignment: .leading, spacing: 10) {
                Text(permissions.accessibilityTrusted ? "OpenScribe is connected. You can finish setup." : "Turn on OpenScribe in the Accessibility list, then return here. Status checks automatically. If it is already on but still says Not enabled, remove OpenScribe with − and add /Applications/OpenScribe.app again with +.")
                    .flowUIFont(size: 11)
                    .foregroundStyle(FlowTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Refresh now") {
                        controller.refreshPermissions()
                    }
                    .buttonStyle(FlowQuietButtonStyle())
                    if !permissions.accessibilityTrusted {
                        Button("Restart OpenScribe") {
                            controller.restartApplication()
                        }
                        .buttonStyle(FlowQuietButtonStyle())
                    }
                }
            }
        case .ready:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Microphone and Accessibility are ready.")
                            .flowUIFont(size: 14, weight: .semibold)
                        Text("OpenScribe can now listen, polish, and paste.")
                            .flowUIFont(size: 11)
                            .foregroundStyle(FlowTheme.inkMuted)
                    }
                }
                .padding(18)
                .background(FlowTheme.paperMuted, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                setupFeature(icon: "globe", title: "Your shortcut", detail: "Press Globe to start and stop dictation. You can change it in Settings.")
            }
        }
    }

    private var previousStep: SetupStep {
        SetupStep(rawValue: max(0, step.rawValue - 1)) ?? .welcome
    }

    private var primaryActionTitle: String {
        switch step {
        case .welcome: return "Continue"
        case .microphone: return "Continue"
        case .accessibility: return permissions.accessibilityTrusted ? "Finish setup" : "Waiting for access"
        case .ready: return "Start speaking"
        }
    }

    private var primaryActionDisabled: Bool {
        step == .accessibility && !permissions.accessibilityTrusted
    }

    private func advance() {
        guard !primaryActionDisabled else { return }
        switch step {
        case .welcome: step = .microphone
        case .microphone: step = .accessibility
        case .accessibility: step = .ready
        case .ready: controller.dismissPermissions()
        }
    }

    private func synchronizeStep() {
        if permissions.microphoneReady && permissions.accessibilityTrusted, step == .welcome {
            step = .ready
        }
    }

    private var accessibilityAction: (() -> Void)? {
        guard !permissions.accessibilityTrusted else { return nil }
        return { controller.openAccessibilitySettings() }
    }

    private var microphoneStatusTitle: String {
        switch permissions.microphoneStatus {
        case .authorized: return "Granted"
        case .notDetermined: return "Waiting for approval"
        case .denied, .restricted: return "Denied"
        @unknown default: return "Unavailable"
        }
    }

    private var microphoneStatusColor: Color {
        permissions.microphoneReady ? .green : FlowTheme.coral
    }

    private var microphoneActionTitle: String {
        switch permissions.microphoneStatus {
        case .authorized: return "Granted"
        case .notDetermined: return requestingMicrophone ? "Waiting…" : "Allow microphone"
        case .denied, .restricted: return "Open System Settings"
        @unknown default: return "Open System Settings"
        }
    }

    private var microphoneAction: (() -> Void)? {
        switch permissions.microphoneStatus {
        case .authorized: return nil
        case .notDetermined:
            return {
                guard !requestingMicrophone else { return }
                requestingMicrophone = true
                Task {
                    await controller.requestMicrophonePermission()
                    requestingMicrophone = false
                }
            }
        case .denied, .restricted:
            return controller.openMicrophoneSettings
        @unknown default:
            return controller.openMicrophoneSettings
        }
    }

    @ViewBuilder
    private func setupFeature(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FlowTheme.ink)
                .frame(width: 34, height: 34)
                .background(FlowTheme.lavender, in: Circle())
                .overlay(Circle().stroke(FlowTheme.ink, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .flowUIFont(size: 13, weight: .semibold)
                Text(detail)
                    .flowUIFont(size: 11)
                    .foregroundStyle(FlowTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func permissionCard(
        symbol: String,
        title: String,
        detail: String,
        status: String,
        statusColor: Color,
        actionTitle: String,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 15) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FlowTheme.ink)
                .frame(width: 38, height: 38)
                .background(FlowTheme.lavender, in: Circle())
                .overlay(Circle().stroke(FlowTheme.ink, lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .flowUIFont(size: 14, weight: .semibold)
                Text(detail)
                    .flowUIFont(size: 11)
                    .foregroundStyle(FlowTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(status)
                    .flowUIFont(size: 10, weight: .semibold)
                    .foregroundStyle(statusColor)
            }
            Spacer()
            if let action {
                Button(actionTitle, action: action)
                    .buttonStyle(FlowPrimaryButtonStyle(tint: FlowTheme.lavender))
            } else {
                Label(actionTitle, systemImage: "checkmark.circle.fill")
                    .flowUIFont(size: 11, weight: .semibold)
                    .foregroundStyle(.green)
            }
        }
        .flowCard(inset: 16)
    }
}
