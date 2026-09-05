import AppKit
import Foundation

@MainActor
final class GlobalHotkey: ObservableObject {
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var globalReleaseMonitor: Any?
    private var localReleaseMonitor: Any?
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var keyCode: UInt16 = 49
    private var requiredModifiers: NSEvent.ModifierFlags = .option
    private var isShortcutDown = false

    func start(
        keyCode: UInt16 = 49,
        modifiers: NSEvent.ModifierFlags = .option,
        onPress: @escaping () -> Void,
        onRelease: (() -> Void)? = nil
    ) {
        stop()
        self.keyCode = keyCode
        requiredModifiers = modifiers.intersection(ShortcutFormatter.supportedModifiers)
        self.onPress = onPress
        self.onRelease = onRelease

        let keyDownHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleKeyDown(event)
        }
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyDownHandler)
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }

        do {
            let releaseHandler: (NSEvent) -> Void = { [weak self] event in
                self?.handleRelease(event)
            }
            globalReleaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp, .flagsChanged], handler: releaseHandler)
            localReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] event in
                self?.handleRelease(event)
                return event
            }
        }
    }

    func stop() {
        [globalKeyDownMonitor, localKeyDownMonitor, globalReleaseMonitor, localReleaseMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        globalKeyDownMonitor = nil
        localKeyDownMonitor = nil
        globalReleaseMonitor = nil
        localReleaseMonitor = nil
        onPress = nil
        onRelease = nil
        isShortcutDown = false
    }

    deinit {
        [globalKeyDownMonitor, localKeyDownMonitor, globalReleaseMonitor, localReleaseMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
    }

    func handleKeyDown(_ event: NSEvent) {
        guard event.type == .keyDown, event.keyCode == keyCode, keyCode != 63 else { return }
        let flags = event.modifierFlags.intersection(ShortcutFormatter.supportedModifiers)
        guard flags.contains(requiredModifiers), !requiredModifiers.isEmpty else { return }
        guard !event.isARepeat, !isShortcutDown else { return }
        isShortcutDown = true
        onPress?()
    }

    func handleRelease(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(ShortcutFormatter.supportedModifiers)

        if keyCode == 63, event.type == .flagsChanged {
            // Other modifier keys also emit flagsChanged. They must not split a Globe recording.
            guard event.keyCode == 63 else { return }
            let functionIsDown = flags.contains(.function)
            if functionIsDown && !isShortcutDown {
                isShortcutDown = true
                onPress?()
            } else if !functionIsDown && isShortcutDown {
                isShortcutDown = false
                onRelease?()
            }
            return
        }

        guard isShortcutDown else { return }
        if event.type == .keyUp && event.keyCode == keyCode {
            isShortcutDown = false
            onRelease?()
        } else if event.type == .flagsChanged && !flags.contains(requiredModifiers) {
            isShortcutDown = false
            onRelease?()
        }
    }
}
