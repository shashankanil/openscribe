import Foundation
import XCTest
@testable import OpenScribe

/// Manual probe against a real provider; skipped unless OPENSCRIBE_LIVE_PROBE points at a 24 kHz PCM16 WAV.
final class LiveProviderProbe: XCTestCase {
    func testOpenAILiveStreaming() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let wav = env["OPENSCRIBE_LIVE_PROBE"], let model = env["OPENSCRIBE_LIVE_MODEL"] else { throw XCTSkip("manual probe") }
        var settings = AppSettings()
        settings.speechProvider = .openAI
        settings.speechBaseURL = "https://api.openai.com/v1"
        settings.speechModel = model
        if let vocabulary = env["OPENSCRIBE_VOCAB"] { settings.customVocabulary = vocabulary.components(separatedBy: ",") }
        let key = try XCTUnwrap(CredentialStore.read(for: .speech, settings: settings))
        let capability = try XCTUnwrap(StreamingCapability.resolve(settings))
        let pcm = try Data(contentsOf: URL(fileURLWithPath: wav)).dropFirst(44)
        let (stream, input) = AsyncThrowingStream<Data, Error>.makeStream()
        let started = Date()
        let firstPartial = LockedDate()
        let session = RealtimeTranscription(capability: capability, apiKey: key) { text in
            if !text.isEmpty { firstPartial.setOnce(Date()) }
        }
        let result = Task { try await session.run(audio: stream) }
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let end = min(offset + 4800, pcm.endIndex)
            input.yield(Data(pcm[offset..<end]))
            offset = end
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let audioEnded = Date()
        input.finish()
        let text = try await result.value
        let done = Date()
        print("PROBE model=\(model) text=\(text)")
        print(String(format: "PROBE audio=%.2fs firstWords=%.2fs afterStart finalAfterStop=%.2fs",
                     audioEnded.timeIntervalSince(started), (firstPartial.value ?? done).timeIntervalSince(started),
                     done.timeIntervalSince(audioEnded)))
    }
}

extension LiveProviderProbe {
    func testOpenAIHandshake() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENSCRIBE_LIVE_PROBE"] != nil, let model = env["OPENSCRIBE_LIVE_MODEL"] else { throw XCTSkip("manual probe") }
        var settings = AppSettings()
        settings.speechProvider = .openAI
        settings.speechBaseURL = "https://api.openai.com/v1"
        settings.speechModel = model
        let key = try XCTUnwrap(CredentialStore.read(for: .speech, settings: settings))
        let socket = URLSession.shared.webSocketTask(with: try XCTUnwrap(StreamingCapability.resolve(settings)).request(apiKey: key))
        socket.resume()
        func next() async throws -> String {
            switch try await socket.receive() { case .string(let s): return s; case .data(let d): return String(decoding: d, as: UTF8.self); @unknown default: return "?" }
        }
        print("HS1", String(try await next().prefix(600)))
        let update = #"{"type":"session.update","session":{"type":"transcription","audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"transcription":{"model":"\#(model)"},"turn_detection":null}}}}"#
        try await socket.send(.string(update))
        print("HS2", String(try await next().prefix(900)))
        socket.cancel(with: .goingAway, reason: nil)
    }
}

extension LiveProviderProbe {
    func testCurrentFileProviderLatency() async throws {
        guard let wav = ProcessInfo.processInfo.environment["OPENSCRIBE_FILE_PROBE"] else { throw XCTSkip("manual probe") }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WhisperFlow")
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
        if let vocabulary = ProcessInfo.processInfo.environment["OPENSCRIBE_VOCAB"] { settings.customVocabulary = vocabulary.components(separatedBy: ",") }
        let key = try XCTUnwrap(CredentialStore.read(for: .speech, settings: settings))
        for run in 1...3 {
            let started = Date()
            let text = try await ProviderClient().transcribeReliably(audioFile: URL(fileURLWithPath: wav), settings: settings, apiKey: key)
            print(String(format: "FILE run=%d %@ %.2fs %@", run, settings.speechModel, Date().timeIntervalSince(started), text))
        }
    }
}

final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value: Date?
    func setOnce(_ date: Date) { lock.lock(); if value == nil { value = date }; lock.unlock() }
}
