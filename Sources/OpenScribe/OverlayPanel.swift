import AppKit
import Combine
import SwiftUI

/// What the Flowbar is showing. Each mode has a fixed size so the pill can animate between them.
enum FlowbarMode: Equatable {
    case idle
    case idleExpanded
    case dictating
    case processing(String)
    case confirmation(String)
    case meeting(paused: Bool, expanded: Bool = false)
    case meetingSaving

    @MainActor
    static func current(_ controller: AppController, hovering: Bool) -> FlowbarMode {
        let meetings = controller.meetings
        if meetings.activeID != nil, meetings.isRecording || meetings.isPaused { return .meeting(paused: meetings.isPaused, expanded: hovering) }
        if meetings.occupiesCapture { return .meetingSaving }
        switch controller.capturePhase {
        case .recording: return .dictating
        case .transcribing: return .processing("Transcribing")
        case .cleaning: return .processing("Polishing")
        case .ready: return .confirmation("Saved")
        case .idle, .failed: break
        }
        if controller.isDictationBusy { return .processing("Starting") }
        if let message = controller.flowbarMessage { return .confirmation(message) }
        return hovering ? .idleExpanded : .idle
    }

    /// Length along the pill.
    var width: CGFloat {
        switch self {
        case .idle: return 34
        case .idleExpanded: return 150
        case .dictating, .processing, .meetingSaving: return 88
        case .confirmation: return 52
        case let .meeting(_, expanded): return expanded ? Self.meetingExpanded : Self.meetingCollapsed
        }
    }

    static let meetingCollapsed: CGFloat = 84
    static let meetingExpanded: CGFloat = 148

    /// A meeting pill grows from its far end only, so the stop button never moves under the pointer.
    var growsFromTrailingEnd: Bool {
        if case .meeting = self { return true }
        return false
    }

    /// How far the pill extends past its resting, centred position toward its leading end.
    var leadingGrowth: CGFloat { growsFromTrailingEnd ? width - Self.meetingCollapsed : 0 }

    /// Thickness of the pill. Idle is a quiet translucent sliver, light enough to find on any background.
    var height: CGFloat { self == .idle ? 6 : FlowbarLayout.pillHeight }
}

enum FlowbarDock: String { case none, left, right }

enum FlowbarLayout {
    static let pillHeight: CGFloat = 32
    /// Room for the shadow around the pill.
    static let inset: CGFloat = 10
    static let edgeMargin: CGFloat = 14
    /// Gap between the pill and the screen edge it snaps to.
    static let edgeGap: CGFloat = 22
    /// Gap between a docked (vertical) pill and its side of the screen.
    static let dockGap: CGFloat = 3
    /// How close to a side the pointer must be for the pill to stand up vertically.
    static let dockReach: CGFloat = 70
    static let maxWidth: CGFloat = 150
    /// A brief cue that dictation is hands-free.
    static let lockTint = Color(red: 0.55, green: 0.85, blue: 0.65)
    static let ink = Color(red: 0.08, green: 0.09, blue: 0.12)
    static let cream = Color(red: 1.0, green: 0.98, blue: 0.90)
    static let amber = Color(red: 0.94, green: 0.72, blue: 0.39)
    static let red = Color(red: 1.0, green: 0.39, blue: 0.40)
}

@MainActor
final class FlowbarModel: ObservableObject {
    @Published var hovering = false
    /// Docked against the left or right edge, the pill stands up vertically.
    @Published var dock: FlowbarDock = .none
    weak var panel: OverlayPanel?
    private var collapseTask: Task<Void, Never>?

    var vertical: Bool { dock != .none }

    /// Opens the pill for a few seconds so it's easy to spot, then lets it settle back.
    func reveal() {
        collapseTask?.cancel()
        hovering = true
        collapseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            self?.hovering = false
        }
    }

    func setHovering(_ inside: Bool) {
        collapseTask?.cancel()
        if inside { if !hovering { hovering = true }; return }
        // A short grace period keeps the actions from vanishing as the pointer crosses the edge.
        collapseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            self?.hovering = false
        }
    }
}

final class OverlayPanel: NSPanel {
    private weak var controller: AppController?
    let model: FlowbarModel
    private let bubble: NoticeBubblePanel
    private var subscriptions = Set<AnyCancellable>()
    /// Center of the pill in screen coordinates.
    private var anchor: NSPoint?
    private var dragStart: (mouse: NSPoint, anchor: NSPoint)?
    private var pressEvent: NSEvent?
    private var shrinkTask: Task<Void, Never>?
    private var layoutScheduled = false
    /// How far the window's centre is shifted from the anchor toward the pill's leading end.
    private var leadOffset: CGFloat = 0

