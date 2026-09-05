import AppKit
import ApplicationServices
import Foundation

enum TextInjector {
    @MainActor
    static func paste(_ text: String, into targetBundleIdentifier: String?) async throws {
        guard !text.isEmpty else { return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw TextInjectorError.accessibilityPermissionDenied
        }

        let pasteboard = NSPasteboard.general
        let targetApplication = targetApplication(for: targetBundleIdentifier)
        if targetBundleIdentifier != nil && targetApplication == nil {
            throw TextInjectorError.targetApplicationUnavailable
        }
        let previous: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInjectorError.clipboardUnavailable
        }

        let changeCount = pasteboard.changeCount
        if let targetApplication {
            guard targetApplication.activate(options: [.activateAllWindows]) else {
                restore(pasteboard, previous: previous, changeCount: changeCount)
                throw TextInjectorError.targetApplicationUnavailable
            }
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            restore(pasteboard, previous: previous, changeCount: changeCount)
            throw TextInjectorError.keyboardEventUnavailable
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        defer { restore(pasteboard, previous: previous, changeCount: changeCount) }
        if let targetApplication {
            try await Task.sleep(nanoseconds: 150_000_000)
            guard targetApplication.isActive else { throw TextInjectorError.targetApplicationUnavailable }
        }
        try Task.checkCancellation()
        guard pasteboard.changeCount == changeCount else { throw TextInjectorError.clipboardUnavailable }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 600_000_000)

    }

    private static func targetApplication(for bundleIdentifier: String?) -> NSRunningApplication? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        return applications.first(where: \.isActive) ?? applications.first
    }

    static func restore(_ pasteboard: NSPasteboard, previous: [NSPasteboardItem], changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        if !previous.isEmpty { pasteboard.writeObjects(previous) }
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
