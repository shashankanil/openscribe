import Foundation
import XCTest
@testable import OpenScribe

final class ProviderClientTests: XCTestCase {
    func testTranscribeUploadsEachChunkAndCombinesResults() async throws {
        MockProviderURLProtocol.reset()
        URLProtocol.registerClass(MockProviderURLProtocol.self)
        defer { URLProtocol.unregisterClass(MockProviderURLProtocol.self) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openscribe-provider-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appendingPathComponent("chunk-00000.wav")
        let secondURL = directory.appendingPathComponent("chunk-00001.wav")
        try Data(repeating: 0x01, count: 128).write(to: firstURL)
        try Data(repeating: 0x02, count: 128).write(to: secondURL)

        var settings = AppSettings()
        settings.speechProvider = .openAI
        settings.speechBaseURL = "https://openscribe.test/v1"
        settings.speechModel = "test-model"
        let recording = RecordedAudio(
            chunkURLs: [firstURL, secondURL],
            directoryURL: directory,
            duration: 30
        )

        let chunks = try await ProviderClient().transcribe(
            recording: recording,
            settings: settings,
            apiKey: "test-key"
        )

        XCTAssertEqual(chunks, ["chunk 1", "chunk 2"])
        XCTAssertEqual(MockProviderURLProtocol.requestCount, 2)
        XCTAssertTrue(MockProviderURLProtocol.allRequestsHaveNoInMemoryBody)
    }
}

private final class MockProviderURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    static var allRequestsHaveNoInMemoryBody: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requests.allSatisfy { $0.httpBody == nil }
    }

    static func reset() {
        lock.lock()
        requests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let index = Self.requests.count
        Self.lock.unlock()

        let responseBody = Data("{\"text\":\"chunk \(index)\"}".utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
