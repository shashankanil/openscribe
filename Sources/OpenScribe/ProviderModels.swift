import Foundation

/// A model a provider offers, as listed by its API.
struct ProviderModel: Identifiable, Hashable {
    let id: String
    var name: String?
}

/// Checks an API key and lists the provider's models for one purpose (transcription or writing).
/// Parsing is separate from networking so each provider's response format is unit-tested.
enum ProviderModelCatalog {
    enum CatalogError: LocalizedError, Equatable {
        case rejected(String)
        case server(Int, String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let provider): return "\(provider) rejected this key. Check that it's correct and active."
            case .server(let status, let message):
                return message.isEmpty ? "The provider answered with an error (\(status))." : "The provider answered with an error (\(status)): \(message)"
            case .unreadable(let provider): return "\(provider) sent a model list OpenScribe couldn't read."
            }
        }
    }

    /// AssemblyAI has no model list; these are the values its API accepts for `speech_model`.
    static let assemblyAIModels = ["best", "universal", "slam-1", "nano"]
    /// Anthropic API version sent with Claude requests elsewhere in the app (ProviderClient).
    static let anthropicVersion = "2023-06-01"

    static func fetch(purpose: CredentialKey, providerID: String, title: String, endpoint: String, apiKey: String,
                      session: URLSession = .shared) async throws -> [ProviderModel] {
        let base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func get(_ path: String, headers: [String: String]) async throws -> Data {
            guard let url = URL(string: base + path) else { throw CatalogError.unreadable(title) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { throw CatalogError.rejected(title) }
            guard (200..<300).contains(status) else { throw CatalogError.server(status, errorMessage(data)) }
            return data
        }
        let bearer = ["Authorization": "Bearer \(apiKey)"]

        switch (purpose, providerID) {
        case (.speech, "assemblyAI"):
            _ = try await get("/transcript?limit=1", headers: ["Authorization": apiKey])
            return assemblyAIModels.map { ProviderModel(id: $0) }
        case (.speech, "deepgram"):
            let key = apiKey.hasPrefix("Token ") ? apiKey : "Token \(apiKey)"
            return try parseDeepgram(await get("/models", headers: ["Authorization": key]), title: title)
        case (_, "openRouter"):
            // The model list is public, so check the key separately.
            _ = try await get("/key", headers: bearer)
            // Transcription goes to /audio/transcriptions, which only dedicated speech-to-text models serve.
            let path = purpose == .speech ? "/models?output_modalities=transcription" : "/models"
            return try parseOpenRouter(await get(path, headers: bearer), purpose: purpose, title: title)
        case (.languageModel, "anthropic"):
            var models: [ProviderModel] = []
            var after: String?
            repeat {
                let page = try parseAnthropicPage(
                    await get("/v1/models?limit=1000" + (after.map { "&after_id=\($0)" } ?? ""),
                        headers: ["x-api-key": apiKey, "anthropic-version": anthropicVersion]), title: title)
                models += page.models
                after = page.hasMore ? page.lastID : nil
            } while after != nil
            return models
        case (.languageModel, "google"):
            var models: [ProviderModel] = []
            var token: String?
            repeat {
                let page = try parseGooglePage(
                    await get("/v1beta/models?pageSize=1000" + (token.map { "&pageToken=\($0)" } ?? ""), headers: ["x-goog-api-key": apiKey]),
                    title: title)
                models += page.models
                token = page.nextPageToken
            } while token != nil
            return models
        default:
            // OpenAI, Groq, Mistral and custom servers share the OpenAI-style list.
            return try parseOpenAIStyle(await get("/models", headers: bearer), purpose: purpose, providerID: providerID, title: title)
        }
    }

    // MARK: Parsing

    private struct DataList<Item: Decodable>: Decodable { let data: [Item] }

    static func parseOpenAIStyle(_ data: Data, purpose: CredentialKey, providerID: String, title: String) throws -> [ProviderModel] {
        struct Item: Decodable { let id: String }
        guard let items = try? JSONDecoder().decode(DataList<Item>.self, from: data).data else { throw CatalogError.unreadable(title) }
        let ids = items.map(\.id)
        let filtered = ids.filter { purpose == .speech ? isTranscriptionModel($0) : isChatModel($0) }
        // A custom server may use names the filters don't know; show everything rather than nothing.
        let chosen = filtered.isEmpty && providerID == "custom" ? ids : filtered
        return sorted(chosen.map { ProviderModel(id: $0) })
    }

    static func parseOpenRouter(_ data: Data, purpose: CredentialKey, title: String) throws -> [ProviderModel] {
        struct Item: Decodable {
            struct Architecture: Decodable { let input_modalities: [String]?; let output_modalities: [String]? }
            let id: String
            let name: String?
            let architecture: Architecture?
        }
        guard let items = try? JSONDecoder().decode(DataList<Item>.self, from: data).data else { throw CatalogError.unreadable(title) }
        // Transcription lists come pre-filtered by the API (`output_modalities=transcription`).
        let models = purpose == .speech ? items : items.filter { item in
            let input = item.architecture?.input_modalities ?? [], output = item.architecture?.output_modalities ?? ["text"]
            return output.contains("text") && input.contains("text")
        }
        return sorted(models.map { ProviderModel(id: $0.id, name: $0.name) })
    }

    static func parseDeepgram(_ data: Data, title: String) throws -> [ProviderModel] {
        struct Reply: Decodable {
            struct Item: Decodable { let canonical_name: String?; let architecture: String?; let name: String? }
            let stt: [Item]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw CatalogError.unreadable(title) }
        // Both the family ("nova-3") and specific variants ("nova-3-medical") are valid `model` values.
        let ids = Set(reply.stt.flatMap { [$0.architecture, $0.canonical_name].compactMap { $0 } })
        return sorted(ids.map { ProviderModel(id: $0) })
    }

    struct Page { var models: [ProviderModel]; var hasMore = false; var lastID: String?; var nextPageToken: String? }

    static func parseAnthropicPage(_ data: Data, title: String) throws -> Page {
        struct Reply: Decodable {
            struct Item: Decodable { let id: String; let display_name: String? }
            let data: [Item]
            let has_more: Bool?
            let last_id: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw CatalogError.unreadable(title) }
        // Newest first, as the API lists them.
        return Page(models: reply.data.map { ProviderModel(id: $0.id, name: $0.display_name) },
                    hasMore: reply.has_more ?? false, lastID: reply.last_id)
    }

    static func parseGooglePage(_ data: Data, title: String) throws -> Page {
        struct Reply: Decodable {
            struct Item: Decodable { let name: String; let displayName: String?; let supportedGenerationMethods: [String]? }
            let models: [Item]?
            let nextPageToken: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw CatalogError.unreadable(title) }
        let models = (reply.models ?? []).filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") && $0.name.contains("gemini") }
            .map { ProviderModel(id: $0.name.replacingOccurrences(of: "models/", with: ""), name: $0.displayName) }
        return Page(models: sorted(models), nextPageToken: reply.nextPageToken.flatMap { $0.isEmpty ? nil : $0 })
    }

    static func isTranscriptionModel(_ id: String) -> Bool {
        let id = id.lowercased()
        return ["whisper", "transcribe", "voxtral", "scribe"].contains(where: id.contains) && !id.contains("tts")
    }

    static func isChatModel(_ id: String) -> Bool {
        let id = id.lowercased()
        let excluded = ["whisper", "transcribe", "tts", "embed", "dall-e", "image", "moderation", "audio", "realtime",
                        "davinci", "babbage", "search", "sora", "voxtral", "guard", "speech", "computer-use"]
        return !excluded.contains(where: id.contains)
    }

    private static func sorted(_ models: [ProviderModel]) -> [ProviderModel] {
        models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func errorMessage(_ data: Data) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
            let message: String?
            let err_msg: String?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return envelope.error?.message ?? envelope.message ?? envelope.err_msg ?? ""
        }
        return String(String(decoding: data.prefix(200), as: UTF8.self))
    }
}
