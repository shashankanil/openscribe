import XCTest
@testable import OpenScribe

final class CalendarAgendaTests: XCTestCase {
    var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/New_York")!
        result.firstWeekday = 2
        return result
    }
    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    func testMonthGridUsesLocaleStartAndIncludesLeapDay() {
        let days = CalendarAgenda.monthDays(date(2024, 2, 10), calendar: calendar)
        XCTAssertEqual(days.count % 7, 0)
        XCTAssertEqual(days.compactMap { $0 }.count, 29)
        XCTAssertNil(days[0]); XCTAssertNil(days[1]); XCTAssertNil(days[2])
        XCTAssertEqual(days[3], date(2024, 2, 1))
    }
    func testOvernightEventsAppearOnBothDaysAndMidnightEndDoesNotLeak() {
        func event(_ start: Date, _ end: Date) -> CalendarMeeting {
            .init(id: UUID().uuidString, title: "Meeting", start: start, end: end, calendarID: "a", calendarName: "Work", link: nil, hasAttendees: true, excluded: false)
        }
        let overnight = event(date(2026, 3, 7, 23), date(2026, 3, 8, 3))
        let midnight = event(date(2026, 3, 7, 22), date(2026, 3, 8))
        XCTAssertEqual(CalendarAgenda.events([overnight, midnight], on: date(2026, 3, 7), calendar: calendar).count, 2)
        XCTAssertEqual(CalendarAgenda.events([overnight, midnight], on: date(2026, 3, 8), calendar: calendar).map(\.id), [overnight.id])
    }
}
