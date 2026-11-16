import XCTest
@testable import OpenScribeContext

final class ContextLibraryTests: XCTestCase {
    private var fixture: FixtureProfile!

    override func setUpWithError() throws { fixture = try FixtureProfile() }
    override func tearDown() { fixture.remove() }

    private func library() -> ContextLibrary { ContextLibrary.load(root: fixture.root) }

    func testLoadsNotesAndMeetingsLeniently() throws {
        let library = library()
        XCTAssertEqual(Set(library.documents.map(\.id)), [
            FixtureProfile.dayNoteID, FixtureProfile.manualNoteID, FixtureProfile.legacyNoteID, FixtureProfile.oldNoteID,
            FixtureProfile.planningMeetingID, FixtureProfile.retroMeetingID,
        ])
        // Corrupt meeting.json and the id/folder mismatch are reported, not fatal.
        XCTAssertEqual(library.warnings.count, 2, "\(library.warnings)")
        XCTAssertEqual(library.documents.first?.id, FixtureProfile.planningMeetingID, "newest first by createdAt")
        XCTAssertEqual(library.meetingInfo[FixtureProfile.retroMeetingID]?.status, "interrupted")
    }

    func testDayNoteBecomesTimeline() throws {
        let note = try XCTUnwrap(library().document(id: FixtureProfile.dayNoteID))
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.title, "November 16, 2026")
        XCTAssertEqual(note.createdAt.timeIntervalSince1970, fixture.ago(hours: 5).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(note.updatedAt.timeIntervalSince1970, fixture.ago(hours: 2).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(note.durationSeconds, 42.5)
        XCTAssertTrue(note.body.contains("· Slack\n\nCall the café about the Zürich offsite"), note.body)
        XCTAssertTrue(note.body.contains("· Screenshot\n\n> Text in screenshot: Invoice number 4471 from Acme Widgets"), note.body)
        XCTAssertTrue(note.body.contains("Planning sync (meeting id: \(FixtureProfile.planningMeetingID))"), note.body)
        XCTAssertTrue(note.body.contains("Draft the quarterly budget"))
        XCTAssertFalse(note.body.contains("This entry was replaced"), "superseded entries are hidden")
        XCTAssertNil(note.summary)
        XCTAssertNil(note.transcript)
        XCTAssertFalse(note.deleted)
    }

    func testPlainNotesUseDisplayTextAndTitle() throws {
        let library = library()
        let manual = try XCTUnwrap(library.document(id: FixtureProfile.manualNoteID))
        XCTAssertEqual(manual.title, "Hiring plan")
        XCTAssertEqual(manual.body, "Hire two backend engineers.\nInterview loop owner: Priya.")
        XCTAssertEqual(manual.tags, ["hiring", "team"])
        let legacy = try XCTUnwrap(library.document(id: FixtureProfile.legacyNoteID.lowercased()))
        XCTAssertEqual(legacy.title, "remember to renew the passport")
        XCTAssertEqual(legacy.body, "remember to renew the passport")
    }

    func testMeetingNormalizationMirrorsApp() throws {
        let meeting = try XCTUnwrap(library().document(id: FixtureProfile.planningMeetingID))
        XCTAssertEqual(meeting.kind, .meeting)
        XCTAssertEqual(meeting.title, "Planning sync")
        XCTAssertEqual(meeting.durationSeconds, 1_830)
        XCTAssertEqual(meeting.body, "Ask about **headcount**.")
        XCTAssertEqual(meeting.createdAt.timeIntervalSince1970, fixture.ago(hours: 3).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(meeting.updatedAt.timeIntervalSince1970, fixture.ago(hours: 2.5).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(meeting.actionItems, ["Send the revised budget to finance", "Book the Zürich offsite venue"])
        XCTAssertEqual(meeting.summary, """
        ## Summary

        - Reviewed the product roadmap and launch timing. [00:00]

        ## Decisions

        - Launch moves to March. [00:05]

        ## Action items

        - Send the revised budget to finance [00:11]
        - Book the Zürich offsite venue [00:40]
        """)
        // Contiguous microphone segments merge; the system track stays separate; blank segments drop.
        XCTAssertEqual(meeting.transcript, """
        [00:00] Me
        Let's review the roadmap. Budget approval is the blocker.

        [00:05] Others
        Agreed, the launch date moves to March.

        [00:40] Me
        Next topic: hiring.
        """)
    }

    func testPassageGroupingLimits() {
        let segments = (0..<12).map { StoredSegment(id: String(format: "m/microphone/%04d.wav", $0), track: "microphone",
                                                     start: Double($0 * 10), duration: 10, text: "part \($0)") }
        let passages = ContextNormalizer.passages(segments)
        // A passage stops growing once it spans 90 s.
        XCTAssertEqual(passages.map(\.start), [0, 90])
        XCTAssertEqual(passages[0].text, (0..<9).map { "part \($0)" }.joined(separator: " "))
    }

    func testContextDocumentEncodesISODatesAndExplicitNulls() throws {
        let document = ContextDocument(id: "x", kind: .note, title: "T", createdAt: Date(timeIntervalSince1970: 0),
                                       updatedAt: Date(timeIntervalSince1970: 1.5), body: "b")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        XCTAssertEqual(object["createdAt"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(object["updatedAt"] as? String, "1970-01-01T00:00:01.500Z")
        XCTAssertTrue(object["summary"] is NSNull)
        XCTAssertTrue(object["transcript"] is NSNull)
        XCTAssertEqual(object["deleted"] as? Bool, false)
        XCTAssertEqual(Set(object.keys), ["id", "kind", "title", "createdAt", "updatedAt", "deleted", "body", "summary",
                                          "transcript", "actionItems", "durationSeconds", "tags"])
        let decoded = try JSONDecoder().decode(ContextDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
    }

    func testMissingProfileIsEmpty() {
        let library = ContextLibrary.load(root: fixture.root.appendingPathComponent("nope"))
        XCTAssertTrue(library.documents.isEmpty)
        XCTAssertTrue(library.warnings.isEmpty)
    }

    func testDataDirOverride() {
        XCTAssertEqual(ContextLibrary.defaultRoot(environment: ["OPENSCRIBE_DATA_DIR": "/tmp/profile"]).path, "/tmp/profile")
        XCTAssertTrue(ContextLibrary.defaultRoot(environment: [:]).path.hasSuffix("Application Support/WhisperFlow"))
    }

    func testCacheReloadsChangedFiles() throws {
        let cache = ContextLibraryCache(root: fixture.root)
        let first = cache.snapshot()
        XCTAssertNil(first.library.document(id: "66666666-6666-6666-6666-666666666666"))
        XCTAssertEqual(cache.snapshot().library.documents, first.library.documents)

        var notes = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.notesURL)) as? [[String: Any]])
        notes.append(["id": "66666666-6666-6666-6666-666666666666", "createdAt": fixture.iso(fixture.now), "title": "Fresh idea",
                      "rawText": "", "cleanedText": "Quantum espresso machine", "duration": 0, "source": "Note"])
        try fixture.writeJSON(notes, to: fixture.notesURL)
        let second = cache.snapshot()
        XCTAssertNotNil(second.library.document(id: "66666666-6666-6666-6666-666666666666"))
        XCTAssertEqual(second.index.search("espresso").first?.id, "66666666-6666-6666-6666-666666666666")

        try FileManager.default.removeItem(at: fixture.meetingURL(FixtureProfile.retroMeetingID).deletingLastPathComponent())
        XCTAssertNil(cache.library().document(id: FixtureProfile.retroMeetingID))
    }
}
