import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

extension MeetingStatus {
    var label: String {
        switch self {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .saved: return "Not transcribed"
        case .transcribing: return "Transcribing"
        case .summarizing: return "Summarizing"
        case .ready: return "Ready"
        case .interrupted: return "Interrupted"
        case .failed: return "Needs attention"
        }
    }

    var color: Color {
        switch self {
        case .recording: return FlowTheme.recording
        case .paused, .interrupted, .failed: return FlowTheme.warning
        case .saved: return FlowTheme.inkMuted
        case .transcribing, .summarizing: return FlowTheme.accent
        case .ready: return FlowTheme.success
        }
    }
}

struct MeetingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var meetings: MeetingController
    @State private var selectedID: UUID?
    @State private var search = ""

    init(controller: AppController) {
        self.controller = controller
        meetings = controller.meetings
    }

    private var filtered: [MeetingRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings.meetings }
        return meetings.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.transcript.localizedCaseInsensitiveContains(query)
                || ($0.userNotes ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var groups: [(title: String, records: [MeetingRecord])] {
        var result: [(title: String, records: [MeetingRecord])] = []
        for record in filtered {
            let title = Self.groupTitle(record.createdAt)
            if result.last?.title == title { result[result.count - 1].records.append(record) }
            else { result.append((title, [record])) }
        }
        return result
    }

    private var selected: MeetingRecord? {
        selectedID.flatMap { meetings.store.record($0) } ?? (selectedID == nil ? meetings.meetings.first : nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            library.frame(minWidth: 250, idealWidth: 280, maxWidth: 300)
            Rectangle().fill(FlowTheme.line).frame(width: 1)
            Group {
                if let record = selected {
                    MeetingDetailView(record: record, controller: controller, isVisible: controller.workspaceSection == .meetings) {
                        selectedID = nil
                    }.id(record.id)
                } else if meetings.meetings.isEmpty {
                    FlowEmptyState(symbol: "person.2.wave.2", title: "No meetings yet",
                                   message: "Record your microphone and the other side of the call, then get a transcript, a summary, and a place for your own notes.") {
                        VStack(spacing: 10) {
                            startButton(size: .large)
                            if let shortcut = controller.settings.shortcut(for: .meeting) {
                                HStack(spacing: 6) { FlowKeycaps(shortcut: shortcut.display); Text("from any app") }
                                    .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted)
                            }
                        }
                    }
                } else {
                    FlowEmptyState(symbol: "person.2.wave.2", title: "Select a meeting", message: "Choose a meeting from the list.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlowTheme.surface)
        }
        .onChange(of: controller.focusedMeetingID) { _, id in focus(id) }
        .onAppear { focus(controller.focusedMeetingID) }
        .onChange(of: meetings.activeID) { _, id in if let id { selectedID = id } }
    }

    private func focus(_ id: UUID?) {
        guard let id else { return }
        search = ""
        selectedID = id
        controller.focusedMeetingID = nil
    }

    // MARK: - Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Meetings").font(.system(size: 21, weight: .semibold)).tracking(-0.4)
                Spacer()
                if meetings.activeID == nil { startButton(size: .small) }
            }.padding(.horizontal, 18).padding(.top, 28).padding(.bottom, 14)
            FlowSearchField(text: $search, prompt: "Search meetings").padding(.horizontal, 16).padding(.bottom, 12)
            if let error = meetings.store.storageError {
                Label(UserNotice.summary(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(FlowTheme.warning).help(error)
                    .padding(.horizontal, 18).padding(.bottom, 10)
            }
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(FlowTheme.inkFaint).padding(.leading, 10).padding(.top, 16).padding(.bottom, 4)
                        ForEach(group.records) { record in
                            MeetingRow(record: record, isActive: meetings.activeID == record.id,
                                       selected: selected?.id == record.id) { selectedID = record.id }
                        }
                    }
                    if !meetings.meetings.isEmpty && filtered.isEmpty {
                        VStack(spacing: 7) {
                            Text("No matching meetings").font(.system(size: 13, weight: .medium)).foregroundStyle(FlowTheme.inkMuted)
                            Button("Clear search") { search = "" }.buttonStyle(.flowGhost)
                        }.frame(maxWidth: .infinity).padding(.vertical, 35)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 20)
            }
        }.background(FlowTheme.background)
    }

    /// Starts right away with the saved sources. The chevron changes those defaults.
    private func startButton(size: FlowButtonStyle.Size) -> some View {
        Menu {
            Toggle("Microphone", isOn: setting(\.meetingMicrophone))
                .disabled(controller.settings.meetingMicrophone && !controller.settings.meetingSystemAudio)
            Toggle("System audio", isOn: setting(\.meetingSystemAudio))
                .disabled(controller.settings.meetingSystemAudio && !controller.settings.meetingMicrophone)
            Divider()
            Toggle("Live transcript", isOn: setting(\.meetingLiveTranscription))
            Toggle("Transcribe & summarize when I stop", isOn: setting(\.meetingSummarize))
            if controller.settings.meetingSystemAudio && !CGPreflightScreenCaptureAccess() {
                Divider()
                Button("Allow system audio…") { controller.open(.permissions) }
            }
        } label: {
            Label("Start", systemImage: "record.circle")
        } primaryAction: {
            controller.startMeeting()
        }
        .menuStyle(.button)
        .buttonStyle(.flow(.primary, size: size))
        .fixedSize()
        .disabled(!controller.canStartMeeting)
        .help("Start recording a meeting. Make sure everyone knows you’re recording.")
    }

    private func setting(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { controller.settings[keyPath: keyPath] }, set: { value in controller.updateSettings { $0[keyPath: keyPath] = value } })
    }

    private static func groupTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

