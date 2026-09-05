import AppKit
import SwiftUI

@main
struct OpenScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { AppController.shared.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var maintenanceMode = false
    private var reopenObserver: NSObjectProtocol?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--credential-smoke") {
            maintenanceMode = true
            let configured = !(CredentialStore.read(for: .languageModel, settings: AppStore().settings) ?? "").isEmpty
            print(configured ? "credential-configured" : "credential-missing")
            fflush(stdout)
            exit(configured ? 0 : 3)
        }
        if CommandLine.arguments.contains("--provider-smoke") {
            maintenanceMode = true
            Task { @MainActor in
                let settings = AppStore().settings
                let key = CredentialStore.read(for: .languageModel, settings: AppStore().settings) ?? ""
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
            let key = ProcessInfo.processInfo.environment["OPENSCRIBE_BOOTSTRAP_KEY"] ?? ""
            do {
                var configuration = AppSettings()
                configuration.languageModelProvider = .openRouter
                configuration.languageModelBaseURL = LanguageModelProvider.openRouter.defaultBaseURL
                try CredentialStore.save(key, account: CredentialScope(.languageModel, settings: configuration).account)
                NSLog("OpenScribe credential bootstrap completed")
            } catch {
                NSLog("OpenScribe credential bootstrap failed: %@", error.localizedDescription)
            }
            NSApp.terminate(nil)
            return
        }

        let identity = Bundle.main.bundleIdentifier ?? "org.open-source.openscribe"
        if NSRunningApplication.runningApplications(withBundleIdentifier: identity).contains(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
                && $0.processIdentifier < ProcessInfo.processInfo.processIdentifier
        }) {
            maintenanceMode = true
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("OpenScribeOpenWorkspace"), object: identity, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        reopenObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("OpenScribeOpenWorkspace"), object: identity, queue: .main) { _ in
            Task { @MainActor in AppController.shared.openMainWindow() }
        }
        NSApp.setActivationPolicy(.accessory)
        AppController.shared.boot()
        statusBarController = StatusBarController(controller: .shared)
        if CommandLine.arguments.contains("--show-workspace") { AppController.shared.openMainWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppController.shared.openMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !maintenanceMode else { return .terminateNow }
        Task { @MainActor in
            AppController.shared.calendar.shutdown()
            await AppController.shared.meetings.prepareToQuit()
            await AppController.shared.prepareDictationToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !maintenanceMode else { return }
        AppController.shared.store.flush()
    }
}
