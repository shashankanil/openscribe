import AVFoundation
import XCTest
import OpenScribeContext
@testable import OpenScribe

final class CloudSyncPlanTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_790_000_000)
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func doc(_ id: String, body: String, kind: ContextDocument.Kind = .note) -> ContextDocument {
        ContextDocument(id: id, kind: kind, title: id, createdAt: created, updatedAt: created, body: body)
    }

    private func library(_ documents: [ContextDocument]) -> ContextLibrary {
        ContextLibrary(root: URL(fileURLWithPath: "/tmp"), documents: documents)
    }

    func testFirstSyncUploadsEverythingStampedNow() {
        let plan = CloudSyncController.plan(library: library([doc("a", body: "one"), doc("b", body: "two")]),
                                            state: .init(server: "s"), now: now)
        let docs = plan.batches.flatMap { $0 }.map(\.document)
        XCTAssertEqual(Set(docs.map(\.id)), ["a", "b"])
        XCTAssertTrue(docs.allSatisfy { $0.updatedAt == now }, "Edits without a new updatedAt must still win on the server")
    }

    func testOnlyChangedDocumentsAndDeletionsAreSent() {
        let a = doc("a", body: "one"), b = doc("b", body: "two"), gone = doc("gone", body: "x", kind: .meeting)
        var state = CloudSyncController.SyncState(server: "s")
        for item in [a, b, gone] {
            state.entries[item.id] = .init(hash: CloudSyncController.fingerprint(item), kind: item.kind.rawValue, createdAt: item.createdAt)
        }
        var edited = b
        edited.body = "two, edited"
        let plan = CloudSyncController.plan(library: library([a, edited]), state: state, now: now)
        let docs = plan.batches.flatMap { $0 }.map(\.document)
        XCTAssertEqual(docs.map(\.id).sorted(), ["b", "gone"])
        let tombstone = try? XCTUnwrap(docs.first { $0.id == "gone" })
        XCTAssertEqual(tombstone?.deleted, true)
        XCTAssertEqual(tombstone?.kind, .meeting)
    }

    func testFingerprintIgnoresUpdatedAt() {
        var a = doc("a", body: "one")
        let before = CloudSyncController.fingerprint(a)
        a.updatedAt = now
        XCTAssertEqual(CloudSyncController.fingerprint(a), before)
        a.title = "Renamed"
        XCTAssertNotEqual(CloudSyncController.fingerprint(a), before)
    }

    func testLargeLibrariesAreBatchedWithinServerLimits() {
        let docs = (0..<400).map { doc("d\($0)", body: String(repeating: "word ", count: 20)) }
        let plan = CloudSyncController.plan(library: library(docs), state: .init(server: "s"), now: now)
        XCTAssertEqual(plan.batches.flatMap { $0 }.count, 400)
        XCTAssertTrue(plan.batches.allSatisfy { $0.count <= 150 })
    }

    func testHugeTranscriptsAreTrimmedToFitOneRow() {
        var meeting = doc("m", body: "", kind: .meeting)
        meeting.transcript = String(repeating: "a", count: 2_000_000)
        let fitted = CloudSyncController.fitted(meeting)
        XCTAssertLessThan(fitted.transcript?.utf8.count ?? 0, 1_600_000)
    }
}

final class CloudMediaTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-media-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func tone(_ name: String, seconds: Double, frequency: Double) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                                              AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(2 * .pi * frequency * Double(i) / 16_000) * 0.3) }
        try file.write(from: buffer)
        return url
    }

    private func attachment(_ kind: ContextAttachment.Kind, _ parts: [ContextAttachment.Part], doc: String = "d1", id: String = "a1") -> ContextAttachment {
        ContextAttachment(id: id, documentID: doc, kind: kind, createdAt: Date(timeIntervalSince1970: 1_790_000_000), parts: parts)
    }

    func testRecordingChunksMixIntoOneCompactFile() async throws {
        let mic1 = try tone("m1.wav", seconds: 2, frequency: 440)
        let mic2 = try tone("m2.wav", seconds: 2, frequency: 660)
        let system = try tone("s1.wav", seconds: 3, frequency: 220)
        let recording = attachment(.recording, [
            .init(url: mic1, track: "microphone", start: 0), .init(url: system, track: "system", start: 0.5),
            .init(url: mic2, track: "microphone", start: 4),
        ])
        let encoded = try await CloudMedia.encode(recording)
        defer { try? FileManager.default.removeItem(at: encoded.url) }
        XCTAssertEqual(encoded.contentType, "audio/mp4")
        let asset = AVURLAsset(url: encoded.url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 6, accuracy: 0.2, "Chunks keep their place on the timeline, with silence in the gap")
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertLessThan(encoded.bytes, 60_000, "About 6 KB a second")
        XCTAssertEqual(encoded.sha256, try CloudMedia.sha256(of: encoded.url))
    }

    func testScreenshotsBecomeBoundedJPEGs() async throws {
        let png = folder.appendingPathComponent("shot.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4000, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        let encoded = try await CloudMedia.encode(attachment(.screenshot, [.init(url: png, track: nil, start: 0)]))
        defer { try? FileManager.default.removeItem(at: encoded.url) }
        XCTAssertEqual(encoded.contentType, "image/jpeg")
        let image = try XCTUnwrap(NSImage(contentsOf: encoded.url)?.representations.first)
        XCTAssertEqual(image.pixelsWide, 2048)
        XCTAssertEqual(image.pixelsHigh, 512)
    }

    func testMediaPlanUploadsChangesAndRemovesWhatWasTurnedOff() throws {
        let png = folder.appendingPathComponent("a.png")
        try Data([1, 2, 3]).write(to: png)
        let wav = try tone("r.wav", seconds: 1, frequency: 300)
        let shot = attachment(.screenshot, [.init(url: png, track: nil, start: 0)], doc: "note", id: "s1")
        let recording = attachment(.recording, [.init(url: wav, track: "microphone", start: 0)], doc: "meeting", id: "recording")
        let unsynced = attachment(.screenshot, [.init(url: png, track: nil, start: 0)], doc: "pending", id: "s2")
        var state = CloudSyncController.SyncState(server: "s")
        let entry = CloudSyncController.SyncState.Entry(hash: "h", kind: "note", createdAt: Date())
        state.entries = ["note": entry, "meeting": entry]
        let library = ["note": [shot], "meeting": [recording], "pending": [unsynced]]

        var work = CloudSyncController.planMedia(library, state: state, screenshots: true, recordings: true)
        XCTAssertEqual(work.uploads.map(\.id), ["s1", "recording"], "Screenshots first; documents the server lacks wait")
        XCTAssertEqual(work.deletions, [])

        state.media = ["note/s1": .init(stamp: shot.sourceStamp, sha256: "x", bytes: 3),
                       "meeting/recording": .init(stamp: recording.sourceStamp, sha256: "y", bytes: 9)]
        work = CloudSyncController.planMedia(library, state: state, screenshots: true, recordings: true)
        XCTAssertEqual(work, .init(uploads: [], deletions: []), "Nothing changed, nothing to do")

        work = CloudSyncController.planMedia(library, state: state, screenshots: true, recordings: false)
        XCTAssertEqual(work.deletions, ["meeting/recording"])

        try Data([1, 2, 3, 4]).write(to: png)
        work = CloudSyncController.planMedia(library, state: state, screenshots: true, recordings: true)
        XCTAssertEqual(work.uploads.map(\.id), ["s1"], "An edited file is sent again")
    }
}

