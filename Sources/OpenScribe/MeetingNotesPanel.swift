import AppKit
import SwiftUI

/// A small floating window for writing notes during a meeting, opened from the Flowbar.
/// Closing it only hides the notes; the meeting keeps recording.
final class MeetingNotesPanel: NSPanel {
    let meetingID: UUID
    var onClose: (() -> Void)?

    @MainActor
    init(controller: AppController, meetingID: UUID) {
        self.meetingID = meetingID
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "Meeting notes"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 300, height: 260)
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = NSColor(FlowTheme.background)
        contentView = NSHostingView(rootView: MeetingNotesView(controller: controller, meetings: controller.meetings, meetingID: meetingID) { [weak self] in
            self?.close()
        })
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }
}

struct MeetingNotesView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var meetings: MeetingController
    let meetingID: UUID
    let dismiss: () -> Void
    @State private var notes: String
    @State private var saveTask: Task<Void, Never>?
    @State private var tab: Tab = .notes

    enum Tab: Hashable { case notes, transcript }
    @FocusState private var editorFocused: Bool

    init(controller: AppController, meetings: MeetingController, meetingID: UUID, dismiss: @escaping () -> Void) {
        self.controller = controller
        self.meetings = meetings
        self.meetingID = meetingID
        self.dismiss = dismiss
        _notes = State(initialValue: meetings.store.record(meetingID)?.userNotes ?? "")
    }

    private var record: MeetingRecord? { meetings.store.record(meetingID) }
    private var screenshots: [NoteCapture] { controller.store.meetingScreenshots(meetingID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            FlowTabs(items: [(Tab.notes, "My notes"), (.transcript, "Transcript")], selection: $tab)
            switch tab {
            case .notes:
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $notes).font(.system(size: 14)).lineSpacing(5)
                        .scrollContentBackground(.hidden).padding(.horizontal, -5)
                        .focused($editorFocused)
                        .accessibilityLabel("Meeting notes")
                    if notes.isEmpty {
                        Text("Jot down what matters. Your notes guide the summary.")
                            .font(.system(size: 14)).foregroundStyle(FlowTheme.inkFaint).padding(.top, 1).allowsHitTesting(false)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                if !screenshots.isEmpty { screenshotStrip }
            case .transcript:
                transcript
            }
            footer
        }
        .padding(.horizontal, 18).padding(.top, 30).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FlowTheme.background)
        .foregroundStyle(FlowTheme.ink)
        .onAppear { editorFocused = true }
        .onDisappear { save() }
        .onChange(of: notes) { _, _ in scheduleSave() }
        // Edits made in the main window flow in here, unless an edit here is still pending.
        .onChange(of: record?.userNotes) { _, stored in
            if saveTask == nil, let stored, stored != notes { notes = stored }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(meetings.isPaused ? FlowTheme.inkFaint : FlowTheme.recording).frame(width: 7, height: 7)
            Text(record?.title.isEmpty == false ? record!.title : "Meeting")
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(meetings.isPaused ? "Paused · \(FlowFormat.duration(meetings.elapsed))" : FlowFormat.duration(meetings.elapsed))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(FlowTheme.inkFaint)
            }
            Spacer(minLength: 0)
            Button {
                save()
                controller.openMeeting(meetingID)
                dismiss()
            } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(FlowTheme.inkMuted)
            .help("Open the full meeting")
        }
    }

    /// Finished passages plus whatever is streaming right now, following along at the bottom.
    private var transcript: some View {
        let passages = record.map { MeetingTranscript.passages($0.segments) } ?? []
        let live = meetings.streamingPartials.keys.sorted { $0.path < $1.path }
            .compactMap { meetings.streamingPartials[$0] }.filter { !$0.isEmpty }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if passages.isEmpty && live.isEmpty {
                        Text(record?.liveTranscription == true ? "Listening… text appears here as you talk."
                                                               : "Live transcription is off. The transcript is created when you stop.")
                            .font(.system(size: 13)).foregroundStyle(FlowTheme.inkFaint)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                    ForEach(passages) { passage in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(passage.track == "microphone" ? record?.microphoneLabel ?? "Microphone" : record?.systemLabel ?? "System audio")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(passage.track == "microphone" ? FlowTheme.accent : FlowTheme.success)
                                Text(MeetingSegment.timestamp(passage.start)).font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(FlowTheme.inkFaint)
                            }
                            Text(passage.text).font(.system(size: 13.5)).lineSpacing(3).textSelection(.enabled)
                        }
                    }
                    if !live.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            FlowBadge(text: "Live", color: FlowTheme.recording, pulsing: true)
                            ForEach(Array(live.enumerated()), id: \.offset) { _, text in
                                Text(text).font(.system(size: 13.5)).lineSpacing(3).foregroundStyle(FlowTheme.inkMuted)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .frame(maxHeight: .infinity)
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: passages.count + live.joined().count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var screenshotStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(screenshots) { capture in
                    if let name = capture.attachment {
                        ScreenshotThumbnail(url: controller.store.attachmentURL(name), maxSize: CGSize(width: 120, height: 72))
                    }
                }
            }
        }
        .frame(height: 74)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                controller.takeScreenshot(.area)
            } label: {
                Label("Screenshot", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.flow(.ghost, size: .small))
            .disabled(controller.screenshotInProgress)
            .help(screenshotHint)
            Spacer()
            Button("Done") { save(); dismiss() }
                .buttonStyle(.flowPrimary)
                .keyboardShortcut(.cancelAction)
                .help("Close notes. The meeting keeps recording.")
        }
    }

    private var screenshotHint: String {
        let shortcut = controller.settings.shortcut(for: .screenshotArea).map { " (\($0.display) works anywhere)" } ?? ""
        return "Add a screenshot to this meeting\(shortcut)"
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            save()
        }
    }

    private func save() {
        saveTask?.cancel()
        saveTask = nil
        guard var current = meetings.store.record(meetingID), (current.userNotes ?? "") != notes else { return }
        current.userNotes = notes
        do { try meetings.store.save(current) } catch { meetings.error = error.localizedDescription }
    }
}
