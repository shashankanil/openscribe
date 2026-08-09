import AppKit
import SwiftUI

@main
struct WhisperFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Whisperlight voice waveform")
        }
        .menuBarExtraStyle(.window)
}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var maintenanceMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--credential-smoke") {
            maintenanceMode = true
            let configured = !(CredentialStore.read(account: CredentialKey.languageModel.rawValue) ?? "").isEmpty
            print(configured ? "credential-configured" : "credential-missing")
            fflush(stdout)
            exit(configured ? 0 : 3)
        }
        if CommandLine.arguments.contains("--provider-smoke") {
            maintenanceMode = true
            Task { @MainActor in
                let settings = AppStore().settings
                let key = CredentialStore.read(account: CredentialKey.languageModel.rawValue) ?? ""
                do {
                    let cleaned = try await ProviderClient().cleanTranscript(
                        "um please send the the draft tomorrow",
                        settings: settings,
                        apiKey: key
                    )
                    print("provider-success chars=\(cleaned.count)")
                    fflush(stdout)
                    exit(0)
                } catch {
                    print("provider-failure \(error.localizedDescription)")
                    fflush(stdout)
                    exit(1)
                }
            }
            return
        }


        if CommandLine.arguments.contains("--bootstrap-openrouter-key") {
            maintenanceMode = true
            let key = ProcessInfo.processInfo.environment["WHISPERFLOW_BOOTSTRAP_KEY"] ?? ""
            do {
                try CredentialStore.save(key, account: CredentialKey.languageModel.rawValue)
                NSLog("WhisperFlow credential bootstrap completed")
            } catch {
                NSLog("WhisperFlow credential bootstrap failed: %@", error.localizedDescription)
            }
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        AppController.shared.boot()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !maintenanceMode else { return }
        AppController.shared.store.flush()
    }
}

struct MenuBarView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                WhisperlightLogo(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WhisperFlow")
                        .flowUIFont(size: 13, weight: .semibold)
                        .foregroundStyle(FlowTheme.ink)
                        .lineLimit(1)
                    Text(statusTitle)
                        .flowUIFont(size: 10, weight: .medium)
                        .foregroundStyle(FlowTheme.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Button(controller.capturePhase == .recording ? "Finish dictation" : "Start dictation") {
                controller.toggleCapture()
            }
            .keyboardShortcut(.space, modifiers: [.option])
            .buttonStyle(FlowPrimaryButtonStyle())
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                menuItem("Open notes", symbol: "text.quote") { controller.openWorkspace() }
                menuItem("Permissions", symbol: "hand.raised") { controller.showPermissions() }
                menuItem("Settings", symbol: "gearshape") { controller.openSettings() }
            }

            Divider().overlay(FlowTheme.ink.opacity(0.15))

            HStack {
                Text("Shortcut")
                    .flowUIFont(size: 10, weight: .medium)
                    .foregroundStyle(FlowTheme.inkMuted)
                Spacer()
                Text(controller.settings.shortcutDisplay)
                    .flowUIFont(size: 10, weight: .semibold)
                    .foregroundStyle(FlowTheme.ink)
                    .flowPill()
            }

            Button("Quit WhisperFlow") { NSApp.terminate(nil) }
                .buttonStyle(FlowQuietButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(width: 250)
        .background(FlowTheme.paper)
    }

    private var statusTitle: String {
        switch controller.capturePhase {
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .cleaning: return "Polishing"
        case .ready: return "Ready"
        case .failed: return "Needs attention"
        case .idle: return controller.permissions.needsAttention ? "Setup needed" : "Idle"
        }
    }

    private func menuItem(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowTheme.lavenderDeep)
                    .frame(width: 16)
                Text(title)
                    .flowUIFont(size: 12, weight: .medium)
                    .foregroundStyle(FlowTheme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(FlowMenuItemStyle())
    }
}
