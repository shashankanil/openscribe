import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One day as a timeline: dictations, screenshots, meetings, and written entries in the order they happened.
struct DayNoteView: View {
    @ObservedObject var controller: AppController
    let date: Date
    let noteID: UUID?
    let onDelete: (VoiceNote) -> Void
    @State private var composer = ""
    @FocusState private var composerFocused: Bool

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    var body: some View {
        // Look the day up once per update; rows only re-render when their own entry changes.
        let note = noteID.flatMap { controller.store.note(withID: $0) }
        let entries = note?.visibleCaptures ?? []
        let lastID = entries.last?.id
        VStack(spacing: 0) {
            toolbar(note)
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header.padding(.bottom, 22)
                        if isToday { quickActions.padding(.bottom, 26) }
                        if entries.isEmpty {
                            emptyDay
                        } else {
                            ForEach(entries) { entry in
                                DayEntryRow(controller: controller, noteID: noteID ?? UUID(), entry: entry,
                                            isLast: entry.id == lastID)
                                    .equatable()
                                    .id(entry.id)
                            }
                        }
                        composerField.id("composer").padding(.top, entries.isEmpty ? 8 : 4)
                    }
                    .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 40)
                    .frame(maxWidth: 780, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: entries.count) { old, new in
                    guard new > old, let lastID else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Header

    private func toolbar(_ note: VoiceNote?) -> some View {
        HStack(spacing: 8) {
            if let note {
                Text(EntryCounts(note).summary).font(.system(size: 11)).foregroundStyle(FlowTheme.inkFaint)
            }
            Spacer()
            if let note {
                FlowIconButton(symbol: note.isPinned ? "pin.fill" : "pin", help: note.isPinned ? "Unpin day" : "Pin day",
                               tint: note.isPinned ? FlowTheme.accent : FlowTheme.inkMuted) { controller.togglePin(note) }
                FlowIconButton(symbol: "doc.on.doc", help: "Copy day as text") {
                    FlowFormat.copy(DayNoteExport.markdown(note)); controller.flash("Copied to clipboard")
                }
                Menu {
                    Button("Export as Markdown…") {
                        NoteExporter.save(DayNoteExport.markdown(note), suggestedName: AppStore.dayTitle(note.createdAt),
                                          type: UTType(filenameExtension: "md") ?? .plainText, controller: controller)
                    }
                    Divider()
                    Button("Delete this day…", role: .destructive) { onDelete(note) }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Day actions")
            }
        }.padding(.horizontal, 20).frame(height: 52)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isToday ? "TODAY" : date.formatted(.dateTime.year()))
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.9).foregroundStyle(FlowTheme.accent)
            Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.system(size: 28, weight: .semibold)).tracking(-0.7)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            QuickAction(symbol: "mic.fill", title: "Dictate", shortcut: controller.settings.dictationHint) {
                controller.startCapture()
            }.disabled(controller.isDictationBusy || controller.meetings.occupiesCapture || !controller.setupReadiness.canDictate)
            QuickAction(symbol: "person.2.wave.2.fill", title: controller.meetings.activeID == nil ? "Meeting" : "Open meeting",
                        shortcut: controller.settings.shortcut(for: .meeting)?.display) {
                if let active = controller.meetings.activeID { controller.openMeeting(active) } else { controller.startMeeting() }
            }.disabled(controller.meetings.activeID == nil && !controller.canStartMeeting)
            Menu {
                ForEach(ScreenshotKind.allCases, id: \.self) { kind in
                    Button(kind.title + (controller.settings.shortcut(for: kind.action).map { "  \($0.display)" } ?? "")) {
                        controller.takeScreenshot(kind)
                    }
                }
            } label: {
                Label("Screenshot", systemImage: "camera.viewfinder")
            }
            .menuStyle(.button).buttonStyle(.flow(.secondary, size: .small)).fixedSize()
            .disabled(controller.screenshotInProgress)
            Spacer(minLength: 0)
        }
    }

    private var emptyDay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isToday ? "Your day starts here" : "Nothing was captured this day")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(FlowTheme.inkMuted)
            Text(isToday ? "Dictations, screenshots, and meetings land here as they happen. Or write below."
                         : "Write something below to add it to this day.")
                .font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkFaint)
        }.padding(.bottom, 18)
    }

    private var composerField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(FlowTheme.inkFaint)
                .frame(width: 52, alignment: .trailing)
            TextField(isToday ? "Write a thought… (⏎ to add)" : "Add to this day…", text: $composer, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14.5)).lineSpacing(5).lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(addEntry)
                .accessibilityLabel("New entry")
        }
        .padding(.vertical, 10)
    }

    private func addEntry() {
        guard controller.addDayEntry(composer, on: date) != nil else { return }
        composer = ""
        composerFocused = true
    }
}

private struct QuickAction: View {
    let symbol: String
    let title: String
    let shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.flow(.secondary, size: .small))
            .help(shortcut.map { "\(title)  \($0)" } ?? title)
    }
}

