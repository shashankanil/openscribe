import AVFoundation
import XCTest
@testable import OpenScribe

@MainActor
final class DictationRecoveryTests: XCTestCase {
    func testJobAndChunkCheckpointsSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-recovery-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationRecoveryStore(root: root)
        var job = DictationJob(settings: AppSettings(), sourceApplication: "Editor", sourceBundleIdentifier: "example.editor")
        try store.save(job)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        for i in 0..<8_000 { buffer.floatChannelData![0][i] = 0.1 }
        let audio = AudioChunkStore(chunkDuration: 1)
        try audio.begin(format: format, directoryURL: store.audioDirectory(job.id))
        audio.append(buffer)
        _ = audio.finish()
        job.transcripts["chunk-00000.wav"] = "Already transcribed"
        try store.save(job)
        let restored = DictationRecoveryStore(root: root)
        XCTAssertEqual(restored.jobs.first?.id, job.id)
        XCTAssertEqual(restored.jobs.first?.transcripts["chunk-00000.wav"], "Already transcribed")
        XCTAssertEqual(try restored.recording(job.id).duration, 1, accuracy: 0.01)
        try restored.remove(job.id)
        XCTAssertTrue(DictationRecoveryStore(root: root).jobs.isEmpty)
    }

    func testStableNoteIDPreventsDuplicateRecoveryResults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-note-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(rootURL: root)
        let id = UUID()
        store.addNote(id: id, rawText: "Hello", cleanedText: "Hello.", duration: 1)
        store.addNote(id: id, rawText: "Hello", cleanedText: "Hello.", duration: 1)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertTrue(store.hasPersistedNote(id))
        XCTAssertEqual(AppStore(rootURL: root).notes.count, 1)
    }
}
