import Foundation

/// Reducer kept separate from networking so partial revisions and final replacements are testable.
struct RealtimeTranscript {
    var text = ""
    var finalParts: [String: String] = [:]
    var order: [String] = []
    var completed = Set<String>()
    var terminal = false

    mutating func consume(_ event: [String: Any], transport: StreamingCapability.Transport) throws {
        let type = event["type"] as? String ?? ""
        if type == "error" || type == "Error" || type.hasSuffix(".failed") {
            throw ProviderClient.ClientError.provider(message: "Live transcription was rejected. The saved audio will use file transcription.")
        }
        switch transport {
        case .mistral:
            if type == "transcription.text.delta" { text += event["text"] as? String ?? "" }
            if type == "transcription.done" { text = event["text"] as? String ?? text; terminal = true }
        case .deepgram:
            if type == "Results", let channel = event["channel"] as? [String: Any],
               let alternatives = channel["alternatives"] as? [[String: Any]], let transcript = alternatives.first?["transcript"] as? String {
                let key = String(event["start"] as? Double ?? 0)
                if event["is_final"] as? Bool == true {
                    if !order.contains(key) { order.append(key) }
                    finalParts[key] = transcript
                    text = order.compactMap { finalParts[$0] }.joined(separator: " ")
                } else {
                    text = (order.compactMap { finalParts[$0] } + [transcript]).joined(separator: " ")
                }
            }
            if type == "Metadata" { terminal = true; text = order.compactMap { finalParts[$0] }.joined(separator: " ") }
        case .assemblyAI:
            if type == "Turn", let turn = event["turn_order"] as? Int, let transcript = event["transcript"] as? String {
                let key = String(turn)
                finalParts[key] = transcript
                text = finalParts.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { finalParts[$0] }.joined(separator: " ")
            }
            if type == "Termination" { terminal = true }
        case .openAI:
            if type == "input_audio_buffer.committed", let id = event["item_id"] as? String, !order.contains(id) { order.append(id) }
            if let id = event["item_id"] as? String {
                if !order.contains(id) { order.append(id) }
                if type == "conversation.item.input_audio_transcription.delta", !completed.contains(id) {
                    finalParts[id, default: ""] += event["delta"] as? String ?? ""
                }
                if type == "conversation.item.input_audio_transcription.completed" {
                    finalParts[id] = event["transcript"] as? String ?? ""
                    completed.insert(id)
                }
                text = order.compactMap { finalParts[$0] }.joined(separator: " ")
            }
        }
    }
}

protocol RealtimeSocket: Sendable {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}
extension URLSessionWebSocketTask: RealtimeSocket {}

actor RealtimeTranscription {
    private let capability: StreamingCapability
    private let socket: any RealtimeSocket
    private let timeoutNanoseconds: UInt64
    private var transcript = RealtimeTranscript()
    private var ended = false
    private var commits = 0
    private var pendingBytes = 0
    private let onPartial: @Sendable (String) -> Void

    init(capability: StreamingCapability, apiKey: String, socket: (any RealtimeSocket)? = nil, timeoutNanoseconds: UInt64 = 45_000_000_000, onPartial: @escaping @Sendable (String) -> Void) {
        self.capability = capability
        self.socket = socket ?? URLSession.shared.webSocketTask(with: capability.request(apiKey: apiKey))
        self.timeoutNanoseconds = timeoutNanoseconds
        self.onPartial = onPartial
    }

    func run(audio: AsyncThrowingStream<Data, Error>) async throws -> String {
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [socket, timeoutNanoseconds] in
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    socket.cancel(with: .goingAway, reason: nil)
                    throw URLError(.timedOut)
                }
                group.addTask { try await self.exchange(audio) }
                defer { group.cancelAll() }
                return try await group.next() ?? ""
            }
        } onCancel: { [socket] in socket.cancel(with: .goingAway, reason: nil) }
    }

    private func exchange(_ audio: AsyncThrowingStream<Data, Error>) async throws -> String {
        // Providers with session handshakes must acknowledge configuration before receiving PCM.
        switch capability.transport {
        case .mistral:
            try await expect("session.created")
            try await sendJSON(["type": "session.update", "session": ["audio_format": ["encoding": "pcm_s16le", "sample_rate": 16000]]])
            try await expect("session.updated")
        case .openAI:
            try await expect("session.created")
            try await sendJSON(["type": "session.update", "session": ["type": "transcription", "audio": ["input": ["format": ["type": "audio/pcm", "rate": 24000], "transcription": ["model": capability.model], "turn_detection": NSNull()]]]])
            try await expect("session.updated")
        case .assemblyAI: try await expect("Begin")
        case .deepgram: break
        }
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await self.sendAudio(audio); return nil }
            group.addTask { try await self.receiveTranscript() }
            defer { group.cancelAll(); socket.cancel(with: .goingAway, reason: nil) }
            for try await result in group { if let result { return result } }
            throw ProviderClient.ClientError.malformedResponse
        }
    }

    private func sendAudio(_ audio: AsyncThrowingStream<Data, Error>) async throws {
        for try await bytes in audio {
            try Task.checkCancellation()
            switch capability.transport {
            case .mistral: try await sendJSON(["type": "input_audio.append", "audio": bytes.base64EncodedString()])
            case .openAI:
                try await sendJSON(["type": "input_audio_buffer.append", "audio": bytes.base64EncodedString()])
                pendingBytes += bytes.count
                // Older transcription models emit text after a commit, unlike gpt-live-transcribe.
                if !["gpt-live-transcribe", "gpt-realtime-whisper"].contains(capability.model), pendingBytes >= 96000 {
                    commits += 1; pendingBytes = 0
                    try await sendJSON(["type": "input_audio_buffer.commit"])
                }
            case .deepgram, .assemblyAI: try await socket.send(.data(bytes))
            }
        }
        try Task.checkCancellation()
        switch capability.transport {
        case .openAI:
            // At least 100 ms is required to commit; pad a short final tail with silence.
            if pendingBytes < 4800 {
                try await sendJSON(["type": "input_audio_buffer.append", "audio": Data(count: 4800 - pendingBytes).base64EncodedString()])
            }
            commits += 1; ended = true
            try await sendJSON(["type": "input_audio_buffer.commit"])
        case .mistral: ended = true; try await sendJSON(["type": "input_audio.end"])
        case .deepgram: ended = true; try await sendJSON(["type": "CloseStream"])
        case .assemblyAI: ended = true; try await sendJSON(["type": "Terminate"])
        }
    }

    private func receiveTranscript() async throws -> String {
        while true {
            try Task.checkCancellation()
            let event = try await receiveJSON()
            try transcript.consume(event, transport: capability.transport)
            onPartial(transcript.text)
            if capability.transport == .openAI {
                if ended && transcript.completed.count >= commits { return transcript.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else if transcript.terminal {
                guard ended else { throw ProviderClient.ClientError.malformedResponse }
                return transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func expect(_ type: String) async throws {
        let event = try await receiveJSON()
        guard event["type"] as? String == type else { throw ProviderClient.ClientError.provider(message: "Live transcription setup failed. Using saved audio sections.") }
    }
    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func receiveJSON() async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw ProviderClient.ClientError.malformedResponse }
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderClient.ClientError.malformedResponse }
        return event
    }
}
