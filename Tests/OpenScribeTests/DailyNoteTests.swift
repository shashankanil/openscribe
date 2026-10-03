import Foundation
import XCTest
@testable import OpenScribe

@MainActor
final class DailyNoteTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-daily-\(UUID())")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var morning: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
    }

    func testSameDayCapturesShareAnEditableNoteAndKeepTheirMetadata() throws {
        let store = AppStore(rootURL: root)
        let firstID = UUID(), secondID = UUID()
        var note = store.addNote(id: firstID, createdAt: morning, rawText: "um first", cleanedText: "First.", duration: 2,
                                 sourceApplication: "Mail", sourceBundleIdentifier: "com.apple.mail")
        note.editedText = "My edited thought."
        note.title = "Today's work"
        note.isPinned = true
        store.updateNote(note)
        store.addNote(id: secondID, createdAt: morning.addingTimeInterval(3600), rawText: "second", cleanedText: "Second.", duration: 3,
                      sourceApplication: "Safari", sourceBundleIdentifier: "com.apple.Safari")

        let restored = AppStore(rootURL: root)
        let daily = try XCTUnwrap(restored.notes.first)
        XCTAssertEqual(restored.notes.count, 1)
        XCTAssertEqual(daily.id, firstID)
        XCTAssertEqual(daily.title, "Today's work")
        XCTAssertEqual(daily.displayText, "My edited thought.\n\nSecond.")
        XCTAssertEqual(daily.rawText, "um first\n\nsecond")
        XCTAssertEqual(daily.duration, 5)
        XCTAssertTrue(daily.isPinned)
        XCTAssertEqual(daily.captures?.map(\.id), [firstID, secondID])
        XCTAssertEqual(daily.captures?.map(\.sourceApplication), ["Mail", "Safari"])
        XCTAssertEqual(daily.captures?.last?.createdAt, morning.addingTimeInterval(3600))
        XCTAssertEqual(restored.latestText, "Second.")
        XCTAssertTrue(restored.hasPersistedNote(secondID))
        // Retrying the most recent capture must not append its transcript again.
        restored.addNote(id: secondID, rawText: "second", cleanedText: "Second.", duration: 3)
        XCTAssertEqual(restored.notes.first?.captures?.count, 2)
    }

    func testLocalMidnightStartsANewNoteAndManualNotesStaySeparate() throws {
        let store = AppStore(rootURL: root)
        let midnight = Calendar.current.startOfDay(for: morning)
        store.addNote(createdAt: midnight.addingTimeInterval(-1), rawText: "Yesterday", cleanedText: "", duration: 1)
        store.addNote(createdAt: midnight, rawText: "Today", cleanedText: "", duration: 1)
        var manual = store.addManualNote()
        manual.editedText = "A separate written note"
        store.updateNote(manual)
        XCTAssertEqual(store.notes.count, 3)
        XCTAssertEqual(store.notes.filter(\.isDailyNote).count, 2)
        XCTAssertEqual(AppStore(rootURL: root).notes.filter { $0.source == "Note" }.first?.id, manual.id)
    }

    func testLegacyGroupingPreservesEditsTitlesPinsTagsAndAnExactBackup() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var first = VoiceNote(createdAt: morning, title: "Custom old title", rawText: "original first", cleanedText: "First.", duration: 1)
        first.editedText = "Edited first."
        first.tags = ["work"]
        var second = VoiceNote(createdAt: morning.addingTimeInterval(60), title: "Cleared note", rawText: "original second", cleanedText: "Second.", duration: 2)
        second.editedText = ""
        second.isPinned = true
        second.tags = ["personal"]
        let manual = VoiceNote(title: "Written", rawText: "", cleanedText: "Written note", duration: 0, source: "Note")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode([second, manual, first])
        try original.write(to: root.appendingPathComponent("notes.json"))
        let store = AppStore(rootURL: root)
        let daily = try XCTUnwrap(store.notes.first { $0.isDailyNote })
        XCTAssertEqual(store.notes.count, 2)
        XCTAssertEqual(daily.displayText, "Edited first.")
        XCTAssertEqual(daily.captures?.map(\.title), ["Custom old title", "Cleared note"])
        XCTAssertEqual(daily.captures?.last?.text, "")
        XCTAssertEqual(Set(daily.tags), ["work", "personal"])
        XCTAssertTrue(daily.isPinned)
        XCTAssertTrue(store.hasPersistedNote(first.id))
        XCTAssertTrue(store.hasPersistedNote(second.id))
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("notes-before-daily-grouping-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), original)
        let restored = AppStore(rootURL: root)
        XCTAssertEqual(restored.notes, store.notes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("notes-before-daily-grouping-") }.count, 1)
    }

    func testClearedDailyTextDoesNotReturnWhenAnotherCaptureArrives() {
        let store = AppStore(rootURL: root)
        var note = store.addNote(createdAt: morning, rawText: "Old words", cleanedText: "", duration: 1)
        note.editedText = ""
        store.updateNote(note)
        store.addNote(createdAt: morning.addingTimeInterval(60), rawText: "New words", cleanedText: "", duration: 1)
        XCTAssertEqual(store.notes.first?.displayText, "New words")
        XCTAssertEqual(store.notes.first?.rawText, "Old words\n\nNew words")
    }

    func testPendingEditorSaveCannotOverwriteANewCapture() throws {
        let store = AppStore(rootURL: root)
        var pending = store.addNote(createdAt: morning, rawText: "First", cleanedText: "", duration: 1)
        pending.editedText = "Unsaved editing"
        let nextID = UUID()
        store.addNote(id: nextID, createdAt: morning.addingTimeInterval(60), rawText: "New dictation", cleanedText: "", duration: 2)
        XCTAssertTrue(store.updateNote(pending))
        let daily = try XCTUnwrap(AppStore(rootURL: root).notes.first)
        XCTAssertEqual(daily.displayText, "Unsaved editing\n\nNew dictation")
        XCTAssertEqual(daily.captures?.count, 2)
        XCTAssertEqual(daily.duration, 3)
        XCTAssertTrue(store.hasPersistedNote(nextID))
    }

    func testRecoveryForAnEarlierCaptureKeepsChronologicalOrderAndLatestPaste() {
        let store = AppStore(rootURL: root)
        store.addNote(createdAt: morning.addingTimeInterval(3600), rawText: "Latest", cleanedText: "", duration: 1)
        store.addNote(createdAt: morning, rawText: "Recovered earlier", cleanedText: "", duration: 1)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.displayText, "Recovered earlier\n\nLatest")
        XCTAssertEqual(store.latestText, "Latest")
    }

    func testFailedAppendMustPersistTheNewCaptureBeforeRecoveryIsComplete() throws {
        let store = AppStore(rootURL: root)
        store.addNote(createdAt: morning, rawText: "First", cleanedText: "", duration: 1)
        let history = root.appendingPathComponent("notes.json")
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let id = UUID()
        store.addNote(id: id, createdAt: morning.addingTimeInterval(60), rawText: "Second", cleanedText: "", duration: 1)
        XCTAssertFalse(store.hasPersistedNote(id))
        try FileManager.default.removeItem(at: history)
        store.addNote(id: id, createdAt: morning.addingTimeInterval(60), rawText: "Second", cleanedText: "", duration: 1)
        XCTAssertTrue(store.hasPersistedNote(id))
        XCTAssertEqual(AppStore(rootURL: root).notes.first?.displayText, "First\n\nSecond")
        XCTAssertEqual(store.notes.first?.captures?.count, 2)
    }
}
