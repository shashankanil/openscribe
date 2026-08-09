import AppKit
import ApplicationServices
import Foundation

enum TextInjector {
    @MainActor
    static func paste(_ text: String, into targetBundleIdentifier: String?) throws {
        guard !text.isEmpty else { return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw TextInjectorError.accessibilityPermissionDenied
        }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInjectorError.clipboardUnavailable
        }

        let targetApplication = targetApplication(for: targetBundleIdentifier)
        if let targetApplication {
            guard targetApplication.activate(options: [.activateAllWindows]) else {
                restore(pasteboard, previous: previous)
                throw TextInjectorError.targetApplicationUnavailable
            }
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            restore(pasteboard, previous: previous)
            throw TextInjectorError.keyboardEventUnavailable
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        if targetApplication == nil {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                restore(pasteboard, previous: previous)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                restore(pasteboard, previous: previous)
            }
        }
    }

    private static func targetApplication(for bundleIdentifier: String?) -> NSRunningApplication? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        return applications.first(where: \.isActive) ?? applications.first
    }

    private static func restore(_ pasteboard: NSPasteboard, previous: String?) {
        pasteboard.clearContents()
        if let previous {
            pasteboard.setString(previous, forType: .string)
        }
    }
}

enum TextInjectorError: LocalizedError {
    case accessibilityPermissionDenied
    case clipboardUnavailable
    case keyboardEventUnavailable
    case targetApplicationUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Enable Accessibility for OpenScribe in System Settings → Privacy & Security → Accessibility."
        case .clipboardUnavailable:
            return "The clipboard could not be prepared for paste."
        case .keyboardEventUnavailable:
            return "macOS did not allow a paste keyboard event."
        case .targetApplicationUnavailable:
            return "The app where dictation started is no longer available."
        }
    }
}
