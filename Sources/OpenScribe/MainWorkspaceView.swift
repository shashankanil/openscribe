import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case notes, meetings, general, shortcuts, connections, personalize, privacy, permissions, calendar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .notes: return "Notes"
        case .meetings: return "Meetings"
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .connections: return "API & Models"
        case .personalize: return "Personalization"
        case .privacy: return "Privacy"
        case .permissions: return "Permissions"
        }
    }
    var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .notes: return "text.alignleft"
        case .meetings: return "person.2.wave.2"
        case .general: return "slider.horizontal.3"
        case .shortcuts: return "command"
        case .connections: return "network"
        case .personalize: return "text.badge.plus"
        case .privacy: return "lock.shield"
        case .permissions: return "checkmark.shield"
        }
    }

    static let library: [WorkspaceSection] = [.notes, .meetings, .calendar]
    static let settings: [WorkspaceSection] = [.general, .shortcuts, .connections, .personalize, .privacy, .permissions]
    var isSettings: Bool { Self.settings.contains(self) }
}

struct MainWorkspaceView: View {
    @ObservedObject var controller: AppController
    @State private var confirmingDiscard = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if controller.onboardingVisible {
                OnboardingView(controller: controller).transition(.opacity)
            } else {
                workspace.transition(.opacity)
            }
            if let toast = controller.toast {
                FlowToast(message: toast)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: controller.onboardingVisible)
        .animation(FlowTheme.spring, value: controller.toast)
        .frame(minWidth: 900, minHeight: 620)
        .background(FlowTheme.background)
        .foregroundStyle(FlowTheme.ink)
        .tint(FlowTheme.accent)
        .ignoresSafeArea()
        .sheet(isPresented: $controller.noticeDetailsVisible) { NoticeDetailsSheet(controller: controller) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissions()
        }
    }

    private var section: WorkspaceSection { controller.workspaceSection }

    private var workspace: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(FlowTheme.line).frame(width: 1)
            VStack(spacing: 0) {
                banners
                // Keep every page mounted so searches and unsaved drafts survive navigation.
                ZStack {
                    page(NotesView(controller: controller), visible: section == .notes)
                    page(MeetingsView(controller: controller), visible: section == .meetings)
                    page(CalendarSettingsView(app: controller, calendar: controller.calendar), visible: section == .calendar)
                    page(SettingsView(controller: controller, section: section), visible: section.isSettings)
                }
                .animation(.easeOut(duration: 0.16), value: section)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlowTheme.background)
        }
        .background(shortcuts)
    }

    private func page<Content: View>(_ content: Content, visible: Bool) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .disabled(!visible)
            .accessibilityHidden(!visible)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                WhisperlightLogo(size: 26)
                Text("OpenScribe").font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    destination(.notes, count: controller.notes.count)
                    destination(.meetings, count: controller.meetings.meetings.count)
                    destination(.calendar, count: 0)
                    Text("SETTINGS").font(.system(size: 9.5, weight: .semibold)).tracking(1)
                        .foregroundStyle(FlowTheme.inkFaint).padding(.horizontal, 9).padding(.top, 24).padding(.bottom, 7)
                    ForEach(WorkspaceSection.settings) { destination($0, count: 0) }
                }
            }

            Spacer(minLength: 16)

            CaptureDock(controller: controller)
                .padding(.bottom, 10)

        }
        .padding(.horizontal, 12)
        .padding(.top, 52)
        .padding(.bottom, 12)
        .frame(width: 204)
        .frame(maxHeight: .infinity)
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow))
    }

    private func destination(_ target: WorkspaceSection, count: Int) -> some View {
        SidebarRow(title: target.title, symbol: target.symbol, selected: section == target, count: count) {
            controller.workspaceSection = target
        }
    }

    // MARK: - Banners

    @ViewBuilder private var banners: some View {
        let meetings = controller.meetings
        let calendarTitle = controller.calendar.trackedTitle
        VStack(spacing: 8) {
            if let error = controller.store.storageError, section == .notes || section.isSettings {
                FlowBanner(symbol: "externaldrive.badge.exclamationmark", tint: FlowTheme.warning,
                           title: "Check your local history", detail: UserNotice.summary(error)) {
                    Button("Details") { controller.inspectNotice(error) }.buttonStyle(.flow(.secondary, size: .small))
                }
            }
            // Meeting controls live in the Flowbar and the sidebar. Only calendar recordings need extra choices here.
            if meetings.occupiesCapture, let calendarTitle {
                FlowBanner(symbol: meetings.isPaused ? "pause.circle.fill" : "record.circle.fill", tint: FlowTheme.recording,
                           title: calendarTitle, detail: meetings.isPaused ? "Paused" : "Recording from your calendar") {
                    Button("Extend 15 min") { controller.calendar.extend() }.buttonStyle(.flow(.secondary, size: .small))
                }
            } else if let calendarTitle {
                FlowBanner(symbol: "calendar", title: calendarTitle, detail: "Calendar recording") {
                    Button("Not happening") { controller.calendar.decline() }.buttonStyle(.flow(.ghost, size: .small))
                    Button("Extend 15 min") { controller.calendar.extend() }.buttonStyle(.flow(.secondary, size: .small))
                }
            }
            if controller.hasFailedRecording && section == .notes {
                let count = controller.failedRecordingCount
                FlowBanner(symbol: "arrow.clockwise.circle.fill", tint: FlowTheme.warning,
                           title: count > 1 ? "\(count) recordings weren’t transcribed" : "A recording wasn’t transcribed",
                           detail: count > 1 ? "The audio is saved on this Mac. Retry transcribes the oldest one."
                                             : "The audio is saved on this Mac. Retry when you’re back online.") {
                    Button(count > 1 ? "Discard all" : "Discard") {
                        if count > 1 { confirmingDiscard = true } else { controller.discardFailedRecordings() }
                    }
                    .buttonStyle(.flow(.ghost, size: .small))
                    Button("Retry") { controller.retryFailedRecording() }.buttonStyle(.flow(.secondary, size: .small))
                }
                .disabled(controller.isDictationBusy)
                .confirmationDialog("Discard \(count) recordings?", isPresented: $confirmingDiscard) {
                    Button("Discard \(count) recordings", role: .destructive) { controller.discardFailedRecordings() }
                } message: {
                    Text("Their audio is deleted from this Mac. Notes you already have are not affected.")
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .animation(FlowTheme.spring, value: controller.hasFailedRecording)
        .animation(FlowTheme.spring, value: meetings.occupiesCapture)
    }

    // MARK: - Keyboard

    private var shortcuts: some View {
        ZStack {
            ForEach(Array(WorkspaceSection.library.enumerated()), id: \.offset) { index, target in
                Button("") { controller.workspaceSection = target }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? FlowTheme.accent : FlowTheme.inkMuted)
                    .frame(width: 18)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(FlowTheme.inkFaint)
                }
            }
            .foregroundStyle(FlowTheme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(selected ? FlowTheme.surfaceHover : hovering ? FlowTheme.surfaceMuted : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The always-available capture controls at the foot of the sidebar.
private struct CaptureDock: View {
    @ObservedObject var controller: AppController

    private var phase: CapturePhase { controller.capturePhase }
    private var processing: Bool { phase == .transcribing || phase == .cleaning }
    private var meetings: MeetingController { controller.meetings }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.setupReadiness.canDictate && !controller.isDictationBusy && !meetings.occupiesCapture {
                setupNeeded
            } else if meetings.occupiesCapture {
                meeting
            } else if phase == .recording {
                recording
            } else if processing {
                working
            } else {
                idle
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlowTheme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(phase == .recording || meetings.isRecording ? FlowTheme.recording.opacity(0.4) : FlowTheme.line, lineWidth: 1))
        .animation(FlowTheme.spring, value: phase)
    }

    private var setupNeeded: some View {
        Group {
            Label("Finish setup", systemImage: "sparkles").font(.system(size: 12.5, weight: .semibold))
            Text("Connect a provider and allow the microphone to start dictating.")
                .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            Button("Continue setup") { controller.showOnboarding() }
                .buttonStyle(.flow(.primary, fullWidth: true))
        }
    }

    private var idle: some View {
        VStack(spacing: 6) {
            Button { controller.startCapture() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "mic.fill")
                    Text("Dictate")
                    Spacer(minLength: 0)
                    if let hint = controller.settings.dictationHint, controller.hotkeyFailures.contains(.dictate) == false {
                        Text(hint).font(.system(size: 11, weight: .medium)).opacity(0.75)
                    }
                }
            }
            .buttonStyle(.flow(.primary, fullWidth: true))
            .disabled(controller.isDictationBusy)
            .help("Saves to today’s note. Use the shortcut to dictate into any app.")
            HStack(spacing: 6) {
                Button { controller.startMeeting() } label: { Label("Meeting", systemImage: "person.2.wave.2") }
                    .buttonStyle(.flow(.secondary, size: .small, fullWidth: true))
                    .disabled(!controller.canStartMeeting)
                    .help(controller.settings.shortcut(for: .meeting).map { "Start a meeting  \($0.display)" } ?? "Start a meeting")
                Menu {
                    ForEach(ScreenshotKind.allCases, id: \.self) { kind in
                        Button(kind.title + (controller.settings.shortcut(for: kind.action).map { "  \($0.display)" } ?? "")) {
                            controller.takeScreenshot(kind)
                        }
                    }
                } label: { Image(systemName: "camera.viewfinder") } primaryAction: { controller.takeScreenshot(.area) }
                    .menuStyle(.button).buttonStyle(.flow(.secondary, size: .small)).fixedSize()
                    .help("Screenshot to today’s note")
            }
        }
    }

    private var recording: some View {
        Group {
            HStack(spacing: 8) {
                Circle().fill(FlowTheme.recording).frame(width: 6, height: 6)
                RecorderSquiggle(recorder: controller.recorder, color: FlowTheme.recording)
                    .frame(maxWidth: .infinity).frame(height: 18)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(FlowFormat.duration(context.date.timeIntervalSince(controller.captureStartedAt ?? context.date)))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(FlowTheme.inkMuted)
                }
            }
            HStack(spacing: 6) {
                Button { controller.finishCapture() } label: { Label("Stop & save", systemImage: "stop.fill") }
                    .buttonStyle(.flow(.primary, fullWidth: true))
                FlowIconButton(symbol: "xmark", help: "Cancel recording") { controller.cancelCapture() }
            }
        }
    }

    private var working: some View {
        HStack(spacing: 8) {
            FlowSquiggle(color: FlowTheme.accent, motion: .flowing).frame(width: 36, height: 16)
            Text(phase == .cleaning ? "Polishing…" : "Transcribing…").font(.system(size: 12, weight: .medium)).foregroundStyle(FlowTheme.inkMuted)
            Spacer()
            FlowIconButton(symbol: "xmark", help: "Cancel") { controller.cancelCapture() }
        }
    }

    private var meeting: some View {
        Group {
            HStack(spacing: 8) {
                if meetings.isPaused {
                    Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(FlowTheme.warning)
                } else {
                    Circle().fill(FlowTheme.recording).frame(width: 6, height: 6)
                }
                RecorderSquiggle(recorder: controller.meetings.microphone, color: FlowTheme.recording,
                                 motion: meetings.isRecording ? .live : meetings.isPaused ? .still : .flowing)
                    .frame(maxWidth: .infinity).frame(height: 18)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(FlowFormat.duration(meetings.elapsed)).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(FlowTheme.inkMuted)
                }
            }
            HStack(spacing: 6) {
                Button { controller.openMeeting(meetings.activeID) } label: { Label("Notes", systemImage: "square.and.pencil") }
                    .buttonStyle(.flow(.secondary, size: .small, fullWidth: true))
                Button { meetings.finish() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.flow(.primary, size: .small, fullWidth: true))
                    .disabled(meetings.isBusy || !(meetings.isRecording || meetings.isPaused))
            }
        }
    }
}
