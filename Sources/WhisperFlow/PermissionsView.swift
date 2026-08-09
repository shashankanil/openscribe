import AppKit
import SwiftUI

struct PermissionsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var permissions: PermissionCenter
    @State private var requestingMicrophone = false

    init(controller: AppController) {
        self.controller = controller
        permissions = controller.permissions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("WHISPERFLOW / FIRST RUN")
                    .flowUIFont(size: 10, weight: .semibold)
                    .tracking(1.4)
                    .foregroundStyle(FlowTheme.lavenderDeep)
                Text("One quiet setup, then just speak.")
                    .flowDisplayFont(size: 34)
                    .foregroundStyle(FlowTheme.ink)
                Text("WhisperFlow asks for permissions only when they are needed. If one was denied, use the matching System Settings button below instead of restarting the app.")
                    .flowUIFont(size: 13)
                    .foregroundStyle(FlowTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionCard(
                symbol: "mic.fill",
                title: "Microphone",
                detail: "Needed to turn your voice into text.",
                status: microphoneStatusTitle,
                statusColor: microphoneStatusColor,
                actionTitle: microphoneActionTitle,
                action: microphoneAction
            )

            permissionCard(
                symbol: "rectangle.on.rectangle",
                title: "Accessibility",
                detail: "Needed to paste polished text and enable the global shortcut. Notes still work without it.",
                status: permissions.accessibilityTrusted ? "Granted" : "Not enabled",
                statusColor: permissions.accessibilityTrusted ? .green : FlowTheme.coral,
                actionTitle: permissions.accessibilityTrusted ? "Granted" : "Open System Settings",
                action: accessibilityAction
            )

            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(FlowTheme.lavenderDeep)
                Text("No audio is uploaded until you finish a recording. Provider keys stay in the app's private credentials file.")
                    .flowUIFont(size: 11, weight: .medium)
                    .foregroundStyle(FlowTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(FlowTheme.paperMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Button("Refresh status") {
                    controller.refreshPermissions()
                }
                .buttonStyle(FlowQuietButtonStyle())
                Spacer()
                Button("Skip for now") {
                    controller.disablePasteInjectionAndDismissPermissions()
                }
                .buttonStyle(FlowQuietButtonStyle())
                Button("Done") {
                    controller.dismissPermissions()
                }
                .buttonStyle(FlowPrimaryButtonStyle())
            }
        }
        .padding(34)
        .frame(width: 560)
        .background(FlowTheme.paper)
        .onAppear { controller.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissions()
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
