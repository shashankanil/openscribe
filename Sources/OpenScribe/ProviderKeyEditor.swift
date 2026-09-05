import SwiftUI

struct ProviderKeyEditor: View {
    let scope: CredentialScope
    let reuseScope: CredentialScope?
    @State private var isEditing = false
    @State private var draft = ""
    @State private var hasSavedKey = false
    @State private var canReuse = false
    @State private var message: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: hasSavedKey ? "key.fill" : "key")
                    .font(.system(size: 15)).foregroundStyle(FlowTheme.lavenderDeep)
                    .frame(width: 36, height: 36)
                    .background(FlowTheme.lavender.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(hasSavedKey ? "API key saved" : "Add your API key")
                        .font(.system(size: 13, weight: .medium))
                    Text(hasSavedKey ? "Stored on this Mac" : "Needed to use " + scope.title)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(hasSavedKey ? "Manage" : "Add key") {
                    draft = ""; message = nil; failure = nil; isEditing = true
                }.buttonStyle(.bordered).controlSize(.small)
            }
            if let failure, !isEditing { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { load() }
        .onChange(of: scope.account) { _, _ in load() }
        .onChange(of: reuseScope?.account) { _, _ in load() }
        .sheet(isPresented: $isEditing) { editor }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(hasSavedKey ? "Manage " + scope.title + " key" : "Add " + scope.title + " key")
                    .font(.system(size: 21, weight: .semibold))
                Text(scope.purpose == .speech ? "Used to transcribe your recordings." : "Used to polish your writing and summarize meetings.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(hasSavedKey ? "Replacement key" : "API key").font(.caption.weight(.medium))
                SecureField(hasSavedKey ? "Paste a new key to replace the saved one" : "Paste your API key", text: $draft)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .onChange(of: draft) { _, _ in message = nil; failure = nil }
                    .onSubmit { save(draft) }
                Text("Saved for this connection only. Your other provider keys stay separate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if canReuse {
                Button(scope.purpose == .speech ? "Use my saved " + scope.title + " cleanup key" : "Use my saved " + scope.title + " transcription key") { reuse() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            DisclosureGroup("Storage details") {
                Text("Keys are stored in a permission-restricted local file. Saving a key does not verify provider access.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                if hasSavedKey { Button("Remove key", role: .destructive) { remove() }.buttonStyle(.borderless) }
                Spacer()
                Button("Cancel") { isEditing = false; draft = "" }.keyboardShortcut(.cancelAction)
                Button(hasSavedKey ? "Save replacement" : "Save key") { save(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 460).background(FlowTheme.paper)
    }

    private func load() {
        draft = ""; message = nil; failure = nil; hasSavedKey = false; canReuse = false
        do {
            hasSavedKey = !(try CredentialStore.readChecked(account: scope.account) ?? "").isEmpty
            if let reuseScope, reuseScope.provider == scope.provider, reuseScope.endpoint == scope.endpoint {
                canReuse = !(try CredentialStore.readChecked(account: reuseScope.account) ?? "").isEmpty
            }
        } catch { failure = "Could not read saved keys: \(error.localizedDescription)" }
    }

    private func save(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try CredentialStore.save(key, account: scope.account)
            draft = ""; hasSavedKey = true; failure = nil
            message = "Key saved for \(scope.title)."
            isEditing = false
        } catch { failure = "Key was not saved: \(error.localizedDescription)" }
    }

    private func remove() {
        do {
            try CredentialStore.delete(account: scope.account)
            draft = ""; hasSavedKey = false; failure = nil
            message = "Key removed for this connection."
            isEditing = false
        } catch { failure = "Key was not removed: \(error.localizedDescription)" }
    }

    private func reuse() {
        guard let reuseScope, reuseScope.provider == scope.provider, reuseScope.endpoint == scope.endpoint else { return }
        do {
            guard let key = try CredentialStore.readChecked(account: reuseScope.account), !key.isEmpty else { load(); return }
            save(key)
        } catch { failure = "Could not read the saved key: \(error.localizedDescription)" }
    }
}
