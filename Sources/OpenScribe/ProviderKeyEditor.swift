import SwiftUI

struct ProviderConnectionCard: View {
    @ObservedObject var controller: AppController
    let purpose: CredentialKey
    @State private var showEditor = false
    @State private var showRemove = false
    @State private var failure: String?

    private var draft: ProviderConnectionDraft { .init(purpose: purpose, settings: controller.settings) }
    private var hasKey: Bool { !controller.credential(for: purpose).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ProviderMark(title: draft.title, size: 46)
                VStack(alignment: .leading, spacing: 5) {
                    Text(draft.title).font(.system(size: 18, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(hasKey ? FlowTheme.success : FlowTheme.warning).frame(width: 5, height: 5)
                        Text(hasKey ? "API key saved" : "API key required").font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                    }
                }
                Spacer()
                Button(hasKey ? "Configure…" : "Connect provider…") { showEditor = true }
                    .buttonStyle(.flow(hasKey ? .secondary : .primary))
            }.padding(20)
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MODEL").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(FlowTheme.inkFaint)
                    Text(draft.model).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                }
                Spacer()
                Menu {
                    Button("Change provider or key…") { showEditor = true }
                    if hasKey { Button("Remove API key…", role: .destructive) { showRemove = true } }
                } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Connection actions")
            }.padding(.horizontal, 20).padding(.vertical, 16)
            if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(FlowTheme.recording).padding(.horizontal, 20).padding(.bottom, 16) }
        }
        .background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(FlowTheme.line, lineWidth: 1))
        .sheet(isPresented: $showEditor) {
            ProviderConnectionEditor(controller: controller, purpose: purpose) { showEditor = false }
        }
        .alert("Remove the \(draft.title) key?", isPresented: $showRemove) {
            Button("Remove key", role: .destructive) {
                do {
                    try CredentialStore.delete(account: draft.scope.account, rootURL: controller.storageRoot)
                    failure = nil; controller.objectWillChange.send(); controller.flash("API key removed")
                } catch { failure = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(purpose == .speech ? "Transcription will need a key before it can run again." : "Writing cleanup and meeting summaries will need a key before they can run again.") }
    }
}

struct ProviderConnectionEditor: View {
    @ObservedObject var controller: AppController
    let purpose: CredentialKey
    let onClose: () -> Void
    @State private var draft: ProviderConnectionDraft
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var canReuseKey = false
    @State private var reuseKey = false
    @State private var advanced = false
    @State private var failure: String?
    @FocusState private var keyFocused: Bool

