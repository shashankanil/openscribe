import AppKit
import SwiftUI

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
