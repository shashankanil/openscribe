import XCTest
@testable import OpenScribe

final class NotesPerformanceTests: XCTestCase {
    private func library(days: Int, entriesPerDay: Int) -> [VoiceNote] {
        let now = Date()
        return (0..<days).map { day in
            let date = now.addingTimeInterval(-Double(day) * 86_400)
            var note = VoiceNote(createdAt: date, title: "", rawText: "", cleanedText: "", duration: 0)
            note.captures = []
            note.appendCaptures((0..<entriesPerDay).map { index in
                NoteCapture(id: UUID(), createdAt: date.addingTimeInterval(Double(index) * 60), title: "",
                            rawText: "entry \(index) of day \(day)", text: "Entry \(index) of day \(day) about the roadmap.",
                            duration: 3, sourceApplication: "Notes", sourceBundleIdentifier: nil)
            })
            note.isPinned = day == 40
            return note
        }
    }

    func testListingGroupsTwoThousandNotesQuickly() {
        let notes = library(days: 2_000, entriesPerDay: 6)
        let started = Date()
        let listing = NoteLibraryListing(notes: notes, today: notes.first, search: "", filter: .all, limit: 60)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        XCTAssertEqual(listing.filtered.count, 1_999, "Today has its own row")
        XCTAssertEqual(listing.groups.first?.title, "Pinned")
        XCTAssertEqual(listing.groups.reduce(0) { $0 + $1.notes.count }, 60)
    }

    func testSearchingTwoThousandNotesIsQuickAndIncludesToday() {
        let notes = library(days: 2_000, entriesPerDay: 6)
        let started = Date()
        let listing = NoteLibraryListing(notes: notes, today: notes.first, search: "of day 7 about", filter: .all, limit: 60)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertTrue(listing.filtered.contains { $0.id == notes[7].id })
        XCTAssertFalse(listing.filtered.contains { $0.id == notes[8].id })
    }
}
