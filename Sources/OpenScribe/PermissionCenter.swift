import AVFoundation
import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var accessibilityTrusted = false

    /// Called after a permission actually changes, so listeners can react (for example, re-register shortcuts).
    var onChange: (() -> Void)?

    private let onboardingSeenKey = "permission-onboarding-seen-v2"
    private var accessibilityRefreshTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    init() {
        refresh()
        // Returning from System Settings is when permissions change, so check right away.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var microphoneReady: Bool { microphoneStatus == .authorized }
    /// macOS only shows its prompt once; after a denial the switch lives in System Settings.
    var microphoneNeedsSettings: Bool { microphoneStatus == .denied || microphoneStatus == .restricted }
    var needsAttention: Bool { !microphoneReady || !accessibilityTrusted }
    var hasSeenOnboarding: Bool { UserDefaults.standard.bool(forKey: onboardingSeenKey) }

    /// Publishes only real changes, so frequent checks don't redraw every window.
    func refresh() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        guard microphone != microphoneStatus || trusted != accessibilityTrusted else { return }
        if microphone != microphoneStatus { microphoneStatus = microphone }
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        onChange?()
    }

    /// Shows the system prompt in front of everything; if access is (or becomes) denied, opens System Settings instead.
    func requestMicrophonePermission() async {
        refresh()
        guard microphoneStatus == .notDetermined else {
            if !microphoneReady { openMicrophoneSettings() }
            return
        }
        // A background (menu bar) app's prompt can open behind other windows.
        NSApp.activate()
        // Never leave the button waiting if the prompt is dismissed without an answer.
        let answered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            AVCaptureDevice.requestAccess(for: .audio) { _ in once.resume(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { once.resume(false) }
        }
        refresh()
        if answered, !microphoneReady { openMicrophoneSettings() }
    }

    func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
        beginAccessibilityMonitoring()
    }
    func beginAccessibilityMonitoring() {
        accessibilityRefreshTask?.cancel()
        accessibilityRefreshTask = Task { @MainActor [weak self] in
            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                refresh()
                if accessibilityTrusted { return }
            }
        }
    }


    func markOnboardingSeen() {
        UserDefaults.standard.set(true, forKey: onboardingSeenKey)
    }

    /// The Privacy & Security pane, using the current System Settings address with the older one as a fallback.
    static func openPrivacyPane(_ pane: String) {
        for address in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)",
                        "x-apple.systempreferences:com.apple.preference.security?\(pane)"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }

    private func openPrivacyPane(_ pane: String) { Self.openPrivacyPane(pane) }

    deinit {
        accessibilityRefreshTask?.cancel()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
}

/// Resumes a continuation from whichever callback arrives first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
