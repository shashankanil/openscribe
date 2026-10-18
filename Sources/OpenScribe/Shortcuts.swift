import AppKit
import Carbon.HIToolbox
import Foundation

/// Everything that can be bound to a global shortcut.
enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case dictate
    case holdToTalk
    case meeting
    case screenshotArea
    case screenshotWindow
    case screenshotScreen
    case pasteLast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictate: return "Dictate"
        case .holdToTalk: return "Push to talk"
        case .meeting: return "Start or stop a meeting"
        case .screenshotArea: return "Screenshot an area"
        case .screenshotWindow: return "Screenshot a window"
        case .screenshotScreen: return "Screenshot the screen"
        case .pasteLast: return "Paste last dictation"
        }
    }

    var detail: String {
        switch self {
        case .dictate: return "Tap to start and stop. Hold to talk, release to finish."
        case .holdToTalk: return "Records only while held down."
        case .meeting: return "Records your microphone and system audio."
        case .screenshotArea: return "Drag to select. Saved to today’s note."
        case .screenshotWindow: return "Click a window. Saved to today’s note."
        case .screenshotScreen: return "The screen under your pointer. Saved to today’s note."
        case .pasteLast: return "Pastes your latest dictation into the focused app."
        }
    }

    var symbol: String {
        switch self {
        case .dictate: return "mic"
        case .holdToTalk: return "hand.point.down"
        case .meeting: return "person.2.wave.2"
        case .screenshotArea: return "rectangle.dashed"
        case .screenshotWindow: return "macwindow"
        case .screenshotScreen: return "display"
        case .pasteLast: return "doc.on.clipboard"
        }
    }

    /// Release events matter only for actions that act while a key is held.
    var usesRelease: Bool { self == .dictate || self == .holdToTalk }

    static let dictation: [ShortcutAction] = [.dictate, .holdToTalk, .pasteLast]
    static let capture: [ShortcutAction] = [.meeting, .screenshotArea, .screenshotWindow, .screenshotScreen]
}

struct KeyShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt
    var display: String

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var isGlobe: Bool { keyCode == 63 }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, display: String? = nil) {
        self.keyCode = keyCode
        let supported = modifiers.intersection(ShortcutFormatter.supportedModifiers)
        self.modifiers = supported.rawValue
        self.display = display ?? ShortcutFormatter.display(keyCode: keyCode, modifiers: supported)
    }

    static let globe = KeyShortcut(keyCode: 63, modifiers: .function, display: "Globe")
    static let optionSpace = KeyShortcut(keyCode: 49, modifiers: .option, display: "⌥ Space")

    /// Two bindings collide when they would fire on the same key press.
    func conflicts(with other: KeyShortcut) -> Bool {
        if isGlobe || other.isGlobe { return isGlobe && other.isGlobe }
        return keyCode == other.keyCode && modifierFlags.subtracting(.function) == other.modifierFlags.subtracting(.function)
    }
}

enum ShortcutDefaults {
    // Mirrors macOS ⌘⇧3/4/5 so the screenshot keys are easy to remember.
    static let bindings: [ShortcutAction: KeyShortcut] = [
        .dictate: .optionSpace,
        .meeting: KeyShortcut(keyCode: 46, modifiers: [.option, .shift]),
        .screenshotScreen: KeyShortcut(keyCode: 20, modifiers: [.option, .shift]),
        .screenshotArea: KeyShortcut(keyCode: 21, modifiers: [.option, .shift]),
        .screenshotWindow: KeyShortcut(keyCode: 23, modifiers: [.option, .shift]),
    ]

    /// Earlier versions had a single key plus a mode. Keep that key working as the user set it up.
    static func migrated(keyCode: UInt16, modifiers: UInt, display: String, mode: DictationMode) -> [String: KeyShortcut] {
        let legacy = KeyShortcut(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers), display: display)
        var result = [String: KeyShortcut]()
        let legacyAction: ShortcutAction = mode == .holdToTalk || legacy.isGlobe ? .holdToTalk : .dictate
        result[legacyAction.rawValue] = legacy
        for (action, shortcut) in bindings where result[action.rawValue] == nil {
            guard !result.values.contains(where: { $0.conflicts(with: shortcut) }) else { continue }
            result[action.rawValue] = shortcut
        }
        return result
    }
}