    init(controller: AppController, purpose: CredentialKey, onClose: @escaping () -> Void) {
        self.controller = controller; self.purpose = purpose; self.onClose = onClose
        _draft = State(initialValue: ProviderConnectionDraft(purpose: purpose, settings: controller.settings))
    }
    private var providers: [(id: String, title: String)] {
        purpose == .speech ? SpeechProvider.allCases.map { ($0.rawValue, $0.title) } : LanguageModelProvider.allCases.map { ($0.rawValue, $0.title) }
    }
    private var readyToSave: Bool {
        draft.validationMessage == nil && (hasSavedKey || reuseKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(purpose == .speech ? "Transcription connection" : "Writing connection")
                        .font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                    Text(purpose == .speech ? "Choose where your recordings are transcribed." : "Choose where your writing is polished and summarized.")
                        .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                }
                Spacer()
                FlowIconButton(symbol: "xmark", help: "Close connection setup", action: onClose)
            }.padding(24)
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROVIDER").font(.system(size: 10, weight: .semibold)).tracking(0.9).foregroundStyle(FlowTheme.inkFaint)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                    ForEach(providers, id: \.id) { provider in
                        Button {
                            draft.select(provider.id); key = ""; reuseKey = false; failure = nil
                            keyFocused = false
                        } label: {
                            HStack(spacing: 9) {
                                ProviderMark(title: provider.title, size: 25)
                                Text(provider.id == "custom" ? "Custom service" : provider.title)
                                    .font(.system(size: 12, weight: draft.providerID == provider.id ? .semibold : .regular))
                                Spacer(minLength: 0)
                                if draft.providerID == provider.id { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(FlowTheme.accent) }
                            }.foregroundStyle(FlowTheme.ink).padding(.horizontal, 10).padding(.vertical, 8)
                                .background(draft.providerID == provider.id ? FlowTheme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(draft.providerID == provider.id ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }.padding(14).frame(width: 195).frame(maxHeight: .infinity).background(FlowTheme.background)
                Rectangle().fill(FlowTheme.line).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 10) {
                            ProviderMark(title: draft.title, size: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.isCustom ? "Custom service" : draft.title).font(.system(size: 19, weight: .semibold))
                                Text(draft.isCustom ? "An OpenAI-compatible endpoint" : "Use your own provider account")
                                    .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                            }
                        }
                        keySection
                        if draft.isCustom { endpointField }
                        modelField
                        DisclosureGroup("Advanced", isExpanded: $advanced) {
                            VStack(alignment: .leading, spacing: 16) {
                                if !draft.isCustom { endpointField }
                                if purpose == .speech {
                                    Toggle("Use streaming when available", isOn: $draft.automaticStreaming).toggleStyle(.switch).font(.system(size: 12))
                                    Text(StreamingCapability.description(for: draft.settings)).font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted)
                                }
                                Text("Keys are stored in a permission-restricted file on this Mac.")
                                    .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint)
                            }.padding(.top, 14)
                        }.font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                        if let failure {
                            Label(failure, systemImage: "exclamationmark.circle").font(.system(size: 12))
                                .foregroundStyle(FlowTheme.recording).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }.background(FlowTheme.surface)
            }.frame(height: 400)
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            HStack {
                Text("Applied when you save.").font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint)
                Spacer()
                Button("Cancel", action: onClose).buttonStyle(.flowSecondary).keyboardShortcut(.cancelAction)
                Button("Save connection") { save() }.buttonStyle(.flowPrimary).keyboardShortcut(.defaultAction).disabled(!readyToSave)
            }.padding(.horizontal, 24).padding(.vertical, 18)
        }.frame(width: 675).background(FlowTheme.background).foregroundStyle(FlowTheme.ink).tint(FlowTheme.accent)
            .onAppear { readKeys() }
            .onChange(of: draft.scope.account) { _, _ in readKeys() }
            .onChange(of: key) { _, _ in failure = nil }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("API key").font(.system(size: 12, weight: .medium))
                Spacer()
                if let url = ProviderLinks.keyURL(for: draft.providerID) {
                    Link(destination: url) { HStack(spacing: 4) { Text("Get a key"); Image(systemName: "arrow.up.right").font(.system(size: 9)) } }
                        .font(.system(size: 11.5)).foregroundStyle(FlowTheme.accent)
                }
            }
            if hasSavedKey {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(FlowTheme.success)
                    Text("A key is saved for this connection").foregroundStyle(FlowTheme.inkMuted)
                }.font(.system(size: 11.5))
            }
            SecureField(hasSavedKey ? "Paste a replacement key (optional)" : "Paste your API key", text: $key)
                .flowField().focused($keyFocused).disabled(reuseKey)
                .accessibilityLabel(hasSavedKey ? "Replacement API key" : "API key")
            if canReuseKey && !hasSavedKey {
                Toggle(purpose == .speech ? "Use my saved writing key" : "Use my saved transcription key", isOn: $reuseKey)
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
            Text("Saving stores the key. Provider access is checked when you use it.")
                .font(.system(size: 11)).foregroundStyle(FlowTheme.inkFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var modelField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Model").font(.system(size: 12, weight: .medium))
                Spacer()
                if !draft.isCustom {
                    Menu("Presets") {
                        ForEach(draft.models, id: \.self) { model in Button(model) { draft.model = model } }
                    }.font(.system(size: 11.5)).fixedSize()
                }
            }
            TextField("Model ID", text: $draft.model).flowField().font(.system(size: 12, design: .monospaced)).accessibilityLabel("Model ID")
        }
    }
    private var endpointField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server address").font(.system(size: 12, weight: .medium))
            TextField("https://your-server.com/v1", text: $draft.endpoint).flowField().font(.system(size: 12)).accessibilityLabel("Server address")
            if let validation = draft.validationMessage, draft.isCustom {
                Text(validation).font(.system(size: 11)).foregroundStyle(FlowTheme.warning)
            }
        }
    }
    private func readKeys() {
        hasSavedKey = false; canReuseKey = false; reuseKey = false
        do {
            hasSavedKey = !(try CredentialStore.readChecked(account: draft.scope.account, rootURL: controller.storageRoot) ?? "").isEmpty
            if draft.scope.provider == draft.otherScope.provider && draft.scope.endpoint == draft.otherScope.endpoint {
                canReuseKey = !(try CredentialStore.readChecked(account: draft.otherScope.account, rootURL: controller.storageRoot) ?? "").isEmpty
            }
        } catch { failure = "Couldn’t read saved keys. \(error.localizedDescription)" }
    }
    private func save() {
        do {
            try controller.saveConnection(draft, key: key, reuseKey: reuseKey)
            key = ""; controller.flash("Connection saved"); onClose()
        } catch { failure = error.localizedDescription }
    }
}

private struct ProviderMark: View {
    let title: String
    var size: CGFloat
    var body: some View {
        Text(String(title.prefix(1))).font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(FlowTheme.inkMuted).frame(width: size, height: size)
            .background(FlowTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: size * 0.25))
            .overlay(RoundedRectangle(cornerRadius: size * 0.25).stroke(FlowTheme.line, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

enum ProviderLinks {
    static func keyURL(for provider: String) -> URL? {
        let address: String?
        switch provider {
        case "openRouter": address = "https://openrouter.ai/settings/keys"
        case "openAI": address = "https://platform.openai.com/api-keys"
        case "groq": address = "https://console.groq.com/keys"
        case "deepgram": address = "https://console.deepgram.com/"
        case "assemblyAI": address = "https://www.assemblyai.com/dashboard/"
        case "mistral": address = "https://console.mistral.ai/"
        case "anthropic": address = "https://console.anthropic.com/settings/keys"
        case "google": address = "https://aistudio.google.com/apikey"
        default: address = nil
        }
        return address.flatMap(URL.init(string:))
    }
}
