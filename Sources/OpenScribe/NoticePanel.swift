import AppKit
import SwiftUI

final class NoticePanel: NSPanel {
    init(controller: AppController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 70), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: NoticeBubble(controller: controller))
    }
    override var canBecomeKey: Bool { false }
    func show() {
        guard let screen = NSScreen.main else { return }
        setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 180, y: screen.visibleFrame.minY + 80))
        orderFrontRegardless()
    }
}

private struct NoticeBubble: View {
    @ObservedObject var controller: AppController
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
            Text(UserNotice.summary(controller.lastError ?? "Needs attention")).font(.system(size: 12)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Details") { controller.inspectNotice() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08)))
            .padding(5)
    }
}
