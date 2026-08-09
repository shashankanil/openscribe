import AVFoundation
import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var accessibilityTrusted = false

    private let onboardingSeenKey = "permission-onboarding-seen-v1"

    init() {
        refresh()
    }

    var microphoneReady: Bool { microphoneStatus == .authorized }
    var needsAttention: Bool { !microphoneReady || !accessibilityTrusted }
    var hasSeenOnboarding: Bool { UserDefaults.standard.bool(forKey: onboardingSeenKey) }

    func refresh() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func requestMicrophonePermission() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            refresh()
            return
        }
        _ = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                continuation.resume()
            }
        }
        refresh()
    }

    func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    func markOnboardingSeen() {
        UserDefaults.standard.set(true, forKey: onboardingSeenKey)
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
