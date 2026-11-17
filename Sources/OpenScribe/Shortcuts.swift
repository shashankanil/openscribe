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
        case .holdToTalk: return "Hold to talk. Double-tap to keep going hands-free, then press once to finish."
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

/// A key combination (any key plus modifiers), a function key on its own, a single modifier key
/// on its own such as Right ⌘ or Globe, or an extra mouse button (Mouse 4, Mouse 5…), optionally with modifiers.
struct KeyShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt
    var display: String

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var isGlobe: Bool { keyCode == 63 }
    /// A lone modifier key. These are watched as the key goes down and up, never as a combination.
    var isModifierOnly: Bool { KeyShortcut.modifierKeys[keyCode] != nil }
    /// Mouse buttons are stored as virtual key codes above any real key code.
    var isMouseButton: Bool { keyCode >= KeyShortcut.mouseBase }
    /// The CGEvent button number (2 = middle, 3 = Mouse 4/back, 4 = Mouse 5/forward…).
    var mouseButton: Int? { isMouseButton ? Int(keyCode - KeyShortcut.mouseBase) : nil }

    static let mouseBase: UInt16 = 0x1000

    static func mouse(_ button: Int, modifiers: NSEvent.ModifierFlags = []) -> KeyShortcut {
        KeyShortcut(keyCode: mouseBase + UInt16(clamping: max(0, button)), modifiers: modifiers)
    }

    static func mouseButtonName(_ button: Int) -> String {
        switch button {
        case 0: return "Left click"
        case 1: return "Right click"
        case 2: return "Middle click"
        default: return "Mouse \(button + 1)"
        }
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, display: String? = nil) {
        self.keyCode = keyCode
        let supported = KeyShortcut.modifierKeys[keyCode] != nil ? [] : modifiers.intersection(ShortcutFormatter.supportedModifiers)
        self.modifiers = (keyCode == 63 ? NSEvent.ModifierFlags.function : supported).rawValue
        self.display = display ?? ShortcutFormatter.display(keyCode: keyCode, modifiers: supported)
    }

    static let globe = KeyShortcut(keyCode: 63, modifiers: .function, display: "Globe")
    static let optionSpace = KeyShortcut(keyCode: 49, modifiers: .option, display: "⌥ Space")
    static let rightCommand = KeyShortcut(keyCode: 54, modifiers: [])
    static let rightOption = KeyShortcut(keyCode: 61, modifiers: [])
    static let mouse4 = KeyShortcut.mouse(3)
    static let mouse5 = KeyShortcut.mouse(4)

    /// Lone modifier keys: key code → (name, device-specific flag bit, generic flag).
    static let modifierKeys: [UInt16: (name: String, device: UInt64, generic: NSEvent.ModifierFlags)] = [
        54: ("Right ⌘", 0x10, .command), 55: ("Left ⌘", 0x08, .command),
        61: ("Right ⌥", 0x40, .option), 58: ("Left ⌥", 0x20, .option),
        62: ("Right ⌃", 0x2000, .control), 59: ("Left ⌃", 0x01, .control),
        60: ("Right ⇧", 0x04, .shift), 56: ("Left ⇧", 0x02, .shift),
        63: ("Globe", 0x800000, .function),
    ]

    /// F1–F20 can stand alone; every other key needs at least one modifier so typing isn't hijacked.
    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// Whether this can be used as a global shortcut at all.
    var isUsable: Bool {
        if isModifierOnly { return true }
        if let button = mouseButton {
            // Left and right clicks are never shortcuts; a middle click needs a modifier.
            return button >= 3 || (button == 2 && !modifierFlags.subtracting(.function).isEmpty)
        }
        if keyCode == UInt16(kVK_Escape) { return false }
        return !modifierFlags.subtracting(.function).isEmpty || KeyShortcut.functionKeys.contains(keyCode)
    }

    /// Option-only and Option-Shift-only combinations can't be registered as Carbon hot keys from
    /// macOS 15 on, and lone modifiers never could. These need the keyboard event tap (Accessibility).
    var needsEventTap: Bool {
        if isModifierOnly || isMouseButton { return true }
        let flags = modifierFlags.intersection([.command, .control, .option, .shift])
        if #available(macOS 15, *) { return flags == .option || flags == [.option, .shift] }
        return false
    }

    /// Two bindings collide when they would fire on the same key press.
    func conflicts(with other: KeyShortcut) -> Bool {
        if isModifierOnly || other.isModifierOnly { return keyCode == other.keyCode && isModifierOnly == other.isModifierOnly }
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

    static var lists: [String: [KeyShortcut]] { Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, [$0.value]) }) }

    /// Quick picks offered for keys that act while held.
    static let holdPresets: [KeyShortcut] = [.globe, .rightCommand, .rightOption, .mouse4, .mouse5]

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
    /// Every shortcut for an action, in the order they were added.
    func shortcuts(for action: ShortcutAction) -> [KeyShortcut] { shortcutBindings[action.rawValue] ?? [] }

    /// The first shortcut, used in hints and menus.
    func shortcut(for action: ShortcutAction) -> KeyShortcut? { shortcuts(for: action).first }

    /// Replaces all of an action's shortcuts with one (or none). Returns the action that lost it, if any.
    @discardableResult
    mutating func assign(_ shortcut: KeyShortcut?, to action: ShortcutAction) -> ShortcutAction? {
        let displaced = shortcut.flatMap { releaseFromOthers($0, keeping: action) }
        shortcutBindings[action.rawValue] = shortcut.map { [$0] } ?? []
        syncLegacyShortcut()
        return displaced
    }

    /// Adds another shortcut to an action, or replaces `existing` with it.
    @discardableResult
    mutating func add(_ shortcut: KeyShortcut, to action: ShortcutAction, replacing existing: KeyShortcut? = nil) -> ShortcutAction? {
        let displaced = releaseFromOthers(shortcut, keeping: action)
        var list = shortcuts(for: action)
        if let existing, let index = list.firstIndex(of: existing) {
            list[index] = shortcut
        } else {
            list.append(shortcut)
        }
        // Keep the first copy of each key, wherever it ended up.
        var seen: [KeyShortcut] = []
        for item in list where !seen.contains(where: { $0.conflicts(with: item) }) { seen.append(item) }
        shortcutBindings[action.rawValue] = seen
        syncLegacyShortcut()
        return displaced
    }

    mutating func remove(_ shortcut: KeyShortcut, from action: ShortcutAction) {
        shortcutBindings[action.rawValue] = shortcuts(for: action).filter { $0 != shortcut }
        syncLegacyShortcut()
    }

    mutating func resetShortcutBindings() {
        shortcutBindings = ShortcutDefaults.lists
        syncLegacyShortcut()
    }

    /// One press never does two things: a key moves to the action it was last assigned to.
    private mutating func releaseFromOthers(_ shortcut: KeyShortcut, keeping action: ShortcutAction) -> ShortcutAction? {
        var displaced: ShortcutAction?
        for other in ShortcutAction.allCases where other != action {
            let list = shortcuts(for: other)
            let kept = list.filter { !$0.conflicts(with: shortcut) }
            if kept.count != list.count {
                shortcutBindings[other.rawValue] = kept
                displaced = other
            }
        }
        return displaced
    }

    /// Keep the original single-shortcut fields meaningful for hints and older builds.
    mutating func syncLegacyShortcut() {
        var primary: [String: KeyShortcut] = [:]
        for (action, list) in shortcutBindings { if let first = list.first { primary[action] = first } }
        shortcuts = primary
        if let first = shortcut(for: .dictate) ?? shortcut(for: .holdToTalk) {
            shortcutKeyCode = first.keyCode
            shortcutModifiers = first.modifiers
            shortcutDisplay = first.display
            dictationMode = shortcut(for: .dictate) == nil ? .holdToTalk : .toggle
        }
    }

    var dictationHint: String? {
        if let dictate = shortcut(for: .dictate) { return dictate.display }
        return shortcut(for: .holdToTalk)?.display
    }
}

