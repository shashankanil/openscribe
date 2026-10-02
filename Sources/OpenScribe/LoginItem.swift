import Foundation
import ServiceManagement

/// Launch at login, backed by the system's own record so it stays in step with System Settings.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var isRequested: Bool { isEnabled || needsApproval }

    /// macOS only registers apps that run from an installed bundle.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { throw LoginItemError.notInstalled }
        if enabled {
            guard !isRequested else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum LoginItemError: LocalizedError {
    case notInstalled

    var errorDescription: String? {
        "Move OpenScribe to the Applications folder to launch it at login."
    }
}
