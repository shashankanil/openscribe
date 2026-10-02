import AppKit
import SwiftUI

final class NoticePanel: NSPanel {
    init(controller: AppController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 84),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: NoticeBubble(controller: controller))
    }
    override var canBecomeKey: Bool { false }
    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.minY + 86))
        orderFrontRegardless()
    }
}

struct NoticeBubble: View {
    @ObservedObject var controller: AppController
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 18)).foregroundStyle(FlowTheme.warning)
            Text(UserNotice.summary(controller.lastError ?? "Needs attention"))
                .font(.system(size: 12.5, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button("Details") { controller.inspectNotice() }.buttonStyle(.flow(.secondary, size: .small))
            FlowIconButton(symbol: "xmark", help: "Dismiss notice", size: 22) { controller.dismissNotice() }
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(FlowTheme.line))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        .padding(8)
    }
}

struct NoticeDetailsSheet: View {
    @ObservedObject var controller: AppController
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 24)).foregroundStyle(FlowTheme.warning)
                Text("This needs a moment").font(.system(size: 20, weight: .bold))
                Spacer()
                FlowIconButton(symbol: "xmark", help: "Close details") { controller.noticeDetailsVisible = false }
            }
            Text(UserNotice.summary(controller.lastError ?? "Something went wrong."))
                .font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted)
            ScrollView {
                Text(controller.lastError ?? "No additional details.").font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            .frame(height: 190).background(FlowTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button(copied ? "Copied" : "Copy details") { FlowFormat.copy(controller.lastError ?? ""); copied = true }.buttonStyle(.flowSecondary)
                Spacer()
                Button("Settings") { controller.noticeDetailsVisible = false; controller.openSettings() }.buttonStyle(.flowSecondary)
                Button("Done") { controller.noticeDetailsVisible = false }.buttonStyle(.flowPrimary).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520).background(FlowTheme.background)
    }
}
