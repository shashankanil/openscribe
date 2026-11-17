import XCTest
@testable import OpenScribeContext

final class SearchTests: XCTestCase {
    private var fixture: FixtureProfile!
    private var index: SearchIndex!

    override func setUpWithError() throws {
        fixture = try FixtureProfile()
        index = SearchIndex(library: ContextLibrary.load(root: fixture.root))
    }

    override func tearDown() { fixture.remove() }

    private func ids(_ query: String, kind: ContextDocument.Kind? = nil) -> [String] {
        index.search(query, kind: kind, limit: 10, now: fixture.now).map(\.id)
    }

    func testDiacriticAndCaseInsensitive() {
        let results = ids("ZURICH")
        XCTAssertEqual(Set(results), [FixtureProfile.dayNoteID, FixtureProfile.planningMeetingID])
        XCTAssertEqual(ids("cafe"), [FixtureProfile.dayNoteID])
    }

    func testTitleAndPhraseOutrankBodyMentions() {
        XCTAssertEqual(ids("budget retrospective").first, FixtureProfile.oldNoteID)
        XCTAssertEqual(ids("launch date").first, FixtureProfile.planningMeetingID)
        XCTAssertEqual(ids("hiring plan").first, FixtureProfile.manualNoteID)
    }

    func testPrefixMatchingAndStopwords() {
        XCTAssertEqual(ids("interv").first, FixtureProfile.manualNoteID)
        XCTAssertEqual(ids("what about the passport").first, FixtureProfile.legacyNoteID)
    }

    func testKindFilter() {
        let meetings = ids("budget", kind: .meeting)
        XCTAssertEqual(meetings, [FixtureProfile.planningMeetingID])
        XCTAssertFalse(ids("budget", kind: .note).contains(FixtureProfile.planningMeetingID))
    }

    func testSearchesScreenshotTextAndBuildsSnippet() throws {
        let hit = try XCTUnwrap(index.search("invoice 4471", now: fixture.now).first)
        XCTAssertEqual(hit.id, FixtureProfile.dayNoteID)
        XCTAssertTrue(hit.snippet.contains("Invoice number 4471"), hit.snippet)
        XCTAssertLessThanOrEqual(hit.snippet.count, SearchIndex.snippetLength + 40)
    }

    func testSnippetCentersOnMatchInLongText() throws {
        let filler = (0..<400).map { "filler\($0)" }.joined(separator: " ")
        let body = filler + " the unicorn migration plan is ready " + filler
        let library = ContextLibrary(root: fixture.root, documents: [
            ContextDocument(id: "long", kind: .note, title: "Notes", createdAt: fixture.now, updatedAt: fixture.now, body: body),
        ])
        let hit = try XCTUnwrap(SearchIndex(library: library).search("unicorn migration").first)
        XCTAssertTrue(hit.snippet.hasPrefix("…") && hit.snippet.hasSuffix("…"), hit.snippet)
        XCTAssertTrue(hit.snippet.contains("unicorn migration plan"), hit.snippet)
    }

    func testRecencyBreaksTies() {
        let old = ContextDocument(id: "old", kind: .note, title: "Standup", createdAt: fixture.ago(hours: 24 * 60),
                                  updatedAt: fixture.ago(hours: 24 * 60), body: "standup notes")
        var new = old
        new.id = "new"
        new.createdAt = fixture.ago(hours: 1)
        new.updatedAt = fixture.ago(hours: 1)
        let index = SearchIndex(library: ContextLibrary(root: fixture.root, documents: [old, new]))
        XCTAssertEqual(index.search("standup", now: fixture.now).map(\.id), ["new", "old"])
    }

    func testNoMatchAndEmptyQuery() {
        XCTAssertTrue(ids("xylophone").isEmpty)
        XCTAssertTrue(ids("   ").isEmpty)
    }

    func testLimit() {
        XCTAssertEqual(index.search("budget", limit: 1, now: fixture.now).count, 1)
    }
}

final class ToolTests: XCTestCase {
    private var fixture: FixtureProfile!
    private var library: ContextLibrary!

    override func setUpWithError() throws {
        fixture = try FixtureProfile()
        library = ContextLibrary.load(root: fixture.root)
    }

