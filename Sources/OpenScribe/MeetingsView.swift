import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selectedID, let record = meetings.store.record(selectedID) {
                MeetingDetailView(record: record, meetings: meetings) { self.selectedID = nil }.id(selectedID)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Text("Meetings").flowDisplayFont(size: 30)
                            Spacer()
                            if let activeID = meetings.activeID {
                                Button("Open recording") { selectedID = activeID }
                            } else {
                                Button(showSetup ? "Cancel" : "New meeting") { showSetup.toggle() }
                                    .buttonStyle(FlowPrimaryButtonStyle())
                            }
                        }
                        if showSetup {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("Meeting title", text: $title).textFieldStyle(.roundedBorder)
                            HStack {
                                Toggle("Microphone", isOn: $includeMicrophone)
                                Toggle("System audio", isOn: $includeSystemAudio)
                            }
                            Text("System audio records sound from other apps, including calls and notifications. No video is saved. Headphones help prevent the same voices being picked up by your mic.")
                                .flowUIFont(size: 11).foregroundStyle(FlowTheme.inkMuted)
                            Toggle("Live transcription", isOn: Binding(get: { controller.settings.meetingLiveTranscription }, set: { value in
                                controller.updateSettings { $0.meetingLiveTranscription = value }
                            }))
                            Text("Live mode sends completed audio sections to your speech provider while recording. Text appears about every 15 seconds, plus provider processing time.")
                                .flowUIFont(size: 11).foregroundStyle(FlowTheme.inkMuted)
                            Toggle("Transcribe & summarize after stopping", isOn: $summarizeOnStop)
                            Text("Start only when participants know you are recording. Transcription sends recorded audio to your speech provider; summaries send the transcript to your writing provider. Turn off live transcription and processing after stop to keep the recording local.")
                                .flowUIFont(size: 11).foregroundStyle(FlowTheme.inkMuted)
                            HStack {
                                Button("Start meeting", systemImage: "record.circle") {
                                    meetings.start(title: title, microphone: includeMicrophone, systemAudio: includeSystemAudio, settings: controller.settings, summarizeOnStop: summarizeOnStop, liveTranscription: controller.settings.meetingLiveTranscription)
                                    selectedID = meetings.activeID
                                    if selectedID != nil { showSetup = false }
                                }.buttonStyle(FlowPrimaryButtonStyle())
                                    .disabled(controller.isDictationBusy || meetings.isBusy || meetings.activeID != nil || (!includeMicrophone && !includeSystemAudio))
                                if let activeID = meetings.activeID {
                                    Button("Return to recording") { selectedID = activeID }
                                }
                            }
                            Button("System audio permissions…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                            }.buttonStyle(FlowQuietButtonStyle())
                        }.flowCard(inset: 20)
                        }
                        if let error = meetings.error ?? meetings.store.storageError {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                        TextField("Search meetings", text: $search).textFieldStyle(.roundedBorder)
                        ForEach(meetings.meetings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.transcript.localizedCaseInsensitiveContains(search) }) { record in
                            Button { selectedID = record.id } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(record.title).flowUIFont(size: 15, weight: .semibold)
                                        Text(record.createdAt.formatted()).flowUIFont(size: 11).foregroundStyle(FlowTheme.inkMuted)
                                    }
                                    Spacer()
                                    Text(record.status.title).flowUIFont(size: 11)
                                    Image(systemName: "chevron.right")
                                }.padding(16).contentShape(Rectangle())
                            }.buttonStyle(.plain).flowCard(inset: 0)
                        }
                        if meetings.meetings.isEmpty { Text("Your recorded meetings will appear here.").foregroundStyle(FlowTheme.inkMuted) }
                    }.padding(32)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(FlowTheme.paper)
    }
}

private struct MeetingDetailView: View {
    let record: MeetingRecord
    @ObservedObject var meetings: MeetingController
    let onClose: () -> Void
    @State private var player: AVAudioPlayer?
    @State private var playingID: String?
    @State private var showDelete = false
    @State private var editTitle = ""
    @State private var tab = "summary"

