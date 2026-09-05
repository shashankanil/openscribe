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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    WhisperlightLogo(size: 32)
                    Text("OpenScribe").flowUIFont(size: 17, weight: .semibold)
                }.padding(.horizontal, 10).padding(.top, 12)

                VStack(alignment: .leading, spacing: 5) {
                    destination(.notes)
                    destination(.meetings)
                    destination(.calendar)
                    destination(.personalize)
                    Button { controller.workspaceSection = .general } label: {
                        Label("Settings", systemImage: "gearshape")
                            .flowUIFont(size: 12, weight: .medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(isSettingsArea ? FlowTheme.lavender.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                    if isSettingsArea {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach([WorkspaceSection.general, .speech, .cleanup, .privacy, .permissions]) { section in
                                Button { controller.workspaceSection = section } label: {
                                    Text(section.title).font(.system(size: 12, weight: controller.workspaceSection == section ? .semibold : .regular))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8).padding(.horizontal, 12)
                                        .background(controller.workspaceSection == section ? FlowTheme.lavender.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.leading, 20)
                    }

                }
                Spacer()
                if controller.hasFailedRecording {
                    Button { controller.workspaceSection = .notes } label: {
                        Label("Recover recording", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }.buttonStyle(.plain).padding(.horizontal, 12)
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        Circle().fill(controller.capturePhase == .recording ? FlowTheme.coral : FlowTheme.lavenderDeep)
                            .frame(width: 6, height: 6)
                        Text(controller.capturePhase.label).flowUIFont(size: 11, weight: .medium)
                    }
                    Text(controller.settings.shortcutDisplay + " to dictate")
                        .flowUIFont(size: 11).foregroundStyle(FlowTheme.inkMuted)

                }.padding(12)
            }
            .padding(14)
            .frame(width: 220)
            .background(FlowTheme.paperMuted)
            Divider().overlay(FlowTheme.line)
            VStack(spacing: 0) {


                if let title = controller.calendar.trackedTitle {
                    HStack {
                        Label(title, systemImage: "calendar").lineLimit(1)
                        Spacer()
                        Button("Not happening · stop") { controller.calendar.decline() }
                        Button("Extend 15 min") { controller.calendar.extend() }
                    }.font(.caption).padding(12).background(FlowTheme.lavender.opacity(0.3))
                }
                if controller.meetings.occupiesCapture {
                    HStack {
                        Label(controller.meetings.isPaused ? "Meeting paused" : "Meeting recording active", systemImage: "record.circle")
                        Spacer()
                        Button("Open meeting") { controller.workspaceSection = .meetings }
                        Button("Stop & save") { controller.meetings.finish() }.disabled(controller.meetings.isBusy)
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

    private var isSettingsArea: Bool { isSettings && controller.workspaceSection != .personalize && controller.workspaceSection != .calendar || controller.workspaceSection == .permissions }

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