// MARK: - Registration

/// Registers system-wide hotkeys.
///
/// With Accessibility access, a keyboard event tap handles every binding: any key combination,
/// function keys, and lone modifiers such as Right ⌘ or Globe. Matching key presses are consumed
/// so they never reach the focused app. Without access, key combinations fall back to Carbon hot
/// keys, which need no permission but can't express lone modifiers or (from macOS 15) Option-only
/// combinations.
@MainActor
final class HotkeyCenter {
    enum FailureReason: Equatable { case needsAccessibility, unavailable }

    private(set) var failures: [ShortcutAction] = []
    private(set) var failedShortcuts: [KeyShortcut: FailureReason] = [:]
    private(set) var usingEventTap = false
    var onEscape: (() -> Void)?

    private var onPress: ((ShortcutAction) -> Void)?
    private var onRelease: ((ShortcutAction) -> Void)?
    /// A lone modifier that was used as part of a combination (Right ⌘ + C) instead of on its own.
    private var onInterrupt: ((ShortcutAction) -> Void)?

    // Carbon
    private var registrations: [UInt32: (ref: EventHotKeyRef, action: ShortcutAction)] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var escapeRef: EventHotKeyRef?
    private static let signature: OSType = 0x4F53_4352 // "OSCR"
    private static let escapeID: UInt32 = 0

