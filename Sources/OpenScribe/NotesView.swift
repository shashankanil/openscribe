import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the editor pane shows. Today is always available, even before anything was captured.
enum NoteSelection: Hashable {
    case today
    case note(UUID)
}

struct NotesView: View {
    @ObservedObject var controller: AppController
    @State private var search = ""
    @State private var filter: NoteFilter = .all
    @State private var selection: NoteSelection = .today
    @State private var draft: VoiceNote?
    @State private var pendingDelete: VoiceNote?
    @State private var displayLimit = 60
    @FocusState private var searchFocused: Bool

    private var isVisible: Bool { controller.workspaceSection == .notes }
    private var todayNote: VoiceNote? { controller.store.dayNote(for: Date()) }

    private var selectedNote: VoiceNote? {
        switch selection {
        case .today: return todayNote
        case let .note(id): return controller.store.note(withID: id) ?? (draft?.id == id ? draft : nil)
        }
    }

    var body: some View {
        // Filter and group once per update; rows below skip re-rendering unless their note changed.
        let listing = NoteLibraryListing(notes: controller.notes, today: todayNote, search: search, filter: filter, limit: displayLimit)
        HStack(spacing: 0) {
            library(listing).frame(minWidth: 250, idealWidth: 280, maxWidth: 300)
            Rectangle().fill(FlowTheme.line).frame(width: 1)
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FlowTheme.surface)
        }
        .background(keyboardActions)
        .onChange(of: search) { _, _ in displayLimit = 60 }
        .onChange(of: filter) { _, _ in displayLimit = 60 }
        .onChange(of: controller.workspaceSection) { _, section in
            if section != .notes { searchFocused = false }
        }
        .onChange(of: controller.noteFocus) { _, focus in applyFocus(focus) }
        .onAppear { applyFocus(controller.noteFocus) }
        .alert("Delete this note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.isDailyNote == true
                 ? "This removes every dictation, screenshot, and entry from this day. Linked meetings are kept."
                 : "This permanently removes the note from this Mac.")
        }
    }

    @ViewBuilder private var editor: some View {
        switch selection {
        case .today:
            DayNoteView(controller: controller, date: Date(), noteID: todayNote?.id) { pendingDelete = $0 }
                .id("today-\(todayNote?.id.uuidString ?? "empty")")
        case let .note(id):
            if let note = selectedNote {
                if note.isDailyNote {
                    DayNoteView(controller: controller, date: note.createdAt, noteID: note.id) { pendingDelete = $0 }.id(id)
                } else {
                    NoteEditorView(note: note, controller: controller, focusOnOpen: draft?.id == note.id) {
                        delete(note)
                    }.id(id)
                }
            } else {
                emptyEditor
            }
        }
    }

    // MARK: - Library

    private func library(_ listing: NoteLibraryListing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes").font(.system(size: 21, weight: .semibold)).tracking(-0.4)
                Spacer()
                FlowIconButton(symbol: "square.and.pencil", help: "New note (⌘N)", size: 30, action: newNote)
            }.padding(.horizontal, 18).padding(.top, 28).padding(.bottom, 14)
            FlowSearchField(text: $search, prompt: "Search notes and screenshots", focus: $searchFocused)
                .padding(.horizontal, 16).padding(.bottom, 10)
            HStack {
                FlowTabs(items: NoteFilter.allCases.map { ($0, $0.title) }, selection: $filter)
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).padding(.bottom, 12)
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if search.isEmpty && filter != .written {
                        TodayRow(note: listing.today, selected: selection == .today) { open(.today) }
                            .equatable()
                            .padding(.top, 10)
                    }
                    if let draft, controller.store.note(withID: draft.id) == nil {
                        sectionLabel("Draft")
                        NoteListRow(note: draft, selected: selection == .note(draft.id)) { open(.note(draft.id)) }
                            .equatable()
                    }
                    ForEach(listing.groups, id: \.title) { group in
                        sectionLabel(group.title)
                        ForEach(group.notes) { note in
                            NoteListRow(note: note, selected: selection == .note(note.id)) { open(.note(note.id)) }
                                .equatable()
                                .contextMenu {
                                    Button("Copy text") { FlowFormat.copy(note.isDailyNote ? DayNoteExport.markdown(note) : note.displayText); controller.flash("Copied to clipboard") }
                                    Button(note.isPinned ? "Unpin" : "Pin") { controller.togglePin(note) }
                                    Divider()
                                    Button("Delete…", role: .destructive) { pendingDelete = note }
                                }
                        }
                    }
                    if listing.filtered.isEmpty && draft == nil && !(search.isEmpty && filter != .written) {
                        emptyLibrary
                    }
                    if displayLimit < listing.filtered.count {
                        Button("Show older notes") { displayLimit += 60 }.buttonStyle(.flowGhost)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 20)
            }
        }.background(FlowTheme.background)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 7) {
            Text(search.isEmpty ? "No written notes yet" : "No matching notes")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(FlowTheme.inkMuted)
            Text(search.isEmpty ? "Press ⌘N to write one." : "Try a different word.")
                .font(.system(size: 12)).foregroundStyle(FlowTheme.inkFaint)
            if !search.isEmpty { Button("Clear search") { search = "" }.buttonStyle(.flowGhost) }
        }.frame(maxWidth: .infinity).padding(.vertical, 35)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
            .foregroundStyle(FlowTheme.inkFaint).padding(.leading, 10).padding(.top, 16).padding(.bottom, 4)
    }

    private var emptyEditor: some View {
        FlowEmptyState(symbol: "text.alignleft", title: "Nothing selected", message: "Pick a note, or go back to today.") {
            Button("Today") { open(.today) }.buttonStyle(.flowPrimary)
        }
    }

    private var keyboardActions: some View {
        ZStack {
            Button("New note", action: newNote).keyboardShortcut("n", modifiers: .command)
            Button("Search notes") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("Today") { open(.today) }.keyboardShortcut("t", modifiers: .command)
        }.disabled(!isVisible).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    // MARK: - Actions

    private func applyFocus(_ focus: NoteFocus?) {
        guard let focus else { return }
        search = ""
        switch focus.target {
        case .today: open(.today)
        case let .note(id): open(.note(id))
        }
        controller.noteFocus = nil
    }

    private func newNote() {
        controller.workspaceSection = .notes
        search = ""; searchFocused = false
        if filter == .days { filter = .all }
        let note = controller.addManualNote()
        draft = note
        selection = .note(note.id)
    }

    private func open(_ target: NoteSelection) {
        if let current = draft, target != .note(current.id) { draft = nil }
        selection = target
    }

    private func delete(_ note: VoiceNote) {
        controller.deleteNote(note)
        if draft?.id == note.id { draft = nil }
        if selection == .note(note.id) { selection = .today }
        controller.flash(note.isDailyNote ? "Day deleted" : "Note deleted")
    }

    static func groupTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day, days < 7 {
            return "Previous 7 days"
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

enum NoteFilter: String, CaseIterable, Identifiable {
    case all, days, written
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .days: return "Days"
        case .written: return "Written"
        }
    }

    func includes(_ note: VoiceNote) -> Bool {
        switch self {
        case .all: return true
        case .days: return note.isDailyNote
        case .written: return !note.isDailyNote
        }
    }
}