    @MainActor
    init(controller: AppController) {
        self.controller = controller
        model = FlowbarModel()
        bubble = NoticeBubblePanel(controller: controller, model: model)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: FlowbarLayout.pillHeight + FlowbarLayout.inset * 2),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        model.panel = self
        let host = NSHostingView(rootView: FlowbarView(controller: controller, model: model))
        // The panel sizes itself; letting SwiftUI drive window constraints causes layout loops.
        host.sizingOptions = []
        contentView = host
        // Follow every state change, coalesced to one layout per run loop turn.
        Publishers.Merge(controller.objectWillChange.map { _ in () }, model.objectWillChange.map { _ in () })
            .sink { [weak self] in self?.scheduleLayout() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.resetPlacement(); self?.scheduleLayout() }
            .store(in: &subscriptions)
    }

    override var canBecomeKey: Bool { false }

    override func orderOut(_ sender: Any?) {
        bubble.orderOut(nil)
        super.orderOut(sender)
    }

    /// Dragging works in every state, even over the pill's buttons: once the pointer moves a few
    /// points the press becomes a move and the button underneath is released without firing.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressEvent = event
        case .leftMouseDragged:
            if dragStart != nil { MainActor.assumeIsolated { dragChanged() }; return }
            if let press = pressEvent,
               hypot(event.locationInWindow.x - press.locationInWindow.x, event.locationInWindow.y - press.locationInWindow.y) >= 3 {
                let release = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000), modifierFlags: [],
                                                 timestamp: event.timestamp, windowNumber: windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 0)
                if let release { super.sendEvent(release) }
                MainActor.assumeIsolated {
                    dragStart = (convertPoint(toScreen: press.locationInWindow), anchor ?? .zero)
                    dragChanged()
                }
                return
            }
        case .leftMouseUp:
            pressEvent = nil
            if dragStart != nil { MainActor.assumeIsolated { dragEnded() }; return }
        default: break
        }
        super.sendEvent(event)
    }

    @MainActor
    func show() {
        layout()
        if !isVisible { orderFrontRegardless() }
        placeBubble()
    }

    /// Forget the current position so the next layout follows Settings.
    func resetPlacement() { anchor = nil }

    private func scheduleLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.layoutScheduled = false
                guard self?.isVisible == true else { return }
                self?.layout()
            }
        }
    }

    private var length: CGFloat { model.vertical ? frame.height : frame.width }

    @MainActor
    private func layout() {
        guard let controller, dragStart == nil else { return }
        if anchor == nil { restorePlacement(controller.settings) }
        let mode = FlowbarMode.current(controller, hovering: model.hovering)
        let target = mode.width + FlowbarLayout.inset * 2
        let lead = mode.leadingGrowth / 2
        shrinkTask?.cancel()
        if target >= length || !isVisible {
            place(length: target, lead: lead)
        } else {
            // Let the pill finish shrinking inside the window before the window follows.
            shrinkTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 320_000_000) } catch { return }
                self?.place(length: target, lead: lead)
            }
        }
        placeBubble()
    }

    @MainActor
    private func place(length: CGFloat, lead: CGFloat? = nil) {
        guard let anchor else { return }
        if let lead { leadOffset = lead }
        let thickness = FlowbarLayout.pillHeight + FlowbarLayout.inset * 2
        let size = model.vertical ? NSSize(width: thickness, height: length) : NSSize(width: length, height: thickness)
        let target = NSRect(origin: origin(for: size, around: anchor), size: size)
        guard target != frame else { return }
        setFrame(target, display: true)
    }

    /// Window origin for a pill resting at `anchor`. A pill that grows from one end is shifted so its
    /// other end stays put, and it is kept on screen along its length.
    private func origin(for size: NSSize, around anchor: NSPoint) -> NSPoint {
        var center = anchor
        // Upright pills are rotated clockwise, so their leading end points up.
        if model.vertical { center.y += leadOffset } else { center.x -= leadOffset }
        var origin = NSPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            let slack = FlowbarLayout.inset
            if model.vertical {
                origin.y = min(max(origin.y, visible.minY - slack), visible.maxY - size.height + slack)
            } else {
                origin.x = min(max(origin.x, visible.minX - slack), visible.maxX - size.width + slack)
            }
        }
        return origin
    }

    /// The notice bubble floats beside the pill, on the side with the most room.
    @MainActor
    private func placeBubble() {
        guard let controller, let anchor, isVisible, controller.noticeVisible || controller.meetings.shortMeeting != nil,
              let visible = (screen ?? NSScreen.main)?.visibleFrame else {
            if bubble.isVisible { bubble.orderOut(nil) }
            return
        }
        let size = bubble.fittedSize()
        bubble.setFrame(NSRect(origin: Self.origin(beside: anchor, dock: model.dock, size: size, gap: 0, in: visible), size: size), display: true)
        if !bubble.isVisible { bubble.orderFrontRegardless() }
    }

    /// Where a window of `size` sits next to the pill: beside it when docked, otherwise above it (or below near the top).
    @MainActor
    func companionOrigin(for size: NSSize, gap: CGFloat) -> NSPoint? {
        guard let anchor, let visible = (screen ?? NSScreen.main)?.visibleFrame else { return nil }
        return Self.origin(beside: anchor, dock: model.dock, size: size, gap: gap, in: visible)
    }

    private static func origin(beside anchor: NSPoint, dock: FlowbarDock, size: NSSize, gap: CGFloat, in visible: NSRect) -> NSPoint {
        let half = FlowbarLayout.pillHeight / 2
        var origin: NSPoint
        switch dock {
        case .left: origin = NSPoint(x: anchor.x + half + gap, y: anchor.y - size.height / 2)
        case .right: origin = NSPoint(x: anchor.x - half - gap - size.width, y: anchor.y - size.height / 2)
        case .none:
            let above = anchor.y + half + gap + size.height < visible.maxY
            origin = NSPoint(x: anchor.x - size.width / 2, y: above ? anchor.y + half + gap : anchor.y - half - gap - size.height)
        }
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        origin.y = min(max(origin.y, visible.minY + 6), visible.maxY - size.height - 6)
        return NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
    }

    // MARK: - Placement

    @MainActor
    private func restorePlacement(_ settings: AppSettings) {
        if let placement = settings.flowbarPlacement {
            let screen = NSScreen.screens.first { $0.localizedName == placement.screen } ?? NSScreen.main ?? NSScreen.screens.first
            if let visible = screen?.visibleFrame {
                let dock = FlowbarDock(rawValue: placement.edge ?? "") ?? .none
                setDock(dock)
                anchor = snapped(NSPoint(x: visible.minX + placement.x * visible.width, y: visible.minY + placement.y * visible.height),
                                 in: visible, dock: dock)
                return
            }
        }
        setDock(.none)
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { anchor = .zero; return }
        let halfLength = FlowbarLayout.maxWidth / 2 + FlowbarLayout.edgeMargin + 10
        let bottom = visible.minY + FlowbarLayout.edgeGap + FlowbarLayout.pillHeight / 2
        let top = visible.maxY - FlowbarLayout.edgeGap - FlowbarLayout.pillHeight / 2
        switch settings.overlayPosition {
        case "bottom-left": anchor = NSPoint(x: visible.minX + halfLength, y: bottom)
        case "bottom-right": anchor = NSPoint(x: visible.maxX - halfLength, y: bottom)
        case "top-center": anchor = NSPoint(x: visible.midX, y: top)
        case "top-right": anchor = NSPoint(x: visible.maxX - halfLength, y: top)
        default: anchor = NSPoint(x: visible.midX, y: bottom)
        }
    }

    @MainActor
    private func setDock(_ dock: FlowbarDock) {
        if model.dock != dock { model.dock = dock }
    }

    /// Keeps room for the longest state so the pill never shifts when it grows, and pins docked pills to their side.
    private func snapped(_ point: NSPoint, in visible: NSRect, dock: FlowbarDock) -> NSPoint {
        let halfLength = FlowbarLayout.maxWidth / 2 + FlowbarLayout.edgeMargin
        let halfThickness = FlowbarLayout.pillHeight / 2 + FlowbarLayout.edgeMargin
        switch dock {
        case .left, .right:
            let x = dock == .left ? visible.minX + FlowbarLayout.dockGap + FlowbarLayout.pillHeight / 2
                                  : visible.maxX - FlowbarLayout.dockGap - FlowbarLayout.pillHeight / 2
            return NSPoint(x: x, y: min(max(point.y, visible.minY + halfLength), visible.maxY - halfLength))
        case .none:
            return NSPoint(x: min(max(point.x, visible.minX + halfLength), visible.maxX - halfLength),
                           y: min(max(point.y, visible.minY + halfThickness), visible.maxY - halfThickness))
        }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    private func dock(for point: NSPoint, in visible: NSRect) -> FlowbarDock {
        if point.x - visible.minX < FlowbarLayout.dockReach { return .left }
        if visible.maxX - point.x < FlowbarLayout.dockReach { return .right }
        return .none
    }

    @MainActor
    private func dragChanged() {
        guard let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation
        let moved = NSPoint(x: start.anchor.x + mouse.x - start.mouse.x, y: start.anchor.y + mouse.y - start.mouse.y)
        anchor = moved
        // Stand the pill up as soon as it nears a side, so you see where it will land.
        if let visible = screen(containing: mouse)?.visibleFrame {
            let dock = dock(for: mouse, in: visible)
            if dock != model.dock {
                setDock(dock)
                place(length: length)
            }
        }
        setFrameOrigin(origin(for: frame.size, around: moved))
        placeBubble()
    }

    @MainActor
    private func dragEnded() {
        guard dragStart != nil, let anchor else { dragStart = nil; return }
        dragStart = nil
        guard let screen = screen(containing: anchor) else { return }
        let visible = screen.visibleFrame
        var target = snapped(anchor, in: visible, dock: model.dock)
        if model.dock == .none {
            // Snap to the center line and to the top and bottom edges.
            let half = FlowbarLayout.pillHeight / 2
            if abs(target.x - visible.midX) < 28 { target.x = visible.midX }
            if target.y - half - visible.minY < 40 { target.y = visible.minY + FlowbarLayout.edgeGap + half }
            if visible.maxY - (target.y + half) < 40 { target.y = visible.maxY - FlowbarLayout.edgeGap - half }
        }
        self.anchor = target
        let size = frame.size
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().setFrameOrigin(origin(for: size, around: target))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.placeBubble() }
        }
        controller?.saveFlowbarPlacement(FlowbarPlacement(screen: screen.localizedName,
                                                          x: (target.x - visible.minX) / visible.width,
                                                          y: (target.y - visible.minY) / visible.height,
                                                          edge: model.dock == .none ? nil : model.dock.rawValue))
        layout()
    }
}

