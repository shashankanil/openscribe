import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case notes, meetings, general, shortcuts, connections, ai, personalize, privacy, permissions, calendar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .notes: return "Notes"
        case .meetings: return "Meetings"
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .connections: return "API & Models"
        case .ai: return "Connect AI apps"
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
        case .ai: return "sparkles"
        case .personalize: return "text.badge.plus"
        case .privacy: return "lock.shield"
        case .permissions: return "checkmark.shield"
        }
    }

    static let library: [WorkspaceSection] = [.notes, .meetings, .calendar]
    static let settings: [WorkspaceSection] = [.general, .shortcuts, .connections, .ai, .personalize, .privacy, .permissions]
    var isSettings: Bool { Self.settings.contains(self) }
    var group: SidebarGroup { SidebarGroup.all.first { $0.sections.contains(self) }! }
}

/// A sidebar entry. Groups with more than one section expand to show them as sub-items.
struct SidebarGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    /// Every section reached from this entry; the first one opens when the entry is clicked.
    let sections: [WorkspaceSection]
    let isSettings: Bool

    var children: [WorkspaceSection] { sections.count > 1 ? sections : [] }

    static let notes = SidebarGroup(id: "notes", title: "Notes", symbol: "text.alignleft", sections: [.notes], isSettings: false)
    static let meetings = SidebarGroup(id: "meetings", title: "Meetings", symbol: "person.2.wave.2", sections: [.meetings, .calendar], isSettings: false)
    static let preferences = SidebarGroup(id: "preferences", title: "Preferences", symbol: "slider.horizontal.3",
                                          sections: [.general, .shortcuts, .personalize], isSettings: true)
    static let ai = SidebarGroup(id: "ai", title: "AI", symbol: "sparkles", sections: [.connections, .ai], isSettings: true)
    static let privacy = SidebarGroup(id: "privacy", title: "Privacy & Access", symbol: "lock.shield",
                                      sections: [.privacy, .permissions], isSettings: true)

    static let all: [SidebarGroup] = [.notes, .meetings, .preferences, .ai, .privacy]

    /// Sub-items use the page title, except the group's own page.
    static func childTitle(_ section: WorkspaceSection) -> String {
        switch section {
        case .meetings: return "All meetings"
        default: return section.title
        }
    }
}

struct MainWorkspaceView: View {
    @ObservedObject var controller: AppController
    @State private var confirmingDiscard = false
    /// The open page's group is expanded unless the user folded it.
    @State private var foldedGroup: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            workspace
            if let toast = controller.toast {
                FlowToast(message: toast)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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
                    ForEach(SidebarGroup.all.filter { !$0.isSettings }) { groupRows($0) }
                    Text("SETTINGS").font(.system(size: 9.5, weight: .semibold)).tracking(1)
                        .foregroundStyle(FlowTheme.inkFaint).padding(.horizontal, 9).padding(.top, 24).padding(.bottom, 7)
                    ForEach(SidebarGroup.all.filter(\.isSettings)) { groupRows($0) }
                }
                .animation(.easeOut(duration: 0.16), value: section)
                .animation(.easeOut(duration: 0.16), value: foldedGroup)
                .onChange(of: section) { _, _ in foldedGroup = nil }
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

