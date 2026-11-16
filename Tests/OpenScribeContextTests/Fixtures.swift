import Foundation
@testable import OpenScribeContext

/// Builds temp-directory profiles shaped like the app's real files:
/// `notes.json` with ISO-8601 dates (AppStore's encoder) and `Meetings/<UUID>/meeting.json`
/// with reference-date numbers (MeetingStore's default JSONEncoder).
struct FixtureProfile {
    let root: URL
    let now: Date

    static let dayNoteID = "11111111-1111-1111-1111-111111111111"
    static let manualNoteID = "22222222-2222-2222-2222-222222222222"
    static let legacyNoteID = "33333333-3333-3333-3333-333333333333"
    static let oldNoteID = "44444444-4444-4444-4444-444444444444"
    static let planningMeetingID = "AAAAAAAA-0000-0000-0000-000000000001"
    static let retroMeetingID = "AAAAAAAA-0000-0000-0000-000000000002"
    static let staleMeetingID = "AAAAAAAA-0000-0000-0000-000000000003"

    init(now: Date = Date(timeIntervalSince1970: 1_795_000_000)) throws {
        self.now = now
        root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeNotes()
        try writeMeetings()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func iso(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle()) }
    func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    /// Meeting `updatedAt` comes from the file's modification date; pin it so tests do not depend on the clock.
    func touch(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    var notesURL: URL { root.appendingPathComponent("notes.json") }

    func meetingURL(_ id: String) -> URL { root.appendingPathComponent("Meetings/\(id)/meeting.json") }

    private func writeNotes() throws {
        let dayStart = ago(hours: 5)
        let notes: [[String: Any]] = [
            // Day note (captures present): a timeline of dictations, a screenshot, a meeting link and a superseded entry.
            [
                "id": Self.dayNoteID, "createdAt": iso(dayStart), "title": "November 16, 2026",
                "rawText": "raw", "cleanedText": "Call the café about the Zürich offsite\n\nDraft the quarterly budget",
                "duration": 42.5, "isPinned": false, "tags": [], "source": "Dictation",
                "captures": [
                    ["id": "C0000000-0000-0000-0000-000000000001", "createdAt": iso(dayStart), "title": "", "rawText": "call the cafe",
                     "text": "Call the café about the Zürich offsite", "duration": 12.5, "sourceApplication": "Slack",
                     "sourceBundleIdentifier": "com.tinyspeck.slackmacgap"],
                    ["id": "C0000000-0000-0000-0000-000000000002", "createdAt": iso(ago(hours: 4)), "title": "", "rawText": "old text",
                     "text": "This entry was replaced", "duration": 5, "kind": "dictation", "superseded": true],
                    ["id": "C0000000-0000-0000-0000-000000000003", "createdAt": iso(ago(hours: 3.5)), "title": "", "rawText": "",
                     "text": "", "duration": 0, "kind": "screenshot", "attachment": "shot.png",
                     "recognizedText": "Invoice number 4471 from Acme Widgets"],
                    ["id": "C0000000-0000-0000-0000-000000000004", "createdAt": iso(ago(hours: 3)), "title": "Planning sync",
                     "rawText": "", "text": "", "duration": 0, "kind": "meeting", "meetingID": Self.planningMeetingID],
                    ["id": "C0000000-0000-0000-0000-000000000005", "createdAt": iso(ago(hours: 2)), "title": "", "rawText": "draft budget",
                     "text": "Draft the quarterly budget", "duration": 30, "kind": "dictation", "sourceApplication": "Notes",
                     "futureField": ["ignored": true]],
                ],
            ],
            // Written note with an explicit edit and tags.
            [
                "id": Self.manualNoteID, "createdAt": iso(ago(hours: 30)), "title": "Hiring plan",
                "rawText": "", "cleanedText": "old body", "editedText": "Hire two backend engineers.\nInterview loop owner: Priya.",
                "duration": 0, "isPinned": true, "tags": ["hiring", "team"], "source": "Note",
            ],
            // Pre-daily-grouping note without captures, untitled: title comes from the first line.
            [
                "id": Self.legacyNoteID, "createdAt": iso(ago(hours: 72)), "title": "Untitled note",
                "rawText": "remember to renew the passport", "cleanedText": "", "duration": 3, "source": "Dictation",
            ],
            // Old note outside the default list window.
            [
                "id": Self.oldNoteID, "createdAt": iso(ago(hours: 24 * 40)), "title": "Budget retrospective notes",
                "rawText": "", "cleanedText": "Budget review from last quarter.", "duration": 0, "source": "Note",
            ],
            // Empty draft: skipped.
            ["id": "55555555-5555-5555-5555-555555555555", "createdAt": iso(now), "title": "", "rawText": "", "cleanedText": "",
             "duration": 0, "source": "Note"],
            // Malformed element (no id): skipped without losing the rest.
            ["title": "broken"],
        ]
        try writeJSON(notes, to: notesURL)
    }

    static func meeting(id: String, title: String, createdAt: Date, duration: Double, status: String = "ready",
                        segments: [[String: Any]], summary: [String: Any]?, userNotes: String?) -> [String: Any] {
        var object: [String: Any] = [
            "id": id, "title": title, "createdAt": createdAt.timeIntervalSinceReferenceDate, "duration": duration,
            "status": status, "summarizeOnStop": true, "liveTranscription": true, "includesMicrophone": true,
            "includesSystemAudio": true, "settings": ["speechProvider": "openRouter", "theme": "system"],
            "segments": segments, "microphoneLabel": "Me", "systemLabel": "Others",
        ]
        if let summary { object["summary"] = summary }
        if let userNotes { object["userNotes"] = userNotes }
        return object
    }

    static func segment(_ id: String, _ track: String, _ start: Double, _ duration: Double, _ text: String) -> [String: Any] {
        ["id": id, "track": track, "start": start, "duration": duration, "text": text]
    }

    private func writeMeetings() throws {
        let planning = Self.meeting(
            id: Self.planningMeetingID, title: "Planning sync", createdAt: ago(hours: 3), duration: 1_830,
            segments: [
                Self.segment("p1/microphone/0001.wav", "microphone", 0, 10, "Let's review the roadmap."),
                Self.segment("p1/microphone/0002.wav", "microphone", 11, 10, "Budget approval is the blocker."),
                Self.segment("p1/system/0001.wav", "system", 5, 10, "Agreed, the launch date moves to March."),
                Self.segment("p1/microphone/0003.wav", "microphone", 40, 10, "Next topic: hiring."),
                Self.segment("p1/microphone/0004.wav", "microphone", 51, 10, "   "),
            ],
            summary: [
                "overview": [["text": "Reviewed the product roadmap and launch timing.", "sources": ["p1/microphone/0001.wav"]]],
                "decisions": [["text": "Launch moves to March.", "sources": ["p1/system/0001.wav"]]],
                "actions": [["text": "Send the revised budget to finance", "sources": ["p1/microphone/0002.wav"]],
                            ["text": "Book the Zürich offsite venue", "sources": ["p1/microphone/0003.wav"]]],
            ],
            userNotes: "Ask about **headcount**.")
        try writeJSON(planning, to: meetingURL(Self.planningMeetingID))
        try touch(meetingURL(Self.planningMeetingID), ago(hours: 2.5))

        let retro = Self.meeting(
            id: Self.retroMeetingID, title: "Sprint retro", createdAt: ago(hours: 24 * 20), duration: 600, status: "interrupted",
            segments: [Self.segment("r/microphone/0001.wav", "microphone", 0, 10, "The deploy pipeline was slow.")],
            summary: ["overview": [], "decisions": [], "actions": [["text": "Speed up CI", "sources": ["r/microphone/0001.wav"]]]],
            userNotes: nil)
        try writeJSON(retro, to: meetingURL(Self.retroMeetingID))
        try touch(meetingURL(Self.retroMeetingID), ago(hours: 24 * 20 - 1))

        // A meeting whose id does not match its folder is ignored, as in the app.
        let mismatched = Self.meeting(id: "BBBBBBBB-0000-0000-0000-000000000000", title: "Wrong folder", createdAt: now,
                                      duration: 1, segments: [], summary: nil, userNotes: nil)
        try writeJSON(mismatched, to: meetingURL(Self.staleMeetingID))

        // Corrupt and non-UUID entries are skipped.
        let corrupt = root.appendingPathComponent("Meetings/CCCCCCCC-0000-0000-0000-000000000000/meeting.json")
        try FileManager.default.createDirectory(at: corrupt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: corrupt)
        try writeJSON(["title": "x"], to: root.appendingPathComponent("Meetings/not-a-uuid/meeting.json"))
    }
}
