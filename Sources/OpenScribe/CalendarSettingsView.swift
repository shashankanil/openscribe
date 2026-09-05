import SwiftUI
import AppKit

struct CalendarSettingsView: View {
    @ObservedObject var app: AppController
    @ObservedObject var calendar: CalendarMeetingController
    @State private var selectedDay = Date()
    @State private var month = Date()
    @State private var showSetup = false
    @State private var excludedTitle = ""
    @State private var sourceFilter = "all"
    private let dates = Calendar.current

    private var visibleEvents: [CalendarMeeting] {
        calendar.displayedEvents.filter { sourceFilter == "all" || $0.calendarID == sourceFilter }
    }
    private var dayEvents: [CalendarMeeting] { CalendarAgenda.events(visibleEvents, on: selectedDay, calendar: dates) }
    private var monthDays: [Date?] { CalendarAgenda.monthDays(month, calendar: dates) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Calendar").font(.system(size: 25, weight: .semibold))
                        Text("Your schedule, with recording on your terms.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Recording setup", systemImage: "slider.horizontal.3") { showSetup = true }.controlSize(.small)
                }
                if !calendar.authorized {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "calendar").font(.system(size: 30)).foregroundStyle(FlowTheme.lavenderDeep)
                        Text("Bring your meetings into view").font(.headline)
                        Text("See calendars already synced to your Mac, including Google. You choose which meetings to record.").foregroundStyle(.secondary)
                        Button("Allow calendar access") { Task { await calendar.requestAccess() } }.buttonStyle(.borderedProminent)
                        Button("Add a Google account") { addAccount() }.buttonStyle(.link)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(FlowTheme.paper, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    HStack {
                        Label(app.settings.calendarEnabled && !app.settings.calendarIDs.isEmpty ? "Meeting prompts on" : "Browsing only", systemImage: app.settings.calendarEnabled ? "bell" : "calendar")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Show", selection: $sourceFilter) {
                            Text("All calendars").tag("all")
                            ForEach(calendar.calendars) { Text($0.title + " · " + $0.account).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 250)
                    }
                    monthView
                    agendaView
                }
                if let error = calendar.error { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(30).frame(maxWidth: 1000).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { calendar.showMonth(month) }
        .sheet(isPresented: $showSetup) { setup }
    }

