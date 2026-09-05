import CryptoKit
import Foundation

/// Keys are isolated by service, endpoint and purpose. Models share a service credential.
struct CredentialScope: Equatable {
    let purpose: CredentialKey
    let provider: String
    let title: String
    let endpoint: String

    init(_ purpose: CredentialKey, settings: AppSettings) {
        self.purpose = purpose
        let raw: String
        switch purpose {
        case .speech:
            provider = settings.speechProvider.rawValue; title = settings.speechProvider.title; raw = settings.speechBaseURL
        case .languageModel:
            provider = settings.languageModelProvider.rawValue; title = settings.languageModelProvider.title; raw = settings.languageModelBaseURL
        }
        var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        if components?.scheme == "https", components?.port == 443 { components?.port = nil }
        if components?.scheme == "http", components?.port == 80 { components?.port = nil }
        if var path = components?.path {
            while path.hasSuffix("/") { path.removeLast() }
            components?.path = path
        }
        endpoint = components?.string ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var account: String {
        let digest = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return "v2.\(purpose.rawValue).\(provider).\(digest)"
    }
}

extension CredentialStore {
    static func read(for purpose: CredentialKey, settings: AppSettings, rootURL: URL? = nil) -> String? {
        read(account: CredentialScope(purpose, settings: settings).account, rootURL: rootURL)
    }
}
