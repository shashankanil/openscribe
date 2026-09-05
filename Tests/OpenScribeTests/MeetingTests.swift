import AVFoundation
import XCTest
@testable import OpenScribe

@MainActor
final class MeetingTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("meeting-tests-\(UUID())") }

    private func addAudio(store: MeetingStore, record: MeetingRecord, count: Int = 2) throws -> [MeetingSegment] {
        let directory = store.directory(for: record.id).appendingPathComponent("part/microphone")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        for i in 0..<8_000 { buffer.floatChannelData![0][i] = 0.1 }
        let chunks = AudioChunkStore(chunkDuration: 1)
        try chunks.begin(format: format, directoryURL: directory)
        for i in 0..<count { chunks.append(buffer, at: Double(i * 3)) }
        _ = chunks.finish()
        return try store.audioChunks(for: record.id)
    }

    func testRestartRecoversTimelineAndCompletedSegments() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var record = MeetingRecord(title: "Planning", settings: AppSettings())
        try store.save(record)
        let chunks = try addAudio(store: store, record: record)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.map(\.start), [0, 3])
        record.segments = [try XCTUnwrap(chunks.first)]
        record.segments[0].text = "Already processed"
        record.status = .transcribing
        try store.save(record)
        let restored = MeetingStore(root: root)
        XCTAssertEqual(restored.record(record.id)?.status, .interrupted)
        XCTAssertEqual(restored.record(record.id)?.segments.first?.text, "Already processed")
        XCTAssertEqual(try restored.audioChunks(for: record.id).count, 2)
    }

    func testLiveTranscriptionWaitsForClosedWAVAndCheckpointsBeforeStop() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var settings = AppSettings()
        settings.speechProvider = .openAI
        settings.speechBaseURL = "https://meeting.test/v1"
        let record = MeetingRecord(title: "Live meeting", settings: settings)
        try store.save(record)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000))
        buffer.frameLength = 4_000
        for i in 0..<4_000 { buffer.floatChannelData![0][i] = 0.1 }
        let audio = AudioChunkStore(chunkDuration: 1)
        try audio.begin(format: format, directoryURL: store.directory(for: record.id).appendingPathComponent("part/microphone"))
        MeetingURLProtocol.uploads = 0
        URLProtocol.registerClass(MeetingURLProtocol.self)
        defer { URLProtocol.unregisterClass(MeetingURLProtocol.self) }
        let controller = MeetingController(store: store, speechKey: { "test" }, languageKey: { "test" })
        audio.append(buffer)
        let beforeClose = try await controller.transcribeNextCompletedChunk(record.id)
        XCTAssertFalse(beforeClose)
        XCTAssertEqual(MeetingURLProtocol.uploads, 0)
        audio.append(buffer)
        let afterClose = try await controller.transcribeNextCompletedChunk(record.id)
        XCTAssertTrue(afterClose)
        XCTAssertEqual(store.record(record.id)?.status, .recording)
        XCTAssertEqual(MeetingStore(root: root).record(record.id)?.segments.count, 1)
        audio.append(buffer)
        let pending = try await controller.transcribeNextCompletedChunk(record.id)
        XCTAssertFalse(pending)
        _ = audio.finish()
        controller.process(record.id, summarizeResult: false)
        await controller.waitUntilIdle()
        XCTAssertEqual(store.record(record.id)?.segments.count, 2)
        XCTAssertEqual(store.record(record.id)?.status, .ready)
        XCTAssertEqual(MeetingURLProtocol.uploads, 2, "Stop must upload only the final partial chunk, not earlier completed chunks")
        XCTAssertNil(store.record(record.id)?.summary)
    }

    func testFailedSectionDoesNotLoseLaterTextAndRetrySkipsCompletedSections() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var settings = AppSettings()
        settings.speechProvider = .openAI
        settings.speechBaseURL = "https://meeting.test/v1"
        let record = MeetingRecord(title: "Unreliable connection", settings: settings)
        try store.save(record)
        _ = try addAudio(store: store, record: record)
        MeetingURLProtocol.uploads = 0
        MeetingURLProtocol.failuresRemaining = 3
        URLProtocol.registerClass(MeetingURLProtocol.self)
        defer { URLProtocol.unregisterClass(MeetingURLProtocol.self); MeetingURLProtocol.failuresRemaining = 0 }
        let controller = MeetingController(store: store, speechKey: { "test" }, languageKey: { "test" })
        controller.process(record.id, summarizeResult: false)
        await controller.waitUntilIdle()
        XCTAssertEqual(store.record(record.id)?.status, .failed)
        XCTAssertEqual(store.record(record.id)?.segments.count, 1, "A failed section must not prevent later sections being saved")
        XCTAssertEqual(MeetingURLProtocol.uploads, 4)
        controller.process(record.id, summarizeResult: false)
        await controller.waitUntilIdle()
        XCTAssertEqual(store.record(record.id)?.status, .ready)
        XCTAssertEqual(store.record(record.id)?.segments.count, 2)
        XCTAssertEqual(MeetingURLProtocol.uploads, 5, "Retry should upload only the missing section")
    }

    func testCorruptManifestIsPreservedAndReported() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("meeting.json")
        let invalid = Data("bad json".utf8)
        try invalid.write(to: url)
        let store = MeetingStore(root: root)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    func testAudioPathCannotEscapeMeeting() {
        let store = MeetingStore(root: root())
        defer { try? FileManager.default.removeItem(at: store.root) }
        XCTAssertNil(store.audioURL(meetingID: UUID(), relativePath: "../../private.wav"))
        XCTAssertNil(store.audioURL(meetingID: UUID(), relativePath: "meeting.json"))
    }

    func testSummaryRejectsUncitedAndUnknownSources() throws {
        let valid = MeetingSummary(overview: [.init(text: "Ship Friday", sources: ["a"])], decisions: [], actions: [])
        XCTAssertNoThrow(try valid.validated(segmentIDs: ["a"]))
        XCTAssertThrowsError(try valid.validated(segmentIDs: ["b"]))
        let uncited = MeetingSummary(overview: [], decisions: [], actions: [.init(text: "Invented", sources: [])])
        XCTAssertThrowsError(try uncited.validated(segmentIDs: ["a"]))
    }

    func testProcessingResumesOnlyMissingChunksAndExportsEvidence() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var settings = AppSettings()
        settings.speechProvider = .openAI
        settings.speechBaseURL = "https://meeting.test/v1"
        settings.languageModelProvider = .openAI
        settings.languageModelBaseURL = "https://meeting.test/v1"
        var record = MeetingRecord(title: "Planning", settings: settings)
        try store.save(record)
        let chunks = try addAudio(store: store, record: record)
        record.segments = [try XCTUnwrap(chunks.first)]
        record.segments[0].text = "We will ship Friday."
        record.status = .failed
        try store.save(record)
        MeetingURLProtocol.summary = MeetingSummary(overview: [.init(text: "Release planning", sources: [chunks[0].id])], decisions: [.init(text: "Ship Friday", sources: [chunks[0].id])], actions: [])
        MeetingURLProtocol.uploads = 0
        URLProtocol.registerClass(MeetingURLProtocol.self)
        defer { URLProtocol.unregisterClass(MeetingURLProtocol.self) }
        let controller = MeetingController(store: store, speechKey: { "test" }, languageKey: { "test" })
        controller.process(record.id)
        await controller.waitUntilIdle()
        let result = try XCTUnwrap(store.record(record.id))
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(MeetingURLProtocol.uploads, 1)
        XCTAssertTrue(result.markdown.contains("Ship Friday [00:00]"))
        XCTAssertEqual(MeetingStore(root: root).record(record.id)?.status, .ready)
    }
}

private final class MeetingURLProtocol: URLProtocol {
    static var summary = MeetingSummary(overview: [], decisions: [], actions: [])
    static var uploads = 0
    static var failuresRemaining = 0
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "meeting.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        var status = 200
        if request.url?.path.contains("transcriptions") == true {
            Self.uploads += 1
            if Self.failuresRemaining > 0 { Self.failuresRemaining -= 1; status = 503 }
            body = Data("{\"text\":\"Confirmed.\"}".utf8)
        } else {
            let content = String(data: try! JSONEncoder().encode(Self.summary), encoding: .utf8)!
            body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
