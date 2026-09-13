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
        case .cleanup: return "Writing & cleanup"
        case .personalize: return "Personalization"
        case .privacy: return "Data & privacy"
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
}

struct MainWorkspaceView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Group {
            if controller.onboardingVisible { OnboardingView(controller: controller) }
            else { workspace }
        }
        .alert("OpenScribe needs attention", isPresented: $controller.noticeDetailsVisible) {
            Button("OK", role: .cancel) {}
        } message: { Text(controller.lastError ?? "") }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    WhisperlightLogo(size: 32)
                    Text("OpenScribe").flowUIFont(size: 17, weight: .semibold)
                }.padding(.horizontal, 10).padding(.top, 12)

                VStack(alignment: .leading, spacing: 5) {
                    Text("LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(FlowTheme.inkMuted).padding(.horizontal, 12).padding(.bottom, 8)
                    destination(.notes)
                    destination(.meetings)
                    destination(.calendar)
                }
                Spacer()
                Button { controller.workspaceSection = .general } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(isSettingsArea ? FlowTheme.lavender.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityValue(isSettingsArea ? "Selected" : "")
                Divider()
                captureControl

            }
            .padding(14)
            .frame(width: 212)
            .background(FlowTheme.paperMuted)
            Divider().overlay(FlowTheme.line)
            VStack(spacing: 0) {
                if isSettingsArea { settingsNavigation }
                if let title = controller.calendar.trackedTitle, !controller.meetings.occupiesCapture {
                    HStack {
                        Label(title, systemImage: "calendar").lineLimit(1)
                        Spacer()
                        Button("Not happening · stop") { controller.calendar.decline() }
                        Button("Extend 15 min") { controller.calendar.extend() }
                    }.font(.caption).padding(12).background(FlowTheme.lavender.opacity(0.3))
                }
                if controller.meetings.occupiesCapture && (controller.workspaceSection != .meetings || controller.calendar.trackedTitle != nil) {
                    HStack {
                        Label(controller.calendar.trackedTitle ?? (controller.meetings.isPaused ? "Meeting paused" : "Meeting recording active"), systemImage: "record.circle").lineLimit(1)
                        Spacer()
                        if controller.workspaceSection != .meetings {
                            Button("Open meeting") { controller.workspaceSection = .meetings }
                        }
                        if controller.calendar.trackedTitle != nil {
                            Button("Extend 15 min") { controller.calendar.extend() }
                        }
                        if controller.workspaceSection != .meetings {
                            Button("Stop & save") { controller.meetings.finish() }.disabled(controller.meetings.isBusy)
                        }
                    }.flowUIFont(size: 11).padding(14).background(FlowTheme.coral.opacity(0.2))
                }
                if controller.hasFailedRecording && controller.workspaceSection == .notes {
                    HStack {
                        Label("A recording needs another try", systemImage: "exclamationmark.circle")
                        Spacer()
                        Button("Retry") { controller.retryFailedRecording() }
                        Button("Discard") { controller.discardFailedRecording() }
                    }.flowUIFont(size: 11).padding(14).background(FlowTheme.lavender.opacity(0.3))
                }
                // Keep both views mounted so searches and unsaved setting drafts survive navigation.
                ZStack {
                    WorkspaceView(controller: controller)
                        .opacity(controller.workspaceSection == .notes ? 1 : 0)
                        .allowsHitTesting(controller.workspaceSection == .notes)
                        .accessibilityHidden(controller.workspaceSection != .notes)
                    SettingsView(controller: controller, section: controller.workspaceSection)
                        .opacity(isSettings ? 1 : 0)
                        .allowsHitTesting(isSettings)
                        .accessibilityHidden(!isSettings)
                    MeetingsView(controller: controller)
                        .opacity(controller.workspaceSection == .meetings ? 1 : 0)
                        .allowsHitTesting(controller.workspaceSection == .meetings)
                        .accessibilityHidden(controller.workspaceSection != .meetings)
                    if controller.workspaceSection == .permissions {
                        PermissionsView(controller: controller)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(FlowTheme.paper)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(FlowTheme.paper)
        .foregroundStyle(FlowTheme.ink)
        .tint(FlowTheme.lavenderDeep)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissions()
        }
    }

    private var isSettingsArea: Bool {
        ![WorkspaceSection.notes, .meetings, .calendar].contains(controller.workspaceSection)
    }

    private var settingsNavigation: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings").flowDisplayFont(size: 30)
                Spacer()
                Button("Setup guide") { controller.showOnboarding() }
                    .buttonStyle(FlowQuietButtonStyle()).disabled(controller.isDictationBusy)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach([WorkspaceSection.general, .speech, .cleanup, .personalize, .privacy, .permissions]) { section in
                        Button { controller.workspaceSection = section } label: {
                            Text(section == .cleanup ? "Writing" : section == .privacy ? "Privacy" : section.title).font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(controller.workspaceSection == section ? FlowTheme.lavender.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                            .accessibilityValue(controller.workspaceSection == section ? "Selected" : "")
                    }
                }
            }
        }.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 16)
            .background(FlowTheme.paper)
    }

    private var captureControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !controller.setupReadiness.canDictate && !controller.isDictationBusy {
                Text("Ready when you are").font(.system(size: 12, weight: .semibold))
                Text("Connect your provider and check permissions.").font(.caption).foregroundStyle(FlowTheme.inkMuted)
                Button("Finish setup") { controller.showOnboarding() }.buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 7) {
                    Circle().fill(controller.capturePhase == .recording ? FlowTheme.coral : FlowTheme.lavenderDeep).frame(width: 6, height: 6)
                    Text(controller.isDictationBusy ? controller.capturePhase.label : "Dictation").font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                Button {
                    if controller.capturePhase == .recording { controller.finishCapture() }
                    else { controller.startCapture() }
                } label: {
                    Label(controller.capturePhase == .recording ? "Stop & save" : "Record a note", systemImage: controller.capturePhase == .recording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(controller.meetings.occupiesCapture || (controller.isDictationBusy && controller.capturePhase != .recording))
                Text(controller.meetings.occupiesCapture ? "Available after your meeting" : controller.permissions.accessibilityTrusted ? controller.settings.shortcutDisplay + " to dictate anywhere" : "Records directly to Notes")
                    .font(.system(size: 10)).foregroundStyle(FlowTheme.inkMuted)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(FlowTheme.paper, in: RoundedRectangle(cornerRadius: 12))
    }

    private var isSettings: Bool { controller.workspaceSection != .notes && controller.workspaceSection != .meetings && controller.workspaceSection != .permissions }

    private func destination(_ section: WorkspaceSection) -> some View {
        Button { controller.workspaceSection = section } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol).frame(width: 17)
                Text(section.title)
                Spacer(minLength: 0)
            }
            .flowUIFont(size: 12, weight: controller.workspaceSection == section ? .semibold : .medium)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(controller.workspaceSection == section ? FlowTheme.lavender.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(controller.workspaceSection == section ? "Selected" : "")
    }
}
