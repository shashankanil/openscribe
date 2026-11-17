import AppKit
import SwiftUI

/// Settings → AI & MCP: connect notes and meetings to LLM apps, locally or through OpenScribe Cloud.
struct ContextAccessView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var cloud: CloudSyncController
    @State private var confirmDelete = false
    @State private var showAdvanced = false
    @State private var serverDraft = ""

    private var localServer: URL? { CloudSyncController.localServerURL }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                localSection
                cloudSection
                Text("Both connections are read-only: AI apps can search and read your notes and meetings, never change or delete them.")
                    .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 760).padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Delete everything in OpenScribe Cloud?", isPresented: $confirmDelete) {
            Button("Delete cloud data", role: .destructive) {
                Task { if await cloud.deleteCloudData() { controller.flash("Cloud data deleted") } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Synced notes and meetings, sessions and connector access are removed from the server. Everything on this Mac stays.")
        }
        .onAppear { serverDraft = controller.settings.cloudServerURL }
    }

    // MARK: Local

    private var localSection: some View {
        FlowSettingsGroup(title: "On this Mac", footer: localServer == nil ? unavailable
                          : "Works offline and needs no account. The AI app runs OpenScribe’s helper, which reads your library directly from this Mac.") {
            FlowSettingsRow(title: "Claude Desktop", detail: "Adds OpenScribe to Claude Desktop’s MCP servers. Restart Claude afterwards.",
                            symbol: "macwindow") {
                Button("Add to Claude Desktop") { addToClaudeDesktop() }
                    .buttonStyle(.flowSecondary).disabled(localServer == nil)
            }
            FlowRowDivider()
            FlowSettingsRow(title: "Claude Code", detail: "Run this once in Terminal.", symbol: "terminal") {
                copyButton("Copy command", value: claudeCodeCommand, confirmation: "Command copied")
            }
            if let command = claudeCodeCommand {
                commandPreview(command)
            }
            FlowRowDivider()
            FlowSettingsRow(title: "Cursor, Windsurf and other MCP apps", detail: "Paste this into the app’s MCP server settings.",
                            symbol: "curlybraces") {
                copyButton("Copy config", value: jsonConfig, confirmation: "Config copied")
            }
        }
    }

    private var unavailable: String { "The local helper isn’t included in this development build. Install OpenScribe from a release to connect AI apps on this Mac." }

    private var claudeCodeCommand: String? {
        localServer.map { "claude mcp add openscribe -- \"\($0.path)\"" }
    }

    private var jsonConfig: String? {
        guard let localServer else { return nil }
        let config: [String: Any] = ["mcpServers": ["openscribe": ["command": localServer.path]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func addToClaudeDesktop() {
        guard let localServer else { return }
        do {
            try CloudSyncController.installInClaudeDesktop(server: localServer)
            controller.flash("Added. Restart Claude Desktop to see OpenScribe.")
        } catch {
            controller.notify("Couldn’t update Claude Desktop: \(error.localizedDescription)")
        }
    }

    // MARK: Cloud

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = cloud.error {
                FlowBanner(symbol: "exclamationmark.triangle.fill", tint: FlowTheme.warning, title: "OpenScribe Cloud", detail: error) {
                    if !cloud.signedIn { Button("Sign in") { cloud.signIn() }.buttonStyle(.flow(.secondary, size: .small)) }
                }
            }
            FlowSettingsGroup(title: "Anywhere with OpenScribe Cloud", footer: cloudFooter) {
                switch cloud.account {
                case .signedOut:
                    FlowSettingsRow(title: "claude.ai, ChatGPT and your phone",
                                    detail: "Sign in with Google to keep a private copy of your notes and meetings in OpenScribe Cloud, then add it as a connector. Nothing is uploaded until you sign in.",
                                    symbol: "icloud") {
                        Button("Sign in with Google") { cloud.signIn() }.buttonStyle(.flowPrimary)
                    }
                case .signingIn:
                    FlowSettingsRow(title: "Finish signing in in your browser", detail: "OpenScribe opens again when you’re done.", symbol: "icloud") {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { cloud.cancelSignIn() }.buttonStyle(.flowSecondary)
                    }
                case let .signedIn(email):
                    FlowSettingsRow(title: email, detail: "Signed in to OpenScribe Cloud", symbol: "person.crop.circle") {
                        Button("Sign out") { Task { await cloud.signOut() } }.buttonStyle(.flowSecondary)
                    }
                    FlowRowDivider()
                    FlowSettingsRow(title: "Sync notes and meetings", detail: syncDetail, symbol: "arrow.triangle.2.circlepath") {
                        if cloud.syncing { ProgressView().controlSize(.small) }
                        Button("Sync now") { Task { await cloud.syncNow() } }
                            .buttonStyle(.flow(.secondary, size: .small)).disabled(cloud.syncing || !controller.settings.cloudSyncEnabled)
                        Toggle("Sync notes and meetings", isOn: Binding(get: { controller.settings.cloudSyncEnabled }, set: { value in
                            controller.updateSettings { $0.cloudSyncEnabled = value }
                            if value { cloud.scheduleSync(after: 0) }
                        })).labelsHidden().toggleStyle(.switch)
                    }
                    FlowRowDivider()
                    FlowSettingsRow(title: "Connector URL", detail: "In claude.ai or ChatGPT, add a custom connector with this URL and sign in with the same Google account.",
                                    symbol: "link") {
                        copyButton("Copy URL", value: cloud.mcpURL, confirmation: "Connector URL copied")
                    }
                    commandPreview(cloud.mcpURL)
                    FlowRowDivider()
                    FlowSettingsRow(title: "Delete cloud data", detail: "Remove everything stored for this account and sign out.", symbol: "trash") {
                        Button("Delete…", role: .destructive) { confirmDelete = true }.buttonStyle(.flowSecondary)
                    }
                }
            }
            DisclosureGroup(isExpanded: $showAdvanced) {
                HStack(spacing: 8) {
                    TextField(CloudSyncController.defaultServer, text: $serverDraft)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button("Save") {
                        let value = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard value.isEmpty || URL(string: value)?.scheme?.hasPrefix("http") == true else {
                            controller.notify("Enter a full server address, starting with https://")
                            return
                        }
                        controller.updateSettings { $0.cloudServerURL = value }
                        controller.flash(value.isEmpty ? "Using OpenScribe Cloud" : "Server saved")
                    }.buttonStyle(.flowSecondary).disabled(serverDraft == controller.settings.cloudServerURL)
                }.padding(.top, 8)
                Text("Run your own copy of OpenScribe Cloud on Cloudflare (see cloud/README.md) and enter its address. Leave empty for the hosted service.")
                    .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted).padding(.top, 4)
            } label: {
                Text("Self-hosted server").font(.system(size: 12, weight: .medium)).foregroundStyle(FlowTheme.inkMuted)
            }
            .padding(.horizontal, 4)
        }
    }

    private var syncDetail: String {
        if !controller.settings.cloudSyncEnabled { return "Paused. Turn on to upload changes automatically." }
        if cloud.syncing { return "Syncing…" }
        var parts: [String] = []
        if let count = cloud.documentCount { parts.append("\(count) in the cloud") }
        if let last = cloud.lastSync { parts.append("synced \(last.formatted(.relative(presentation: .named)))") }
        else { parts.append("not synced yet") }
        return parts.joined(separator: " · ").prefix(1).uppercased() + parts.joined(separator: " · ").dropFirst()
    }

    private var cloudFooter: String {
        cloud.signedIn
            ? "Changes upload a few seconds after you make them. Only you can read your documents."
            : "Optional. Your library stays on this Mac unless you sign in."
    }

    // MARK: Helpers

    private func copyButton(_ title: String, value: String?, confirmation: String) -> some View {
        Button(title) {
            guard let value else { return }
            FlowFormat.copy(value)
            controller.flash(confirmation)
        }
        .buttonStyle(.flowSecondary).disabled(value == nil)
    }

    private func commandPreview(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(FlowTheme.inkMuted)
            .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FlowTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.leading, 54).padding(.trailing, 14).padding(.bottom, 11)
    }
}
