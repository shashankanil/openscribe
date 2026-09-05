import AppKit
import Combine
import EventKit
import AVFoundation
import CoreGraphics
import SwiftUI

@MainActor
final class CalendarMeetingController: ObservableObject {
    struct CalendarChoice: Identifiable {
        let id: String
        let title: String
        let account: String
    }
    @Published private(set) var calendars: [CalendarChoice] = []
    @Published private(set) var displayedEvents: [CalendarMeeting] = []
    private var displayedMonth = Date()
    @Published private(set) var upcoming: [CalendarMeeting] = []
    @Published private(set) var prompt: CalendarPrompt?
    @Published private(set) var authorized = false
    @Published var error: String?
    @Published private(set) var trackedTitle: String?
    private let events = EKEventStore()
    private weak var app: AppController?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var panel: NSPanel?
    private var lastRefresh = Date.distantPast
    private var lastTick = Date()
    private var suspended = false
    private var stopped = false
    private var tracked: (event: CalendarMeeting, id: UUID, end: Date)?
    private var stopRequested = false
    private var normalStopRequested = false
    @Published private(set) var skippedOccurrences: [String: Double]
    private var handled: [String: Double]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        skippedOccurrences = defaults.dictionary(forKey: "calendarSkippedOccurrences") as? [String: Double] ?? [:]
        handled = defaults.dictionary(forKey: "calendarHandledOccurrences") as? [String: Double] ?? [:]
    }

    func boot(app: AppController) {
        guard timer == nil else { return }
        self.app = app
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: events, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspended = true; self?.closePrompt() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspended = false; self?.lastTick = Date(); self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refresh()
    }

    func shutdown() { stopped = true; timer?.invalidate(); timer = nil; closePrompt() }

    func requestAccess() async {
        do {
            authorized = try await events.requestFullAccessToEvents()
            error = authorized ? nil : "Calendar access is off. Allow OpenScribe in System Settings → Privacy & Security → Calendars."
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func refresh() {
        lastRefresh = Date()
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard authorized else { calendars = []; upcoming = []; displayedEvents = []; cancelStartPrompt(); return }
        let available = events.calendars(for: .event)
        calendars = available.map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        loadDisplayedEvents()
        guard let settings = app?.settings, settings.calendarEnabled else { upcoming = []; cancelStartPrompt(); return }
        let selected = available.filter { settings.calendarIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { upcoming = []; cancelStartPrompt(); return }
        let now = Date()
        let predicate = events.predicateForEvents(withStart: now.addingTimeInterval(-120), end: now.addingTimeInterval(86400), calendars: selected)
        upcoming = events.events(matching: predicate).compactMap(Self.meeting)
            .filter { !$0.excluded && $0.end > now }.sorted { $0.start < $1.start }
        if let prompt, prompt.kind == .start,
           !upcoming.contains(where: { $0.id == prompt.event.id }) || isSkipped(prompt.event) || prompt.event.matchesExclusion(settings.calendarExcludedTitles) { closePrompt() }
        skippedOccurrences = skippedOccurrences.filter { $0.value > now.addingTimeInterval(-7 * 86400).timeIntervalSince1970 }
        defaults.set(skippedOccurrences, forKey: "calendarSkippedOccurrences")
        handled = handled.filter { $0.value > now.addingTimeInterval(-7 * 86400).timeIntervalSince1970 }
    }

    func showMonth(_ date: Date) {
        displayedMonth = date
        refresh()
    }

    private func loadDisplayedEvents() {
        guard let interval = Calendar.current.dateInterval(of: .month, for: displayedMonth) else { return }
        // Browsing is independent of recording consent and selected automation calendars.
        let predicate = events.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        displayedEvents = events.events(matching: predicate).compactMap(Self.meeting).sorted { $0.start < $1.start }
    }

    private static func meeting(_ event: EKEvent) -> CalendarMeeting? {
        guard let identifier = event.eventIdentifier, let start = event.startDate, let end = event.endDate else { return nil }
        let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
        let text = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        return CalendarMeeting(id: identifier + ":" + String(start.timeIntervalSince1970), title: event.title ?? "Meeting", start: start, end: end,
            calendarID: event.calendar.calendarIdentifier, calendarName: event.calendar.title,
            link: CalendarMeeting.meetingLink(in: text), hasAttendees: event.hasAttendees,
            excluded: event.isAllDay || event.status == .canceled || declined, isAllDay: event.isAllDay)
    }

    func isSkipped(_ event: CalendarMeeting) -> Bool { skippedOccurrences[event.id] != nil }

    func skip(_ event: CalendarMeeting) {
        objectWillChange.send()
        skippedOccurrences[event.id] = event.end.timeIntervalSince1970
        defaults.set(skippedOccurrences, forKey: "calendarSkippedOccurrences")
        if prompt?.event.id == event.id && prompt?.kind == .start { closePrompt() }
        if tracked?.event.id == event.id { decline() }
    }

    func allow(_ event: CalendarMeeting) {
        objectWillChange.send()
        guard skippedOccurrences.removeValue(forKey: event.id) != nil else { return }
        handled.removeValue(forKey: event.id)
        defaults.set(skippedOccurrences, forKey: "calendarSkippedOccurrences")
        defaults.set(handled, forKey: "calendarHandledOccurrences")
    }

    private func markHandled(_ event: CalendarMeeting) {
        handled[event.id] = Date().timeIntervalSince1970
        defaults.set(handled, forKey: "calendarHandledOccurrences")
    }

    private func tick() {
        guard !stopped, let app else { return }
        let now = Date()
        let gap = now.timeIntervalSince(lastTick)
        lastTick = now
        if gap > 10 { closePrompt() } // Never act on a countdown missed during sleep or a stalled UI.
        if now.timeIntervalSince(lastRefresh) > 30 { refresh() }
        if let tracked {
            if !stopRequested && (!app.settings.calendarEnabled || !authorized || !app.settings.calendarIDs.contains(tracked.event.calendarID) || tracked.event.matchesExclusion(app.settings.calendarExcludedTitles)) {
                decline()
            }
            if app.meetings.activeID != tracked.id {
                self.tracked = nil; trackedTitle = nil; stopRequested = false; normalStopRequested = false
                closePrompt()
            } else if stopRequested && !app.meetings.isBusy {
                app.meetings.finish(summarize: false)
                stopRequested = false
            } else if normalStopRequested && !app.meetings.isBusy {
                app.meetings.finish()
                normalStopRequested = false
            } else if !suspended && prompt == nil && !app.meetings.isBusy && now >= tracked.end {
                present(CalendarPrompt(event: tracked.event, kind: .end, deadline: now.addingTimeInterval(60), automatic: true))
            }
        }
        guard !suspended else { return }
        if let prompt {
            if prompt.kind == .start && (!app.settings.calendarEnabled || !authorized || !app.settings.calendarIDs.contains(prompt.event.calendarID)) {
                closePrompt(); return
            }
            if prompt.kind == .start && prompt.automatic && !app.settings.calendarAutoStart {
                self.prompt = CalendarPrompt(event: prompt.event, kind: .start, deadline: prompt.deadline, automatic: false)
                return
            }
            if prompt.automatic && now >= prompt.deadline {
                if prompt.kind == .start { startPrompt(automatic: true) } else { finishPrompt() }
            }
            return
        }
        guard authorized, app.settings.calendarEnabled, !app.isDictationBusy, app.meetings.activeID == nil, !app.meetings.isBusy else { return }
        if let event = upcoming.first(where: { $0.isDue(at: now, selected: app.settings.calendarIDs, handled: Set(handled.keys).union(skippedOccurrences.keys), meetingsOnly: app.settings.calendarMeetingsOnly, excludedTitles: app.settings.calendarExcludedTitles) }) {
            markHandled(event)
            present(CalendarPrompt(event: event, kind: .start, deadline: now.addingTimeInterval(60), automatic: app.settings.calendarAutoStart))
        }
    }

    func startPrompt(automatic: Bool = false) {
        guard let prompt, prompt.kind == .start, let app else { return }
        let event = prompt.event
        closePrompt()
        guard !event.excluded, !isSkipped(event), !event.matchesExclusion(app.settings.calendarExcludedTitles) else { return }
        guard app.settings.calendarEnabled, authorized, app.settings.calendarIDs.contains(event.calendarID), event.end > Date(),
              !app.isDictationBusy, !app.meetings.isBusy, app.meetings.activeID == nil else {
            error = "Calendar recording skipped: capture is busy or this event is no longer available."
            return
        }
        if automatic && (AVCaptureDevice.authorizationStatus(for: .audio) != .authorized || !CGPreflightScreenCaptureAccess()) {
            error = "Automatic recording skipped. Enable Microphone and Screen & System Audio Recording access before the next meeting."
            app.workspaceSection = .calendar
            app.openMainWindow()
            return
        }
        app.meetings.start(title: event.title, microphone: true, systemAudio: true, settings: app.settings,
                           summarizeOnStop: app.settings.calendarSummarize, liveTranscription: !automatic && app.settings.meetingLiveTranscription)
        if let id = app.meetings.activeID {
            tracked = (event, id, event.end); trackedTitle = event.title
            showPanel()
        }
    }

    func decline() {
        if let prompt, prompt.kind == .start { skip(prompt.event) }
        closePrompt()
        if let tracked, app?.meetings.activeID == tracked.id {
            // Stop further processing. Unanswered starts are local-only; explicit Yes can enable live uploads.
            normalStopRequested = false
            stopRequested = true
            if app?.meetings.isBusy == false { app?.meetings.finish(summarize: false); stopRequested = false }
        }
    }

    func finishPrompt() {
        closePrompt()
        guard let tracked, let app, app.meetings.activeID == tracked.id else { return }
        if app.meetings.isBusy { normalStopRequested = true }
        else { app.meetings.finish() }
    }

    func extend() {
        guard var tracked else { return }
        tracked.end = max(tracked.end, Date()).addingTimeInterval(15 * 60)
        self.tracked = tracked
        closePrompt()
        showPanel()
    }

    private func present(_ prompt: CalendarPrompt) {
        self.prompt = prompt
        showPanel()
    }

    private func showPanel() {
        panel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 220), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "OpenScribe · Calendar"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CalendarPromptView(calendar: self))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 414, y: screen.maxY - 244))
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hideRecordingControls() { panel?.orderOut(nil); panel = nil }
    private func cancelStartPrompt() { if prompt?.kind == .start { closePrompt() } }
    private func closePrompt() { prompt = nil; panel?.orderOut(nil); panel = nil }
}

