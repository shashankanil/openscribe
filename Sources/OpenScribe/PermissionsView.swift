import AppKit
import CoreGraphics
import SwiftUI

struct PermissionsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var permissions: PermissionCenter
    @ObservedObject private var calendar: CalendarMeetingController
    @State private var requestingMicrophone = false
    @State private var systemAudioReady = CGPreflightScreenCaptureAccess()

    init(controller: AppController) {
        self.controller = controller
        permissions = controller.permissions
        calendar = controller.calendar
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Give OpenScribe the access you need. You control each permission in macOS.")
                    .font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted)
                FlowSettingsGroup(title: "Dictation", footer: "The microphone is used only when you start a recording. Accessibility enables pasting and your global shortcut.") {
                    FlowSettingsRow(title: "Microphone", detail: "Record your voice", symbol: "mic") {
                        permissionStatus(permissions.microphoneReady)
                        if !permissions.microphoneReady {
                            Button(requestingMicrophone ? "Waiting…" : permissions.microphoneStatus == .notDetermined ? "Allow" : "Open Settings") {
                                microphoneAction()
                            }.buttonStyle(.flowSecondary).disabled(requestingMicrophone)
                        }
                    }
                    FlowRowDivider()
                    FlowSettingsRow(title: "Accessibility", detail: "Type into other apps and use your shortcut", symbol: "text.cursor") {
                        permissionStatus(permissions.accessibilityTrusted)
                        if !permissions.accessibilityTrusted {
                            Button("Open Settings") { controller.openAccessibilitySettings() }.buttonStyle(.flowSecondary)
                        }
                    }
                }
                if !permissions.accessibilityTrusted {
                    FlowSettingsGroup(footer: "Enable OpenScribe in System Settings → Privacy & Security → Accessibility. Return here to check the status.") {
                        FlowSettingsRow(title: "Paste into other apps", detail: "Turn off to use Notes with the app’s recording controls.") {
                            Toggle("Paste into other apps", isOn: Binding(get: { controller.settings.pasteIntoFocusedApp }, set: { value in
                                controller.updateSettings { $0.pasteIntoFocusedApp = value }
                            })).labelsHidden().toggleStyle(.switch)
                        }
                    }
                    DisclosureGroup("Access is enabled but still not working?") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Remove OpenScribe from the Accessibility list with −, add /Applications/OpenScribe.app again with +, then restart the app.")
                                .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                            Button("Restart OpenScribe") { controller.restartApplication() }.buttonStyle(.flowSecondary)
                        }.padding(.top, 8)
                    }.font(.system(size: 12))
                }
                FlowSettingsGroup(title: "Meetings & calendar", footer: "These are optional for dictation. System audio includes other apps and notifications. Calendar access reads events and never changes them.") {
                    FlowSettingsRow(title: "Screen & system audio", detail: "Capture the other side of your calls", symbol: "speaker.wave.2") {
                        permissionStatus(systemAudioReady)
                        Button("Open Settings") { openScreenSettings() }.buttonStyle(.flowSecondary)
                    }
                    FlowRowDivider()
                    FlowSettingsRow(title: "Calendar", detail: "Browse your schedule and prompt before meetings", symbol: "calendar") {
                        permissionStatus(calendar.authorized)
                        if !calendar.authorized {
                            Button("Allow") { Task { await calendar.requestAccess() } }.buttonStyle(.flowSecondary)
                        } else {
                            Button("Open calendar") { controller.workspaceSection = .calendar }.buttonStyle(.flowSecondary)
                        }
                    }
                }
                HStack {
                    Button { refresh() } label: { Label("Refresh permissions", systemImage: "arrow.clockwise") }.buttonStyle(.flowGhost)
                    Spacer()
                    if controller.setupReadiness.canDictate {
                        FlowBadge(text: "Ready to dictate", color: FlowTheme.success, symbol: "checkmark")
                    }
                }
            }.padding(.horizontal, 28).padding(.vertical, 24)
        }
        .task {
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }

    private func permissionStatus(_ granted: Bool) -> some View {
        FlowBadge(text: granted ? "Allowed" : "Not enabled", color: granted ? FlowTheme.success : FlowTheme.inkMuted,
                  symbol: granted ? "checkmark" : "minus")
    }

    private func microphoneAction() {
        if permissions.microphoneStatus == .notDetermined {
            requestingMicrophone = true
            Task { await controller.requestMicrophonePermission(); requestingMicrophone = false }
        } else { controller.openMicrophoneSettings() }
    }

    private func refresh() {
        controller.refreshPermissions()
        systemAudioReady = CGPreflightScreenCaptureAccess()
    }

    private func openScreenSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