/// The library's filtered, grouped notes, computed in one pass.
struct NoteLibraryListing {
    let today: VoiceNote?
    let filtered: [VoiceNote]
    let groups: [(title: String, notes: [VoiceNote])]

    init(notes: [VoiceNote], today: VoiceNote?, search: String, filter: NoteFilter, limit: Int) {
        self.today = today
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let todayID = today?.id
        var pinned: [VoiceNote] = [], others: [VoiceNote] = []
        for note in notes where filter.includes(note) {
            if query.isEmpty {
                // Today has its own row unless the user is searching.
                if note.id == todayID { continue }
            } else {
                guard note.title.localizedCaseInsensitiveContains(query)
                    || note.displayText.localizedCaseInsensitiveContains(query)
                    || (note.captures?.contains { $0.matches(query) } ?? false) else { continue }
            }
            if note.isPinned { pinned.append(note) } else { others.append(note) }
        }
        filtered = pinned + others
        var groups: [(title: String, notes: [VoiceNote])] = []
        var titles: [Date: String] = [:]
        let calendar = Calendar.current
        for note in filtered.prefix(limit) {
            let title: String
            if note.isPinned { title = "Pinned" } else {
                let day = calendar.startOfDay(for: note.lastCapturedAt)
                if let known = titles[day] { title = known } else { title = NotesView.groupTitle(day); titles[day] = title }
            }
            if groups.last?.title == title { groups[groups.count - 1].notes.append(note) }
            else { groups.append((title, [note])) }
        }
        self.groups = groups
    }
}