    private var isActive: Bool { meetings.activeID == record.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("All meetings", systemImage: "chevron.left", action: onClose).buttonStyle(FlowQuietButtonStyle())
                Spacer()
                Button("Export Markdown", action: export).disabled(record.segments.isEmpty)
                Button("Delete", role: .destructive) { showDelete = true }.disabled(isActive || meetings.isBusy)
            }
            TextField("Meeting title", text: $editTitle).flowDisplayFont(size: 26)
                .textFieldStyle(.plain).onSubmit { updateTitle() }
            HStack {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("· \(record.status.title)")
                Spacer()
                if isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(MeetingSegment.timestamp(meetings.elapsed)).monospacedDigit()
                    }
                } else { Text(MeetingSegment.timestamp(record.duration)).monospacedDigit() }
            }.flowUIFont(size: 11).foregroundStyle(FlowTheme.inkMuted)
            if isActive {
                HStack {
                    Label(meetings.isPaused ? "Paused" : meetings.isRecording ? "Recording" : "Finishing…", systemImage: "record.circle.fill").foregroundStyle(.red)
                    Spacer()
                    Button(meetings.isPaused ? "Resume" : "Pause") {
                        if meetings.isPaused { meetings.resume() } else { meetings.pause() }
                    }.disabled(meetings.isBusy)
                    if !meetings.isRecording && !meetings.isPaused && meetings.isBusy {
                        Button("Finish processing later") { meetings.cancelProcessing() }
                    } else {
                        Button("Stop & save") { meetings.finish() }.disabled(meetings.isBusy)
                    }
                }.padding(14).background(FlowTheme.coral.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            } else {
                HStack {
                    Button(record.segments.isEmpty ? "Transcribe & summarize" : "Resume transcription") { meetings.process(record.id) }
                        .buttonStyle(FlowPrimaryButtonStyle()).disabled(meetings.isBusy)
                    if !record.segments.isEmpty {
                        Button("Summarize again") { meetings.process(record.id, summarizeOnly: true) }.disabled(meetings.isBusy)
                    }
                    if meetings.isBusy { Button("Cancel processing") { meetings.cancelProcessing() } }
                }
            }
            if isActive && record.liveTranscription == true {
                HStack {
                    Text(meetings.liveError ?? meetings.liveProgress).font(.caption).foregroundStyle(meetings.liveError == nil ? Color.secondary : .orange)
                    Spacer()
                    Text("\(record.segments.count) sections saved").font(.caption).monospacedDigit()
                    if meetings.liveError != nil { Button("Retry live") { meetings.retryLiveTranscription() } }
                }
            }
            if isActive && !meetings.streamingPartials.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live transcript").font(.caption).foregroundStyle(.secondary)
                    ForEach(meetings.streamingPartials.keys.sorted(by: { $0.path < $1.path }), id: \.self) { url in
                        Text(meetings.streamingPartials[url] ?? "").font(.callout).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice = record.recoveryNotice { Text(notice).flowUIFont(size: 11).foregroundStyle(.orange) }
            if meetings.isBusy { HStack { ProgressView().controlSize(.small); Text(meetings.progress).flowUIFont(size: 11) } }
            if let error = meetings.error ?? record.lastError ?? meetings.store.storageError {
                Text(error).flowUIFont(size: 11).foregroundStyle(.red).textSelection(.enabled)
            }
            Picker("Meeting view", selection: $tab) {
                Text("Summary").tag("summary")
                Text("Transcript").tag("transcript")
                Text("Recording").tag("recording")
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if tab == "summary" {
                        if let summary = record.summary {
                            points("Summary", summary.overview)
                            points("Decisions", summary.decisions)
                            points("Action items", summary.actions)
                            Text("AI-generated notes. Check the linked audio before relying on an action or decision.").flowUIFont(size: 10).foregroundStyle(FlowTheme.inkMuted)
                        } else {
                            Text("Save your recording, then transcribe and summarize to see the key points here.").foregroundStyle(FlowTheme.inkMuted)
                        }
                    } else if tab == "transcript" {
                        Text("Timestamps mark audio chunks. Microphone and system audio are sources, not identified speakers.")
                            .flowUIFont(size: 11).foregroundStyle(FlowTheme.inkMuted)
                        if record.segments.isEmpty {
                            Text(isActive && record.liveTranscription == true ? "Listening… Your first transcript section will appear here shortly." : "No transcript yet.").foregroundStyle(FlowTheme.inkMuted)
                        }
                        ForEach(record.segments) { segment in
                            VStack(alignment: .leading, spacing: 8) {
                                Button("\(segment.timestamp) · \(segment.track == "microphone" ? record.microphoneLabel : record.systemLabel)") { play(segment) }
                                Text(segment.text.isEmpty ? "No speech returned for this section." : segment.text).textSelection(.enabled)
                            }
                        }
                    } else {
                        Text("Saved audio tracks").flowUIFont(size: 16, weight: .semibold)
                        TextField("Microphone label", text: trackLabel(\.microphoneLabel)).textFieldStyle(.roundedBorder).disabled(meetings.isBusy)
                        TextField("System audio label", text: trackLabel(\.systemLabel)).textFieldStyle(.roundedBorder).disabled(meetings.isBusy)
                        Text("Recordings are kept locally with this meeting. Deleting the meeting removes its audio too.").flowUIFont(size: 11).foregroundStyle(FlowTheme.inkMuted)
                        ForEach((try? meetings.store.audioChunks(for: record.id)) ?? []) { chunk in
                            Button("\(playingID == chunk.id ? "Stop" : "Play") · \(chunk.timestamp) · \(chunk.track) · \(Int(chunk.duration))s") { play(chunk) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            }
        }.padding(28)
            .onAppear { editTitle = record.title; if isActive { tab = "transcript" } }
            .onDisappear { player?.stop(); updateTitle() }
            .alert("Delete meeting and its recording?", isPresented: $showDelete) {
                Button("Delete", role: .destructive) {
                    do { try meetings.store.delete(record.id); onClose() } catch { meetings.error = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This permanently removes this meeting's transcript, summary and audio files.") }
    }

    private func points(_ title: String, _ points: [MeetingSummary.Point]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).flowUIFont(size: 18, weight: .semibold)
            if points.isEmpty { Text("None identified.").foregroundStyle(FlowTheme.inkMuted) }
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                VStack(alignment: .leading, spacing: 6) {
                    Text(point.text).textSelection(.enabled)
                    HStack {
                        ForEach(point.sources, id: \.self) { source in
                            if let segment = record.segments.first(where: { $0.id == source }) {
                                Button(segment.timestamp, systemImage: "play.circle") { play(segment) }.font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }
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
        guard let url = meetings.store.audioURL(meetingID: record.id, relativePath: segment.id) else { return }
        do { player?.stop(); player = try AVAudioPlayer(contentsOf: url); player?.play(); playingID = segment.id }
        catch { meetings.error = error.localizedDescription }
    }
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Meeting.md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try record.markdown.write(to: url, atomically: true, encoding: .utf8) }
            catch { meetings.error = error.localizedDescription }
        }
    }
}