// MARK: - Entries

/// Not observing the controller: a row redraws only when its entry changes, not on every app update.
private struct DayEntryRow: View, Equatable {
    let controller: AppController
    let noteID: UUID
    let entry: NoteCapture
    let isLast: Bool
    @State private var hovering = false
    @State private var showOriginal = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(FlowTheme.inkFaint)
                    .padding(.top, 3)
            }.frame(width: 52, alignment: .trailing)
            VStack(spacing: 0) {
                Image(systemName: entry.entryKind.symbol).font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(entry.entryKind == .meeting ? FlowTheme.recording : FlowTheme.accent)
                    .frame(width: 22, height: 22)
                    .background((entry.entryKind == .meeting ? FlowTheme.recording : FlowTheme.accent).opacity(0.11), in: Circle())
                if !isLast {
                    Rectangle().fill(FlowTheme.line).frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                content
                meta
            }
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onHover { hovering = $0 }
        .contextMenu { actions }
        .alert("Delete this entry?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { controller.removeCapture(entry.id, from: noteID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(entry.entryKind == .meeting ? "The meeting itself is kept in Meetings." : "This can’t be undone.")
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.noteID == rhs.noteID && lhs.isLast == rhs.isLast && lhs.entry == rhs.entry
    }

    @ViewBuilder private var content: some View {
        switch entry.entryKind {
        case .dictation, .text:
            if showOriginal {
                Text(entry.rawText).font(.system(size: 14.5)).lineSpacing(5).foregroundStyle(FlowTheme.inkMuted)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                EntryTextEditor(controller: controller, noteID: noteID, entry: entry)
            }
        case .screenshot:
            if let name = entry.attachment {
                ScreenshotThumbnail(url: controller.store.attachmentURL(name))
            }
        case .meeting:
            MeetingEntryCard(controller: controller, meetings: controller.meetings, entry: entry)
        }
    }

    private var meta: some View {
        HStack(spacing: 8) {
            Text(metaText).lineLimit(1)
            if hovering {
                HStack(spacing: 2) {
                    if canShowOriginal {
                        Button(showOriginal ? "Edited" : "Original") { showOriginal.toggle() }
                            .buttonStyle(.plain).foregroundStyle(FlowTheme.accent)
                            .help(showOriginal ? "Show your edited text" : "Show the original transcript")
                            .padding(.trailing, 6)
                    }
                    FlowIconButton(symbol: "doc.on.doc", help: "Copy", size: 22, action: copy)
                    FlowIconButton(symbol: "trash", help: "Delete entry", size: 22) { confirmDelete = true }
                }.transition(.opacity)
            }
        }
        .font(.system(size: 11)).foregroundStyle(FlowTheme.inkFaint)
        .frame(height: 22)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var canShowOriginal: Bool {
        (entry.entryKind == .dictation || entry.entryKind == .text) && !entry.rawText.isEmpty && entry.rawText != entry.text
    }

    private var metaText: String {
        switch entry.entryKind {
        case .dictation:
            let source = entry.sourceApplication.flatMap { $0.isEmpty ? nil : $0 } ?? "Dictation"
            return entry.duration > 0 ? "\(source) · \(FlowFormat.duration(entry.duration))" : source
        case .text: return "Written"
        case .screenshot:
            let found = entry.recognizedText == nil ? "" : " · text searchable"
            return "Screenshot" + (entry.sourceApplication.map { " · \($0)" } ?? "") + found
        case .meeting: return "Meeting"
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Copy", action: copy)
        if entry.entryKind == .screenshot, let name = entry.attachment {
            let url = controller.store.attachmentURL(name)
            Button("Open in Preview") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if let text = entry.recognizedText {
                Button("Copy text in image") { FlowFormat.copy(text); controller.flash("Copied to clipboard") }
            }
        }
        if entry.entryKind == .meeting, let id = entry.meetingID {
            Button("Open meeting") { controller.openMeeting(id) }
        }
        Divider()
        Button("Delete entry…", role: .destructive) { confirmDelete = true }
    }

    private func copy() {
        switch entry.entryKind {
        case .screenshot:
            guard let name = entry.attachment, let image = NSImage(contentsOf: controller.store.attachmentURL(name)) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        case .meeting:
            let record = entry.meetingID.flatMap { controller.meetings.store.record($0) }
            FlowFormat.copy(record?.markdown ?? entry.title)
        case .dictation, .text:
            FlowFormat.copy(showOriginal ? entry.rawText : entry.text)
        }
        controller.flash("Copied to clipboard")
    }
}

/// Shows an entry as plain text and turns into an editor when clicked, saving shortly after typing stops.
/// Live text fields for every entry made long days slow to scroll.
private struct EntryTextEditor: View {
    let controller: AppController
    let noteID: UUID
    let entry: NoteCapture
    @State private var text: String
    @State private var editing = false
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(controller: AppController, noteID: UUID, entry: NoteCapture) {
        self.controller = controller
        self.noteID = noteID
        self.entry = entry
        _text = State(initialValue: entry.text)
    }

    var body: some View {
        Group {
            if editing {
                TextField("Empty", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14.5)).lineSpacing(5)
                    .focused($focused)
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .onChange(of: text) { _, _ in scheduleSave() }
                    .onChange(of: focused) { _, isFocused in
                        guard !isFocused else { return }
                        save()
                        editing = false
                    }
                    .onDisappear { saveTask?.cancel(); save() }
            } else {
                Text(text.isEmpty ? "Empty" : text)
                    .font(.system(size: 14.5)).lineSpacing(5)
                    .foregroundStyle(text.isEmpty ? FlowTheme.inkFaint : FlowTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Edit")
            }
        }
        .onChange(of: entry.text) { _, stored in if !editing && stored != text { text = stored } }
        .accessibilityLabel("Entry text")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
            save()
        }
    }

    private func save() {
        guard text != entry.text, var current = controller.store.note(withID: noteID)?.captures?.first(where: { $0.id == entry.id }) else { return }
        current.text = text
        if !controller.updateCapture(current, in: noteID) { controller.flash("Couldn’t save this entry") }
    }
}

struct ScreenshotThumbnail: View {
    let url: URL
    var maxSize = CGSize(width: 520, height: 300)
    @State private var image: NSImage?
    @State private var missing = false
    @State private var hovering = false
    /// Decoded thumbnails survive rows scrolling out of the lazy timeline and back.
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 60
        return cache
    }()

    init(url: URL, maxSize: CGSize = CGSize(width: 520, height: 300)) {
        self.url = url
        self.maxSize = maxSize
        _image = State(initialValue: Self.cache.object(forKey: url as NSURL))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxSize.width, maxHeight: maxSize.height, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
                    .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: hovering ? 8 : 0, y: 2)
                    .onHover { hovering = $0 }
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    .help("Double-click to open in Preview")
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            } else if missing {
                Label("Image file is missing", systemImage: "photo.badge.exclamationmark")
                    .font(.system(size: 12)).foregroundStyle(FlowTheme.inkFaint)
            } else {
                RoundedRectangle(cornerRadius: 9).fill(FlowTheme.surfaceMuted).frame(width: min(240, maxSize.width), height: min(140, maxSize.height))
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            let loaded = await Self.thumbnail(url)
            if let loaded { Self.cache.setObject(loaded, forKey: url as NSURL) }
            image = loaded
            missing = loaded == nil
        }
    }

    /// Screenshots can be large. Decode a downsampled copy off the main thread.
    private static func thumbnail(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 1400,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
        }.value
    }
}

