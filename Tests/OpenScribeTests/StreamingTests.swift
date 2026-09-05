import AVFoundation
import XCTest
@testable import OpenScribe

final class StreamingTests: XCTestCase {
    func settings(_ provider: SpeechProvider, _ model: String) -> AppSettings {
        var result = AppSettings()
        result.speechProvider = provider; result.speechBaseURL = provider.defaultBaseURL; result.speechModel = model
        return result
    }

    func testExactCapabilitiesAndEndpointBoundaries() throws {
        for (provider, model) in [(SpeechProvider.mistral, "voxtral-mini-transcribe-realtime-2602"), (.openAI, "gpt-4o-mini-transcribe"), (.deepgram, "nova-3"), (.assemblyAI, "universal-streaming-english")] {
            var configuration = settings(provider, model)
            XCTAssertNotNil(StreamingCapability.resolve(configuration))
            configuration.speechBaseURL += "/other"
            XCTAssertNil(StreamingCapability.resolve(configuration))
        }
        XCTAssertNil(StreamingCapability.resolve(settings(.openRouter, "mistralai/voxtral-mini-transcribe")))
        XCTAssertNil(StreamingCapability.resolve(settings(.groq, "whisper-large-v3-turbo")))
        XCTAssertNil(StreamingCapability.resolve(settings(.openAI, "future-model")))
        XCTAssertNil(StreamingCapability.resolve(settings(.mistral, "voxtral-mini-latest")))
        for url in ["https://api.openai.com.evil.test/v1", "http://api.openai.com/v1", "https://api.openai.com/v1?redirect=x", "https://user@api.openai.com/v1", "https://api.openai.com:4433/v1"] {
            var config = settings(.openAI, "gpt-live-transcribe"); config.speechBaseURL = url
            XCTAssertNil(StreamingCapability.resolve(config))
        }
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.automaticStreaming)
        var manual = old; manual.automaticStreaming = false
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(manual)).automaticStreaming)
    }

    func testRequestAuthenticationAndFallbackStayWithProvider() throws {
        let deepgram = try XCTUnwrap(StreamingCapability.resolve(settings(.deepgram, "nova-3")))
        XCTAssertEqual(deepgram.request(apiKey: "secret").value(forHTTPHeaderField: "Authorization"), "Token secret")
        XCTAssertEqual(deepgram.request(apiKey: "Token secret").value(forHTTPHeaderField: "Authorization"), "Token secret")
        let mistral = try XCTUnwrap(StreamingCapability.resolve(settings(.mistral, "voxtral-mini-transcribe-realtime-2602")))
        XCTAssertEqual(mistral.fallbackModel, "voxtral-mini-latest")
        XCTAssertEqual(mistral.request(apiKey: "secret").url?.host, "api.mistral.ai")
        XCTAssertFalse(mistral.request(apiKey: "secret").url!.absoluteString.contains("secret"))
    }

    func testPartialRevisionsAndFinalsNeverDuplicate() throws {
        var mistral = RealtimeTranscript()
        try mistral.consume(["type": "transcription.text.delta", "text": "hello"], transport: .mistral)
        try mistral.consume(["type": "transcription.done", "text": "Hello."], transport: .mistral)
        XCTAssertEqual(mistral.text, "Hello."); XCTAssertTrue(mistral.terminal)
        var assembly = RealtimeTranscript()
        for text in ["hello", "hello world", "Hello, world."] {
            try assembly.consume(["type": "Turn", "turn_order": 1, "transcript": text], transport: .assemblyAI)
        }
        XCTAssertEqual(assembly.text, "Hello, world.")
        var openAI = RealtimeTranscript()
        try openAI.consume(["type": "conversation.item.input_audio_transcription.delta", "item_id": "a", "delta": "live before commit"], transport: .openAI)
        XCTAssertEqual(openAI.text, "live before commit")
        for id in ["a", "b"] { try openAI.consume(["type": "input_audio_buffer.committed", "item_id": id], transport: .openAI) }
        for (id, text) in [("b", "second"), ("a", "first"), ("a", "first")] {
            try openAI.consume(["type": "conversation.item.input_audio_transcription.completed", "item_id": id, "transcript": text], transport: .openAI)
        }
        XCTAssertEqual(openAI.text, "first second"); XCTAssertEqual(openAI.completed.count, 2)
        XCTAssertThrowsError(try openAI.consume(["type": "error"], transport: .openAI))
    }

    func testPCMStreamsBeforeWAVClosesAndReturnsOnlyFinalText() async throws {
        let received = expectation(description: "PCM before section is closed")
        let capability = try XCTUnwrap(StreamingCapability.resolve(settings(.mistral, "voxtral-mini-transcribe-realtime-2602")))
        let pipeline = LiveAudioPipeline(capability: capability, apiKey: "unused", run: { _, _, audio, partial in
            var bytes = 0
            for try await data in audio {
                if bytes == 0 { received.fulfill(); partial("provisional") }
                bytes += data.count
            }
            // 1 second of stereo 48k source becomes 1 second of mono PCM16 at 16k.
            XCTAssertEqual(bytes, 32000, accuracy: 100)
            return "Final text."
        })
        let store = AudioChunkStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); pipeline.cancel() }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        try store.begin(format: format, directoryURL: directory)
        store.liveSink = pipeline.makeSink()
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0.1, count: 48000) }
        store.append(buffer)
        await fulfillment(of: [received], timeout: 2)
        let file = try XCTUnwrap(store.finish().chunkURLs.first)
        let text = try await pipeline.result(for: file)
        XCTAssertEqual(text, "Final text.")
        let alreadyConsumed = try await pipeline.result(for: file)
        XCTAssertNil(alreadyConsumed)
    }

    func testFailedStreamFallsBackWithoutAcceptingPartialText() async throws {
        let capability = try XCTUnwrap(StreamingCapability.resolve(settings(.deepgram, "nova-3")))
        let pipeline = LiveAudioPipeline(capability: capability, apiKey: "unused", run: { _, _, _, partial in
            partial("incomplete"); throw URLError(.networkConnectionLost)
        })
        let sink = pipeline.makeSink()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
        let url = URL(fileURLWithPath: "/tmp/synthetic-stream.wav")
        sink.append(buffer, url: url); sink.close(url)
        let text = try await pipeline.result(for: url)
        XCTAssertNil(text)
        pipeline.cancel()
    }

    func testRealtimeHandshakeAudioAndFinalization() async throws {
        let capability = try XCTUnwrap(StreamingCapability.resolve(settings(.mistral, "voxtral-mini-transcribe-realtime-2602")))
        let socket = MockRealtimeSocket(events: [["type": "session.created"]])
        let connection = RealtimeTranscription(capability: capability, apiKey: "unused", socket: socket, timeoutNanoseconds: 1_000_000_000, onPartial: { _ in })
        let stream = AsyncThrowingStream<Data, Error> { input in input.yield(Data(count: 3200)); input.finish() }
        let text = try await connection.run(audio: stream)
        XCTAssertEqual(text, "Complete.")
        XCTAssertEqual(socket.sentTypes(), ["session.update", "input_audio.append", "input_audio.end"])
    }

    func testOtherTransportsFlushFinalAudio() async throws {
        for (provider, model) in [(SpeechProvider.openAI, "gpt-4o-mini-transcribe"), (.deepgram, "nova-3"), (.assemblyAI, "universal-streaming-english")] {
            let capability = try XCTUnwrap(StreamingCapability.resolve(settings(provider, model)))
            let initial: [[String: Any]] = provider == .openAI ? [["type": "session.created"]] : provider == .assemblyAI ? [["type": "Begin"]] : []
            let socket = MockRealtimeSocket(events: initial, transport: capability.transport)
            let connection = RealtimeTranscription(capability: capability, apiKey: "unused", socket: socket, timeoutNanoseconds: 1_000_000_000, onPartial: { _ in })
            let audio = AsyncThrowingStream<Data, Error> { $0.yield(Data(count: 4800)); $0.finish() }
            let text = try await connection.run(audio: audio)
            XCTAssertEqual(text, "Complete.", provider.title)
            XCTAssertTrue(socket.isClosed())
        }
    }

    func testTimeoutClosesSocketWithoutHanging() async throws {
        let capability = try XCTUnwrap(StreamingCapability.resolve(settings(.mistral, "voxtral-mini-transcribe-realtime-2602")))
        let socket = MockRealtimeSocket(events: [])
        let connection = RealtimeTranscription(capability: capability, apiKey: "unused", socket: socket, timeoutNanoseconds: 30_000_000, onPartial: { _ in })
        let audio = AsyncThrowingStream<Data, Error> { $0.finish() }
        do { _ = try await connection.run(audio: audio); XCTFail("Should time out") } catch {}
        XCTAssertTrue(socket.isClosed())
    }
}