    private var monthView: some View {
        VStack(spacing: 18) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Today") { month = Date(); selectedDay = month; calendar.showMonth(month) }.controlSize(.small)
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }.help("Previous month").accessibilityLabel("Previous month")
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }.help("Next month").accessibilityLabel("Next month")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(0..<7, id: \.self) { offset in
                    Text(dates.shortWeekdaySymbols[(dates.firstWeekday - 1 + offset) % 7]).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.bottom, 5)
                }
                ForEach(monthDays.indices, id: \.self) { index in
                    if let day = monthDays[index] {
                        let events = CalendarAgenda.events(visibleEvents, on: day, calendar: dates)
                        Button { selectedDay = day } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(String(dates.component(.day, from: day))).font(.system(size: 12, weight: dates.isDateInToday(day) ? .bold : .medium))
                                    Spacer()
                                    if dates.isDateInToday(day) { Circle().fill(FlowTheme.lavenderDeep).frame(width: 5, height: 5) }
                                }
                                ForEach(events.prefix(2)) { event in
                                    Text(event.title).font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary)
                                }
                                if events.count > 2 { Text("+\(events.count - 2) more").font(.system(size: 10)).foregroundStyle(.secondary) }
                                Spacer(minLength: 0)
                            }.padding(8).frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74, alignment: .topLeading)
                                .background(dates.isDate(day, inSameDayAs: selectedDay) ? FlowTheme.lavender.opacity(0.5) : FlowTheme.paperMuted.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                            .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + ", \(events.count) events")
                    } else { Color.clear.frame(height: 74) }
                }
            }
        }.padding(20).background(FlowTheme.paper, in: RoundedRectangle(cornerRadius: 14))
    }

    private var agendaView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(selectedDay.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.headline)
                Spacer()
                Text("\(dayEvents.count) events").font(.caption).foregroundStyle(.secondary)
            }
            if dayEvents.isEmpty {
                Label("Nothing scheduled. A little room to breathe.", systemImage: "sun.max")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(dayEvents) { event in eventRow(event) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(FlowTheme.paper, in: RoundedRectangle(cornerRadius: 14))
    }

    private func eventRow(_ event: CalendarMeeting) -> some View {
        let excluded = event.matchesExclusion(app.settings.calendarExcludedTitles)
        let watched = app.settings.calendarEnabled && app.settings.calendarIDs.contains(event.calendarID)
        let eligible = !event.excluded && (!app.settings.calendarMeetingsOnly || event.hasAttendees || event.link != nil)
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 12, weight: .semibold))
                if !event.isAllDay { Text(event.end, style: .time).font(.caption).foregroundStyle(.secondary) }
            }.frame(width: 78, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(FlowTheme.lavenderDeep).frame(width: 3, height: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text(event.title).font(.system(size: 13, weight: .semibold))
                Text(event.calendarName).font(.caption).foregroundStyle(.secondary)
                Text(event.end < Date() ? "Ended" : excluded ? "Excluded by title rule" : calendar.isSkipped(event) ? "Recording skipped" : !eligible ? "No recording prompt" : watched ? "Will ask before recording" : "Calendar not watched")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                if let link = event.link { Link("Join", destination: link).font(.caption) }
                if event.end > Date(), eligible, !excluded {
                    Button(calendar.isSkipped(event) ? "Undo skip" : "Skip recording") {
                        if calendar.isSkipped(event) { calendar.allow(event) } else { calendar.skip(event) }
                    }.controlSize(.small)
                }
            }
        }.padding(.vertical, 10)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Recording setup").font(.title2.bold()); Spacer(); Button("Done") { showSetup = false }.keyboardShortcut(.defaultAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Toggle("Ask to record calendar meetings", isOn: binding(\.calendarEnabled)).toggleStyle(.switch)
                    Text("Calendars to watch").font(.headline)
                    Text("These selections control prompts, not what appears in your calendar.").font(.caption).foregroundStyle(.secondary)
                    ForEach(calendar.calendars) { choice in
                        Toggle(choice.title + " · " + choice.account, isOn: Binding(get: { app.settings.calendarIDs.contains(choice.id) }, set: { selected in
                            app.updateSettings { $0.calendarIDs.removeAll { $0 == choice.id }; if selected { $0.calendarIDs.append(choice.id) } }
                            calendar.refresh()
                        }))
                    }
                    HStack { Button("Add account…") { addAccount() }; Button("Refresh calendars") { calendar.refresh() } }
                    Divider()
                    Toggle("Only events with guests or a meeting link", isOn: binding(\.calendarMeetingsOnly))
                    Toggle("Record if unanswered after 60 seconds", isOn: binding(\.calendarAutoStart))
                    Text("With this on, an unanswered prompt starts local recording. Choosing No stops it.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Transcribe live after I choose Yes", isOn: binding(\.meetingLiveTranscription))
                    Toggle("Summarize when the meeting ends", isOn: binding(\.calendarSummarize))
                    Divider()
                    Text("Always skip matching titles").font(.headline)
                    HStack {
                        TextField("For example: personal or 1:1", text: $excludedTitle).textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let value = excludedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            app.updateSettings { if !$0.calendarExcludedTitles.contains(value) { $0.calendarExcludedTitles.append(value) } }
                            excludedTitle = ""; calendar.refresh()
                        }.disabled(excludedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(app.settings.calendarExcludedTitles, id: \.self) { phrase in
                        HStack { Text(phrase); Spacer(); Button("Remove") { app.updateSettings { $0.calendarExcludedTitles.removeAll { $0 == phrase } }; calendar.refresh() } }
                    }
                    Text("OpenScribe must be running. Recording uses your microphone and system audio. Calendar timing does not confirm that a call is connected.").font(.caption).foregroundStyle(.secondary)
                }.padding(.trailing, 8)
            }
        }.padding(26).frame(width: 540, height: 620).background(FlowTheme.paper)
    }

    private func moveMonth(_ offset: Int) {
        guard let next = dates.date(byAdding: .month, value: offset, to: month), let start = dates.dateInterval(of: .month, for: next)?.start else { return }
        month = start; selectedDay = start; calendar.showMonth(month)
    }
    private func addAccount() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.internetaccounts") { NSWorkspace.shared.open(url) }
    }
    private func binding(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { app.settings[keyPath: key] }, set: { value in app.updateSettings { $0[keyPath: key] = value }; calendar.refresh() })
    }
}

/// Date arithmetic uses local calendar boundaries, including daylight saving and overnight events.
enum CalendarAgenda {
    static func events(_ events: [CalendarMeeting], on day: Date, calendar: Calendar) -> [CalendarMeeting] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return events.filter { $0.start < interval.end && $0.end > interval.start }
    }
    static func monthDays(_ date: Date, calendar: Calendar) -> [Date?] {
        guard let start = calendar.dateInterval(of: .month, for: date)?.start,
              let days = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let values: [Date?] = days.map { calendar.date(byAdding: .day, value: $0 - 1, to: start) }
        let count = offset + values.count
        return Array(repeating: nil, count: offset) + values + Array(repeating: nil, count: (7 - count % 7) % 7)
    }
}