// MARK: - Rows

private struct TodayRow: View, Equatable {
    let note: VoiceNote?
    let selected: Bool
    let onOpen: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.selected == rhs.selected && lhs.note == rhs.note }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "sun.max").font(.system(size: 13, weight: .semibold)).foregroundStyle(FlowTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(FlowTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today").font(.system(size: 13, weight: .semibold)).foregroundStyle(FlowTheme.ink)
                    Text(note.map { EntryCounts($0).summary } ?? Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.system(size: 11)).foregroundStyle(FlowTheme.inkFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(selected ? FlowTheme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .flowHoverHighlight(radius: 9)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Counts of each kind of entry in a day, for compact summaries.
struct EntryCounts {
    var dictations = 0, screenshots = 0, meetings = 0, written = 0

    init(_ note: VoiceNote) {
        for capture in note.visibleCaptures {
            switch capture.entryKind {
            case .dictation: dictations += 1
            case .screenshot: screenshots += 1
            case .meeting: meetings += 1
            case .text: written += 1
            }
        }
    }

    var summary: String {
        var parts: [String] = []
        if dictations > 0 { parts.append("\(dictations) dictation\(dictations == 1 ? "" : "s")") }
        if meetings > 0 { parts.append("\(meetings) meeting\(meetings == 1 ? "" : "s")") }
        if screenshots > 0 { parts.append("\(screenshots) screenshot\(screenshots == 1 ? "" : "s")") }
        if written > 0 { parts.append("\(written) written") }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: " · ")
    }

    var symbols: [(symbol: String, count: Int)] {
        [(CaptureKind.dictation.symbol, dictations), (CaptureKind.meeting.symbol, meetings),
         (CaptureKind.screenshot.symbol, screenshots), (CaptureKind.text.symbol, written)].filter { $0.count > 0 }
    }
}

private struct NoteListRow: View, Equatable {
    let note: VoiceNote
    let selected: Bool
    let onOpen: () -> Void
    @State private var hovering = false
    private let title: String
    private let preview: String
    private let symbols: [(symbol: String, count: Int)]

    init(note: VoiceNote, selected: Bool, onOpen: @escaping () -> Void) {
        self.note = note
        self.selected = selected
        self.onOpen = onOpen
        if note.isDailyNote {
            let counts = EntryCounts(note)
            title = note.createdAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            let text = note.latestText
            preview = Self.clipped(text.isEmpty ? counts.summary : text)
            symbols = counts.symbols
        } else {
            title = note.displayTitle
            preview = note.displayText.isEmpty ? "Start writing…" : Self.clipped(note.displayText)
            symbols = []
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.selected == rhs.selected && lhs.note == rhs.note }

    /// Two preview lines never need more than this; long notes would otherwise be laid out in full.
    private static func clipped(_ text: String) -> String {
        text.count > 280 ? String(text.prefix(280)) : text
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if note.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(FlowTheme.accent) }
                }.foregroundStyle(FlowTheme.ink)
                Text(preview).font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted).lineSpacing(2).lineLimit(2)
                HStack(spacing: 8) {
                    if note.isDailyNote {
                        ForEach(symbols, id: \.symbol) { item in
                            HStack(spacing: 3) {
                                Image(systemName: item.symbol).font(.system(size: 9))
                                Text("\(item.count)").monospacedDigit()
                            }
                        }
                    } else {
                        Image(systemName: "text.alignleft").font(.system(size: 9))
                        Text(note.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }.font(.system(size: 10.5)).foregroundStyle(FlowTheme.inkFaint)
            }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(selected ? FlowTheme.surfaceHover : hovering ? FlowTheme.surfaceMuted : .clear,
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .leading) {
                    if selected { RoundedRectangle(cornerRadius: 2).fill(FlowTheme.accent).frame(width: 3).padding(.vertical, 12) }
                }.contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Written note editor

struct NoteEditorView: View {
    @ObservedObject var controller: AppController
    let focusOnOpen: Bool
    let onDelete: () -> Void
    @State private var note: VoiceNote
    @State private var lastSaved: VoiceNote?
    @State private var showOriginal = false
    @State private var showCorrection = false
    @State private var showDelete = false
    @State private var deleted = false
    @State private var saveFailed = false
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var editorFocused: Bool

    init(note: VoiceNote, controller: AppController, focusOnOpen: Bool = false, onDelete: @escaping () -> Void) {
        self.controller = controller; self.focusOnOpen = focusOnOpen; self.onDelete = onDelete
        _note = State(initialValue: note)
        _lastSaved = State(initialValue: controller.store.note(withID: note.id))
    }
    private var wordCount: Int { note.displayText.split(whereSeparator: \.isWhitespace).count }
    private var hasOriginal: Bool { !note.rawText.isEmpty && note.rawText != note.displayText }
    private var saveLabel: String {
        if saveFailed { return "Couldn’t save" }
        if lastSaved == nil && !note.hasContent { return "Draft" }
        return note == lastSaved ? "Saved" : "Saving…"
    }
    private var bodyText: Binding<String> {
        Binding(get: { note.displayText }, set: { note.editedText = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(note.createdAt.formatted(.dateTime.month(.wide).day().year().hour().minute()))
                    .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint).padding(.bottom, 14)
                TextField("Untitled note", text: $note.title, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 28, weight: .semibold)).tracking(-0.7)
                    .lineLimit(1...3).accessibilityLabel("Note title").padding(.bottom, 18)
                if hasOriginal || showOriginal {
                    Picker("Transcript version", selection: $showOriginal) {
                        Text("Note").tag(false); Text("Original").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 145).padding(.bottom, 16)
                }
                if showOriginal {
                    ScrollView {
                        Text(note.rawText).font(.system(size: 15)).lineSpacing(7).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: bodyText).font(.system(size: 15)).lineSpacing(7)
                            .scrollContentBackground(.hidden).focused($editorFocused)
                            .accessibilityLabel("Note text")
                            .padding(.horizontal, -5)
                        if note.displayText.isEmpty {
                            Text("Start writing…")
                                .font(.system(size: 15)).foregroundStyle(FlowTheme.inkFaint)
                                .padding(.top, 1).allowsHitTesting(false)
                        }
                    }
                }
            }.padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 16)
                .frame(maxWidth: 780, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if showOriginal { Label("Original transcript · read only", systemImage: "lock").font(.system(size: 11)) }
                Spacer()
                Text("\(wordCount) \(wordCount == 1 ? "word" : "words")").font(.system(size: 11)).monospacedDigit()
            }.foregroundStyle(FlowTheme.inkFaint).padding(.horizontal, 36).padding(.bottom, 18)
        }
        .onChange(of: note) { _, _ in scheduleSave() }
        .onChange(of: controller.workspaceSection) { _, section in
            if section != .notes { persist(); editorFocused = false }
        }
        .onChange(of: controller.store.note(withID: note.id)) { _, stored in synchronize(stored) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in persist() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in persist() }
        .task {
            guard focusOnOpen else { return }
            // Focus after the editor has entered the native view hierarchy.
            await Task.yield()
            editorFocused = true
        }
        .onDisappear { saveTask?.cancel(); persist() }
        .alert("Delete this note?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) { deleted = true; saveTask?.cancel(); onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes the note from this Mac.") }
        .sheet(isPresented: $showCorrection) { CorrectionEditor(controller: controller, isPresented: $showCorrection) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(saveLabel).font(.system(size: 11)).foregroundStyle(saveFailed ? FlowTheme.warning : FlowTheme.inkFaint)
            if saveFailed {
                Button("Retry saving") { persist() }.buttonStyle(.flow(.ghost, size: .small))
            }
            Spacer()
            FlowIconButton(symbol: note.isPinned ? "pin.fill" : "pin", help: note.isPinned ? "Unpin note" : "Pin note",
                           tint: note.isPinned ? FlowTheme.accent : FlowTheme.inkMuted) { note.isPinned.toggle() }
            FlowIconButton(symbol: "doc.on.doc", help: "Copy note") {
                FlowFormat.copy(showOriginal ? note.rawText : note.displayText); controller.flash("Copied to clipboard")
            }.disabled((showOriginal ? note.rawText : note.displayText).isEmpty)
            Menu {
                Button("Export as text…", action: exportNote)
                Button("Teach a correction…") { showCorrection = true }
                Divider()
                Button("Delete note…", role: .destructive) { showDelete = true }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Note actions")
        }.padding(.horizontal, 20).frame(height: 52)
    }

    private func synchronize(_ stored: VoiceNote?) {
        guard let stored, stored != lastSaved else { return }
        if note == lastSaved { note = stored }
        else {
            note = note.mergingNewCaptures(from: stored)
            if note.isPinned == lastSaved?.isPinned { note.isPinned = stored.isPinned }
        }
        lastSaved = stored
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            persist()
        }
    }
    private func persist() {
        guard !deleted, note != lastSaved, lastSaved != nil || note.hasContent else { return }
        guard lastSaved == nil || controller.store.note(withID: note.id) != nil else { return }
        saveFailed = !controller.updateNote(note)
        if !saveFailed, let saved = controller.store.note(withID: note.id) {
            note = saved
            lastSaved = saved
        }
    }
    private func exportNote() {
        persist()
        let text = showOriginal ? note.rawText : note.displayText
        NoteExporter.save(text, suggestedName: note.displayTitle, controller: controller)
    }
}

