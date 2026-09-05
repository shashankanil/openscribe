import AVFoundation
import Foundation
import XCTest
@testable import OpenScribe

final class AudioChunkStoreTests: XCTestCase {
    func testChunkStoreRotatesRecordedAudioIntoBoundedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openscribe-chunks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let store = AudioChunkStore(chunkDuration: 1)
        try store.begin(format: format, directoryURL: directory)

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<8_000 {
                channel[index] = 0.1
            }
        }

        store.append(buffer)
        store.append(buffer)
        store.append(buffer)
        let result = store.finish()

        store.cancel()
        // Finishing transfers file ownership to the processing task.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(result.hadWriteError)
        XCTAssertEqual(result.chunkURLs.count, 3)
        for url in result.chunkURLs {
            let file = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(file.length, 0)
            XCTAssertLessThanOrEqual(file.length, 8_000)
        }
    }

    func testCancelRemovesTemporaryChunkDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openscribe-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let store = AudioChunkStore()
        try store.begin(format: format, directoryURL: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        store.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