    @ViewBuilder private func groupRows(_ group: SidebarGroup) -> some View {
        let containsSelection = group.sections.contains(section)
        let expanded = !group.children.isEmpty && containsSelection && foldedGroup != group.id
        SidebarRow(title: group.title, symbol: group.symbol,
                   selected: containsSelection && (group.children.isEmpty || !expanded),
                   emphasized: containsSelection, count: count(for: group),
                   disclosure: group.children.isEmpty ? nil : expanded) {
            if containsSelection && !group.children.isEmpty {
                // Clicking the open group again folds or unfolds it; the page stays.
                foldedGroup = expanded ? group.id : nil
            } else {
                controller.workspaceSection = group.sections[0]
            }
        }
        if expanded {
            ForEach(group.children) { child in
                SidebarChildRow(title: SidebarGroup.childTitle(child), selected: section == child) {
                    controller.workspaceSection = child
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func count(for group: SidebarGroup) -> Int {
        switch group.id {
        case SidebarGroup.notes.id: return controller.notes.count
        case SidebarGroup.meetings.id: return controller.meetings.meetings.count
        default: return 0
        }
    }

    // MARK: - Banners

    @ViewBuilder private var banners: some View {
        let meetings = controller.meetings
        let calendarTitle = controller.calendar.trackedTitle
        VStack(spacing: 8) {
            setupBanner
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

    /// After setup, anything dictation loses (microphone, key) or paste loses (Accessibility) is explained
    /// here with its fix, instead of reopening onboarding.
    @ViewBuilder private var setupBanner: some View {
        let readiness = controller.setupReadiness
        if controller.hasCompletedSetup && !controller.onboardingVisible {
            if !readiness.microphone && section != .permissions {
                FlowBanner(symbol: "mic.slash.fill", tint: FlowTheme.warning, title: "Microphone access is off",
                           detail: "Dictation is paused until you switch it back on.") {
                    Button(controller.permissions.microphoneStatus == .notDetermined ? "Allow" : "Open System Settings") {
                        Task { await controller.requestMicrophonePermission() }
                    }.buttonStyle(.flow(.secondary, size: .small))
                }
            } else if !readiness.speechKey && section != .connections {
                FlowBanner(symbol: "key.fill", tint: FlowTheme.warning, title: "Add a speech key to dictate",
                           detail: "Your notes are safe. Dictation needs a provider key to transcribe.") {
                    Button("Add key") { controller.workspaceSection = .connections }.buttonStyle(.flow(.secondary, size: .small))
                }
            } else if readiness.canDictate && readiness.pasteBlocked && section != .permissions && (section == .notes || section.isSettings) {
                FlowBanner(symbol: "text.cursor", tint: FlowTheme.warning, title: "Paste is off — Accessibility isn’t allowed",
                           detail: "Dictations are saved to Notes until you allow it.") {
                    Button("Fix") { controller.workspaceSection = .permissions }.buttonStyle(.flow(.secondary, size: .small))
                }
            }
        }
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
    /// The open page is inside this entry (tints the icon even when a sub-item is highlighted).
    var emphasized = false
    let count: Int
    /// nil: no sub-items; otherwise whether they are showing.
    var disclosure: Bool? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected || emphasized ? FlowTheme.accent : FlowTheme.inkMuted)
                    .frame(width: 18)
                Text(title).font(.system(size: 13, weight: selected || emphasized ? .semibold : .medium))
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(FlowTheme.inkFaint)
                }
                if let disclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(FlowTheme.inkFaint)
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                        .opacity(disclosure || hovering || emphasized ? 1 : 0.6)
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

/// A sub-item under an expanded sidebar entry.
private struct SidebarChildRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? FlowTheme.ink : FlowTheme.inkMuted)
                Spacer(minLength: 0)
            }
            .padding(.leading, 36)
            .padding(.trailing, 9)
            .padding(.vertical, 5.5)
            .background(selected ? FlowTheme.surfaceHover : hovering ? FlowTheme.surfaceMuted : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .leading) {
                // A thin guide ties the sub-items to their entry.
                Rectangle().fill(selected ? FlowTheme.accent : FlowTheme.line).frame(width: selected ? 2 : 1)
                    .padding(.vertical, selected ? 5 : 0).padding(.leading, 18)
            }
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
            if controller.hasCompletedSetup {
                let missing = controller.setupReadiness.missingRequirement
                Label(missing == .microphone ? "Microphone is off" : "Add a speech key", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(missing == .microphone ? "Allow the microphone to dictate again." : "Dictation needs a provider key.")
                    .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                Button("Fix it") { controller.workspaceSection = missing == .microphone ? .permissions : .connections }
                    .buttonStyle(.flow(.primary, fullWidth: true))
            } else {
                Label("Finish setup", systemImage: "sparkles").font(.system(size: 12.5, weight: .semibold))
                Text("Allow the microphone and connect a provider to start dictating.")
                    .font(.system(size: 11.5)).foregroundStyle(FlowTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                Button("Continue setup") { controller.showOnboarding() }
                    .buttonStyle(.flow(.primary, fullWidth: true))
            }
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
