import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

extension MeetingStatus {
    var label: String {
        switch self {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .saved: return "Saved"
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
    @State private var title = ""
    @State private var showSetup = false
    @State private var includeMicrophone = true
    @State private var includeSystemAudio = true
    @State private var search = ""
    @State private var summarizeOnStop = true

    init(controller: AppController) {
        self.controller = controller
        meetings = controller.meetings
    }

    private var filtered: [MeetingRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings.meetings }
        return meetings.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.transcript.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if let selectedID, let record = meetings.store.record(selectedID) {
                MeetingDetailView(record: record, meetings: meetings, isVisible: controller.workspaceSection == .meetings) { self.selectedID = nil }
                    .id(selectedID)
                    .transition(.opacity)
            } else {
                list.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: selectedID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSetup) { meetingSetup }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                FlowPageHeader(title: "Meetings", subtitle: "Record, transcribe and summarize your calls.") {
                    if let activeID = meetings.activeID {
                        Button { selectedID = activeID } label: { Label("Open recording", systemImage: "record.circle") }
                            .buttonStyle(.flowDestructive)
                    } else {
                        Button { title = ""; showSetup = true } label: { Label("New meeting", systemImage: "plus") }
                            .buttonStyle(.flowPrimary)
                            .disabled(meetings.isBusy)
                    }
                }
                if !meetings.meetings.isEmpty {
                    FlowSearchField(text: $search, prompt: "Search titles and transcripts").frame(maxWidth: 340)
                }
                if let error = meetings.store.storageError {
                    FlowBanner(symbol: "exclamationmark.triangle.fill", tint: FlowTheme.warning,
                               title: UserNotice.summary(error), detail: nil) { EmptyView() }
                        .help(error)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 14)

            if meetings.meetings.isEmpty {
                FlowEmptyState(symbol: "person.2.wave.2", title: "No meetings yet",
                               message: "Capture your microphone and system audio, then get a transcript and a summary with links back to the recording.") {
                    Button { title = ""; showSetup = true } label: { Label("New meeting", systemImage: "plus") }
                        .buttonStyle(.flow(.primary, size: .large))
                }
            } else if filtered.isEmpty {
                FlowEmptyState(symbol: "magnifyingglass", title: "No matching meetings", message: "Try a different word.") {
                    Button("Clear search") { search = "" }.buttonStyle(.flowSecondary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { record in
                            MeetingRow(record: record, isActive: meetings.activeID == record.id) { selectedID = record.id }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var meetingSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New meeting").font(.system(size: 20, weight: .bold))
                Text("Make sure everyone knows you’re recording.").font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkMuted)
            }
            TextField("Meeting title (optional)", text: $title).flowField()

            FlowSettingsGroup(title: "Audio", footer: "System audio includes other apps and notifications. Headphones help avoid duplicate voices.") {
                FlowSettingsRow(title: "Microphone", detail: "Your voice", symbol: "mic") {
                    Toggle("", isOn: $includeMicrophone).labelsHidden().toggleStyle(.switch)
                }
                FlowRowDivider()
                FlowSettingsRow(title: "System audio", detail: "Everyone else on the call", symbol: "speaker.wave.2") {
                    Toggle("", isOn: $includeSystemAudio).labelsHidden().toggleStyle(.switch)
                }
            }
            FlowSettingsGroup(title: "Transcript", footer: "These options send audio to your transcription provider and text to your writing provider. Turn both off to keep the recording on this Mac.") {
                FlowSettingsRow(title: "Show transcript while recording") {
                    Toggle("", isOn: Binding(get: { controller.settings.meetingLiveTranscription }, set: { value in
                        controller.updateSettings { $0.meetingLiveTranscription = value }
                    })).labelsHidden().toggleStyle(.switch)
                }
                FlowRowDivider()
                FlowSettingsRow(title: "Transcribe and summarize when I stop") {
                    Toggle("", isOn: $summarizeOnStop).labelsHidden().toggleStyle(.switch)
                }
            }
            if let error = meetings.error {
                Label(UserNotice.summary(error), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(FlowTheme.recording)
            }
            HStack {
                if includeSystemAudio && !CGPreflightScreenCaptureAccess() {
                    Button("Allow system audio…") { controller.open(.permissions); showSetup = false }.buttonStyle(.flowGhost)
                }
                Spacer()
                Button("Cancel") { showSetup = false }.buttonStyle(.flowSecondary).keyboardShortcut(.cancelAction)
                Button { startMeeting() } label: { Label("Start recording", systemImage: "record.circle") }
                    .buttonStyle(.flowPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.isDictationBusy || meetings.isBusy || meetings.activeID != nil || (!includeMicrophone && !includeSystemAudio))
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(FlowTheme.background)
        .foregroundStyle(FlowTheme.ink)
        .tint(FlowTheme.accent)
    }

    private func startMeeting() {
        meetings.start(title: title, microphone: includeMicrophone, systemAudio: includeSystemAudio, settings: controller.settings,
                       summarizeOnStop: summarizeOnStop, liveTranscription: controller.settings.meetingLiveTranscription)
        selectedID = meetings.activeID
        if selectedID != nil { showSetup = false }
    }
}

private struct MeetingRow: View {
    let record: MeetingRecord
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    private var preview: String? {
        if let point = record.summary?.overview.first?.text { return point }
        return record.segments.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isActive ? "record.circle.fill" : "person.2.wave.2")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isActive ? FlowTheme.recording : FlowTheme.accent)
                    .frame(width: 36, height: 36)
                    .background((isActive ? FlowTheme.recording : FlowTheme.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if record.duration > 0 {
                            Text("·")
                            Text(FlowFormat.duration(record.duration)).monospacedDigit()
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                    if let preview {
                        Text(preview).font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkMuted).lineLimit(2)
                            .multilineTextAlignment(.leading).padding(.top, 2)
                    }
                }
                Spacer(minLength: 12)
                FlowBadge(text: record.status.label, color: record.status.color, pulsing: record.status == .recording)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(FlowTheme.inkFaint)
                    .padding(.top, 5)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? FlowTheme.surfaceHover : FlowTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(FlowTheme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Observes the recorder directly so the meter moves without redrawing the whole meeting.
private struct MeetingMeter: View {
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        FlowWaveform(levels: recorder.isRecording ? recorder.inputLevels : Array(repeating: 0.2, count: 11),
                     color: FlowTheme.recording, maxHeight: 22, animated: !recorder.isRecording)
    }
}

struct MeetingDetailView: View {
    private enum Tab: Hashable { case summary, transcript, recording }

    let record: MeetingRecord
    @ObservedObject var meetings: MeetingController
    let onClose: () -> Void
    @State private var player: AVAudioPlayer?
    @State private var playingID: String?
    @State private var showDelete = false
    @State private var editTitle = ""
    @State private var tab: Tab
    @State private var transcriptSearch = ""
    @State private var transcriptSource = "all"
    @State private var showErrorDetails = false

    var isVisible: Bool

    init(record: MeetingRecord, meetings: MeetingController, isVisible: Bool = true, onClose: @escaping () -> Void) {
        self.record = record; self.meetings = meetings; self.onClose = onClose
        self.isVisible = isVisible
        _tab = State(initialValue: record.summary == nil ? .transcript : .summary)
    }

    private var isActive: Bool { meetings.activeID == record.id }
    private var errorMessage: String? { meetings.error ?? record.lastError ?? meetings.store.storageError }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Button(action: onClose) { Label("Meetings", systemImage: "chevron.left") }
                    .buttonStyle(.flowGhost).keyboardShortcut(.cancelAction)
                Spacer()
                Button { export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.flowSecondary).disabled(record.segments.isEmpty)
                FlowIconButton(symbol: "trash", help: isActive ? "Stop the recording before deleting" : "Delete meeting") { showDelete = true }
                    .disabled(isActive || meetings.isBusy)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Meeting title", text: $editTitle)
                    .textFieldStyle(.plain).font(.system(size: 24, weight: .bold))
                    .onSubmit { updateTitle() }
                HStack(spacing: 8) {
                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    if isActive {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(FlowFormat.duration(meetings.elapsed)).monospacedDigit()
                        }
                    } else {
                        Text(FlowFormat.duration(record.duration)).monospacedDigit()
                    }
                    FlowBadge(text: record.status.label, color: record.status.color, pulsing: isActive && meetings.isRecording)
                }
                .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
            }
            .padding(.horizontal, 8)

            controls

            if isActive && record.liveTranscription == true, meetings.liveError != nil || !meetings.liveProgress.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: meetings.liveError == nil ? "waveform" : "exclamationmark.triangle.fill")
                        .foregroundStyle(meetings.liveError == nil ? FlowTheme.accent : FlowTheme.warning)
                    Text(meetings.liveError ?? meetings.liveProgress).lineLimit(2)
                    Spacer()
                    if meetings.liveError != nil {
                        Button("Retry live transcript") { meetings.retryLiveTranscription() }.buttonStyle(.flow(.secondary, size: .small))
                    }
                }
                .font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted).padding(.horizontal, 8)
            }
            if let notice = record.recoveryNotice {
                FlowBanner(symbol: "exclamationmark.triangle.fill", tint: FlowTheme.warning, title: "Some audio couldn’t be read", detail: notice) { EmptyView() }
            }
            if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    FlowBanner(symbol: "exclamationmark.circle.fill", tint: FlowTheme.recording, title: UserNotice.summary(errorMessage)) {
                        Button(showErrorDetails ? "Hide details" : "Details") { showErrorDetails.toggle() }.buttonStyle(.flow(.ghost, size: .small))
                    }
                    if showErrorDetails {
                        Text(errorMessage).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(FlowTheme.inkMuted)
                            .textSelection(.enabled).padding(.horizontal, 8)
                    }
                }
            }

            FlowTabs(items: [(Tab.summary, "Summary"), (.transcript, "Transcript"), (.recording, "Recording")], selection: $tab)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .summary: summaryTab
                    case .transcript: transcriptTab
                    case .recording: recordingTab
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(FlowTheme.ink)
        .onAppear { editTitle = record.title; if isActive { tab = .transcript } }
        .onDisappear { player?.stop(); updateTitle() }
        .onChange(of: isVisible) { _, visible in
            if !visible { player?.stop(); playingID = nil; updateTitle() }
        }
        .alert("Delete this meeting and its recording?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) {
                do { player?.stop(); try meetings.store.delete(record.id); onClose() } catch { meetings.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes the transcript, summary and audio files.") }
    }

    // MARK: - Controls

    @ViewBuilder private var controls: some View {
        if isActive {
            HStack(spacing: 12) {
                if meetings.isRecording {
                    MeetingMeter(recorder: meetings.microphone)
                } else {
                    Image(systemName: meetings.isPaused ? "pause.circle.fill" : "hourglass")
                        .font(.system(size: 18)).foregroundStyle(FlowTheme.recording)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(meetings.isPaused ? "Paused" : meetings.isRecording ? "Recording" : "Finishing…")
                        .font(.system(size: 13, weight: .semibold))
                    if meetings.isBusy && !meetings.progress.isEmpty {
                        Text(meetings.progress).font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted).lineLimit(1)
                    }
                }
                Spacer()
                if !meetings.isRecording && !meetings.isPaused && meetings.isBusy {
                    Button("Finish processing later") { meetings.cancelProcessing() }.buttonStyle(.flowSecondary)
                } else {
                    Button { if meetings.isPaused { meetings.resume() } else { meetings.pause() } } label: {
                        Label(meetings.isPaused ? "Resume" : "Pause", systemImage: meetings.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.flowSecondary).disabled(meetings.isBusy)
                    Button { meetings.finish() } label: { Label("Stop & save", systemImage: "stop.fill") }
                        .buttonStyle(.flowPrimary).disabled(meetings.isBusy)
                }
            }
            .padding(14)
            .background(FlowTheme.recording.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(FlowTheme.recording.opacity(0.25), lineWidth: 1))
        } else if meetings.isBusy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(meetings.progress.isEmpty ? "Working…" : meetings.progress).font(.system(size: 12.5, weight: .medium))
                Spacer()
                Button("Cancel") { meetings.cancelProcessing() }.buttonStyle(.flow(.secondary, size: .small))
            }
            .padding(12)
            .background(FlowTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if record.status != .ready || record.segments.isEmpty || record.summary == nil {
            HStack(spacing: 8) {
                if record.status != .ready || record.segments.isEmpty {
                    Button { meetings.process(record.id) } label: {
                        Label(record.segments.isEmpty ? "Transcribe & summarize" : "Resume transcription", systemImage: "sparkles")
                    }.buttonStyle(.flowPrimary)
                }
                if !record.segments.isEmpty && record.summary == nil {
                    Button("Create summary") { meetings.process(record.id, summarizeOnly: true) }.buttonStyle(.flowSecondary)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Tabs

    @ViewBuilder private var summaryTab: some View {
        if let summary = record.summary {
            points("Summary", symbol: "text.alignleft", summary.overview)
            points("Decisions", symbol: "checkmark.seal", summary.decisions)
            points("Action items", symbol: "checklist", summary.actions)
            HStack {
                Text("AI-generated. Check the linked audio before relying on a decision or action.")
                    .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint)
                Spacer()
                Button("Summarize again") { meetings.process(record.id, summarizeOnly: true) }
                    .buttonStyle(.flow(.ghost, size: .small)).disabled(meetings.isBusy || isActive)
            }
        } else {
            FlowEmptyState(symbol: "sparkles", title: "No summary yet",
                           message: isActive ? "Stop the recording to get key points, decisions and action items."
                                             : "Transcribe this meeting to get key points, decisions and action items.")
                .frame(minHeight: 260)
        }
    }

    @ViewBuilder private var transcriptTab: some View {
        HStack(spacing: 10) {
            FlowSearchField(text: $transcriptSearch, prompt: "Search this transcript")
            Picker("Source", selection: $transcriptSource) {
                Text("All audio").tag("all")
                Text(record.microphoneLabel).tag("microphone")
                Text(record.systemLabel).tag("system")
            }.labelsHidden().frame(width: 150)
        }
        let passages = MeetingTranscript.passages(record.segments, track: transcriptSource == "all" ? nil : transcriptSource)
            .filter { transcriptSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(transcriptSearch) }
        if passages.isEmpty {
            FlowEmptyState(symbol: isActive ? "waveform" : "text.quote",
                           title: !transcriptSearch.isEmpty ? "No matching passages" : isActive ? "Listening…" : "No transcript yet",
                           message: !transcriptSearch.isEmpty ? "Try a different word or source."
                               : isActive ? "Text appears here as each section of audio is ready."
                               : "Transcribe this meeting to read it here.")
                .frame(minHeight: 220)
        }
        ForEach(passages) { passage in
            let fromMicrophone = passage.track == "microphone"
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: fromMicrophone ? "mic.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(fromMicrophone ? FlowTheme.accent : FlowTheme.success)
                    .frame(width: 28, height: 28)
                    .background((fromMicrophone ? FlowTheme.accent : FlowTheme.success).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(fromMicrophone ? record.microphoneLabel : record.systemLabel).font(.system(size: 12, weight: .semibold))
                        Menu(MeetingSegment.timestamp(passage.start)) {
                            ForEach(passage.segmentIDs, id: \.self) { id in
                                if let segment = record.segments.first(where: { $0.id == id }) {
                                    Button("Listen at " + segment.timestamp) { play(segment) }
                                }
                            }
                        }
                        .menuStyle(.borderlessButton).font(.system(size: 11.5)).fixedSize()
                    }
                    .foregroundStyle(FlowTheme.inkMuted)
                    Text(passage.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        if isActive && !meetings.streamingPartials.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FlowBadge(text: "Live", color: FlowTheme.recording, pulsing: true)
                ForEach(meetings.streamingPartials.keys.sorted(by: { $0.path < $1.path }), id: \.self) { url in
                    Text(meetings.streamingPartials[url] ?? "").font(.system(size: 14)).foregroundStyle(FlowTheme.inkMuted).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !passages.isEmpty {
            Text("Labels identify audio inputs, not individual speakers. Timing is approximate.")
                .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkFaint)
        }
    }

    @ViewBuilder private var recordingTab: some View {
        FlowSettingsGroup(title: "Track names", footer: "Used in the transcript and exports.") {
            FlowSettingsRow(title: "Microphone", symbol: "mic") {
                TextField("Microphone", text: trackLabel(\.microphoneLabel)).flowField().frame(width: 220).disabled(meetings.isBusy)
            }
            FlowRowDivider()
            FlowSettingsRow(title: "System audio", symbol: "speaker.wave.2") {
                TextField("System audio", text: trackLabel(\.systemLabel)).flowField().frame(width: 220).disabled(meetings.isBusy)
            }
        }
        let chunks = (try? meetings.store.audioChunks(for: record.id)) ?? []
        FlowSettingsGroup(title: "Saved audio", footer: "Recordings stay on this Mac with the meeting. Deleting the meeting removes its audio.") {
            if chunks.isEmpty {
                Text(isActive ? "Audio appears here as it’s saved." : "No audio was saved for this meeting.")
                    .font(.system(size: 12.5)).foregroundStyle(FlowTheme.inkMuted).padding(14)
            }
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
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
    }

    private func points(_ title: String, symbol: String, _ points: [MeetingSummary.Point]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
            if points.isEmpty { Text("None identified.").font(.system(size: 13)).foregroundStyle(FlowTheme.inkMuted) }
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(FlowTheme.accent).frame(width: 5, height: 5).padding(.top, 7)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(point.text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                        HStack(spacing: 6) {
                            ForEach(point.sources, id: \.self) { source in
                                if let segment = record.segments.first(where: { $0.id == source }) {
                                    Button { play(segment) } label: {
                                        Label(segment.timestamp, systemImage: playingID == segment.id ? "stop.fill" : "play.fill")
                                    }.buttonStyle(.flow(.secondary, size: .small))
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowCard(padding: 16)
    }

    // MARK: - Actions

    private func trackLabel(_ keyPath: WritableKeyPath<MeetingRecord, String>) -> Binding<String> {
        Binding(get: { record[keyPath: keyPath] }, set: { value in
            guard var current = meetings.store.record(record.id) else { return }
            current[keyPath: keyPath] = value
            do { try meetings.store.save(current) } catch { meetings.error = error.localizedDescription }
        })
    }

    private func updateTitle() {
        guard var current = meetings.store.record(record.id), !editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              current.title != editTitle else { return }
        current.title = editTitle
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
        let panel = NSSavePanel()
        let name = record.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = String((name.isEmpty ? "Meeting" : name).prefix(80)) + ".md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try record.markdown.write(to: url, atomically: true, encoding: .utf8) }
            catch { meetings.error = error.localizedDescription }
        }
    }
}
