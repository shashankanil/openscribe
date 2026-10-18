import AppKit
import Foundation
import Vision

enum ScreenshotKind: String, CaseIterable {
    case area, window, screen

    var action: ShortcutAction {
        switch self {
        case .area: return .screenshotArea
        case .window: return .screenshotWindow
        case .screen: return .screenshotScreen
        }
    }

    var title: String {
        switch self {
        case .area: return "Area"
        case .window: return "Window"
        case .screen: return "Full screen"
        }
    }
}

enum ScreenshotError: LocalizedError {
    case permissionNeeded
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionNeeded:
            return "Allow Screen Recording for OpenScribe in System Settings to save screenshots to your notes."
        case let .failed(detail):
            return "The screenshot couldn’t be taken. \(detail)"
        }
    }
}

/// Uses the system `screencapture` tool, which provides the familiar selection UI
/// (drag for an area, click for a window, Space to switch, Escape to cancel).
enum ScreenshotCapture {
    /// Returns `false` when the user cancelled the selection.
    static func capture(_ kind: ScreenshotKind, to url: URL, playSound: Bool) async throws -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenshotError.permissionNeeded
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var arguments = ["-t", "png"]
        if !playSound { arguments.append("-x") }
        switch kind {
        case .area: arguments += ["-i", "-s"]
        case .window: arguments += ["-i", "-w", "-o"]
        case .screen: arguments += ["-D", String(displayIndexUnderPointer())]
        }
        arguments.append(url.path)

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: ScreenshotError.failed(error.localizedDescription)) }
        }
        let saved = FileManager.default.fileExists(atPath: url.path)
        if !saved && status != 0 && kind == .screen { throw ScreenshotError.failed("screencapture exited with status \(status).") }
        return saved
    }

    /// `screencapture -D` numbers displays from 1 in the same order as `NSScreen.screens`.
    private static func displayIndexUnderPointer() -> Int {
        let pointer = NSEvent.mouseLocation
        let index = NSScreen.screens.firstIndex { NSMouseInRect(pointer, $0.frame, false) } ?? 0
        return index + 1
    }

    static func recognizeText(in url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            guard (try? VNImageRequestHandler(url: url).perform([request])) != nil else { return nil }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }.value
    }
}