// MARK: - Notice bubble

/// A short message that pops out of the pill, such as "We couldn’t find enough speech".
final class NoticeBubblePanel: NSPanel {
    private let host: NSHostingView<NoticeBubbleView>

    @MainActor
    init(controller: AppController, model: FlowbarModel) {
        host = NSHostingView(rootView: NoticeBubbleView(controller: controller, meetings: controller.meetings))
        host.sizingOptions = []
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 34), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        contentView = host
    }

    override var canBecomeKey: Bool { false }

    /// Measures the bubble's current content directly, so a stale window size never squeezes or clips it.
    @MainActor
    func fittedSize() -> NSSize {
        let size = NSHostingController(rootView: host.rootView).sizeThatFits(in: NSSize(width: 380, height: 400))
        return NSSize(width: min(380, ceil(size.width)), height: min(400, ceil(size.height)))
    }
}

struct NoticeBubbleView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var meetings: MeetingController
    @State private var hovering = false

    private static let success = Color(red: 0.30, green: 0.82, blue: 0.55)

    var body: some View {
        Group {
            if let id = meetings.shortMeeting {
                shortMeeting(id)
            } else {
                notice
            }
        }
        // Room for the shadow; the panel itself is transparent.
        .padding(8)
        .environment(\.colorScheme, .dark)
    }

    /// "Was this a mistake?" for a meeting too short to summarize.
    private func shortMeeting(_ id: UUID) -> some View {
        let words = controller.meetings.store.record(id)?.wordCount ?? 0
        return HStack(alignment: .top, spacing: 10) {
            icon("person.2.wave.2.fill", tint: FlowbarLayout.amber)
            VStack(alignment: .leading, spacing: 4) {
                Text(words == 0 ? "That meeting had almost no speech." : "That meeting was very short (\(words) words).")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(FlowbarLayout.cream.opacity(0.95))
                Text("Started by mistake? Summarize only if you need it.")
                    .font(.system(size: 12)).foregroundStyle(FlowbarLayout.cream.opacity(0.62))
                HStack(spacing: 6) {
                    bubbleButton("Summarize", prominent: true) { controller.resolveShortMeeting(summarize: true) }
                    bubbleButton("Keep transcript") { controller.resolveShortMeeting(summarize: false) }
                    bubbleButton("Delete") { controller.resolveShortMeeting(delete: true) }
                }
                .padding(.top, 5)
            }
            .fixedSize()
            closeButton(help: "Keep the transcript without a summary") { controller.resolveShortMeeting(summarize: false) }
        }
        .modifier(BubbleChrome())
    }

    private func bubbleButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(prominent ? FlowbarLayout.ink : FlowbarLayout.cream.opacity(0.88))
                .padding(.horizontal, 10).frame(height: 24)
                .background(prominent ? FlowbarLayout.amber : .white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private var notice: some View {
        let info = controller.infoNotice != nil
        let full = controller.lastError ?? ""
        let message = controller.infoNotice ?? UserNotice.summary(full)
        let hasDetails = !info && !full.isEmpty && full != message
        return HStack(alignment: .top, spacing: 10) {
            icon(info ? "checkmark.circle.fill" : "exclamationmark.circle.fill", tint: info ? Self.success : FlowbarLayout.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowbarLayout.cream.opacity(0.95))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if info || hasDetails {
                    Text(info ? "Open dictionary" : "Show details")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(FlowbarLayout.cream.opacity(hovering ? 0.8 : 0.5))
                }
            }
            .frame(minWidth: 150, maxWidth: 260, alignment: .leading)
            .padding(.top, 1)
            closeButton(help: "Dismiss") { controller.dismissNotice() }
        }
        .modifier(BubbleChrome())
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { inside in
            hovering = inside
            controller.holdNotice(inside)
        }
        .onTapGesture { controller.inspectNotice() }
        .help(info ? "Click to open your dictionary" : "Click for details")
    }

    private func icon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
    }

    private func closeButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(FlowbarLayout.cream.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Shared look for bubbles beside the Flowbar.
private struct BubbleChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.leading, 12).padding(.trailing, 9).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FlowbarLayout.ink))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .fixedSize()
            .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
    }
}

