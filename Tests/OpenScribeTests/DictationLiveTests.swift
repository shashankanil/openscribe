import AVFoundation
import XCTest
@testable import OpenScribe

@MainActor
final class DictationLiveTests: XCTestCase {
    func testClosedChunksAreSavedDuringCaptureAndNotUploadedTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationRecoveryStore(root: root)
        let job = DictationJob(settings: AppSettings())
        try store.save(job)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000))
        buffer.frameLength = 4_000
        for i in 0..<4_000 { buffer.floatChannelData![0][i] = 0.1 }
        let audio = AudioChunkStore(chunkDuration: 1)
        try audio.begin(format: format, directoryURL: store.audioDirectory(job.id))
        var uploads = 0
        let worker = DictationLiveTranscriber(store: store) { _, _ in uploads += 1; return "Section \\(uploads)" }
        audio.append(buffer)
        let pending = try await worker.processNext(job.id)
        XCTAssertFalse(pending)
        audio.append(buffer)
        let completed = try await worker.processNext(job.id)
        XCTAssertTrue(completed)
        XCTAssertEqual(DictationRecoveryStore(root: root).jobs.first?.transcripts.count, 1)
        XCTAssertEqual(uploads, 1)
        let repeated = try await worker.processNext(job.id)
        XCTAssertFalse(repeated)
        audio.append(buffer)
        _ = audio.finish()
        let tail = try await worker.processNext(job.id)
        XCTAssertTrue(tail)
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(store.jobs.first?.transcripts.count, 2)
    }

    func testMultipleChunksAndRetryProduceOneSessionHistoryEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = DictationRecoveryStore(root: root.appendingPathComponent("recovery"))
        let history = AppStore(rootURL: root.appendingPathComponent("history"))
        let job = DictationJob(settings: AppSettings())
        try recovery.save(job)
        try FileManager.default.createDirectory(at: recovery.audioDirectory(job.id), withIntermediateDirectories: true)
        for index in 0..<3 {
            let name = String(format: "chunk-%05d.wav", index)
            let file = recovery.audioDirectory(job.id).appendingPathComponent(name)
            try Data().write(to: file)
            try JSONEncoder().encode(AudioChunkDescriptor(filename: name, start: Double(index * 15), duration: 15))
                .write(to: file.appendingPathExtension("json"))
        }
        let worker = DictationLiveTranscriber(store: recovery) { url, _ in url.deletingPathExtension().lastPathComponent }
        for _ in 0..<3 {
            let progressed = try await worker.processNext(job.id)
            XCTAssertTrue(progressed)
            XCTAssertTrue(history.notes.isEmpty, "Internal chunks must not enter history")
        }
        let completed = try XCTUnwrap(recovery.jobs.first)
        let text = completed.transcripts.keys.sorted().compactMap { completed.transcripts[$0] }.joined(separator: " ")
        let first = history.addNote(id: job.id, createdAt: job.createdAt, rawText: text, cleanedText: text, duration: 45)
        history.togglePin(first)
        _ = history.addNote(id: job.id, createdAt: Date(), rawText: text, cleanedText: text, duration: 45)
        let restored = AppStore(rootURL: root.appendingPathComponent("history"))
        XCTAssertEqual(restored.notes.count, 1)
        XCTAssertEqual(restored.notes.first?.id, job.id)
        XCTAssertEqual(restored.notes.first?.duration, 45)
        XCTAssertTrue(restored.notes.first?.isPinned == true)
        XCTAssertEqual(restored.notes.first?.createdAt.timeIntervalSince1970 ?? 0, job.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(restored.notes.first?.rawText, "chunk-00000 chunk-00001 chunk-00002")
    }

    func testLateResponseCannotRecreateDiscardedJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationRecoveryStore(root: root)
        let job = DictationJob(settings: AppSettings())
        try store.save(job)
        try FileManager.default.createDirectory(at: store.audioDirectory(job.id), withIntermediateDirectories: true)
        let url = store.audioDirectory(job.id).appendingPathComponent("chunk-00000.wav")
        try Data().write(to: url)
        try JSONEncoder().encode(AudioChunkDescriptor(filename: url.lastPathComponent, start: 0, duration: 1))
            .write(to: url.appendingPathExtension("json"))
        let worker = DictationLiveTranscriber(store: store) { _, _ in
            try store.remove(job.id)
            return "Late provider response"
        }
        let result = try await worker.processNext(job.id)
        XCTAssertFalse(result)
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(job.id).path))
    }
}
