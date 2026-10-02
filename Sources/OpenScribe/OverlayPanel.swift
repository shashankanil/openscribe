import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
    private weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: 112, height: 58),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: OverlayView(controller: controller))
    }

    override var canBecomeKey: Bool { false }

    func placeOnScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let position = controller?.settings.overlayPosition ?? "bottom-center"
        let x: CGFloat
        switch position {
        case "bottom-left": x = visible.minX + 24
        case "bottom-right": x = visible.maxX - frame.width - 24
        default: x = visible.midX - frame.width / 2
        }
        setFrameOrigin(NSPoint(x: x, y: visible.minY + 20))
    }

    func show() {
        let phase = controller?.capturePhase ?? .idle
        let width: CGFloat = phase == .recording ? 264 : phase == .transcribing || phase == .cleaning ? 232 : phase == .ready ? 164 : 112
        setContentSize(NSSize(width: width, height: 58))
        placeOnScreen()
        orderFrontRegardless()
    }
}

struct OverlayView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var recorder: AudioRecorder

    init(controller: AppController) {
        self.controller = controller
        recorder = controller.recorder
    }

    private var phase: CapturePhase { controller.capturePhase }
    private var processing: Bool { phase == .transcribing || phase == .cleaning }

    var body: some View {
        HStack(spacing: 10) {
            if phase == .recording {
                Circle().fill(FlowTheme.recording).frame(width: 7, height: 7)
                FlowWaveform(levels: recorder.inputLevels, color: .white, barWidth: 2, spacing: 2, maxHeight: 22)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(FlowFormat.duration(context.date.timeIntervalSince(controller.captureStartedAt ?? context.date)))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
                overlayButton("stop.fill", label: "Stop and save", color: FlowTheme.recording) { controller.finishCapture() }
                overlayButton("xmark", label: "Cancel recording") { controller.cancelCapture() }
            } else if processing {
                FlowWaveform(levels: Array(repeating: 0.2, count: 7), color: FlowTheme.accent, barWidth: 2, spacing: 2, maxHeight: 22, animated: true)
                Text(phase == .cleaning ? "Polishing…" : "Transcribing…").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                overlayButton("xmark", label: "Cancel processing") { controller.cancelCapture() }
            } else if phase == .ready {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(FlowTheme.success)
                Text("Saved to Notes").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            } else {
                Button { controller.toggleCaptureFromQuickPanel() } label: {
                    FlowWaveform(levels: Array(repeating: 0.14, count: 11), color: .white.opacity(0.55), maxHeight: 22)
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Start dictation")
            }
        }
        .padding(.horizontal, 14).frame(height: 40)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        .padding(.horizontal, 7).padding(.vertical, 9)
        .environment(\.colorScheme, .dark)
        .help(controller.captureHint)
        .contextMenu {
            Button("Open Notes") { controller.openWorkspace() }
            Button("Settings…") { controller.openSettings() }
            if phase == .recording {
                Divider()
                Button("Stop & save") { controller.finishCapture() }
                Button("Cancel recording", role: .destructive) { controller.cancelCapture() }
            }
        }
    }

    private func overlayButton(_ symbol: String, label: String, color: Color = .white.opacity(0.6), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                .frame(width: 24, height: 24).background(.white.opacity(0.08), in: Circle()).contentShape(Circle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
