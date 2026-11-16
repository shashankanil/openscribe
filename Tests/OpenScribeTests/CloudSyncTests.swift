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

        // A second sync with no changes uploads nothing and stays clean.
        await cloud.syncNow()
        XCTAssertNil(cloud.error)
    }
}