private struct CalendarPromptView: View {
    @ObservedObject var calendar: CalendarMeetingController
    var body: some View {
        if let prompt = calendar.prompt {
            VStack(alignment: .leading, spacing: 12) {
                Text(prompt.kind == .start ? "Do you want to record this meeting?" : "Still in this meeting?").font(.headline)
                Text(prompt.event.title).font(.subheadline).lineLimit(2)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(ceil(prompt.deadline.timeIntervalSince(context.date))))
                    Text(prompt.automatic ? "\(prompt.kind == .start ? "Recording starts" : "Recording stops") in \(seconds)s" : "Microphone and system audio")
                        .font(.callout).monospacedDigit()
                }
                if prompt.kind == .start {
                    Text("Make sure everyone knows you're recording.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("No", action: calendar.decline)
                        Spacer()
                        Button("Yes") { calendar.startPrompt() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    HStack {
                        Button("Stop & save", action: calendar.finishPrompt)
                        Spacer()
                        Button("15 more minutes", action: calendar.extend).buttonStyle(.borderedProminent)
                    }
                }
            }.padding(20).frame(width: 390, alignment: .leading)
        } else if let title = calendar.trackedTitle {
            VStack(alignment: .leading, spacing: 14) {
                Label("Calendar recording", systemImage: "record.circle").font(.headline)
                Text(title).lineLimit(2)
                Text("“Not happening” stops capture and further processing.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Not happening", action: calendar.decline)
                    Button("Stop & save", action: calendar.finishPrompt)
                    Spacer()
                    Button("Hide", action: calendar.hideRecordingControls)
                }
            }.padding(20).frame(width: 390, alignment: .leading)
        }
    }
}
