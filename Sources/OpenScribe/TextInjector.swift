import AppKit
import ApplicationServices
import Foundation

enum TextInjector {
    @MainActor
    static func paste(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else { throw TextInjectorError.accessibilityPermissionDenied }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw TextInjectorError.clipboardUnavailable }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            throw TextInjectorError.keyboardEventUnavailable
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }
}

enum TextInjectorError: LocalizedError {
    case accessibilityPermissionDenied
    case clipboardUnavailable
    case keyboardEventUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Enable Accessibility for OpenScribe in System Settings → Privacy & Security → Accessibility."
        case .clipboardUnavailable:
            return "The clipboard could not be prepared for paste."
        case .keyboardEventUnavailable:
            return "macOS did not allow a paste keyboard event."
        }
    }
}
