import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case notes, meetings, general, speech, cleanup, personalize, privacy, permissions, calendar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .notes: return "Notes"
        case .meetings: return "Meetings"
        case .general: return "General"
        case .speech: return "Transcription"
        case .cleanup: return "Writing"
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
        case .speech: return "mic"
        case .cleanup: return "text.badge.checkmark"
        case .personalize: return "text.badge.plus"
        case .privacy: return "lock.shield"
        case .permissions: return "checkmark.shield"
        }
    }

    static let library: [WorkspaceSection] = [.notes, .meetings, .calendar]
    static let settings: [WorkspaceSection] = [.general, .speech, .cleanup, .personalize, .privacy, .permissions]
    var isSettings: Bool { Self.settings.contains(self) }
}

struct MainWorkspaceView: View {
    @ObservedObject var controller: AppController

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
            if meetings.occupiesCapture && (section != .meetings || calendarTitle != nil) {
                FlowBanner(symbol: meetings.isPaused ? "pause.circle.fill" : "record.circle.fill", tint: FlowTheme.recording,
                           title: calendarTitle ?? (meetings.isPaused ? "Meeting paused" : "Recording a meeting"),
                           detail: calendarTitle == nil ? nil : (meetings.isPaused ? "Paused" : "Recording from your calendar")) {
                    if calendarTitle != nil {
                        Button("Extend 15 min") { controller.calendar.extend() }.buttonStyle(.flow(.secondary, size: .small))
                    }
                    if section != .meetings {
                        Button("Open") { controller.workspaceSection = .meetings }.buttonStyle(.flow(.secondary, size: .small))
                        Button("Stop & save") { meetings.finish() }.buttonStyle(.flow(.destructive, size: .small))
                            .disabled(meetings.isBusy)
                    }
                }
            } else if let calendarTitle {
                FlowBanner(symbol: "calendar", title: calendarTitle, detail: "Calendar recording") {
                    Button("Not happening") { controller.calendar.decline() }.buttonStyle(.flow(.ghost, size: .small))
                    Button("Extend 15 min") { controller.calendar.extend() }.buttonStyle(.flow(.secondary, size: .small))
                }
            }
            if controller.hasFailedRecording && section == .notes {
                FlowBanner(symbol: "arrow.clockwise.circle.fill", tint: FlowTheme.warning,
                           title: "A recording wasn’t transcribed",
                           detail: "The audio is saved on this Mac. Retry when you’re back online.") {
                    Button("Discard") { controller.discardFailedRecording() }.buttonStyle(.flow(.ghost, size: .small))
                    Button("Retry") { controller.retryFailedRecording() }.buttonStyle(.flow(.secondary, size: .small))
                }
                .disabled(controller.isDictationBusy)
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

/// The always-available recording control at the foot of the sidebar.
private struct CaptureDock: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var recorder: AudioRecorder

    init(controller: AppController) {
        self.controller = controller
        recorder = controller.recorder
    }

    private var phase: CapturePhase { controller.capturePhase }
    private var processing: Bool { phase == .transcribing || phase == .cleaning }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.setupReadiness.canDictate && !controller.isDictationBusy {
                setupNeeded
            } else if phase == .recording {
                recording
            } else if processing {
                working
            } else {
                idle
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlowTheme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(phase == .recording ? FlowTheme.recording.opacity(0.45) : FlowTheme.line, lineWidth: 1))
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
        Group {
            Button { controller.startCapture() } label: { Label("Start dictation", systemImage: "mic.fill") }
                .buttonStyle(.flow(.primary, size: .large, fullWidth: true))
                .disabled(controller.meetings.occupiesCapture || controller.isDictationBusy)
            HStack(spacing: 6) {
                if controller.meetings.occupiesCapture {
                    Text("Available after your meeting")
                } else if controller.permissions.accessibilityTrusted {
                    FlowKeycaps(shortcut: controller.settings.shortcutDisplay)
                    Text(controller.settings.dictationMode == .holdToTalk || controller.settings.shortcutKeyCode == 63 ? "hold, in any app" : "in any app")
                } else {
                    Text("Saves to Notes")
                }
            }
            .font(.system(size: 11)).foregroundStyle(FlowTheme.inkMuted)
            .frame(maxWidth: .infinity)
        }
    }

    private var recording: some View {
        Group {
            HStack(spacing: 8) {
                FlowBadge(text: "Listening", color: FlowTheme.recording, pulsing: true)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(FlowFormat.duration(context.date.timeIntervalSince(controller.captureStartedAt ?? context.date)))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(FlowTheme.inkMuted)
                }
            }
            FlowWaveform(levels: recorder.inputLevels, color: FlowTheme.recording, maxHeight: 26)
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                Button { controller.finishCapture() } label: { Label("Stop & save", systemImage: "stop.fill") }
                    .buttonStyle(.flow(.primary, fullWidth: true))
                FlowIconButton(symbol: "xmark", help: "Cancel recording") { controller.cancelCapture() }
            }
        }
    }

    private var working: some View {
        Group {
            HStack(spacing: 8) {
                FlowBadge(text: phase == .cleaning ? "Polishing" : "Transcribing", color: FlowTheme.accent, pulsing: true)
                Spacer()
                FlowIconButton(symbol: "xmark", help: "Cancel") { controller.cancelCapture() }
            }
            FlowWaveform(levels: Array(repeating: 0.2, count: 11), color: FlowTheme.accent, maxHeight: 26, animated: true)
                .frame(maxWidth: .infinity)
        }
    }
}
