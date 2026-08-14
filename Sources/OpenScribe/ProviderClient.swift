import Foundation

struct ProviderClient {
    enum ClientError: LocalizedError {
        case invalidURL
        case missingAPIKey
        case http(status: Int, message: String)
        case malformedResponse
        case audioFile(message: String)
        case provider(message: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "The provider URL is invalid."
            case .missingAPIKey: return "Add an API key in Settings before recording."
            case let .http(status, message): return "Provider request failed (HTTP \(status)): \(message)"
            case .malformedResponse: return "The provider returned an unreadable response."
            case let .audioFile(message): return message
            case let .provider(message): return message
            }
        }
    }

    func transcribe(recording: RecordedAudio, settings: AppSettings, apiKey: String) async throws -> [String] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.missingAPIKey
        }

        var transcripts: [String] = []
        transcripts.reserveCapacity(recording.chunkURLs.count)
        for chunkURL in recording.chunkURLs {
            try Task.checkCancellation()
            let text = try await transcribe(
                audioFile: chunkURL,
                settings: settings,
                apiKey: apiKey
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                transcripts.append(trimmed)
            }
        }
        guard !transcripts.isEmpty else { throw ClientError.malformedResponse }
        return transcripts
    }

    func cleanTranscript(_ text: String, settings: AppSettings, apiKey: String) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.missingAPIKey
        }
        let vocabularyInstruction = settings.customVocabulary.isEmpty
            ? ""
            : "Preserve these custom words and names exactly when they appear: \(settings.customVocabulary.joined(separator: ", "))."
        let system = """
        You are the quiet editing layer of a voice dictation app. Clean the transcript without changing meaning.
        Remove filler words, false starts, repeated words, and obvious transcription errors. Preserve names, numbers,
        intent, and paragraph breaks. \(settings.writingTone.instruction)
        \(vocabularyInstruction)
        Return only the polished text with no preamble, labels, quotes, or commentary.
        """
        switch settings.languageModelProvider {
        case .anthropic:
            return try await cleanWithAnthropic(text: text, system: system, settings: settings, apiKey: apiKey)
        case .google:
            return try await cleanWithGemini(text: text, system: system, settings: settings, apiKey: apiKey)
        case .openRouter, .openAI, .groq, .custom:
            return try await cleanWithOpenAICompatible(text: text, system: system, settings: settings, apiKey: apiKey)
        }
    }

    private func transcribe(
        audioFile: URL,
        settings: AppSettings,
        apiKey: String
    ) async throws -> String {
        switch settings.speechProvider {
        case .deepgram:
            return try await transcribeWithDeepgram(audioFile: audioFile, settings: settings, apiKey: apiKey)
        case .assemblyAI:
            return try await transcribeWithAssemblyAI(audioFile: audioFile, settings: settings, apiKey: apiKey)
        case .openRouter, .openAI, .groq, .custom:
            return try await transcribeOpenAICompatible(audioFile: audioFile, settings: settings, apiKey: apiKey)
        }
    }

    private func transcribeOpenAICompatible(
        audioFile: URL,
        settings: AppSettings,
        apiKey: String
    ) async throws -> String {
        let endpoint = try url(base: settings.speechBaseURL, path: "/audio/transcriptions")
        let boundary = "OpenScribe-\(UUID().uuidString)"
        let bodyURL = try makeMultipartBody(
            audioFile: audioFile,
            boundary: boundary,
            model: settings.speechModel
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if settings.speechProvider == .openRouter {
            request.setValue("https://openscribe.local", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("OpenScribe", forHTTPHeaderField: "X-Title")
        }
        let data = try await send(request, bodyFile: bodyURL)
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        guard let text = response.text else { throw ClientError.malformedResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeWithDeepgram(
        audioFile: URL,
        settings: AppSettings,
        apiKey: String
    ) async throws -> String {
        let baseEndpoint = try url(base: settings.speechBaseURL, path: "/listen")
        var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "model", value: settings.speechModel),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]
        guard let endpoint = components?.url else { throw ClientError.invalidURL }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let data = try await send(request, bodyFile: audioFile)
        let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        guard let text = response.results?.channels?.first?.alternatives?.first?.transcript else {
            throw ClientError.malformedResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeWithAssemblyAI(
        audioFile: URL,
        settings: AppSettings,
        apiKey: String
    ) async throws -> String {
        let uploadURL = try url(base: settings.speechBaseURL, path: "/upload")
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let uploadData = try await send(uploadRequest, bodyFile: audioFile)
        let upload = try JSONDecoder().decode(AssemblyUploadResponse.self, from: uploadData)

        let transcriptURL = try url(base: settings.speechBaseURL, path: "/transcript")
        var createRequest = URLRequest(url: transcriptURL)
        createRequest.httpMethod = "POST"
        createRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "audio_url": upload.uploadURL,
            "speech_model": settings.speechModel,
        ])
        let createData = try await send(createRequest)
        let created = try JSONDecoder().decode(AssemblyTranscriptResponse.self, from: createData)

        for _ in 0..<90 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let pollURL = try url(base: settings.speechBaseURL, path: "/transcript/\(created.id)")
            var pollRequest = URLRequest(url: pollURL)
            pollRequest.httpMethod = "GET"
            pollRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
            let pollData = try await send(pollRequest)
            let result = try JSONDecoder().decode(AssemblyTranscriptResponse.self, from: pollData)
            if result.status == "completed", let text = result.text {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if result.status == "error" {
                throw ClientError.provider(message: result.error ?? "AssemblyAI could not transcribe the recording.")
            }
        }
        throw ClientError.provider(message: "AssemblyAI transcription timed out.")
    }

    private func cleanWithOpenAICompatible(text: String, system: String, settings: AppSettings, apiKey: String) async throws -> String {
        let endpoint = try url(base: settings.languageModelBaseURL, path: "/chat/completions")
        let payload: [String: Any] = [
            "model": settings.languageModel,
            "temperature": 0.15,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
        ]
        var request = try jsonRequest(url: endpoint, payload: payload)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if settings.languageModelProvider == .openRouter {
            request.setValue("https://openscribe.local", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("OpenScribe", forHTTPHeaderField: "X-Title")
        }
        let data = try await send(request)
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = response.choices?.first?.message?.content, !content.isEmpty else { throw ClientError.malformedResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanWithAnthropic(text: String, system: String, settings: AppSettings, apiKey: String) async throws -> String {
        let endpoint = try url(base: settings.languageModelBaseURL, path: "/v1/messages")
        let payload: [String: Any] = [
            "model": settings.languageModel,
            "max_tokens": 2048,
            "temperature": 0.15,
            "system": system,
            "messages": [["role": "user", "content": text]],
        ]
        var request = try jsonRequest(url: endpoint, payload: payload)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let data = try await send(request)
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let content = response.content?.first?.text, !content.isEmpty else { throw ClientError.malformedResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanWithGemini(text: String, system: String, settings: AppSettings, apiKey: String) async throws -> String {
        let endpoint = try url(base: settings.languageModelBaseURL, path: "/v1beta/models/\(settings.languageModel):generateContent")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let endpointWithKey = components?.url else { throw ClientError.invalidURL }
        let payload: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": text]]]],
            "generationConfig": ["temperature": 0.15],
        ]
        let request = try jsonRequest(url: endpointWithKey, payload: payload)
        let data = try await send(request)
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let content = response.candidates?.first?.content?.parts?.first?.text, !content.isEmpty else {
            throw ClientError.malformedResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeMultipartBody(audioFile: URL, boundary: String, model: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            throw ClientError.audioFile(message: "The recorded audio file is no longer available.")
        }
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openscribe-upload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw ClientError.audioFile(message: "OpenScribe could not prepare the audio upload.")
        }

        let output = try FileHandle(forWritingTo: bodyURL)
        let input = try FileHandle(forReadingFrom: audioFile)
        defer {
            input.closeFile()
            output.closeFile()
        }

        output.write(Data("--\(boundary)\r\n".utf8))
        output.write(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
        output.write(Data("\(model)\r\n".utf8))
        output.write(Data("--\(boundary)\r\n".utf8))
        output.write(Data("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".utf8))
        output.write(Data("json\r\n".utf8))
        output.write(Data("--\(boundary)\r\n".utf8))
        output.write(Data("Content-Disposition: form-data; name=\"file\"; filename=\"openscribe.wav\"\r\n".utf8))
        output.write(Data("Content-Type: audio/wav\r\n\r\n".utf8))

        while true {
            let chunk = input.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            output.write(chunk)
        }

        output.write(Data("\r\n--\(boundary)--\r\n".utf8))
        return bodyURL
    }

    private func url(base: String, path: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)\(path)") else { throw ClientError.invalidURL }
        return url
    }

    private func jsonRequest(url: URL, payload: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        return try validate(data: data, response: response)
    }

    private func send(_ request: URLRequest, bodyFile: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyFile)
        return try validate(data: data, response: response)
    }

    private func validate(data: Data, response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown provider error"
            throw ClientError.http(status: http.statusCode, message: String(message.prefix(400)))
        }
        return data
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String?
}

private struct DeepgramResponse: Decodable {
    struct Results: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable { let transcript: String? }
            let alternatives: [Alternative]?
        }
        let channels: [Channel]?
    }
    let results: Results?
}

private struct AssemblyUploadResponse: Decodable {
    let uploadURL: String
    enum CodingKeys: String, CodingKey { case uploadURL = "upload_url" }
}

private struct AssemblyTranscriptResponse: Decodable {
    let id: String
    let status: String
    let text: String?
    let error: String?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
    }
    let choices: [Choice]?
}

private struct AnthropicResponse: Decodable {
    struct Block: Decodable { let text: String? }
    let content: [Block]?
}

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}

