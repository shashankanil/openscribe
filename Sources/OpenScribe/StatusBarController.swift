import AppKit
import Combine

/// Left click opens the workspace; right click (or Control-click) exposes quick actions.
@MainActor
final class StatusBarController: NSObject {
    private let controller: AppController
    private let item: NSStatusItem
    private var subscription: AnyCancellable?

    init(controller: AppController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        subscription = controller.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.updateIndicator() }
        }
        if let button = item.button {
            updateIndicator()
            button.toolTip = "OpenScribe — click to open, right-click for quick actions"
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
        item.button?.toolTip = recording ? "Recording — click to open controls" : paused ? "Meeting paused — click to open controls" : "OpenScribe — click to open, right-click for quick actions"
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
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
        } else {
            controller.openMainWindow()
        }
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }
    @objc private func openWorkspace() { controller.openMainWindow() }
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
