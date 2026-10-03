import AppKit
import Combine
import SwiftUI

/// Left click opens quick capture controls; right click retains the native menu.
@MainActor
final class StatusBarController: NSObject {
    private let controller: AppController
    private let item: NSStatusItem
    private var subscription: AnyCancellable?
    private let popover = NSPopover()

    init(controller: AppController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: QuickPanelView(controller: controller, close: { [weak self] in self?.popover.performClose(nil) }))
        subscription = controller.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.updateIndicator() }
        }
        if let button = item.button {
            updateIndicator()
            button.toolTip = "OpenScribe — click for controls, right-click for menu"
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func updateIndicator() {
        let recording = controller.meetings.isRecording || controller.capturePhase == .recording
        let paused = controller.meetings.isPaused
        // Draw the same vector wave as the app logo, without its tile/background.
        // A template image lets macOS choose the correct monochrome menu-bar tint.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let wave = WhisperlightWave().path(in: CGRect(x: 1.5, y: 3, width: 15, height: 12))
            context.addPath(wave.cgPath)
            context.strokePath()
            if recording {
                context.fillEllipse(in: CGRect(x: 7.5, y: 15, width: 3, height: 3))
            } else if paused {
                context.fill(CGRect(x: 6.5, y: 15, width: 1.5, height: 3))
                context.fill(CGRect(x: 10, y: 15, width: 1.5, height: 3))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = recording ? "OpenScribe — recording" : paused ? "OpenScribe — meeting paused" : "Open OpenScribe"
        item.button?.image = image
        item.button?.contentTintColor = nil
        item.button?.toolTip = recording ? "Recording — click to open controls" : paused ? "Meeting paused — click to open controls" : "OpenScribe — click for controls, right-click for menu"
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            let menu = NSMenu()
            let status = NSMenuItem(title: controller.capturePhase == .recording ? "● Recording dictation" : controller.meetings.occupiesCapture ? "● Meeting in progress" : "OpenScribe", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
            menu.addItem(action("Open OpenScribe", #selector(openWorkspace)))
            menu.addItem(action("Meetings", #selector(openMeetings)))
            menu.addItem(action("Settings…", #selector(openSettings)))
            menu.addItem(.separator())
            let capture = action(controller.capturePhase == .recording ? "Finish dictation" : "Start dictation", #selector(toggleCapture))
            capture.isEnabled = !controller.meetings.occupiesCapture && controller.capturePhase != .transcribing && controller.capturePhase != .cleaning
            menu.autoenablesItems = false
            menu.addItem(capture)
            let paste = action("Paste latest note", #selector(pasteLast))
            paste.isEnabled = controller.canPasteLast
            menu.addItem(paste)
            if controller.capturePhase == .recording || controller.capturePhase == .transcribing || controller.capturePhase == .cleaning {
                menu.addItem(action("Cancel dictation", #selector(cancelCapture)))
            }
            if controller.hasFailedRecording {
                menu.addItem(action("Retry failed recording", #selector(retry)))
            }
            if controller.calendar.trackedTitle != nil {
                menu.addItem(action("Not happening — stop without transcribing", #selector(declineCalendar)))
            }
            if controller.meetings.activeID != nil {
                menu.addItem(action("Finish meeting", #selector(finishMeeting)))
            }
            menu.addItem(.separator())
            menu.addItem(action("Quit OpenScribe", #selector(quit)))
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showQuickPanel()
        }
    }

    func showQuickPanel() {
        guard let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }
    @objc private func openWorkspace() { controller.openWorkspace() }
    @objc private func openMeetings() { controller.workspaceSection = .meetings; controller.openMainWindow() }
    @objc private func openSettings() { controller.openSettings() }
    @objc private func toggleCapture() { controller.toggleCapture() }
    @objc private func cancelCapture() { controller.cancelCapture() }
    @objc private func pasteLast() { controller.pasteLastDictation() }
    @objc private func retry() { controller.retryFailedRecording() }
    @objc private func declineCalendar() { controller.calendar.decline() }
    @objc private func finishMeeting() { controller.meetings.finish() }
    @objc private func quit() { NSApp.terminate(nil) }
}


struct QuickPanelView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var recorder: AudioRecorder
    let close: () -> Void
    @State private var copiedID: UUID?

    init(controller: AppController, close: @escaping () -> Void) {
        self.controller = controller
        recorder = controller.recorder
        self.close = close
    }

    private var recording: Bool { controller.capturePhase == .recording }
    private var processing: Bool { controller.capturePhase == .transcribing || controller.capturePhase == .cleaning }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                WhisperlightLogo(size: 29)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenScribe").font(.system(size: 14, weight: .semibold))
                    Text(recording ? "Listening" : processing ? "Working on your words" : "A little less typing")
                        .font(.system(size: 11)).foregroundStyle(FlowTheme.inkMuted)
                }
                Spacer()
                FlowIconButton(symbol: "house", help: "Home — open Notes") { close(); controller.openWorkspace() }
                FlowIconButton(symbol: "gearshape", help: "Settings") { close(); controller.openSettings() }
            }
            if controller.meetings.occupiesCapture {
                FlowBanner(symbol: "person.2.wave.2", tint: FlowTheme.recording, title: controller.meetings.isPaused ? "Meeting paused" : "Recording a meeting") {
                    Button("Open") { close(); controller.open(.meetings) }.buttonStyle(.flow(.secondary, size: .small))
                }
            } else if !controller.setupReadiness.canDictate && !controller.isDictationBusy {
                Text("Connect a provider and allow the microphone to start.").font(.system(size: 12)).foregroundStyle(FlowTheme.inkMuted)
                Button("Finish setup") { close(); controller.showOnboarding() }.buttonStyle(.flow(.primary, size: .large, fullWidth: true))
            } else {
                if recording || processing {
                    HStack {
                        FlowWaveform(levels: recorder.inputLevels, color: recording ? FlowTheme.recording : FlowTheme.accent, maxHeight: 24, animated: processing)
                        Spacer()
                        if recording {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(FlowFormat.duration(context.date.timeIntervalSince(controller.captureStartedAt ?? context.date)))
                                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(FlowTheme.inkMuted)
                            }
                        }
                        FlowIconButton(symbol: "xmark", help: "Cancel dictation") { close(); controller.cancelCapture() }
                    }
                }
                Button {
                    close()
                    if recording { controller.finishCapture() } else { controller.toggleCaptureFromQuickPanel() }
                } label: {
                    Label(recording ? "Stop & save" : processing ? controller.captureHint : "Start dictation", systemImage: recording ? "stop.fill" : "mic.fill")
                }.buttonStyle(.flow(.primary, size: .large, fullWidth: true)).disabled(processing || controller.isDictationBusy && !recording)
                if !recording && !processing {
                    HStack { FlowKeycaps(shortcut: controller.settings.shortcutDisplay); Text("in any app").font(.system(size: 11)).foregroundStyle(FlowTheme.inkMuted) }.frame(maxWidth: .infinity)
                }
            }
            if controller.hasFailedRecording {
                FlowBanner(symbol: "arrow.clockwise", tint: FlowTheme.warning, title: "Recording ready to retry") {
                    Button("Retry") { close(); controller.retryFailedRecording() }.buttonStyle(.flow(.secondary, size: .small)).disabled(controller.isDictationBusy || controller.meetings.occupiesCapture)
                }
            }
            if !controller.notes.isEmpty {
                Rectangle().fill(FlowTheme.line).frame(height: 1)
                HStack {
                    Text("RECENT NOTES").font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundStyle(FlowTheme.inkFaint)
                    Spacer()
                    Button("View all") { close(); controller.openWorkspace() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(FlowTheme.accent)
                }
                VStack(spacing: 2) {
                    ForEach(controller.notes.prefix(3)) { note in
                        Button {
                            FlowFormat.copy(note.latestText)
                            copiedID = note.id
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(note.latestText.isEmpty ? note.displayTitle : note.latestText).font(.system(size: 12.5)).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: 4) {
                                        Text(note.lastCapturedAt, style: .relative)
                                        if note.isDailyNote { Text("·"); Text(note.captureCountLabel) }
                                    }.font(.system(size: 10.5)).foregroundStyle(FlowTheme.inkFaint)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: copiedID == note.id ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(copiedID == note.id ? FlowTheme.success : FlowTheme.inkFaint)
                            }.padding(8).contentShape(Rectangle()).flowHoverHighlight(radius: 8)
                        }.buttonStyle(.plain).help(note.isDailyNote ? "Copy latest capture" : "Copy note")
                    }
                }
            }
            Rectangle().fill(FlowTheme.line).frame(height: 1)
            HStack {
                Button("Meetings") { close(); controller.open(.meetings) }.buttonStyle(.flow(.ghost, size: .small))
                Button("Paste latest") { close(); controller.pasteLastFromQuickPanel() }.buttonStyle(.flow(.ghost, size: .small)).disabled(!controller.canPasteLast)
                Spacer()
                FlowIconButton(symbol: "power", help: "Quit OpenScribe", size: 24) { close(); NSApp.terminate(nil) }
            }
        }
        .padding(18).frame(width: 340).background(FlowTheme.background).tint(FlowTheme.accent)
        .onDisappear { copiedID = nil }
    }
}
