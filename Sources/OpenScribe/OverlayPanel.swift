import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
    private weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 104, height: 42),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: OverlayView(controller: controller))
    }

    override var canBecomeKey: Bool { true }

    func placeOnScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        let position = controller?.settings.overlayPosition ?? "bottom-center"
        let x: CGFloat
        switch position {
        case "bottom-left":
            x = visible.minX + 24
        case "bottom-right":
            x = visible.maxX - size.width - 24
        default:
            x = visible.midX - size.width / 2
        }
        setFrameOrigin(NSPoint(x: x, y: visible.minY + 24))
    }

    func show() {
        placeOnScreen()
        orderFrontRegardless()
    }
}

struct OverlayView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var recorder: AudioRecorder

    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let paper = Color(red: 1.0, green: 1.0, blue: 0.92)

    init(controller: AppController) {
        self.controller = controller
        _recorder = ObservedObject(wrappedValue: controller.recorder)
    }

    var body: some View {
        let isProcessing = controller.capturePhase == .transcribing || controller.capturePhase == .cleaning
        TimelineView(.animation(minimumInterval: 0.08, paused: !isProcessing)) { context in
            Flowbar(
                phase: controller.capturePhase,
                hint: controller.captureHint,
                inputLevels: recorder.inputLevels,
                loadingTime: context.date.timeIntervalSinceReferenceDate,
                ink: ink,
                paper: paper
            )
        }
        .frame(width: 104, height: 42)
        .contextMenu {
            Button("Open workspace") { controller.openWorkspace() }
            Button("Open settings") { controller.openSettings() }
            if controller.capturePhase == .recording {
                Divider()
                Button("Cancel recording", role: .destructive) { controller.cancelCapture() }
            }
        }
    }
}

private struct Flowbar: View {
    let phase: CapturePhase
    let hint: String
    let inputLevels: [Float]
    let loadingTime: TimeInterval
    let ink: Color
    let paper: Color

    private var accent: Color {
        switch phase {
        case .failed:
            return Color(red: 1.0, green: 0.48, blue: 0.52)
        case .transcribing, .cleaning:
            return Color(red: 0.88, green: 0.80, blue: 1.0)
        default:
            return paper
        }
    }

    var body: some View {
        waveform
            .frame(width: 90, height: 28)
            .padding(.horizontal, 4)
            .frame(width: 104, height: 38)
            .background(ink, in: Capsule())
            .overlay(Capsule().stroke(Color(red: 0.30, green: 0.29, blue: 0.26), lineWidth: 1))
            .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hint)
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<11, id: \.self) { index in
                let level = inputLevels.indices.contains(index) ? inputLevels[index] : 0.04
                let loadingPulse = Float(
                    0.04 + abs(sin(loadingTime * 3.4 + Double(index) * 0.55)) * 0.08
                )
                let renderedLevel = phase == .transcribing || phase == .cleaning
                    ? loadingPulse
                    : max(0.04, level)
                Capsule()
                    .fill(accent)
                    .frame(width: 2.6, height: 4 + CGFloat(renderedLevel) * 20)
                    .opacity(
                        phase == .transcribing || phase == .cleaning
                            ? 0.72 + 0.18 * abs(sin(loadingTime * 3.4 + Double(index) * 0.55))
                            : 1
                    )
                    .animation(.easeOut(duration: 0.08), value: renderedLevel)
            }
        }
    }
}