enum NoteExporter {
    @MainActor
    static func save(_ text: String, suggestedName: String, type: UTType = .plainText, controller: AppController) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let ext = type == .plainText ? "txt" : "md"
        panel.nameFieldStringValue = String(suggestedName.prefix(80)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            controller.flash("Exported")
        } catch { controller.report(error) }
    }
}

struct CorrectionEditor: View {
    @ObservedObject var controller: AppController
    @Binding var isPresented: Bool
    var heard = ""
    @State private var correctionHeard = ""
    @State private var correctionReplacement = ""
    @State private var correctionFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Teach a correction").font(.system(size: 22, weight: .semibold))
            Text("OpenScribe will remember this replacement for future dictations.").font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted)
            VStack(alignment: .leading, spacing: 7) {
                Text("Usually transcribed as").font(.system(size: 12, weight: .medium))
                TextField("Word or phrase", text: $correctionHeard).flowField()
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Replace with").font(.system(size: 12, weight: .medium))
                TextField("Correct spelling", text: $correctionReplacement).flowField()
            }
            if let correctionFailure { Text(correctionFailure).font(.system(size: 12)).foregroundStyle(FlowTheme.warning) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.buttonStyle(.flowSecondary).keyboardShortcut(.cancelAction)
                Button("Save correction") {
                    let heard = correctionHeard.trimmingCharacters(in: .whitespacesAndNewlines)
                    let saved = controller.updateSettings {
                        $0.correctionRules.removeAll { $0.heard.caseInsensitiveCompare(heard) == .orderedSame }
                        $0.correctionRules.append(CorrectionRule(heard: heard, replacement: correctionReplacement.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    guard saved else { correctionFailure = "Couldn’t save the correction. Check local storage and try again."; return }
                    isPresented = false
                    controller.flash("Correction saved")
                }.buttonStyle(.flowPrimary).keyboardShortcut(.defaultAction)
                    .disabled(correctionHeard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || correctionReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28).frame(width: 420).background(FlowTheme.background)
        .onAppear { correctionHeard = heard }
    }
}
