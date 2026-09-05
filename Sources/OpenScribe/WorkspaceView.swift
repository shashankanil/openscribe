import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @ObservedObject var controller: AppController
    @State private var search = ""
    @State private var filter: NoteFilter = .all
    @State private var displayLimit = 20
    @State private var editingNote: VoiceNote?

    private let pageSize = 20

    private var visibleNotes: [VoiceNote] {
        controller.notes.filter { note in
            let matchesFilter = filter == .all || (filter == .pinned && note.isPinned)
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || note.title.localizedCaseInsensitiveContains(query)
                || note.displayText.localizedCaseInsensitiveContains(query)
                || note.sourceLabel.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesSearch
        }
    }

    private var loadedNotes: [VoiceNote] {
        Array(visibleNotes.prefix(displayLimit))
    }

    var body: some View {
        Group {
            if let editingNote {
                NoteDetailView(note: editingNote, controller: controller) { self.editingNote = nil }
                    .id(editingNote.id)
            } else {
                feed
            }
        }
    }

    private var feed: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            feedControls
            Divider().overlay(FlowTheme.line)

            if visibleNotes.isEmpty {
                emptyFeed
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(loadedNotes) { note in
                            PlainNoteRow(
                                note: note,
                                onEdit: { editingNote = note },
                                onPin: { controller.togglePin(note) }
                            )
                            if note.id != loadedNotes.last?.id {
                                Divider().overlay(FlowTheme.line.opacity(0.8))
                            }
                        }

                        if loadedNotes.count < visibleNotes.count {
                            VStack(spacing: 8) {
                                Text("Showing \(loadedNotes.count) of \(visibleNotes.count)")
                                    .flowUIFont(size: 10, weight: .medium)
                                    .foregroundStyle(FlowTheme.inkMuted)
                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        displayLimit += pageSize
                                    }
                                } label: {
                                    Label("Load older notes", systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(FlowQuietButtonStyle())
                                .accessibilityLabel("Load older notes")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }
                    }
                    .padding(.horizontal, 42)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(FlowTheme.paper)
        .tint(FlowTheme.lavenderDeep)
        .onChange(of: search) { _, _ in displayLimit = pageSize }
        .onChange(of: filter) { _, _ in displayLimit = pageSize }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .flowDisplayFont(size: 30)
                    .foregroundStyle(FlowTheme.ink)

            }
            Spacer()
            Text("\(visibleNotes.count) \(visibleNotes.count == 1 ? "note" : "notes")")
                .flowUIFont(size: 11, weight: .semibold)
                .foregroundStyle(FlowTheme.inkMuted)
                .padding(.top, 8)
            Button {
                let note = controller.addManualNote()
                editingNote = note
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FlowTheme.ink)
                    .frame(width: 30, height: 30)
                    .background(FlowTheme.lavender, in: Circle())
                    .overlay(Circle().stroke(FlowTheme.ink, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("New note")
        }
        .padding(.horizontal, 42)
        .padding(.top, 30)
        .padding(.bottom, 22)
    }

    private var feedControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(FlowTheme.inkMuted)
                TextField("Search text or app", text: $search)
                    .textFieldStyle(.plain)
                    .flowUIFont(size: 12)
                    .foregroundStyle(FlowTheme.ink)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(FlowTheme.paperMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
            .frame(maxWidth: 360)

            Picker("Filter", selection: $filter) {
                ForEach(NoteFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 145)

            Spacer()
        }
        .padding(.horizontal, 42)
        .padding(.bottom, 16)
    }

    private var emptyFeed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(FlowTheme.lavenderDeep)
            Text(search.isEmpty ? "Your first thought is one shortcut away." : "No notes match that search.")
                .flowUIFont(size: 13, weight: .semibold)
                .foregroundStyle(FlowTheme.ink)
            Text(search.isEmpty ? "Press \(controller.settings.shortcutDisplay), speak, and your transcript will appear here." : "Try a different word, app, or filter.")
                .flowUIFont(size: 11)
                .foregroundStyle(FlowTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(42)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

enum NoteFilter: String, CaseIterable, Identifiable {
    case all
    case pinned

    var id: String { rawValue }
    var title: String { self == .all ? "All" : "Pinned" }
    var symbol: String { self == .all ? "tray.full" : "pin" }
}

private struct PlainNoteRow: View {
    let note: VoiceNote
    let onEdit: () -> Void
    let onPin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.timestampLabel)
                    .flowUIFont(size: 11, weight: .semibold)
                    .foregroundStyle(FlowTheme.ink)
                Text("·")
                    .foregroundStyle(FlowTheme.inkMuted)
                Text(note.sourceLabel)
                    .flowUIFont(size: 11, weight: .medium)
                    .foregroundStyle(FlowTheme.lavenderDeep)
                    .lineLimit(1)
                    .help(note.sourceBundleIdentifier ?? "")
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(FlowTheme.lavenderDeep)
                }
                Spacer(minLength: 8)
                Button(action: onPin) {
                    Image(systemName: note.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(FlowTheme.inkMuted)
                }
                .buttonStyle(.plain)
                .help(note.isPinned ? "Unpin note" : "Pin note")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.displayText, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).help("Copy note")
                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(FlowTheme.inkMuted)
                }
                .buttonStyle(.plain)
                .help("Edit note")
            }

            Text(note.displayText.isEmpty ? "Empty note" : note.displayText)
                .flowUIFont(size: 16)
                .foregroundStyle(FlowTheme.ink)
                .lineLimit(3)
                .contentShape(Rectangle())
                .onTapGesture(perform: onEdit)

            HStack(spacing: 8) {
                Text(note.duration > 0 ? "Dictation" : "Note")
                if note.duration > 0 {
                    Text("·")
                    Text(formattedDuration(note.duration))
                }
            }
            .flowUIFont(size: 10)
            .foregroundStyle(FlowTheme.inkMuted)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct NoteDetailView: View {
    let onClose: () -> Void
    @ObservedObject var controller: AppController
    @State private var note: VoiceNote
    @State private var showRaw = false
    @State private var saved = false
    @State private var showCorrection = false
    @State private var correctionHeard = ""
    @State private var correctionReplacement = ""
    @State private var exportError: String?
    @State private var deleted = false
    @State private var showDelete = false

    init(note: VoiceNote, controller: AppController, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.controller = controller
        _note = State(initialValue: note)
    }

    private var bodyText: Binding<String> {
        Binding(
            get: { showRaw ? note.rawText : (note.cleanedText.isEmpty ? note.rawText : note.cleanedText) },
            set: { value in
                if !showRaw { note.cleanedText = value }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { onClose() } label: {
                    Label("All notes", systemImage: "chevron.left")
                }.buttonStyle(FlowQuietButtonStyle())
                Spacer()
                Button("Remember correction") { showCorrection.toggle() }.buttonStyle(FlowQuietButtonStyle())
                Button("Export…", action: exportNote).buttonStyle(FlowQuietButtonStyle())
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(showRaw ? note.rawText : note.displayText, forType: .string)
                } label: { Label("Copy text", systemImage: "doc.on.doc") }
                    .buttonStyle(FlowQuietButtonStyle())
            }.padding(.horizontal, 32).padding(.top, 20)

            if showCorrection {
                HStack {
                    TextField("Mistaken phrase", text: $correctionHeard)
                    Image(systemName: "arrow.right")
                    TextField("Correct spelling", text: $correctionReplacement)
                    Button("Remember") {
                        let heard = correctionHeard.trimmingCharacters(in: .whitespacesAndNewlines)
                        let replacement = correctionReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
                        controller.updateSettings {
                            $0.correctionRules.removeAll { $0.heard.caseInsensitiveCompare(heard) == .orderedSame }
                            $0.correctionRules.append(CorrectionRule(heard: heard, replacement: replacement))
                        }
                        showCorrection = false; correctionHeard = ""; correctionReplacement = ""
                    }.disabled(correctionHeard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || correctionReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { showCorrection = false }
                }.textFieldStyle(.roundedBorder).padding(24)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("NOTE")
                        .flowUIFont(size: 10, weight: .semibold)
                        .tracking(1.4)
                        .foregroundStyle(FlowTheme.lavenderDeep)
                    TextField("Untitled note", text: $note.title)
                        .textFieldStyle(.plain)
                        .flowDisplayFont(size: 34)
                        .foregroundStyle(FlowTheme.ink)
                }
                Spacer()
                Button {
                    controller.togglePin(note)
                    note.isPinned.toggle()
                } label: {
                    Image(systemName: note.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(FlowTheme.ink)
                        .frame(width: 34, height: 34)
                        .background(note.isPinned ? FlowTheme.lavender : FlowTheme.paperMuted, in: Circle())
                        .overlay(Circle().stroke(FlowTheme.ink, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    controller.updateNote(note)
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { saved = false }
                } label: {
                    Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "arrow.down")
                }
                .buttonStyle(FlowPrimaryButtonStyle())
            }
            .padding(.horizontal, 42)
            .padding(.top, 35)
            .padding(.bottom, 24)

            HStack(spacing: 8) {
                Text(note.timestampLabel)
                Text("·")
                Text(formattedDuration(note.duration))
                Text("·")
                Text(note.sourceLabel)
                Spacer()
                Picker("Transcript", selection: $showRaw) {
                    Text("Polished").tag(false)
                    Text("Original").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            .flowUIFont(size: 11, weight: .medium)
            .foregroundStyle(FlowTheme.inkMuted)
            .padding(.horizontal, 42)
            .padding(.bottom, 16)

            TextEditor(text: bodyText)
                .disabled(showRaw)
                .flowUIFont(size: 16)
                .foregroundStyle(FlowTheme.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 38)
                .padding(.vertical, 18)
                .background(FlowTheme.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(FlowTheme.ink.opacity(0.14), lineWidth: 1))
                .padding(.horizontal, 28)
                .padding(.bottom, 25)

            HStack {
                Text("Original is read-only. Edits save when you leave.")
                    .flowUIFont(size: 10)
                    .foregroundStyle(FlowTheme.inkMuted)
                Spacer()
                Button("Delete note", role: .destructive) {
                    showDelete = true
                }
                .buttonStyle(FlowQuietButtonStyle())
            }
            .padding(.horizontal, 42)
            .padding(.bottom, 18)
        }
        .background(FlowTheme.paper)
        .onDisappear { if !deleted { controller.updateNote(note) } }
        .alert("Delete this note?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) { deleted = true; controller.deleteNote(note); onClose() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private func exportNote() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = String(note.title.prefix(80)).replacingOccurrences(of: "/", with: "-") + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try (showRaw ? note.rawText : note.displayText).write(to: url, atomically: true, encoding: .utf8) }
        catch { exportError = error.localizedDescription }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "Note" }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