    override func tearDown() { fixture.remove() }

    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) throws -> ContextTools.Result {
        try ContextTools.call(name, arguments: arguments, library: library, now: fixture.now)
    }

    func testDefinitions() {
        let tools = ContextTools.definitions
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, ContextTools.names)
        for tool in tools {
            XCTAssertEqual(tool["annotations"]?["readOnlyHint"], true)
            XCTAssertEqual(tool["inputSchema"]?["type"], "object")
            XCTAssertEqual(tool["outputSchema"]?["type"], "object")
        }
        XCTAssertEqual(tools[0]["inputSchema"]?["required"], ["query"])
    }

    func testSearchTool() throws {
        let result = try call("search", ["query": "launch date", "limit": 3])
        XCTAssertFalse(result.isError)
        let results = try XCTUnwrap(result.structured?["results"]?.arrayValue)
        XCTAssertEqual(results.first?["id"]?.stringValue, FixtureProfile.planningMeetingID)
        XCTAssertEqual(results.first?["kind"], "meeting")
        XCTAssertNotNil(results.first?["createdAt"]?.stringValue.flatMap(ContextDate.parse))
        XCTAssertTrue(results.first?["snippet"]?.stringValue?.contains("launch date") == true)
        // The text mirrors the structured content as JSON.
        let mirrored = try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
        XCTAssertEqual(mirrored, result.structured)
        XCTAssertTrue(try call("search", ["kind": "meeting", "query": "budget", "limit": "50"]).structured?["results"]?.arrayValue?.count == 1)
    }

    func testSearchToolErrors() throws {
        XCTAssertTrue(try call("search").isError)
        XCTAssertTrue(try call("search", ["query": "x", "kind": "email"]).isError)
        XCTAssertTrue(try call("search", ["query": "x", "limit": "lots"]).isError)
        XCTAssertThrowsError(try call("delete_everything"))
    }

    func testFetch() throws {
        let result = try call("fetch", ["id": .string(FixtureProfile.planningMeetingID.lowercased())])
        XCTAssertFalse(result.isError)
        let document = try JSONDecoder().decode(ContextDocument.self, from: JSONEncoder().encode(XCTUnwrap(result.structured)))
        XCTAssertEqual(document.id, FixtureProfile.planningMeetingID)
        XCTAssertEqual(document.actionItems.count, 2)
        XCTAssertTrue(result.text.hasPrefix("# Planning sync\n\nid: \(FixtureProfile.planningMeetingID) · meeting"), result.text)
        XCTAssertTrue(result.text.contains("## My notes\n\nAsk about **headcount**."))
        XCTAssertTrue(result.text.contains("## Decisions"))
        XCTAssertTrue(result.text.contains("## Transcript\n\n[00:00] Me"))

        let note = try call("fetch", ["id": .string(FixtureProfile.manualNoteID)])
        XCTAssertTrue(note.text.contains("tags: hiring, team"))
        XCTAssertTrue(note.text.hasSuffix("Interview loop owner: Priya."))

        let missing = try call("fetch", ["id": "nope"])
        XCTAssertTrue(missing.isError)
        XCTAssertNil(missing.structured)
        XCTAssertEqual(missing.json["isError"], true)
    }

    func testFetchTruncatesHugeTranscripts() throws {
        let id = "DDDDDDDD-0000-0000-0000-000000000000"
        let segments = (0..<2_000).map {
            FixtureProfile.segment("d/microphone/\($0).wav", "microphone", Double($0 * 100), 10, String(repeating: "word ", count: 20))
        }
        try fixture.writeJSON(FixtureProfile.meeting(id: id, title: "All hands", createdAt: fixture.now, duration: 7_200,
                                                     segments: segments, summary: nil, userNotes: nil), to: fixture.meetingURL(id))
        library = ContextLibrary.load(root: fixture.root)
        let full = try XCTUnwrap(library.document(id: id)?.transcript)
        XCTAssertGreaterThan(full.count, 200_000)

        let fetched = try call("fetch", ["id": .string(id)])
        let transcript = try XCTUnwrap(fetched.structured?["transcript"]?.stringValue)
        XCTAssertLessThan(transcript.count, ContextTools.transcriptLimit + 400)
        XCTAssertTrue(transcript.contains("[Transcript truncated: showing the first"))
        XCTAssertTrue(transcript.contains("get_meeting"))

        let meeting = try call("get_meeting", ["id": .string(id), "includeTranscript": true])
        XCTAssertEqual(meeting.structured?["transcriptTruncated"], true)
        XCTAssertEqual(meeting.structured?["summary"], .null)
    }

    func testListRecent() throws {
        let result = try call("list_recent")
        let documents = try XCTUnwrap(result.structured?["documents"]?.arrayValue)
        XCTAssertEqual(documents.compactMap { $0["id"]?.stringValue },
                       [FixtureProfile.dayNoteID, FixtureProfile.planningMeetingID, FixtureProfile.manualNoteID, FixtureProfile.legacyNoteID])
        XCTAssertTrue(documents.allSatisfy { $0["transcript"] == .null })
        XCTAssertTrue(result.text.hasPrefix("4 documents updated in the last 7 days."), result.text)

        let meetings = try call("list_recent", ["kind": "meeting", "days": 30, "limit": 1])
        XCTAssertEqual(meetings.structured?["documents"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, [FixtureProfile.planningMeetingID])
        let all = try call("list_recent", ["days": 365, "limit": 100])
        XCTAssertEqual(all.structured?["documents"]?.arrayValue?.count, 6)
    }

    func testGetMeeting() throws {
        let brief = try call("get_meeting", ["id": .string(FixtureProfile.planningMeetingID)])
        XCTAssertFalse(brief.isError)
        let structured = try XCTUnwrap(brief.structured)
        XCTAssertEqual(structured["title"], "Planning sync")
        XCTAssertEqual(structured["status"], "ready")
        XCTAssertEqual(structured["durationSeconds"], .double(1_830))
        XCTAssertEqual(structured["notes"], "Ask about **headcount**.")
        XCTAssertEqual(structured["transcript"], .null)
        XCTAssertEqual(structured["transcriptTruncated"], false)
        XCTAssertEqual(structured["actionItems"]?.arrayValue?.count, 2)
        XCTAssertTrue(brief.text.contains("includeTranscript: true"))
        XCTAssertFalse(brief.text.contains("## Transcript"))

        let full = try call("get_meeting", ["id": .string(FixtureProfile.planningMeetingID), "includeTranscript": true])
        XCTAssertTrue(full.structured?["transcript"]?.stringValue?.hasPrefix("[00:00] Me\nLet's review the roadmap.") == true)
        XCTAssertTrue(full.text.contains("## Transcript"))

        let retro = try call("get_meeting", ["id": .string(FixtureProfile.retroMeetingID)])
        XCTAssertEqual(retro.structured?["status"], "interrupted")
        XCTAssertTrue(retro.text.contains("status interrupted"))

        XCTAssertTrue(try call("get_meeting", ["id": .string(FixtureProfile.manualNoteID)]).isError)
        XCTAssertTrue(try call("get_meeting", [:]).isError)
    }

    func testListActionItems() throws {
        let recent = try call("list_action_items")
        let items = try XCTUnwrap(recent.structured?["actionItems"]?.arrayValue)
        XCTAssertEqual(items.compactMap { $0["text"]?.stringValue }, ["Send the revised budget to finance", "Book the Zürich offsite venue"])
        XCTAssertEqual(items.first?["meetingId"]?.stringValue, FixtureProfile.planningMeetingID)
        XCTAssertEqual(items.first?["meetingTitle"], "Planning sync")
        XCTAssertNotNil(items.first?["meetingDate"]?.stringValue.flatMap(ContextDate.parse))
        XCTAssertTrue(recent.text.hasPrefix("2 action items from 1 meeting in the last 14 days."), recent.text)

        let month = try call("list_action_items", ["days": 30])
        XCTAssertEqual(month.structured?["actionItems"]?.arrayValue?.count, 3)
    }

    func testTruncateHelper() {
        let short = ContextTools.truncateTranscript("hello")
        XCTAssertEqual(short.text, "hello")
        XCTAssertFalse(short.truncated)
        let long = ContextTools.truncateTranscript(String(repeating: "a", count: 70_000))
        XCTAssertTrue(long.truncated)
        XCTAssertTrue(long.text.hasPrefix(String(repeating: "a", count: 60_000) + "\n\n[Transcript truncated"))
    }
}
