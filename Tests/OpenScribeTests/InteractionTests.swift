import AppKit
import XCTest
@testable import OpenScribe

final class InteractionTests: XCTestCase {
    func testSnippetsMatchWholeUtterancesAndPreserveExactExpansion() {
        let snippets = [VoiceSnippet(trigger: "my signature", replacement: "Regards,\nAlex")]
        XCTAssertEqual(VoiceSnippet.expansion(for: " My  signature. ", snippets: snippets), "Regards,\nAlex")
        XCTAssertNil(VoiceSnippet.expansion(for: "Please check my signature", snippets: snippets))
        XCTAssertNil(VoiceSnippet.expansion(for: "", snippets: snippets))
        XCTAssertNil(VoiceSnippet.expansion(for: "blank", snippets: [.init(trigger: "blank", replacement: " ")]))
    }

    func testPersonalizationMigratesAndPersists() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.interactionSounds)
        XCTAssertTrue(legacy.snippets.isEmpty)
        var settings = legacy
        settings.interactionSounds = false
        settings.snippets = [.init(trigger: "my signature", replacement: "Alex")]
        settings.appWritingTones = ["com.apple.mail": .formal]
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
    }

    @MainActor
    func testClipboardRestoresAllFormatsButKeepsNewCopies() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let previous = NSPasteboardItem()
        previous.setString("original", forType: .string)
        let richData = Data("{\\rtf1 original}".utf8)
        previous.setData(richData, forType: .rtf)
        board.setString("dictation", forType: .string)
        TextInjector.restore(board, previous: [previous], changeCount: board.changeCount)
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(board.data(forType: .rtf), richData)
        board.clearContents()
        board.setString("dictation", forType: .string)
        let ownership = board.changeCount
        board.clearContents()
        board.setString("new user copy", forType: .string)
        TextInjector.restore(board, previous: [], changeCount: ownership)
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }

    @MainActor
    func testOtherModifierEventsCannotSplitGlobeSession() throws {
        let hotkey = GlobalHotkey()
        var presses = 0, releases = 0
        hotkey.start(keyCode: 63, modifiers: .function, onPress: { presses += 1 }, onRelease: { releases += 1 })
        defer { hotkey.stop() }
        func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        hotkey.handleRelease(try event(63, .function))
        hotkey.handleRelease(try event(56, .shift))
        hotkey.handleRelease(try event(55, [.command, .function]))
        XCTAssertEqual(presses, 1); XCTAssertEqual(releases, 0)
        hotkey.handleRelease(try event(63, []))
        XCTAssertEqual(releases, 1)
    }

    @MainActor
    func testToggleAcceptsSecondPressAndIgnoresRepeat() throws {
        let hotkey = GlobalHotkey()
        var presses = 0
        hotkey.start(onPress: { presses += 1 })
        defer { hotkey.stop() }
        func event(_ type: NSEvent.EventType, repeatKey: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .option,
                timestamp: 0, windowNumber: 0, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: repeatKey, keyCode: 49))
        }
        hotkey.handleKeyDown(try event(.keyDown))
        hotkey.handleKeyDown(try event(.keyDown, repeatKey: true))
        hotkey.handleRelease(try event(.keyUp))
        hotkey.handleKeyDown(try event(.keyDown))
        XCTAssertEqual(presses, 2)
    }
}
