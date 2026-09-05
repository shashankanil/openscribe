import XCTest
@testable import OpenScribe

final class CalendarMeetingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func meeting(startOffset: Double = 0, endOffset: Double = 3600, excluded: Bool = false,
                         attendees: Bool = true) -> CalendarMeeting {
        CalendarMeeting(id: "event:occurrence", title: "Weekly sync", start: now.addingTimeInterval(startOffset),
                        end: now.addingTimeInterval(endOffset), calendarID: "work", calendarName: "Work",
                        link: nil, hasAttendees: attendees, excluded: excluded)
    }
    func testOnlySelectedUnansweredCurrentMeetingsAreDue() {
        let event = meeting()
        XCTAssertTrue(event.isDue(at: now, selected: ["work"], handled: [], meetingsOnly: true))
        XCTAssertFalse(event.isDue(at: now, selected: [], handled: [], meetingsOnly: true))
        XCTAssertFalse(event.isDue(at: now, selected: ["work"], handled: [event.id], meetingsOnly: true))
        XCTAssertFalse(meeting(startOffset: 30).isDue(at: now, selected: ["work"], handled: [], meetingsOnly: true))
        XCTAssertFalse(meeting(startOffset: -121).isDue(at: now, selected: ["work"], handled: [], meetingsOnly: true))
        XCTAssertFalse(meeting(endOffset: -1).isDue(at: now, selected: ["work"], handled: [], meetingsOnly: true))
        XCTAssertFalse(meeting(excluded: true).isDue(at: now, selected: ["work"], handled: [], meetingsOnly: true))
    }
    func testFocusTimeIsOptionalButMeetingLinksAreRecognized() {
        XCTAssertFalse(meeting(attendees: false).isDue(at: now, selected: ["work"], handled: [], meetingsOnly: true))
        XCTAssertTrue(meeting(attendees: false).isDue(at: now, selected: ["work"], handled: [], meetingsOnly: false))
        XCTAssertEqual(CalendarMeeting.meetingLink(in: "Join https://meet.google.com/abc-defg-hij")?.host, "meet.google.com")
        XCTAssertEqual(CalendarMeeting.meetingLink(in: "https://us02web.zoom.us/j/123")?.host, "us02web.zoom.us")
        XCTAssertNil(CalendarMeeting.meetingLink(in: "https://zoom.us.evil.example/j/123"))
        XCTAssertNil(CalendarMeeting.meetingLink(in: "https://example.com/meet.google.com"))
        XCTAssertNil(CalendarMeeting.meetingLink(in: "file:///tmp/meeting"))
    }
    func testTitleExclusionsIgnoreCaseAndEmptyRules() {
        let event = meeting()
        XCTAssertTrue(event.matchesExclusion(["weekly"]))
        XCTAssertTrue(event.matchesExclusion([" SYNC "]))
        XCTAssertFalse(event.matchesExclusion(["", "   ", "personal"]))
        XCTAssertFalse(event.isDue(at: now, selected: ["work"], handled: [], meetingsOnly: true, excludedTitles: ["Weekly sync"]))
    }

    @MainActor
    func testPerOccurrenceSkipSurvivesRestartAndCanBeAllowedAgain() {
        let suite = "OpenScribe.CalendarTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let event = meeting()
        let controller = CalendarMeetingController(defaults: defaults)
        controller.skip(event)
        let restored = CalendarMeetingController(defaults: defaults)
        XCTAssertTrue(restored.isSkipped(event))
        let next = CalendarMeeting(id: "next-occurrence", title: event.title, start: event.start, end: event.end,
                                   calendarID: event.calendarID, calendarName: event.calendarName, link: nil, hasAttendees: true, excluded: false)
        XCTAssertFalse(restored.isSkipped(next))
        restored.allow(event)
        XCTAssertFalse(CalendarMeetingController(defaults: defaults).isSkipped(event))
    }

    func testCalendarAutomationRequiresSetupAndSettingsPersist() throws {
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.calendarEnabled)
        XCTAssertTrue(settings.calendarIDs.isEmpty)
        XCTAssertTrue(settings.calendarAutoStart)
        settings.calendarEnabled = true
        settings.calendarIDs = ["work"]
        settings.calendarExcludedTitles = ["personal"]
        settings.calendarAutoStart = false
        settings.calendarSummarize = false
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