private struct MeetingRow: View {
    let record: MeetingRecord
    let isActive: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var preview: String? {
        if let point = record.summary?.overview.first?.text { return point }
        if let notes = record.userNotes, !notes.isEmpty { return notes }
        return record.segments.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if isActive { Circle().fill(FlowTheme.recording).frame(width: 7, height: 7) }
                    Text(record.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }.foregroundStyle(FlowTheme.ink)
                if let preview {
                    Text(preview).font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted).lineLimit(2)
                }
                HStack(spacing: 5) {
                    Text(record.createdAt.formatted(date: Calendar.current.isDateInToday(record.createdAt) ? .omitted : .abbreviated, time: .shortened))
                    if record.duration > 0 { Text("·"); Text(FlowFormat.duration(record.duration)).monospacedDigit() }
                    if !isActive && record.status != .ready {
                        Text("·")
                        Text(record.status.label).foregroundStyle(record.status.color)
                    }
                }.font(.system(size: 10.5)).foregroundStyle(FlowTheme.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(selected ? FlowTheme.surfaceHover : hovering ? FlowTheme.surfaceMuted : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 2).fill(FlowTheme.accent).frame(width: 3).padding(.vertical, 12) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Observes the recorder directly so the line moves without redrawing the whole meeting.
private struct MeetingMeter: View {
    @ObservedObject var recorder: AudioRecorder
    let paused: Bool

    var body: some View {
        FlowSquiggle(level: CGFloat(recorder.inputLevel), color: FlowTheme.recording, motion: paused ? .still : .live)
            .frame(width: 54, height: 18)
            .opacity(paused ? 0.5 : 1)
    }
}

// MARK: - Meeting note

struct MeetingDetailView: View {
    private enum Tab: Hashable { case notes, summary, transcript }

    let record: MeetingRecord
    @ObservedObject var controller: AppController
    @ObservedObject private var meetings: MeetingController
    let onDeleted: () -> Void
    @State private var player: AVAudioPlayer?
    @State private var playingID: String?
    @State private var showDelete = false
    @State private var showAudio = false
    @State private var editTitle = ""
    @State private var tab: Tab
    @State private var notes: String
    @State private var notesSaveTask: Task<Void, Never>?
    @State private var transcriptSearch = ""
    @State private var transcriptSource = "all"
    @State private var showErrorDetails = false

    var isVisible: Bool

    init(record: MeetingRecord, controller: AppController, isVisible: Bool = true, onDeleted: @escaping () -> Void) {
        self.record = record
        self.controller = controller
        meetings = controller.meetings
        self.onDeleted = onDeleted
        self.isVisible = isVisible
        let active = controller.meetings.activeID == record.id
        let hasNotes = !(record.userNotes ?? "").isEmpty
        _tab = State(initialValue: active ? .notes : record.summary != nil ? .summary : hasNotes || record.segments.isEmpty ? .notes : .transcript)
        _notes = State(initialValue: record.userNotes ?? "")
    }

    private var isActive: Bool { meetings.activeID == record.id }
    private var errorMessage: String? { meetings.error ?? record.lastError ?? meetings.store.storageError }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 16) {
                header
                stateStrip
                FlowTabs(items: [(Tab.notes, "My notes"), (.summary, "Summary"), (.transcript, "Transcript")], selection: $tab)
                switch tab {
                case .notes: notesTab
                case .summary: ScrollView { summaryTab.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24) }
                case .transcript: transcriptTab
                }
            }
            .padding(.horizontal, 36).padding(.top, 24)
            .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(FlowTheme.ink)
        .onAppear { editTitle = record.title }
        .onDisappear { player?.stop(); updateTitle(); saveNotes() }
        .onChange(of: isVisible) { _, visible in
            if !visible { player?.stop(); playingID = nil; updateTitle(); saveNotes() }
        }
        .onChange(of: notes) { _, _ in scheduleNotesSave() }
        // Notes typed in the floating meeting notes window show up here too, unless an edit here is still pending.
        .onChange(of: meetings.store.record(record.id)?.userNotes) { _, stored in
            if notesSaveTask == nil, let stored, stored != notes { notes = stored }
        }
        .onChange(of: record.summary) { old, new in if old == nil && new != nil && !isActive { tab = .summary } }
        .alert("Delete this meeting and its recording?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) {
                do { player?.stop(); try controller.deleteMeeting(record.id); onDeleted() } catch { meetings.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes your notes, the transcript, the summary, and the audio.") }
        .sheet(isPresented: $showAudio) { audioSheet }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { controller.openDayNote(record.createdAt) } label: {
                Label(Calendar.current.isDateInToday(record.createdAt) ? "Today" : record.createdAt.formatted(.dateTime.month(.abbreviated).day()),
                      systemImage: "calendar")
            }
            .buttonStyle(.flow(.ghost, size: .small)).help("Open this day’s note")
            Spacer()
            FlowIconButton(symbol: "doc.on.doc", help: "Copy as Markdown") { FlowFormat.copy(currentRecord.markdown); controller.flash("Copied to clipboard") }
            Menu {
                Button("Export as Markdown…") { export() }
                Button("Audio & track names…") { showAudio = true }
                Divider()
                Button("Delete meeting…", role: .destructive) { showDelete = true }.disabled(isActive || meetings.isBusy)
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Meeting actions")
        }.padding(.horizontal, 20).frame(height: 52)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Meeting title", text: $editTitle)
                .textFieldStyle(.plain).font(.system(size: 26, weight: .semibold)).tracking(-0.6)
                .onSubmit { updateTitle() }
            HStack(spacing: 7) {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                if isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in Text(FlowFormat.duration(meetings.elapsed)).monospacedDigit() }
                } else {
                    Text(FlowFormat.duration(record.duration)).monospacedDigit()
                }
                if record.includesMicrophone { Image(systemName: "mic").help(record.microphoneLabel) }
                if record.includesSystemAudio { Image(systemName: "speaker.wave.2").help(record.systemLabel) }
                if !isActive && record.status != .ready {
                    Text("·")
                    Text(record.status.label).foregroundStyle(record.status.color)
                }
            }
            .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
        }
    }

    // MARK: - State

    /// At most one strip: recording controls, progress, a next step, or a problem.
    @ViewBuilder private var stateStrip: some View {
        if isActive {
            HStack(spacing: 12) {
                if meetings.isRecording || meetings.isPaused {
                    MeetingMeter(recorder: meetings.microphone, paused: meetings.isPaused)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(meetings.isPaused ? "Paused" : meetings.isRecording ? "Recording" : "Finishing…").font(.system(size: 13, weight: .semibold))
                    Text(liveDetail).font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted).lineLimit(1)
                }
                Spacer()
                if meetings.liveError != nil {
                    Button("Retry live transcript") { meetings.retryLiveTranscription() }.buttonStyle(.flow(.ghost, size: .small))
                }
                if !meetings.isRecording && !meetings.isPaused && meetings.isBusy {
                    Button("Finish later") { meetings.cancelProcessing() }.buttonStyle(.flow(.secondary, size: .small))
                } else {
                    Button { if meetings.isPaused { meetings.resume() } else { meetings.pause() } } label: {
                        Label(meetings.isPaused ? "Resume" : "Pause", systemImage: meetings.isPaused ? "play.fill" : "pause.fill")
                    }.buttonStyle(.flow(.secondary, size: .small)).disabled(meetings.isBusy)
                    Button { meetings.finish() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.flow(.primary, size: .small)).disabled(meetings.isBusy)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(FlowTheme.recording.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FlowTheme.recording.opacity(0.22), lineWidth: 1))
        } else if meetings.isBusy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(meetings.progress.isEmpty ? "Working…" : meetings.progress).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer()
                Button("Cancel") { meetings.cancelProcessing() }.buttonStyle(.flow(.ghost, size: .small))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(FlowTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                FlowBanner(symbol: "exclamationmark.circle.fill", tint: FlowTheme.warning, title: UserNotice.summary(errorMessage)) {
                    Button(showErrorDetails ? "Hide details" : "Details") { showErrorDetails.toggle() }.buttonStyle(.flow(.ghost, size: .small))
                    if record.status != .ready || record.segments.isEmpty {
                        Button("Try again") { meetings.process(record.id) }.buttonStyle(.flow(.secondary, size: .small))
                    }
                }
                if showErrorDetails {
                    Text(errorMessage).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(FlowTheme.inkMuted).textSelection(.enabled)
                }
            }
        } else if record.status != .ready || record.segments.isEmpty {
            nextStep(record.segments.isEmpty ? "This meeting hasn’t been transcribed yet." : "Transcription stopped partway.",
                     action: record.segments.isEmpty ? "Transcribe & summarize" : "Resume") { meetings.process(record.id) }
        } else if record.summary == nil {
            nextStep("The transcript is ready.", action: "Create summary") { meetings.process(record.id, summarizeOnly: true) }
        }
        if let notice = record.recoveryNotice {
            FlowBanner(symbol: "exclamationmark.triangle.fill", tint: FlowTheme.warning, title: "Some audio couldn’t be read", detail: notice) { EmptyView() }
        }
    }

    private var liveDetail: String {
        if let error = meetings.liveError { return UserNotice.summary(error) }
        if meetings.isBusy && !meetings.progress.isEmpty { return meetings.progress }
        if !meetings.liveProgress.isEmpty { return meetings.liveProgress }
        return record.liveTranscription == true ? "Transcript appears as you talk" : "Transcribed when you stop"
    }

    private func nextStep(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(FlowTheme.accent)
            Text(message).font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkMuted)
            Spacer()
            Button(action, action: perform).buttonStyle(.flow(.primary, size: .small))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(FlowTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Tabs

    private var notesTab: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $notes).font(.system(size: 15)).lineSpacing(6)
                .scrollContentBackground(.hidden).padding(.horizontal, -5)
                .accessibilityLabel("Meeting notes")
            if notes.isEmpty {
                Text(isActive ? "Jot down what matters as you talk. Your notes guide the summary."
                              : "Write your own notes about this meeting.")
                    .font(.system(size: 15)).foregroundStyle(FlowTheme.inkFaint).padding(.top, 1).allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var summaryTab: some View {
        if let summary = record.summary {
            VStack(alignment: .leading, spacing: 26) {
                points("Key points", summary.overview)
                points("Decisions", summary.decisions)
                points("Action items", summary.actions, checklist: true)
                HStack {
                    Text("AI-generated. Check the linked audio before relying on a decision or action.")
                        .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint)
                    Spacer()
                    Button("Summarize again") { meetings.process(record.id, summarizeOnly: true) }
                        .buttonStyle(.flow(.ghost, size: .small)).disabled(meetings.isBusy || isActive)
                }
            }
        } else if record.summaryNeedsConfirmation == true {
            VStack(spacing: 14) {
                FlowEmptyState(symbol: "questionmark.bubble", title: "Very short meeting",
                               message: "Only \(record.wordCount) words were transcribed, so it wasn’t summarized automatically. Was it started by mistake?")
                HStack(spacing: 10) {
                    Button("Summarize anyway") { meetings.summarizeShortMeeting(record.id) }.buttonStyle(.flowPrimary)
                        .disabled(meetings.isBusy)
                    Button("No summary needed") { meetings.skipSummary(record.id) }.buttonStyle(.flowSecondary)
                }
            }.frame(minHeight: 260)
        } else {
            FlowEmptyState(symbol: "sparkles", title: "No summary yet",
                           message: isActive ? "Stop the recording to get key points, decisions, and action items."
                                             : "Transcribe this meeting to get key points, decisions, and action items.")
                .frame(minHeight: 260)
        }
    }

    @ViewBuilder private var transcriptTab: some View {
        let passages = MeetingTranscript.passages(record.segments, track: transcriptSource == "all" ? nil : transcriptSource)
            .filter { transcriptSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(transcriptSearch) }
        VStack(alignment: .leading, spacing: 12) {
            if !record.segments.isEmpty {
                HStack(spacing: 10) {
                    FlowSearchField(text: $transcriptSearch, prompt: "Search this transcript")
                    if record.includesMicrophone && record.includesSystemAudio {
                        Picker("Source", selection: $transcriptSource) {
                            Text("All audio").tag("all")
                            Text(record.microphoneLabel).tag("microphone")
                            Text(record.systemLabel).tag("system")
                        }.labelsHidden().frame(width: 150)
                    }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if passages.isEmpty && (!isActive || meetings.streamingPartials.isEmpty) {
                        FlowEmptyState(symbol: isActive ? "waveform" : "text.quote",
                                       title: !transcriptSearch.isEmpty ? "No matching passages" : isActive ? "Listening…" : "No transcript yet",
                                       message: !transcriptSearch.isEmpty ? "Try a different word or source."
                                           : isActive ? (record.liveTranscription == true ? "Text appears here as each section of audio is ready." : "The transcript is created when you stop.")
                                           : "Transcribe this meeting to read it here.")
                            .frame(minHeight: 220)
                    }
                    ForEach(passages) { passage in passageRow(passage) }
                    if isActive && !meetings.streamingPartials.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            FlowBadge(text: "Live", color: FlowTheme.recording, pulsing: true)
                            ForEach(meetings.streamingPartials.keys.sorted(by: { $0.path < $1.path }), id: \.self) { url in
                                Text(meetings.streamingPartials[url] ?? "").font(.system(size: 14)).foregroundStyle(FlowTheme.inkMuted).textSelection(.enabled)
                            }
                        }
                    }
                    if !passages.isEmpty {
                        Text("Labels identify audio inputs, not individual speakers. Timing is approximate.")
                            .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint)
                    }
                }.padding(.bottom, 24)
            }
        }
    }

    private func passageRow(_ passage: MeetingTranscriptPassage) -> some View {
        let fromMicrophone = passage.track == "microphone"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(fromMicrophone ? record.microphoneLabel : record.systemLabel).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(fromMicrophone ? FlowTheme.accent : FlowTheme.success)
                if let first = passage.segmentIDs.first.flatMap({ id in record.segments.first { $0.id == id } }) {
                    Button { play(first) } label: {
                        Label(MeetingSegment.timestamp(passage.start), systemImage: playingID == first.id ? "stop.fill" : "play.fill")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(FlowTheme.inkFaint)
                    }.buttonStyle(.plain).help("Listen from here")
                }
            }
            Text(passage.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func points(_ title: String, _ points: [MeetingSummary.Point], checklist: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(FlowTheme.inkFaint)
            if points.isEmpty { Text("None identified.").font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted) }
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if checklist {
                        Image(systemName: "circle").font(.system(size: 10)).foregroundStyle(FlowTheme.accent)
                    } else {
                        Circle().fill(FlowTheme.accent).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(point.text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                        HStack(spacing: 4) {
                            ForEach(point.sources, id: \.self) { source in
                                if let segment = record.segments.first(where: { $0.id == source }) {
                                    Button { play(segment) } label: {
                                        Label(segment.timestamp, systemImage: playingID == segment.id ? "stop.fill" : "play.fill")
                                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(FlowTheme.inkMuted)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(FlowTheme.surfaceMuted, in: Capsule())
                                    }.buttonStyle(.plain).help("Listen to this part")
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var audioSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Audio & track names").font(.system(size: 20, weight: .semibold))
            FlowSettingsGroup(title: "Track names", footer: "Used in the transcript and exports.") {
                FlowSettingsRow(title: "Microphone", symbol: "mic") {
                    TextField("Microphone", text: trackLabel(\.microphoneLabel)).flowField().frame(width: 200).disabled(meetings.isBusy)
                }
                FlowRowDivider()
                FlowSettingsRow(title: "System audio", symbol: "speaker.wave.2") {
                    TextField("System audio", text: trackLabel(\.systemLabel)).flowField().frame(width: 200).disabled(meetings.isBusy)
                }
            }
            let chunks = (try? meetings.store.audioChunks(for: record.id)) ?? []
            FlowSettingsGroup(title: "Saved audio", footer: "Recordings stay on this Mac. Deleting the meeting removes its audio.") {
                if chunks.isEmpty {
                    Text(isActive ? "Audio appears here as it’s saved." : "No audio was saved for this meeting.")
                        .font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkMuted).padding(14)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(chunks.enumerated()), id: \.element.id) { index, chunk in
                            if index > 0 { FlowRowDivider() }
                            HStack(spacing: 10) {
                                FlowIconButton(symbol: playingID == chunk.id ? "stop.fill" : "play.fill",
                                               help: playingID == chunk.id ? "Stop" : "Play", tint: FlowTheme.accent) { play(chunk) }
                                Text(chunk.timestamp).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                                Text(chunk.track == "microphone" ? record.microphoneLabel : record.systemLabel)
                                    .font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkMuted)
                                Spacer()
                                Text("\(Int(chunk.duration.rounded()))s").font(.system(size: 12)).monospacedDigit().foregroundStyle(FlowTheme.inkFaint)
                            }.padding(.horizontal, 10).padding(.vertical, 6)
                        }
                    }
                }.frame(maxHeight: 260)
            }
            HStack { Spacer(); Button("Done") { showAudio = false }.buttonStyle(.flowPrimary).keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 480).background(FlowTheme.background).foregroundStyle(FlowTheme.ink)
    }

    // MARK: - Actions

    private var currentRecord: MeetingRecord {
        var current = meetings.store.record(record.id) ?? record
        current.userNotes = notes
        return current
    }

    private func scheduleNotesSave() {
        notesSaveTask?.cancel()
        notesSaveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            saveNotes()
        }
    }

    private func saveNotes() {
        notesSaveTask?.cancel()
        notesSaveTask = nil
        guard var current = meetings.store.record(record.id), (current.userNotes ?? "") != notes else { return }
        current.userNotes = notes
        do { try meetings.store.save(current) } catch { meetings.error = error.localizedDescription }
    }

    private func trackLabel(_ keyPath: WritableKeyPath<MeetingRecord, String>) -> Binding<String> {
        Binding(get: { meetings.store.record(record.id)?[keyPath: keyPath] ?? record[keyPath: keyPath] }, set: { value in
            guard var current = meetings.store.record(record.id) else { return }
            current[keyPath: keyPath] = value
            do { try meetings.store.save(current) } catch { meetings.error = error.localizedDescription }
        })
    }

    private func updateTitle() {
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var current = meetings.store.record(record.id), !title.isEmpty, current.title != title else { return }
        current.title = title
        do { try meetings.store.save(current) } catch { meetings.error = error.localizedDescription }
    }

    private func play(_ segment: MeetingSegment) {
        if playingID == segment.id, player?.isPlaying == true { player?.stop(); playingID = nil; return }
        guard let url = meetings.store.audioURL(meetingID: record.id, relativePath: segment.id),
              FileManager.default.fileExists(atPath: url.path) else {
            meetings.error = "That part of the recording is no longer on this Mac."
            return
        }
        do {
            player?.stop()
            let next = try AVAudioPlayer(contentsOf: url)
            player = next
            playingID = segment.id
            guard next.play() else {
                playingID = nil
                meetings.error = "This audio could not be played. Check your audio output and try again."
                return
            }
            // Clear the indicator when this clip ends, unless another one started.
            let id = segment.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((next.duration + 0.2) * 1_000_000_000))
                if playingID == id, player === next, !next.isPlaying { playingID = nil }
            }
        } catch { meetings.error = error.localizedDescription }
    }

    private func export() {
        saveNotes()
        let name = record.title.isEmpty ? "Meeting" : record.title
        NoteExporter.save(currentRecord.markdown, suggestedName: name, type: UTType(filenameExtension: "md") ?? .plainText, controller: controller)
    }
}
