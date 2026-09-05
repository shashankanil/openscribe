import Foundation

struct CalendarMeeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendarID: String
    let calendarName: String
    let link: URL?
    let hasAttendees: Bool
    let excluded: Bool
    var isAllDay = false

    func isDue(at now: Date, selected: [String], handled: Set<String>, meetingsOnly: Bool, excludedTitles: [String] = []) -> Bool {
        !excluded && !matchesExclusion(excludedTitles) && selected.contains(calendarID) && !handled.contains(id)
            && start <= now && now.timeIntervalSince(start) <= 120 && end > now
            && (!meetingsOnly || link != nil || hasAttendees)
    }

    func matchesExclusion(_ phrases: [String]) -> Bool {
        phrases.contains {
            let phrase = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !phrase.isEmpty && title.localizedCaseInsensitiveContains(phrase)
        }
    }

    static func meetingLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let hosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"]
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first {
            guard $0.scheme == "https", let host = $0.host?.lowercased() else { return false }
            return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}

struct CalendarPrompt: Identifiable {
    enum Kind { case start, end }
    let id = UUID()
    let event: CalendarMeeting
    let kind: Kind
    let deadline: Date
    let automatic: Bool
}