private struct MeetingEntryCard: View {
    let controller: AppController
    @ObservedObject var meetings: MeetingController
    let entry: NoteCapture

    private var record: MeetingRecord? { entry.meetingID.flatMap { meetings.store.record($0) } }
    private var isActive: Bool { entry.meetingID != nil && meetings.activeID == entry.meetingID }

    var body: some View {
        if let record {
            Button { controller.openMeeting(record.id) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(record.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        FlowBadge(text: isActive ? (meetings.isPaused ? "Paused" : "Recording") : record.status.label,
                                  color: isActive ? FlowTheme.recording : record.status.color, pulsing: isActive && meetings.isRecording)
                    }
                    if let summary = record.summary {
                        if let first = summary.overview.first {
                            Text(first.text).font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkMuted).lineLimit(2)
                        }
                        if !summary.actions.isEmpty {
                            Label("\(summary.actions.count) action item\(summary.actions.count == 1 ? "" : "s")", systemImage: "checklist")
                                .font(.system(size: 11.5)).foregroundStyle(FlowTheme.accent)
                        }
                    } else if let notes = record.userNotes, !notes.isEmpty {
                        Text(notes).font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkMuted).lineLimit(2)
                    }
                    Text(isActive ? "Open meeting notes" : FlowFormat.duration(record.duration))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(FlowTheme.inkFaint)
                }
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(maxWidth: 520, alignment: .leading)
                .background(FlowTheme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .flowHoverHighlight(radius: 10)
        } else {
            Text("\(entry.title.isEmpty ? "Meeting" : entry.title) · removed")
                .font(.system(size: 13)).foregroundStyle(FlowTheme.inkFaint)
        }
    }
}

enum DayNoteExport {
    static func markdown(_ note: VoiceNote) -> String {
        var lines = ["# \(note.createdAt.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))", ""]
        for entry in note.visibleCaptures {
            let time = entry.createdAt.formatted(date: .omitted, time: .shortened)
            switch entry.entryKind {
            case .dictation, .text:
                guard !entry.text.isEmpty else { continue }
                lines += ["**\(time)**", entry.text, ""]
            case .screenshot:
                lines += ["**\(time)** · Screenshot" + (entry.attachment.map { " (\($0))" } ?? ""), ""]
            case .meeting:
                lines += ["**\(time)** · Meeting: \(entry.title)", ""]
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
