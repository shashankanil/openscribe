import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotesView: View {
    @ObservedObject var controller: AppController
    @State private var search = ""
    @State private var filter: NoteFilter = .all
    @State private var selectedID: UUID?
    @State private var draft: VoiceNote?
    @State private var pendingDelete: VoiceNote?
    @State private var displayLimit = 50
    @FocusState private var searchFocused: Bool

    private var isVisible: Bool { controller.workspaceSection == .notes }
    private var selectedNote: VoiceNote? {
        if let selectedID {
            return controller.store.note(withID: selectedID) ?? (draft?.id == selectedID ? draft : nil)
        }
        return filteredNotes.first
    }
    private var filteredNotes: [VoiceNote] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = controller.notes.filter {
            (filter == .all || $0.isPinned) && (query.isEmpty
                || $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.displayText.localizedCaseInsensitiveContains(query)
                || $0.sourceLabel.localizedCaseInsensitiveContains(query))
        }
        return notes.filter(\.isPinned) + notes.filter { !$0.isPinned }
    }
    private var groups: [(title: String, notes: [VoiceNote])] {
        var result: [(title: String, notes: [VoiceNote])] = []
        for note in filteredNotes.prefix(displayLimit) {
            let title = note.isPinned && filter == .all ? "Pinned" : Self.dayTitle(note.createdAt)
            if result.last?.title == title { result[result.count - 1].notes.append(note) }
            else { result.append((title, [note])) }
        }
        return result
    }

    var body: some View {
        HStack(spacing: 0) {
            library.frame(minWidth: 245, idealWidth: 275, maxWidth: 290)
            Rectangle().fill(FlowTheme.line).frame(width: 1)
            Group {
                if let note = selectedNote {
                    NoteEditorView(note: note, controller: controller, focusOnOpen: draft?.id == note.id) {
                        delete(note)
                    }.id(note.id)
                } else { emptyEditor }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlowTheme.surface)
        }
        .background(keyboardActions)
        .onChange(of: search) { _, _ in displayLimit = 50 }
        .onChange(of: filter) { _, _ in displayLimit = 50 }
        .onChange(of: controller.workspaceSection) { _, section in
            if section != .notes { searchFocused = false }
        }
        .alert("Delete this note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("This permanently removes the note from this Mac.") }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes").font(.system(size: 21, weight: .semibold)).tracking(-0.4)
                Spacer()
                Button(action: newNote) {
                    Image(systemName: "square.and.pencil").font(.system(size: 16, weight: .medium))
                        .frame(width: 30, height: 30)
                }.buttonStyle(.plain).foregroundStyle(FlowTheme.inkMuted)
                    .help("New note (⌘N)").accessibilityLabel("New note")
            }.padding(.horizontal, 18).padding(.top, 28).padding(.bottom, 16)
            FlowSearchField(text: $search, prompt: "Search notes", focus: $searchFocused)
                .padding(.horizontal, 16).padding(.bottom, 12)
            HStack {
                FlowTabs(items: NoteFilter.allCases.map { ($0, $0.title) }, selection: $filter)
                Spacer()
                Text("\(filteredNotes.count)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(FlowTheme.inkFaint)
            }.padding(.horizontal, 16).padding(.bottom, 12)
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if let draft, controller.store.note(withID: draft.id) == nil {
                        Text("DRAFT").font(.system(size: 10, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(FlowTheme.inkFaint).padding(.leading, 10).padding(.top, 16).padding(.bottom, 3)
                        NoteListRow(note: draft, selected: selectedNote?.id == draft.id) { open(draft.id) }
                    }
                    ForEach(groups, id: \.title) { group in
                        Text(group.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(FlowTheme.inkFaint).padding(.leading, 10).padding(.top, 16).padding(.bottom, 3)
                        ForEach(group.notes) { note in
                            NoteListRow(note: note, selected: selectedNote?.id == note.id) { open(note.id) }
                                .contextMenu {
                                    Button("Copy text") { FlowFormat.copy(note.displayText); controller.flash("Copied to clipboard") }
                                    Button(note.isPinned ? "Unpin" : "Pin") { controller.togglePin(note) }
                                    Divider()
                                    Button("Delete…", role: .destructive) { pendingDelete = note }
                                }
                        }
                    }
                    if filteredNotes.isEmpty && draft == nil {
                        VStack(spacing: 7) {
                            Text(search.isEmpty ? filter == .pinned ? "No pinned notes" : "Your notes live here" : "No matching notes")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(FlowTheme.inkMuted)
                            Text(search.isEmpty ? "Write a note or start a dictation." : "Try a different word.")
                                .font(.system(size: 12)).foregroundStyle(FlowTheme.inkFaint)
                            if !search.isEmpty { Button("Clear search") { search = "" }.buttonStyle(.flowGhost) }
                        }.frame(maxWidth: .infinity).padding(.vertical, 35)
                    }
                    if displayLimit < filteredNotes.count {
                        Button("Show older notes") { displayLimit += 50 }.buttonStyle(.flowGhost)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 20)
            }
        }.background(FlowTheme.background)
    }

    private var emptyEditor: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.alignleft").font(.system(size: 32, weight: .light)).foregroundStyle(FlowTheme.inkFaint)
            VStack(spacing: 7) {
                Text("A place for your thoughts").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                Text("Write freely. Dictate when the words come faster.")
                    .font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted)
            }
            HStack(spacing: 10) {
                Button("New note", action: newNote).buttonStyle(.flowPrimary)
                Button(controller.setupReadiness.canDictate ? "Start dictation" : "Set up dictation") {
                    if controller.setupReadiness.canDictate { controller.startCapture() }
                    else { controller.showOnboarding() }
                }.buttonStyle(.flowSecondary).disabled(controller.isDictationBusy || controller.meetings.occupiesCapture)
            }.padding(.top, 3)
            FlowKeycaps(shortcut: "⌘ N").padding(.top, 10)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var keyboardActions: some View {
        ZStack {
            Button("New note", action: newNote).keyboardShortcut("n", modifiers: .command)
            Button("Search notes") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
        }.disabled(!isVisible).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
    private func newNote() {
        controller.workspaceSection = .notes
        search = ""; filter = .all; searchFocused = false
        let note = controller.addManualNote()
        draft = note; selectedID = note.id
    }
    private func open(_ id: UUID) {
        if let current = draft, current.id != id { draft = nil }
        selectedID = id
    }
    private func delete(_ note: VoiceNote) {
        controller.deleteNote(note)
        if draft?.id == note.id { draft = nil }
        if selectedID == note.id { selectedID = nil }
        controller.flash("Note deleted")
    }
    private static func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

enum NoteFilter: String, CaseIterable, Identifiable {
    case all, pinned
    var id: String { rawValue }
    var title: String { self == .all ? "All notes" : "Pinned" }
}

private struct NoteListRow: View {
    let note: VoiceNote
    let selected: Bool
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(note.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                    if note.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(FlowTheme.accent) }
                }.foregroundStyle(FlowTheme.ink)
                Text(note.displayText.isEmpty ? "Start writing…" : note.displayText)
                    .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted).lineSpacing(2).lineLimit(2)
                HStack(spacing: 5) {
                    Text(note.createdAt.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Image(systemName: note.duration > 0 ? "waveform" : "square.and.pencil").font(.system(size: 9))
                    Text(note.sourceLabel).lineLimit(1)
                }.font(.system(size: 10.5)).foregroundStyle(FlowTheme.inkFaint)
            }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                .padding(.horizontal, 12).padding(.vertical, 13)
                .background(selected ? FlowTheme.surfaceHover : hovering ? FlowTheme.surfaceMuted : .clear,
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .leading) {
                    if selected { RoundedRectangle(cornerRadius: 2).fill(FlowTheme.accent).frame(width: 3).padding(.vertical, 13) }
                }.contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

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
    @State private var correctionHeard = ""
    @State private var correctionReplacement = ""
    @State private var correctionFailure: String?
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
                    .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint).padding(.bottom, 15)
                TextField("Untitled note", text: $note.title, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 28, weight: .semibold)).tracking(-0.7)
                    .lineLimit(1...3).accessibilityLabel("Note title").padding(.bottom, 12)
                HStack(spacing: 7) {
                    Image(systemName: note.duration > 0 ? "waveform" : "square.and.pencil")
                    Text(note.sourceLabel)
                    if note.duration > 0 { Text("·"); Text(FlowFormat.duration(note.duration)).monospacedDigit() }
                    Spacer()
                    if hasOriginal || showOriginal {
                        Picker("Transcript version", selection: $showOriginal) {
                            Text("Note").tag(false); Text("Original").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 145)
                    }
                }.font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted).padding(.bottom, 24)
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
                            Text("Start writing, or capture a thought with your voice.")
                                .font(.system(size: 15)).foregroundStyle(FlowTheme.inkFaint)
                                .padding(.top, 1).allowsHitTesting(false)
                        }
                    }
                }
            }.padding(.horizontal, 32).padding(.top, 27).padding(.bottom, 16)
                .frame(maxWidth: 800, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if showOriginal { Label("Original transcript · read only", systemImage: "lock").font(.system(size: 11)) }
                Spacer()
                Text("\(wordCount) \(wordCount == 1 ? "word" : "words")").font(.system(size: 11)).monospacedDigit()
            }.foregroundStyle(FlowTheme.inkFaint).padding(.horizontal, 32).padding(.bottom, 18)
        }
        .onChange(of: note) { _, _ in scheduleSave() }
        .onChange(of: controller.workspaceSection) { _, section in
            if section != .notes { persist(); editorFocused = false }
        }
        .onChange(of: controller.store.note(withID: note.id)?.isPinned) { _, pinned in
            if let pinned, pinned != note.isPinned { note.isPinned = pinned; lastSaved?.isPinned = pinned }
        }
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
        .sheet(isPresented: $showCorrection) { correctionEditor }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: note.duration > 0 ? "waveform" : "doc.text").font(.system(size: 13)).foregroundStyle(FlowTheme.inkFaint)
            Text(note.duration > 0 ? "Dictation" : "Note").font(.system(size: 12, weight: .medium)).foregroundStyle(FlowTheme.inkMuted)
            Spacer()
            if saveFailed {
                Button("Retry saving") { persist() }.buttonStyle(.flow(.ghost, size: .small))
            }
            Text(saveLabel).font(.system(size: 11)).foregroundStyle(saveFailed ? FlowTheme.warning : FlowTheme.inkFaint)
            Rectangle().fill(FlowTheme.line).frame(width: 1, height: 16).padding(.horizontal, 3)
            FlowIconButton(symbol: note.isPinned ? "pin.fill" : "pin", help: note.isPinned ? "Unpin note" : "Pin note",
                           tint: note.isPinned ? FlowTheme.accent : FlowTheme.inkMuted) { note.isPinned.toggle() }
            FlowIconButton(symbol: "doc.on.doc", help: "Copy note") {
                FlowFormat.copy(showOriginal ? note.rawText : note.displayText); controller.flash("Copied to clipboard")
            }.disabled((showOriginal ? note.rawText : note.displayText).isEmpty)
            Menu {
                Button("Export as text…", action: exportNote)
                Button("Teach a correction…") { correctionFailure = nil; showCorrection = true }
                Divider()
                Button("Delete note…", role: .destructive) { showDelete = true }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Note actions")
        }.padding(.horizontal, 20).frame(height: 68)
    }

    private var correctionEditor: some View {
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
                Button("Cancel") { showCorrection = false }.buttonStyle(.flowSecondary).keyboardShortcut(.cancelAction)
                Button("Save correction") {
                    let heard = correctionHeard.trimmingCharacters(in: .whitespacesAndNewlines)
                    let saved = controller.updateSettings {
                        $0.correctionRules.removeAll { $0.heard.caseInsensitiveCompare(heard) == .orderedSame }
                        $0.correctionRules.append(CorrectionRule(heard: heard, replacement: correctionReplacement.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    guard saved else { correctionFailure = "Couldn’t save the correction. Check local storage and try again."; return }
                    correctionHeard = ""; correctionReplacement = ""; showCorrection = false
                    controller.flash("Correction saved")
                }.buttonStyle(.flowPrimary).keyboardShortcut(.defaultAction)
                    .disabled(correctionHeard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || correctionReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 420).background(FlowTheme.background)
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
        if !saveFailed { lastSaved = note }
    }
    private func exportNote() {
        persist()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = String(note.displayTitle.prefix(80)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (showOriginal ? note.rawText : note.displayText).write(to: url, atomically: true, encoding: .utf8)
            controller.flash("Exported")
        } catch { controller.report(error) }
    }
}
