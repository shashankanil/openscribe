import AppKit
import Combine
import Sparkle
import SwiftUI

/// Over-the-air updates via Sparkle 2 (EdDSA-signed appcast; see docs/UPDATES.md).
///
/// Updates are checked on Sparkle's schedule (`SUScheduledCheckInterval`) and downloaded silently in the
/// background (`SUAutomaticallyUpdate`). Once an update is ready, OpenScribe takes over the "install" step:
/// it shows **Install and relaunch** in the menu bar, quick panel and Settings instead of relaunching on its own,
/// because the app is usually mid-dictation or mid-meeting. If the user simply quits, Sparkle installs on quit.
///
/// The updater never starts in DEBUG builds, under `swift run`/`swift test`, or outside a signed `.app` bundle
/// with a feed URL and public key, so development and tests never hit the network or replace anything.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    /// Whether this process can update itself at all (release build, running from an `.app` with Sparkle keys).
    let isAvailable: Bool

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastChecked: Date?
    /// Display version of an update that is downloaded, verified, and waiting for "Install and relaunch".
    @Published private(set) var readyVersion: String?
    @Published var automaticallyChecks = false {
        didSet {
            guard let updater, updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }
    @Published var automaticallyDownloads = false {
        didSet {
            guard let updater, updater.automaticallyDownloadsUpdates != automaticallyDownloads else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloads
        }
    }

    /// Set by the app: returns true while installing now would interrupt work (recording, transcribing).
    var isBusy: @MainActor () -> Bool = { false }

    let currentVersion: String
    let currentBuild: String

    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }
    private var observations: [NSKeyValueObservation] = []
    private var pendingInstall: (() -> Void)?
    private var smokeTest = false

    private override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        currentVersion = info["CFBundleShortVersionString"] as? String ?? "dev"
        currentBuild = info["CFBundleVersion"] as? String ?? "0"
        isAvailable = Self.bundleSupportsUpdates(Bundle.main)
        super.init()
    }

    static func bundleSupportsUpdates(_ bundle: Bundle) -> Bool {
        #if DEBUG
        return false
        #else
        guard bundle.bundleIdentifier != nil, bundle.bundleURL.pathExtension == "app" else { return false }
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
        #endif
    }

    /// Starts Sparkle's scheduler. Safe to call more than once; a no-op where updates are unavailable.
    func start() {
        guard isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        // Settings KVO can fire off the main thread (e.g. a defaults change), so always hop to the main actor.
        let sync: (SPUUpdater) -> Void = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncFromUpdater() } }
        }
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { updater, _ in sync(updater) },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { updater, _ in sync(updater) },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { updater, _ in sync(updater) },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { updater, _ in sync(updater) },
        ]
        controller.startUpdater()
        syncFromUpdater()
    }

    private func syncFromUpdater() {
        guard let updater else { return }
        if canCheckForUpdates != updater.canCheckForUpdates { canCheckForUpdates = updater.canCheckForUpdates }
        if automaticallyChecks != updater.automaticallyChecksForUpdates { automaticallyChecks = updater.automaticallyChecksForUpdates }
        if automaticallyDownloads != updater.automaticallyDownloadsUpdates { automaticallyDownloads = updater.automaticallyDownloadsUpdates }
        if lastChecked != updater.lastUpdateCheckDate { lastChecked = updater.lastUpdateCheckDate }
    }

    /// User-initiated check. Shows Sparkle's standard window (progress, release notes, or "up to date").
    func checkForUpdates() {
        if canInstallNow {
            installAndRelaunch()
            return
        }
        controller?.checkForUpdates(nil)
    }

    var canInstallNow: Bool { pendingInstall != nil && !isBusy() }

    /// Installs the downloaded update and relaunches. The app quits through its normal path,
    /// so in-progress meetings and dictation are finalized first.
    func installAndRelaunch() {
        guard let pendingInstall, !isBusy() else { return }
        pendingInstall()
    }

    // MARK: - Maintenance smoke test

    /// `OpenScribe --update-smoke`: checks the feed, downloads and verifies any update, quits so Sparkle
    /// installs it (no relaunch), and prints one result line. Used by the local end-to-end update test.
    func runSmokeTest() {
        guard isAvailable else {
            Self.finishSmoke("update-smoke unavailable (debug build or not an .app with SUFeedURL/SUPublicEDKey)", code: 4)
            return
        }
        smokeTest = true
        start()
        automaticallyChecks = true
        automaticallyDownloads = true
        print("update-smoke start version=\(currentVersion) build=\(currentBuild) feed=\(updater?.feedURL?.absoluteString ?? "-")")
        fflush(stdout)
        updater?.checkForUpdatesInBackground()
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { Self.finishSmoke("update-smoke timeout", code: 2) }
    }

    private static func finishSmoke(_ line: String, code: Int32) {
        print(line)
        fflush(stdout)
        exit(code)
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingInstall = immediateInstallHandler
        readyVersion = item.displayVersionString
        if smokeTest {
            // Quit instead of using the immediate handler: Sparkle installs on quit, and the test copy is not
            // relaunched into a full session (it would share the real profile). Sparkle refuses an immediate
            // install when relaunching is disabled, so this exercises the same installer via the on-quit path.
            print("update-smoke downloaded version=\(item.displayVersionString) build=\(item.versionString); quitting to install")
            fflush(stdout)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard smokeTest else { return }
        Self.finishSmoke("update-smoke up-to-date version=\(currentVersion) build=\(currentBuild)", code: 0)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard smokeTest else { return }
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) { return }
        Self.finishSmoke("update-smoke error \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)", code: 1)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastChecked = updater.lastUpdateCheckDate
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdateController: SPUStandardUserDriverDelegate {
    /// OpenScribe can run as a menu-bar-only app; Sparkle then shows scheduled alerts without stealing focus.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}

// MARK: - Settings UI

/// Drop-in Settings section: current version, check now, and automatic check/download toggles.
struct UpdateSettingsSection: View {
    @ObservedObject var updates: UpdateController = .shared

    var body: some View {
        FlowSettingsGroup(title: "Updates", footer: footer) {
            FlowSettingsRow(title: "OpenScribe \(updates.currentVersion)", detail: statusDetail, symbol: "arrow.triangle.2.circlepath") {
                if updates.readyVersion != nil {
                    Button("Install and relaunch") { updates.installAndRelaunch() }
                        .buttonStyle(.flow(.primary, size: .small))
                        .disabled(!updates.canInstallNow)
                        .help(updates.canInstallNow ? "Restart OpenScribe on the new version" : "Finish recording first")
                } else {
                    Button("Check for updates") { updates.checkForUpdates() }
                        .buttonStyle(.flow(.secondary, size: .small))
                        .disabled(!updates.isAvailable || !updates.canCheckForUpdates)
                }
            }
            FlowRowDivider()
            FlowSettingsRow(title: "Check automatically", detail: "Looks for a new version every few hours.") {
                Toggle("Check automatically", isOn: $updates.automaticallyChecks).labelsHidden().toggleStyle(.switch)
                    .disabled(!updates.isAvailable)
            }
            FlowRowDivider()
            FlowSettingsRow(title: "Download in the background", detail: "Have updates ready to install when you are.") {
                Toggle("Download in the background", isOn: $updates.automaticallyDownloads).labelsHidden().toggleStyle(.switch)
                    .disabled(!updates.isAvailable || !updates.automaticallyChecks)
            }
        }
    }

    private var statusDetail: String {
        if let ready = updates.readyVersion { return "Version \(ready) is downloaded and ready." }
        guard updates.isAvailable else { return "Build \(updates.currentBuild) · updates are off in development builds." }
        guard let last = updates.lastChecked else { return "Build \(updates.currentBuild) · not checked yet." }
        return "Build \(updates.currentBuild) · last checked \(last.formatted(.relative(presentation: .named)))."
    }

    private var footer: String? {
        updates.readyVersion != nil ? "If you quit OpenScribe instead, the update installs automatically." : nil
    }
}