    // Event tap
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var combos: [(shortcut: KeyShortcut, action: ShortcutAction)] = []
    private var lone: [UInt16: ShortcutAction] = [:]
    private var heldKeys: [UInt16: ShortcutAction] = [:]
    private var heldModifier: (keyCode: UInt16, action: ShortcutAction, interrupted: Bool)?

    func start(bindings: [ShortcutAction: [KeyShortcut]], accessibility: Bool,
               onPress: @escaping (ShortcutAction) -> Void, onRelease: @escaping (ShortcutAction) -> Void,
               onInterrupt: @escaping (ShortcutAction) -> Void = { _ in }) {
        stop()
        self.onPress = onPress
        self.onRelease = onRelease
        self.onInterrupt = onInterrupt
        installHandlerIfNeeded()
        failures = []
        failedShortcuts = [:]
        let all = ShortcutAction.allCases.flatMap { action in (bindings[action] ?? []).map { (shortcut: $0, action: action) } }

        if accessibility, installTap() {
            usingEventTap = true
            for item in all {
                if item.shortcut.isModifierOnly { lone[item.shortcut.keyCode] = item.action }
                else { combos.append(item) }
            }
            return
        }

        usingEventTap = false
        for item in all {
            if item.shortcut.needsEventTap {
                fail(item.shortcut, item.action, .needsAccessibility)
                continue
            }
            var ref: EventHotKeyRef?
            let id = nextID
            nextID += 1
            let status = RegisterEventHotKey(UInt32(item.shortcut.keyCode), Self.carbonModifiers(item.shortcut.modifierFlags),
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref { registrations[id] = (ref, item.action) }
            else { fail(item.shortcut, item.action, .unavailable) }
        }
    }

    private func fail(_ shortcut: KeyShortcut, _ action: ShortcutAction, _ reason: FailureReason) {
        failedShortcuts[shortcut] = reason
        if !failures.contains(action) { failures.append(action) }
    }

    func stop() {
        for registration in registrations.values { UnregisterEventHotKey(registration.ref) }
        registrations.removeAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        combos = []
        lone = [:]
        heldKeys = [:]
        heldModifier = nil
        usingEventTap = false
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

    // MARK: Event tap

    private func installTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { center.handleTap(type: type, event: event) }
        }, userInfo: context) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let consumed = handleKey(type: type, keyCode: keyCode, flags: event.flags.rawValue,
                                     isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            return consumed ? nil : Unmanaged.passUnretained(event)
        case .otherMouseDown, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            let consumed = handleMouse(down: type == .otherMouseDown, button: button, flags: event.flags.rawValue)
            return consumed ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Matches one keyboard event against the bindings. Returns true when the event should be swallowed.
    /// Separated from the tap so it can be tested with synthetic input.
    @discardableResult
    func handleKey(type: CGEventType, keyCode: UInt16, flags: UInt64, isRepeat: Bool = false) -> Bool {
        let generic = NSEvent.ModifierFlags(rawValue: UInt(flags)).intersection([.command, .control, .option, .shift, .function])
        switch type {
        case .keyDown:
            interruptHeldModifier()
            if heldKeys[keyCode] != nil { return true } // Auto-repeat of a held shortcut.
            guard let match = combos.first(where: { matches($0.shortcut, keyCode: keyCode, flags: generic) }) else { return false }
            if isRepeat { return true }
            heldKeys[keyCode] = match.action
            dispatch { $0.onPress?(match.action) }
            return true
        case .keyUp:
            guard let action = heldKeys.removeValue(forKey: keyCode) else { return false }
            dispatch { $0.onRelease?(action) }
            return true
        case .flagsChanged:
            guard let key = KeyShortcut.modifierKeys[keyCode] else { return false }
            let down = flags & key.device != 0 || (keyCode == 63 && generic.contains(.function))
            if down {
                if let held = heldModifier, held.keyCode != keyCode {
                    interruptHeldModifier() // Another modifier joined in: this is a combination.
                    return false
                }
                guard heldModifier == nil, let action = lone[keyCode] else { return false }
                // Only on its own: no other modifier may already be down.
                guard generic.subtracting(key.generic).subtracting(.function).isEmpty else { return false }
                heldModifier = (keyCode, action, false)
                dispatch { $0.onPress?(action) }
            } else if let held = heldModifier, held.keyCode == keyCode {
                heldModifier = nil
                if !held.interrupted { dispatch { $0.onRelease?(held.action) } }
            }
            return false // Modifier changes always pass through so the rest of the system stays consistent.
        default:
            return false
        }
    }

    /// Extra mouse buttons behave like keys: press, hold and release.
    @discardableResult
    func handleMouse(down: Bool, button: Int, flags: UInt64) -> Bool {
        guard button >= 2 else { return false }
        let code = KeyShortcut.mouseBase + UInt16(clamping: button)
        if !down, heldKeys[code] == nil { return false }
        return handleKey(type: down ? .keyDown : .keyUp, keyCode: code, flags: flags)
    }

    private func matches(_ shortcut: KeyShortcut, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard shortcut.keyCode == keyCode else { return false }
        // Function keys and arrows report Fn implicitly, so it never decides a match.
        return flags.subtracting(.function) == shortcut.modifierFlags.subtracting(.function)
    }

    private func interruptHeldModifier() {
        guard let held = heldModifier, !held.interrupted else { return }
        heldModifier?.interrupted = true
        dispatch { $0.onInterrupt?(held.action) }
    }

    /// Actions run after the tap callback returns, so the tap is never held up by app work.
    private func dispatch(_ body: @escaping @MainActor (HotkeyCenter) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
    }

    // MARK: Carbon

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

    /// Test support: install bindings without a real tap so `handleKey` can be exercised directly.
    func installForTesting(bindings: [ShortcutAction: [KeyShortcut]], onPress: @escaping (ShortcutAction) -> Void,
                           onRelease: @escaping (ShortcutAction) -> Void, onInterrupt: @escaping (ShortcutAction) -> Void) {
        stop()
        self.onPress = onPress
        self.onRelease = onRelease
        self.onInterrupt = onInterrupt
        for action in ShortcutAction.allCases {
            for shortcut in bindings[action] ?? [] {
                if shortcut.isModifierOnly { lone[shortcut.keyCode] = action } else { combos.append((shortcut, action)) }
            }
        }
    }
}
