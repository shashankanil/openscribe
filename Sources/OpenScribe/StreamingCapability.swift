import Foundation

/// Deliberately exact: an OpenAI-compatible file endpoint does not imply a realtime API.
/// Protocol references and model review date are in docs/streaming.md.
struct StreamingCapability: Equatable {
    enum Transport { case openAI, mistral, deepgram, assemblyAI }
    let transport: Transport
    let model: String
    let endpoint: URL
    let sampleRate: Double
    let fallbackModel: String

    static func models(for provider: SpeechProvider) -> [String] {
        switch provider {
        case .mistral: return ["voxtral-mini-transcribe-realtime-2602"]
        case .openAI: return ["gpt-live-transcribe", "gpt-transcribe", "gpt-realtime-whisper", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-mini-transcribe-2025-12-15", "whisper-1"]
        case .deepgram: return ["nova-3", "nova-3-general", "nova-2", "nova-2-general", "nova-2-meeting", "nova-2-phonecall", "nova-2-medical", "nova-2-conversationalai"]
        case .assemblyAI: return ["universal-3-5-pro", "universal-streaming-english", "universal-streaming-multilingual"]
        default: return []
        }
    }

    static func resolve(_ settings: AppSettings) -> Self? {
        guard let base = URLComponents(string: settings.speechBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme == "https", base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil, base.port == nil || base.port == 443 else { return nil }
        let path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let model = settings.speechModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = base.host?.lowercased()
        var transport: Transport
        var endpoint: String
        var fallback = model
        var rate = 16000.0
        switch settings.speechProvider {
        case .mistral where host == "api.mistral.ai" && path == "v1":
            guard models(for: settings.speechProvider).contains(model) else { return nil }
            transport = .mistral
            endpoint = "wss://api.mistral.ai/v1/audio/transcriptions/realtime"
            fallback = "voxtral-mini-latest"
        case .openAI where host == "api.openai.com" && path == "v1":
            guard models(for: settings.speechProvider).contains(model) else { return nil }
            transport = .openAI
            endpoint = "wss://api.openai.com/v1/realtime"
            rate = 24000
            if ["gpt-live-transcribe", "gpt-transcribe", "gpt-realtime-whisper"].contains(model) { fallback = "gpt-4o-mini-transcribe" }
        case .deepgram where host == "api.deepgram.com" && path == "v1":
            guard models(for: settings.speechProvider).contains(model) else { return nil }
            transport = .deepgram
            endpoint = "wss://api.deepgram.com/v1/listen"
        case .assemblyAI where host == "api.assemblyai.com" && path == "v2":
            guard models(for: settings.speechProvider).contains(model) else { return nil }
            transport = .assemblyAI
            endpoint = "wss://streaming.assemblyai.com/v3/ws"
            fallback = "best"
        default: return nil
        }
        return Self(transport: transport, model: model, endpoint: URL(string: endpoint)!, sampleRate: rate, fallbackModel: fallback)
    }

    static func description(for settings: AppSettings) -> String {
        guard let capability = resolve(settings) else {
            return "15-second sections · Live audio is not mapped for this provider, endpoint and model."
        }
        let mode = settings.automaticStreaming ? "Live audio streaming" : "15-second sections"
        let fallback = capability.fallbackModel == capability.model ? "" : " File recovery uses \(capability.fallbackModel) with the same provider."
        return mode + " · " + capability.model + "." + fallback
    }

    func request(apiKey: String) -> URLRequest {
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        switch transport {
        case .openAI: parts.queryItems = [.init(name: "intent", value: "transcription")]
        case .mistral: parts.queryItems = [.init(name: "model", value: model)]
        case .deepgram:
            parts.queryItems = ["model": model, "encoding": "linear16", "sample_rate": "16000", "channels": "1", "interim_results": "true", "smart_format": "true"].map { .init(name: $0.key, value: $0.value) }
        case .assemblyAI:
            parts.queryItems = ["speech_model": model, "sample_rate": "16000", "encoding": "pcm_s16le", "format_turns": "true"].map { .init(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: parts.url!)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorization: String
        switch transport {
        case .deepgram: authorization = key.hasPrefix("Token ") ? key : "Token \(key)"
        case .assemblyAI: authorization = key
        default: authorization = "Bearer \(key)"
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }
}
