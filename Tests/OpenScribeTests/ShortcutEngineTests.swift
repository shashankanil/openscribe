import AppKit
import Carbon.HIToolbox
import XCTest
@testable import OpenScribe

@MainActor
final class ShortcutEngineTests: XCTestCase {
    private var events: [String] = []
    private let center = HotkeyCenter()

    override func tearDown() {
        center.stop()
        events = []
        super.tearDown()
    }

    private func install(_ bindings: [ShortcutAction: [KeyShortcut]]) {
        center.installForTesting(bindings: bindings,
                                 onPress: { [weak self] in self?.events.append("press \($0.rawValue)") },
                                 onRelease: { [weak self] in self?.events.append("release \($0.rawValue)") },
                                 onInterrupt: { [weak self] in self?.events.append("interrupt \($0.rawValue)") })
    }

    /// Actions are delivered on the next main-queue turn.
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private let option = UInt64(NSEvent.ModifierFlags.option.rawValue)
    private let command = UInt64(NSEvent.ModifierFlags.command.rawValue)

    // MARK: Settings

    func testActionsKeepSeveralShortcutsAndMoveConflicts() throws {
        var settings = AppSettings()
        let second = KeyShortcut(keyCode: 2, modifiers: [.control, .option])
        settings.add(.rightCommand, to: .dictate)
        settings.add(second, to: .dictate)
        XCTAssertEqual(settings.shortcuts(for: .dictate), [.optionSpace, .rightCommand, second])
        XCTAssertEqual(settings.shortcut(for: .dictate), .optionSpace, "The first shortcut stays the primary hint")

        // Adding the same key to another action moves it there.
        let displaced = settings.add(second, to: .pasteLast)
        XCTAssertEqual(displaced, .dictate)
        XCTAssertEqual(settings.shortcuts(for: .dictate), [.optionSpace, .rightCommand])

        // Replacing keeps the position; duplicates collapse.
        settings.add(.rightOption, to: .dictate, replacing: .rightCommand)
        settings.add(.rightOption, to: .dictate)
        XCTAssertEqual(settings.shortcuts(for: .dictate), [.optionSpace, .rightOption])

        settings.remove(.optionSpace, from: .dictate)
        XCTAssertEqual(settings.shortcut(for: .dictate), .rightOption)
        XCTAssertEqual(settings.shortcuts[ShortcutAction.dictate.rawValue], .rightOption, "Legacy single map mirrors the first binding")

        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.shortcutBindings, settings.shortcutBindings)
    }

    func testSingleShortcutSettingsMigrateToLists() throws {
        let json = #"{"shortcuts": {"dictate": {"keyCode": 49, "modifiers": 524288, "display": "⌥ Space"}}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.shortcuts(for: .dictate), [.optionSpace])
        XCTAssertTrue(settings.shortcuts(for: .meeting).isEmpty)
    }

    func testShortcutRules() {
        XCTAssertTrue(KeyShortcut.rightCommand.isModifierOnly)
        XCTAssertEqual(KeyShortcut.rightCommand.display, "Right ⌘")
        XCTAssertTrue(KeyShortcut.rightCommand.needsEventTap)
        XCTAssertFalse(KeyShortcut(keyCode: 0, modifiers: []).isUsable, "A bare letter would hijack typing")
        XCTAssertTrue(KeyShortcut(keyCode: 105, modifiers: []).isUsable, "F13 can stand alone")
        XCTAssertFalse(KeyShortcut(keyCode: 53, modifiers: [.command]).isUsable, "Escape stays reserved for cancel")
        XCTAssertTrue(KeyShortcut(keyCode: 2, modifiers: [.command, .shift]).isUsable)
        if #available(macOS 15, *) {
            XCTAssertTrue(KeyShortcut.optionSpace.needsEventTap, "Option-only hot keys can't be registered with Carbon on macOS 15+")
            XCTAssertFalse(KeyShortcut(keyCode: 49, modifiers: [.control, .option]).needsEventTap)
        }
    }

    // MARK: Event matching

    func testComboFiresOnceAndIsSwallowed() {
        install([.dictate: [.optionSpace], .meeting: [KeyShortcut(keyCode: 46, modifiers: [.option, .shift])]])
        XCTAssertTrue(center.handleKey(type: .keyDown, keyCode: 49, flags: option))
        XCTAssertTrue(center.handleKey(type: .keyDown, keyCode: 49, flags: option, isRepeat: true), "Auto-repeat is swallowed")
        XCTAssertTrue(center.handleKey(type: .keyUp, keyCode: 49, flags: 0))
        // Extra modifiers make it a different combination.
        XCTAssertFalse(center.handleKey(type: .keyDown, keyCode: 49, flags: option | command))
        XCTAssertFalse(center.handleKey(type: .keyDown, keyCode: 49, flags: 0), "Plain Space keeps typing")
        drain()
        XCTAssertEqual(events, ["press dictate", "release dictate"])
    }

    func testSeveralShortcutsTriggerTheSameAction() {
        install([.dictate: [.optionSpace, KeyShortcut(keyCode: 2, modifiers: [.control, .option])]])
        center.handleKey(type: .keyDown, keyCode: 2, flags: option | UInt64(NSEvent.ModifierFlags.control.rawValue))
        center.handleKey(type: .keyUp, keyCode: 2, flags: 0)
        center.handleKey(type: .keyDown, keyCode: 49, flags: option)
        center.handleKey(type: .keyUp, keyCode: 49, flags: option)
        drain()
        XCTAssertEqual(events, ["press dictate", "release dictate", "press dictate", "release dictate"])
    }

    func testLoneModifierPressesAndReleases() {
        install([.holdToTalk: [.rightCommand]])
        // Right ⌘ down: generic command plus the right-side device bit. Modifier events always pass through.
        XCTAssertFalse(center.handleKey(type: .flagsChanged, keyCode: 54, flags: command | 0x10))
        XCTAssertFalse(center.handleKey(type: .flagsChanged, keyCode: 54, flags: 0))
        // Left ⌘ isn't Right ⌘.
        center.handleKey(type: .flagsChanged, keyCode: 55, flags: command | 0x08)
        center.handleKey(type: .flagsChanged, keyCode: 55, flags: 0)
        drain()
        XCTAssertEqual(events, ["press holdToTalk", "release holdToTalk"])
    }

    func testLoneModifierUsedInACombinationIsInterrupted() {
        install([.holdToTalk: [.rightCommand]])
        center.handleKey(type: .flagsChanged, keyCode: 54, flags: command | 0x10)
        XCTAssertFalse(center.handleKey(type: .keyDown, keyCode: 8, flags: command | 0x10), "⌘C still copies")
        center.handleKey(type: .keyUp, keyCode: 8, flags: command | 0x10)
        center.handleKey(type: .flagsChanged, keyCode: 54, flags: 0)
        drain()
        XCTAssertEqual(events, ["press holdToTalk", "interrupt holdToTalk"], "No release after an interruption")
    }

    func testLoneModifierIgnoredWhileAnotherModifierIsHeld() {
        install([.holdToTalk: [.rightCommand]])
        center.handleKey(type: .flagsChanged, keyCode: 56, flags: UInt64(NSEvent.ModifierFlags.shift.rawValue) | 0x02)
        center.handleKey(type: .flagsChanged, keyCode: 54, flags: UInt64(NSEvent.ModifierFlags.shift.rawValue) | 0x02 | command | 0x10)
        drain()
        XCTAssertTrue(events.isEmpty)
    }

    func testGlobeUsesTheFunctionFlag() {
        install([.holdToTalk: [.globe]])
        center.handleKey(type: .flagsChanged, keyCode: 63, flags: UInt64(NSEvent.ModifierFlags.function.rawValue))
        center.handleKey(type: .flagsChanged, keyCode: 63, flags: 0)
        drain()
        XCTAssertEqual(events, ["press holdToTalk", "release holdToTalk"])
    }

    // MARK: Capture view

    func testMouseButtonsActLikeKeys() {
        install([.holdToTalk: [.mouse4], .meeting: [KeyShortcut.mouse(2, modifiers: .option)]])
        XCTAssertTrue(center.handleMouse(down: true, button: 3, flags: 0))
        XCTAssertTrue(center.handleMouse(down: false, button: 3, flags: 0))
        XCTAssertFalse(center.handleMouse(down: true, button: 4, flags: 0), "Unbound buttons pass through")
        XCTAssertFalse(center.handleMouse(down: false, button: 4, flags: 0))
        XCTAssertFalse(center.handleMouse(down: true, button: 2, flags: 0), "A plain middle click is left alone")
        XCTAssertTrue(center.handleMouse(down: true, button: 2, flags: option))
        XCTAssertTrue(center.handleMouse(down: false, button: 2, flags: 0), "Release matches even after the modifier lifts")
        XCTAssertFalse(center.handleMouse(down: true, button: 0, flags: 0))
        drain()
        XCTAssertEqual(events, ["press holdToTalk", "release holdToTalk", "press meeting", "release meeting"])
    }

    func testMouseButtonRulesAndNames() {
        XCTAssertEqual(KeyShortcut.mouse4.display, "Mouse 4")
        XCTAssertEqual(KeyShortcut.mouse(5, modifiers: .command).display, "⌘ Mouse 6")
        XCTAssertTrue(KeyShortcut.mouse4.isUsable)
        XCTAssertTrue(KeyShortcut.mouse4.needsEventTap)
        XCTAssertFalse(KeyShortcut.mouse(2).isUsable)
        XCTAssertTrue(KeyShortcut.mouse(2, modifiers: .control).isUsable)
        XCTAssertFalse(KeyShortcut.mouse(0, modifiers: .command).isUsable)
        XCTAssertFalse(KeyShortcut.mouse4.conflicts(with: .mouse5))
        XCTAssertTrue(KeyShortcut.mouse4.conflicts(with: .mouse(3)))
        let decoded = try? JSONDecoder().decode(KeyShortcut.self, from: JSONEncoder().encode(KeyShortcut.mouse5))
        XCTAssertEqual(decoded, .mouse5)
    }

    func testCaptureViewRecordsMouseSideButtons() throws {
        let view = HotkeyCaptureNSView()
        var captured: KeyShortcut?
        view.onCapture = { captured = $0 }
        // NSEvent.mouseEvent can't set buttonNumber, so build the event from a CGEvent.
        let cg = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .init(rawValue: 3)!))
        let side = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertTrue(view.handle(side))
        XCTAssertEqual(captured, .mouse4)
    }

    func testCaptureViewRecordsLoneModifiersAndRejectsBareKeys() throws {
        let view = HotkeyCaptureNSView()
        var captured: [KeyShortcut] = []
        var invalid: [String] = []
        view.onCapture = { captured.append($0) }
        view.onInvalid = { invalid.append($0) }
        func flags(_ code: UInt16, _ raw: UInt) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw),
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags, _ chars: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        _ = view.handle(try flags(61, NSEvent.ModifierFlags.option.rawValue | 0x40))
        _ = view.handle(try flags(61, 0))
        XCTAssertEqual(captured.last, .rightOption)

        _ = view.handle(try key(0, [], "a"))
        XCTAssertEqual(invalid.count, 1)

        // A modifier used for a combination becomes that combination, not a lone key.
        _ = view.handle(try flags(55, NSEvent.ModifierFlags.command.rawValue | 0x08))
        _ = view.handle(try key(40, .command, "k"))
        _ = view.handle(try flags(55, 0))
        XCTAssertEqual(captured.last?.display, "⌘ K")
        XCTAssertEqual(captured.count, 2)
    }
}