private final class MockRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: Any]]
    private var sent: [String] = []
    private var closed = false
    private let transport: StreamingCapability.Transport
    init(events: [[String: Any]], transport: StreamingCapability.Transport = .mistral) { self.events = events; self.transport = transport }
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { lock.lock(); closed = true; lock.unlock() }
    func isClosed() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }
    func sentTypes() -> [String] { lock.lock(); defer { lock.unlock() }; return sent }
    private func record(_ message: URLSessionWebSocketTask.Message) throws {
        lock.lock(); defer { lock.unlock() }
        guard case .string(let text) = message, let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let type = object["type"] as? String else { return }
        sent.append(type)
        if type == "session.update" { events.append(["type": "session.updated"]) }
        if type == "input_audio.append" { events.append(["type": "transcription.text.delta", "text": "Partial"]) }
        if type == "input_audio.end" { events.append(["type": "transcription.done", "text": "Complete."]) }
        if type == "input_audio_buffer.commit" {
            let id = "item-" + String(sent.count)
            events.append(["type": "input_audio_buffer.committed", "item_id": id])
            events.append(["type": "conversation.item.input_audio_transcription.completed", "item_id": id, "transcript": "Complete."])
        }
        if type == "CloseStream" {
            events.append(["type": "Results", "start": 0.0, "is_final": true, "channel": ["alternatives": [["transcript": "Complete."]]]])
            events.append(["type": "Metadata"])
        }
        if type == "Terminate" {
            events.append(["type": "Turn", "turn_order": 0, "transcript": "Complete.", "end_of_turn": true])
            events.append(["type": "Termination"])
        }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try record(message) }
    private func next() throws -> URLSessionWebSocketTask.Message? {
        lock.lock(); defer { lock.unlock() }
        if closed { throw URLError(.cancelled) }
        guard !events.isEmpty else { return nil }
        return .data(try JSONSerialization.data(withJSONObject: events.removeFirst()))
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        while true { if let event = try next() { return event }; try await Task.sleep(nanoseconds: 1_000_000) }
    }
}