// MARK: - View

private struct FlowbarUprightKey: EnvironmentKey { static let defaultValue = Angle.zero }

extension EnvironmentValues {
    /// Counter-rotation that keeps icons and text upright when the pill stands vertically.
    var flowbarUpright: Angle {
        get { self[FlowbarUprightKey.self] }
        set { self[FlowbarUprightKey.self] = newValue }
    }
}

struct FlowbarView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var model: FlowbarModel

    private var mode: FlowbarMode { FlowbarMode.current(controller, hovering: model.hovering) }

    var body: some View {
        let mode = mode
        let vertical = model.vertical
        let idle = mode == .idle
        HStack(spacing: 8) { content(mode) }
            .padding(.horizontal, idle ? 6 : 11)
            // Content stays pinned to the stop button while the pill animates its width.
            .frame(width: mode.width, height: mode.height, alignment: mode.growsFromTrailingEnd ? .trailing : .center)
            // Idle: a pale sliver with a dark rim, faint but findable on light and dark screens alike.
            .background(Capsule().fill(idle ? FlowbarLayout.cream.opacity(0.5) : FlowbarLayout.ink))
            .overlay(Capsule().strokeBorder(idle ? Color.black.opacity(0.3) : .white.opacity(0.13), lineWidth: idle ? 0.5 : 1))
            .clipShape(Capsule())
            .environment(\.flowbarUpright, .degrees(vertical ? -90 : 0))
            .rotationEffect(.degrees(vertical ? 90 : 0))
            .frame(width: vertical ? mode.height : mode.width, height: vertical ? mode.width : mode.height)
            .shadow(color: .black.opacity(idle ? 0 : 0.28), radius: idle ? 0 : 6, y: 2)
            // Docked, every state hugs the screen edge instead of floating at the window's center.
            .padding(model.dock == .left ? .leading : .trailing, model.dock == .none ? 0 : FlowbarLayout.inset)
            // A meeting pill is pinned at its stop-button end while it grows and shrinks.
            .padding(vertical ? .bottom : .trailing, mode.growsFromTrailingEnd ? FlowbarLayout.inset : 0)
            // The idle sliver is tiny, so the whole window catches the pointer.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: mode))
            .contentShape(Rectangle())
            .onHover { model.setHovering($0) }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: mode)
            .environment(\.colorScheme, .dark)
            .help(help(mode))
            .contextMenu { menu }
    }

    private func alignment(for mode: FlowbarMode) -> Alignment {
        let pinned = mode.growsFromTrailingEnd
        switch model.dock {
        case .left: return pinned ? .bottomLeading : .leading
        case .right: return pinned ? .bottomTrailing : .trailing
        case .none: return pinned ? .trailing : .center
        }
    }

    @ViewBuilder private func content(_ mode: FlowbarMode) -> some View {
        switch mode {
        case .idle:
            Button { controller.toggleCaptureFromQuickPanel() } label: {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Start dictation")
        case .idleExpanded:
            Button { controller.toggleCaptureFromQuickPanel() } label: {
                FlowSquiggle(color: FlowbarLayout.cream.opacity(0.85), motion: .still)
                    .frame(width: 34, height: 14).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Start dictation")
            Spacer(minLength: 0)
            FlowbarButton(symbol: "mic.fill", help: hint("Dictate", .dictate)) { controller.toggleCaptureFromQuickPanel() }
                .disabled(controller.meetings.occupiesCapture)
            FlowbarButton(symbol: "person.2.wave.2.fill", help: hint("Start meeting", .meeting)) { controller.startMeeting() }
                .disabled(!controller.canStartMeeting)
            ScreenshotMenu(controller: controller, help: hint("Screenshot to today’s note · hold for more", .screenshotArea),
                           hint: hint)
        case .dictating:
            // The line is the whole control: click to finish, Escape to cancel.
            Button { controller.finishCapture() } label: {
                RecorderSquiggle(recorder: controller.recorder, color: controller.handsFree ? FlowbarLayout.lockTint : FlowbarLayout.cream)
                    .frame(maxWidth: .infinity).frame(height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.handsFree ? "Hands-free dictation. Click or press the key again to finish."
                                                     : "Listening. Click to finish, or press Escape to cancel.")
        case .processing, .meetingSaving:
            FlowSquiggle(color: FlowbarLayout.amber, motion: .flowing)
                .frame(maxWidth: .infinity).frame(height: 16)
                .accessibilityLabel(mode == .meetingSaving ? "Saving meeting" : "Transcribing")
        case let .confirmation(message):
            Upright {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(FlowbarLayout.amber)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(message)
        case let .meeting(paused, expanded):
            // Hovering slides notes and screenshot buttons in from the far end. The line (open notes)
            // and the stop button keep their exact position, so the pointer never chases them.
            if expanded {
                Group {
                    FlowbarButton(symbol: "note.text", help: "Meeting notes") { controller.showMeetingNotes() }
                    ScreenshotMenu(controller: controller, help: hint("Screenshot into this meeting · hold for more", .screenshotArea),
                                   hint: hint)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
            Button { controller.showMeetingNotes() } label: {
                RecorderSquiggle(recorder: controller.meetings.microphone, color: FlowbarLayout.cream.opacity(paused ? 0.4 : 1),
                                 motion: paused ? .still : .live)
                    .frame(width: 34, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(paused ? "Meeting paused. Open meeting notes." : "Recording meeting. Open meeting notes.")
            MeetingStopButton(paused: paused, busy: controller.meetings.isBusy) { controller.meetings.finish() }
        }
    }

    /// Hover text explains the one-click behavior of each state without adding controls.
    private func help(_ mode: FlowbarMode) -> String {
        switch mode {
        case .idle, .idleExpanded: return controller.captureHint
        case .dictating: return controller.handsFree ? "Hands-free · press the key again or click to finish" : "Click to finish · Esc to cancel"
        case let .processing(label): return label + "…"
        case .meetingSaving: return "Saving meeting…"
        case let .confirmation(message): return message
        case .meeting:
            let stop = controller.settings.shortcut(for: .meeting).map { " · \($0.display) to stop" } ?? ""
            return "Meeting · \(FlowFormat.duration(controller.meetings.elapsed)) · click for notes\(stop)"
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Today’s note") { controller.openDayNote() }
        Button("Open OpenScribe") { controller.openWorkspace() }
        Divider()
        Menu("Position") {
            ForEach([("Bottom center", "bottom-center"), ("Bottom left", "bottom-left"), ("Bottom right", "bottom-right"),
                     ("Top center", "top-center"), ("Top right", "top-right")], id: \.1) { title, value in
                Button(title) { controller.updateSettings { $0.overlayPosition = value; $0.flowbarPlacement = nil } }
            }
        }
        Toggle("Keep on screen when idle", isOn: Binding(get: { controller.settings.showOverlayWhenIdle },
                                                          set: { value in controller.updateSettings { $0.showOverlayWhenIdle = value } }))
        Button("Shortcuts…") { controller.open(.shortcuts) }
        Button("Settings…") { controller.openSettings() }
        switch mode {
        case .dictating:
            Divider()
            Button("Stop and save") { controller.finishCapture() }
            Button("Cancel recording", role: .destructive) { controller.cancelCapture() }
        case .processing:
            Divider()
            Button("Cancel", role: .destructive) { controller.cancelCapture() }
        case let .meeting(paused, _):
            Divider()
            Button("Meeting notes…") { controller.showMeetingNotes() }
            Button(paused ? "Resume meeting" : "Pause meeting") {
                if paused { controller.meetings.resume() } else { controller.meetings.pause() }
            }.disabled(controller.meetings.isBusy)
            Button("Stop meeting and save") { controller.meetings.finish() }.disabled(controller.meetings.isBusy)
        default: EmptyView()
        }
    }

    private func hint(_ title: String, _ action: ShortcutAction) -> String {
        controller.settings.shortcut(for: action).map { "\(title)  \($0.display)" } ?? title
    }
}

/// Keeps glyphs and text upright when the pill is rotated against a side of the screen.
private struct Upright<Content: View>: View {
    @Environment(\.flowbarUpright) private var angle
    @ViewBuilder let content: Content
    var body: some View { content.rotationEffect(angle) }
}

private struct ScreenshotMenu: View {
    let controller: AppController
    let help: String
    let hint: (String, ShortcutAction) -> String
    @Environment(\.flowbarUpright) private var angle

    var body: some View {
        Menu {
            ForEach(ScreenshotKind.allCases, id: \.self) { kind in
                Button(hint(kind.title, kind.action)) { controller.takeScreenshot(kind) }
            }
        } label: {
            Image(systemName: "camera.viewfinder").font(.system(size: 11.5, weight: .semibold))
        } primaryAction: { controller.takeScreenshot(.area) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .rotationEffect(angle)
            .frame(width: 24, height: 24).foregroundStyle(.white.opacity(0.75))
            .help(help)
    }
}

/// A small red stop square: the recording indicator and the way to end the meeting in one.
private struct MeetingStopButton: View {
    let paused: Bool
    let busy: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(FlowbarLayout.red)
                .frame(width: 7, height: 7)
                .frame(width: 20, height: 20)
                .background(FlowbarLayout.red.opacity(hovering ? 0.3 : 0.16), in: Circle())
                .opacity(paused ? 0.6 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering = $0 }
        .help("Stop meeting and save")
        .accessibilityLabel("Stop meeting and save")
    }
}

private struct FlowbarButton: View {
    let symbol: String
    let help: String
    var tint: Color = .white.opacity(0.75)
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.flowbarUpright) private var upright

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).foregroundStyle(tint)
                .rotationEffect(upright)
                .frame(width: 24, height: 24)
                .background(.white.opacity(hovering ? 0.14 : 0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 && isEnabled }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct RecordingDot: View {
    @State private var dim = false
    var body: some View {
        Circle().fill(FlowbarLayout.red).frame(width: 6, height: 6)
            .opacity(dim ? 0.4 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true } }
    }
}

/// The OpenScribe mark as a single line. Still, it is the logo's wave; live, it follows the voice;
/// flowing, a bright stroke traces the logo while work is in progress.
struct FlowSquiggle: View {
    enum Motion { case still, live, flowing }

    var level: CGFloat = 0
    var color: Color
    var motion: Motion
    var lineWidth: CGFloat = 2
    @State private var voice = VoiceFollower()

    var body: some View {
        switch motion {
        case .still:
            WhisperlightWave()
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .padding(.vertical, 1)
        case .live:
            TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                Canvas { graphics, size in
                    voice.step(to: level, at: context.date.timeIntervalSinceReferenceDate)
                    graphics.stroke(Self.path(in: size, phase: voice.phase, amplitude: voice.level(delay:)), with: .color(color),
                                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        case .flowing:
            TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                Canvas { graphics, size in
                    Self.trace(in: &graphics, size: size, time: context.date.timeIntervalSinceReferenceDate,
                               color: color, lineWidth: lineWidth)
                }
            }
        }
    }

    /// A faint logo wave with a comet that sweeps along it, easing in and out, then pauses off the end.
    static func trace(in graphics: inout GraphicsContext, size: CGSize, time: TimeInterval, color: Color, lineWidth: CGFloat) {
        let wave = WhisperlightWave().path(in: CGRect(origin: .zero, size: size).insetBy(dx: lineWidth / 2, dy: lineWidth / 2 + 1))
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        graphics.stroke(wave, with: .color(color.opacity(0.2)), style: style)
        let cycle = 1.5
        let t = (time / cycle).truncatingRemainder(dividingBy: 1)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        let tail = 0.42
        let head = eased * (1 + tail)
        // Overlapping slices with falling opacity read as one stroke that fades toward its tail.
        let slices = 5
        for slice in (0..<slices).reversed() {
            let to = head - tail * Double(slice) / Double(slices)
            let from = to - tail / Double(slices) - 0.01
            guard to > 0, from < 1 else { continue }
            let opacity = pow(1 - Double(slice) / Double(slices), 1.6)
            graphics.stroke(wave.trimmedPath(from: max(0, from), to: min(1, to)), with: .color(color.opacity(opacity)), style: style)
        }
    }

    /// One smooth wave in the logo's shape. Its height comes from the voice, and louder moments
    /// ripple outward from the center, so the line answers each syllable instead of just oscillating.
    /// `amplitude(delay)` gives the smoothed voice level, 0…1, from `delay` seconds ago.
    static func path(in size: CGSize, phase: Double, amplitude: (Double) -> CGFloat) -> Path {
        let half = max(1, size.height / 2 - 1)
        var path = Path()
        let steps = max(16, Int(size.width / 1.5))
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            let envelope = pow(sin(.pi * x), 0.9)
            let level = amplitude(abs(x - 0.5) * 2 * VoiceFollower.ripple)
            let height = half * (0.1 + 0.9 * min(1, level))
            let y = size.height / 2 - height * CGFloat(envelope * sin(2 * .pi * 3.5 * x - phase))
            let point = CGPoint(x: CGFloat(x) * size.width, y: y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    static func path(in size: CGSize, phase: Double, level: CGFloat) -> Path {
        path(in: size, phase: phase) { _ in level }
    }
}

/// The live line bound to a recorder. Only this small view redraws as the level changes, not its parent.
struct RecorderSquiggle: View {
    @ObservedObject var recorder: AudioRecorder
    var color: Color
    var motion: FlowSquiggle.Motion = .live

    var body: some View {
        FlowSquiggle(level: CGFloat(recorder.inputLevel), color: color, motion: motion)
    }
}

/// Per-frame smoothing for the live line: snaps up with the voice, settles gently, drifts only while
/// you talk, and remembers the last moments so loud syllables can ripple outward.
final class VoiceFollower {
    /// Seconds a syllable takes to travel from the center to the ends of the line.
    static let ripple = 0.28
    private(set) var phase: Double = 0
    private var current: CGFloat = 0
    private var last: TimeInterval?
    private var history: [(time: TimeInterval, level: CGFloat)] = []

    @discardableResult
    func step(to target: CGFloat, at time: TimeInterval) -> CGFloat {
        let delta = min(0.1, max(0, time - (last ?? time)))
        last = time
        // Perceptual boost so normal speech fills the pill, not just shouting.
        let boosted = min(1, pow(max(0, target), 0.55) * 1.5)
        let rate: CGFloat = boosted > current ? 30 : 7
        current += (boosted - current) * min(1, rate * CGFloat(delta))
        phase += delta * (1.2 + 7 * Double(current))
        history.append((time, current))
        if let first = history.first, time - first.time > Self.ripple + 0.1 { history.removeFirst() }
        return current
    }

    /// The level `delay` seconds ago, interpolated between frames.
    func level(delay: Double) -> CGFloat {
        guard let newest = history.last else { return current }
        let when = newest.time - delay
        guard let index = history.lastIndex(where: { $0.time <= when }) else { return history.first?.level ?? current }
        guard index + 1 < history.count else { return history[index].level }
        let a = history[index], b = history[index + 1]
        let t = b.time > a.time ? CGFloat((when - a.time) / (b.time - a.time)) : 0
        return a.level + (b.level - a.level) * t
    }
}
