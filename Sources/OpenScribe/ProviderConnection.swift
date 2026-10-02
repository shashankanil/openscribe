import Foundation

/// An editable connection. Browsing providers never changes the active settings.
struct ProviderConnectionDraft {
    let purpose: CredentialKey
    private(set) var settings: AppSettings

    init(purpose: CredentialKey, settings: AppSettings) {
        self.purpose = purpose
        self.settings = settings
    }
    var scope: CredentialScope { CredentialScope(purpose, settings: settings) }
    var otherScope: CredentialScope { CredentialScope(purpose == .speech ? .languageModel : .speech, settings: settings) }
    var providerID: String { scope.provider }
    var title: String { scope.title }
    var isCustom: Bool { providerID == "custom" }
    var model: String {
        get { purpose == .speech ? settings.speechModel : settings.languageModel }
        set { if purpose == .speech { settings.speechModel = newValue } else { settings.languageModel = newValue } }
    }
    var endpoint: String {
        get { purpose == .speech ? settings.speechBaseURL : settings.languageModelBaseURL }
        set { if purpose == .speech { settings.speechBaseURL = newValue } else { settings.languageModelBaseURL = newValue } }
    }
    var automaticStreaming: Bool {
        get { settings.automaticStreaming }
        set { settings.automaticStreaming = newValue }
    }
    var models: [String] {
        guard purpose == .speech else { return [settings.languageModelProvider.defaultModel] }
        return Array(Set([settings.speechProvider.defaultModel] + StreamingCapability.models(for: settings.speechProvider))).sorted()
    }
    mutating func select(_ identifier: String) {
        guard identifier != providerID else { return }
        if purpose == .speech, let provider = SpeechProvider(rawValue: identifier) {
            settings.speechProvider = provider; settings.speechBaseURL = provider.defaultBaseURL; settings.speechModel = provider.defaultModel
        } else if purpose == .languageModel, let provider = LanguageModelProvider(rawValue: identifier) {
            settings.languageModelProvider = provider; settings.languageModelBaseURL = provider.defaultBaseURL; settings.languageModel = provider.defaultModel
        }
    }
    func applying(to current: AppSettings) -> AppSettings {
        var result = current
        if purpose == .speech {
            result.speechProvider = settings.speechProvider
            result.speechBaseURL = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            result.speechModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            result.automaticStreaming = automaticStreaming
        } else {
            result.languageModelProvider = settings.languageModelProvider
            result.languageModelBaseURL = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            result.languageModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
    var validationMessage: String? {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter a model ID." }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, host.lowercased() != "example.com",
              url.user == nil, url.password == nil else { return "Enter a valid HTTP or HTTPS server address." }
        return nil
    }
}

struct ConnectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AppController {
    func saveConnection(_ draft: ProviderConnectionDraft, key: String, reuseKey: Bool = false) throws {
        if let error = draft.validationMessage { throw ConnectionError(message: error) }
        let scope = draft.scope
        var replacement = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if reuseKey {
            guard scope.provider == draft.otherScope.provider, scope.endpoint == draft.otherScope.endpoint else {
                throw ConnectionError(message: "The other key belongs to a different provider or server.")
            }
            replacement = try CredentialStore.readChecked(account: draft.otherScope.account, rootURL: storageRoot) ?? ""
        }
        let savedKey = try CredentialStore.readChecked(account: scope.account, rootURL: storageRoot) ?? ""
        guard !replacement.isEmpty || !savedKey.isEmpty else { throw ConnectionError(message: "Add an API key for this provider.") }
        if !replacement.isEmpty { try CredentialStore.save(replacement, account: scope.account, rootURL: storageRoot) }
        guard store.saveSettings(draft.applying(to: settings)) else {
            throw ConnectionError(message: "Couldn’t save the connection settings. Check local storage and try again.")
        }
        objectWillChange.send()
    }
}