/// Runs the real sync client against a running OpenScribe Cloud (for example `wrangler dev`).
/// Set OPENSCRIBE_CLOUD_E2E_URL and OPENSCRIBE_CLOUD_E2E_TOKEN to enable.
@MainActor
final class CloudSyncLiveTests: XCTestCase {
    func testSyncRoundTripAgainstServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["OPENSCRIBE_CLOUD_E2E_URL"], let token = env["OPENSCRIBE_CLOUD_E2E_TOKEN"] else {
            throw XCTSkip("Set OPENSCRIBE_CLOUD_E2E_URL and OPENSCRIBE_CLOUD_E2E_TOKEN to run against a server")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-cloud-e2e-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppController(rootURL: root)
        app.updateSettings { $0.cloudServerURL = server; $0.cloudSyncEnabled = true }
        app.store.addNote(rawText: "Quarterly planning with the Zurich team", cleanedText: "Quarterly planning with the Zurich team.",
                          duration: 4, sourceApplication: "Notes")
        // A screenshot in today's note and a finished meeting with audio on disk.
        let shotName = "Screenshot-\(UUID().uuidString).png"
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try FileManager.default.createDirectory(at: app.store.attachmentsURL, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: app.store.attachmentURL(shotName))
        _ = app.store.addCapture(NoteCapture(id: UUID(), createdAt: Date(), title: "", rawText: "", text: "", duration: 0,
                                             sourceApplication: "Figma", sourceBundleIdentifier: nil, kind: .screenshot,
                                             attachment: shotName, meetingID: nil))
        var meeting = MeetingRecord(title: "Zurich sync", settings: AppSettings())
        meeting.status = .ready
        meeting.duration = 2
        let meetingFolder = root.appendingPathComponent("Meetings/\(meeting.id.uuidString)")
        let chunk = meetingFolder.appendingPathComponent("S1/microphone/chunk-00000.wav")
        try FileManager.default.createDirectory(at: chunk.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        for i in 0..<32_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) / 8) * 0.3) }
        try AVAudioFile(forWriting: chunk, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1]).write(from: buffer)
        try JSONEncoder().encode(meeting).write(to: meetingFolder.appendingPathComponent("meeting.json"))
        let cloud = app.cloud
        try CredentialStore.save(token, account: "openscribe-cloud:\(URL(string: server)!.host!)", rootURL: root)
        cloud.boot(app: app)
        await cloud.syncNow()
        XCTAssertNil(cloud.error)
        XCTAssertNotNil(cloud.lastSync)

        // The server can now find it.
        var request = URLRequest(url: URL(string: server)!.appendingPathComponent("api/v1/me"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let me = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertGreaterThanOrEqual(me?["documentCount"] as? Int ?? 0, 1)

        XCTAssertEqual(me?["attachmentCount"] as? Int, 2, "The screenshot and the recording are stored")

        var listRequest = URLRequest(url: URL(string: server)!.appendingPathComponent("api/v1/attachments"))
        listRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let listed = try JSONSerialization.jsonObject(with: try await URLSession.shared.data(for: listRequest).0) as? [String: Any]
        let attachments = listed?["attachments"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(attachments.compactMap { $0["contentType"] as? String }), ["image/jpeg", "audio/mp4"])

        // A second sync with no changes uploads nothing and stays clean.
        await cloud.syncNow()
        XCTAssertNil(cloud.error)

        // Turning recordings off removes them from the cloud.
        app.updateSettings { $0.cloudSyncRecordings = false }
        await cloud.syncNow()
        let after = try JSONSerialization.jsonObject(with: try await URLSession.shared.data(for: request).0) as? [String: Any]
        XCTAssertEqual(after?["attachmentCount"] as? Int, 1)
    }
}
