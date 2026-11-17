import XCTest
@testable import OpenScribe
import OpenScribeContext

/// Writes a profile with the app's real stores and models, then reads it back with the
/// dependency-free `OpenScribeContext` decoder used by `openscribe-mcp`. Guards against format drift.
@MainActor
final class ContextFormatTests: XCTestCase {
    func testContextLibraryReadsFilesWrittenByTheApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-format-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Notes: a dictation (joins a day note), a screenshot capture, and a written note with tags.
        let store = AppStore(rootURL: root)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let day = store.addNote(createdAt: start, rawText: "ship it", cleanedText: "Ship the Zürich build on Friday.", duration: 4.5,
                                sourceApplication: "Slack")
        var screenshot = NoteCapture(id: UUID(), createdAt: start.addingTimeInterval(60), title: "", rawText: "", text: "",
                                     duration: 0, sourceApplication: "Safari", sourceBundleIdentifier: nil, kind: .screenshot)
        screenshot.attachment = "shot.png"
        screenshot.recognizedText = "Quarterly revenue dashboard"
        store.addCapture(screenshot)
        var written = store.addManualNote()
        written.title = "Launch checklist"
        written.cleanedText = "Write release notes\nNotify support"
        written.tags = ["launch"]
        written.createdAt = start.addingTimeInterval(-3_600)
        XCTAssertTrue(store.updateNote(written))
        store.flush()

        // Meeting: segments on both tracks, a summary with sources, and user notes.
        let meetings = MeetingStore(root: root.appendingPathComponent("Meetings"))
        var record = MeetingRecord(title: "Design review", settings: AppSettings())
        record.createdAt = start.addingTimeInterval(7_200)
        record.duration = 905
        record.status = .ready
        record.userNotes = "Follow up with design."
        record.segments = [
            MeetingSegment(id: "a/microphone/0001.wav", track: "microphone", start: 0, duration: 10, text: "Welcome everyone."),
            MeetingSegment(id: "a/microphone/0002.wav", track: "microphone", start: 11, duration: 10, text: "First, the onboarding flow."),
            MeetingSegment(id: "a/system/0001.wav", track: "system", start: 4, duration: 10, text: "Thanks for having us."),
            MeetingSegment(id: "a/microphone/0003.wav", track: "microphone", start: 120, duration: 10, text: "Last item: pricing."),
        ]
        record.summary = MeetingSummary(
            overview: [.init(text: "Reviewed onboarding and pricing.", sources: ["a/microphone/0002.wav"])],
            decisions: [],
            actions: [.init(text: "Prototype the new pricing page", sources: ["a/microphone/0003.wav"])])
        try meetings.save(record)

        let library = ContextLibrary.load(root: root)
        XCTAssertTrue(library.warnings.isEmpty, "\(library.warnings)")

        let dayDocument = try XCTUnwrap(library.document(id: day.id.uuidString))
        let storedDay = try XCTUnwrap(store.note(withID: day.id))
        XCTAssertEqual(dayDocument.kind, .note)
        XCTAssertEqual(dayDocument.title, storedDay.displayTitle)
        XCTAssertEqual(dayDocument.createdAt.timeIntervalSince1970, storedDay.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(dayDocument.updatedAt.timeIntervalSince1970, storedDay.lastCapturedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(dayDocument.durationSeconds, storedDay.duration)
        XCTAssertTrue(dayDocument.body.contains("· Slack\n\nShip the Zürich build on Friday."), dayDocument.body)
        XCTAssertTrue(dayDocument.body.contains("· Safari · Screenshot\n\n> Text in screenshot: Quarterly revenue dashboard"), dayDocument.body)

        let writtenDocument = try XCTUnwrap(library.document(id: written.id.uuidString))
        XCTAssertEqual(writtenDocument.title, "Launch checklist")
        XCTAssertEqual(writtenDocument.body, written.displayText)
        XCTAssertEqual(writtenDocument.tags, ["launch"])

        let meeting = try XCTUnwrap(library.document(id: record.id.uuidString))
        XCTAssertEqual(meeting.kind, .meeting)
        XCTAssertEqual(meeting.title, record.title)
        XCTAssertEqual(meeting.createdAt.timeIntervalSinceReferenceDate, record.createdAt.timeIntervalSinceReferenceDate, accuracy: 0.001)
        XCTAssertEqual(meeting.durationSeconds, 905)
        XCTAssertEqual(meeting.body, "Follow up with design.")
        XCTAssertEqual(meeting.transcript, record.transcript, "transcript grouping must match MeetingTranscript.passages")
        XCTAssertEqual(meeting.actionItems, ["Prototype the new pricing page"])
        // The summary sections match the app's markdown export.
        let summary = try XCTUnwrap(meeting.summary)
        XCTAssertTrue(record.markdown.contains(summary), "\(summary)\n---\n\(record.markdown)")
        XCTAssertTrue(summary.contains("- Prototype the new pricing page [02:00]"))
        XCTAssertEqual(library.meetingInfo[meeting.id]?.status, "ready")

        let hits = SearchIndex(library: library).search("zurich")
        XCTAssertEqual(hits.first?.id, day.id.uuidString)
    }
}