extension AppSettings {
    func shortcut(for action: ShortcutAction) -> KeyShortcut? { shortcuts[action.rawValue] }

    /// Assigning a shortcut removes it from any other action so one press never does two things.
    @discardableResult
    mutating func assign(_ shortcut: KeyShortcut?, to action: ShortcutAction) -> ShortcutAction? {
        var displaced: ShortcutAction?
        if let shortcut {
            for other in ShortcutAction.allCases where other != action {
                if let existing = shortcuts[other.rawValue], existing.conflicts(with: shortcut) {
                    shortcuts[other.rawValue] = nil
                    displaced = other
                }
            }
        }
        shortcuts[action.rawValue] = shortcut
        syncLegacyShortcut()
        return displaced
    }

    /// Keep the original single-shortcut fields meaningful for hints and older builds.
    mutating func syncLegacyShortcut() {
        if let primary = shortcuts[ShortcutAction.dictate.rawValue] ?? shortcuts[ShortcutAction.holdToTalk.rawValue] {
            shortcutKeyCode = primary.keyCode
            shortcutModifiers = primary.modifiers
            shortcutDisplay = primary.display
            dictationMode = shortcuts[ShortcutAction.dictate.rawValue] == nil ? .holdToTalk : .toggle
        }
    }

    var dictationHint: String? {
        if let dictate = shortcut(for: .dictate) { return dictate.display }
        return shortcut(for: .holdToTalk)?.display
    }
}

// MARK: - Registration

/// Registers system-wide hotkeys. Key combinations use Carbon hot keys, which are consumed so the
/// keystroke never reaches the focused app and need no Accessibility access. Globe has no Carbon
/// equivalent and is observed through modifier-change events instead.
@MainActor
final class HotkeyCenter {
    private var registrations: [UInt32: (ref: EventHotKeyRef, action: ShortcutAction)] = [:]
    private var handlerRef: EventHandlerRef?
    private var globe: GlobalHotkey?
    private var nextID: UInt32 = 1
    private var onPress: ((ShortcutAction) -> Void)?
    private var onRelease: ((ShortcutAction) -> Void)?
    private(set) var failures: [ShortcutAction] = []
    private var escapeRef: EventHotKeyRef?
    var onEscape: (() -> Void)?

    private static let signature: OSType = 0x4F53_4352 // "OSCR"

    func start(bindings: [ShortcutAction: KeyShortcut], globeAllowed: Bool,
               onPress: @escaping (ShortcutAction) -> Void, onRelease: @escaping (ShortcutAction) -> Void) {
        stop()
        self.onPress = onPress
        self.onRelease = onRelease
        installHandlerIfNeeded()
        failures = []
        for (action, shortcut) in bindings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if shortcut.isGlobe {
                guard globeAllowed else { failures.append(action); continue }
                let monitor = GlobalHotkey()
                monitor.start(keyCode: 63, modifiers: .function,
                              onPress: { [weak self] in self?.onPress?(action) },
                              onRelease: { [weak self] in self?.onRelease?(action) })
                globe = monitor
                continue
            }
            var ref: EventHotKeyRef?
            let id = nextID
            nextID += 1
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifierFlags),
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref { registrations[id] = (ref, action) }
            else { failures.append(action) }
        }
    }

    func stop() {
        for registration in registrations.values { UnregisterEventHotKey(registration.ref) }
        registrations.removeAll()
        globe?.stop()
        globe = nil
    }

    /// Escape cancels a dictation. It is only claimed while recording so it keeps working everywhere else.
    func setEscapeActive(_ active: Bool) {
        if active, escapeRef == nil {
            installHandlerIfNeeded()
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: Self.escapeID),
                                   GetEventDispatcherTarget(), 0, &ref) == noErr { escapeRef = ref }
        } else if !active, let escapeRef {
            UnregisterEventHotKey(escapeRef)
            self.escapeRef = nil
        }
    }

    private static let escapeID: UInt32 = 0

    fileprivate func handle(id: UInt32, released: Bool) {
        if id == Self.escapeID {
            if !released { onEscape?() }
            return
        }
        guard let action = registrations[id]?.action else { return }
        if released { onRelease?(action) } else { onPress?(action) }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            let id = hotKeyID.id
            MainActor.assumeIsolated { center.handle(id: id, released: released) }
            return noErr
        }, types.count, &types, context, &handlerRef)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
