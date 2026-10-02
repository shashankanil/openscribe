import Foundation
import XCTest
@testable import OpenScribe

@MainActor
final class AppStoreTests: XCTestCase {
    func testNotesAndSettingsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AppStore(rootURL: root)
        let note = store.addNote(
            rawText: "um send the draft tomorrow",
            cleanedText: "Send the draft tomorrow.",
            duration: 2.4
        )
        var updatedSettings = store.settings
        updatedSettings.speechProvider = .groq
        updatedSettings.speechModel = "whisper-large-v3-turbo"
        updatedSettings.cleanupEnabled = false
        updatedSettings.dictationMode = .holdToTalk
        updatedSettings.theme = .dark
        store.settings = updatedSettings
        store.flush()

        let restored = AppStore(rootURL: root)
        XCTAssertEqual(restored.notes.first?.id, note.id)
        XCTAssertEqual(restored.notes.first?.displayText, "Send the draft tomorrow.")
        XCTAssertEqual(restored.settings.speechProvider, .groq)
        XCTAssertEqual(restored.settings.speechModel, "whisper-large-v3-turbo")
        XCTAssertFalse(restored.settings.cleanupEnabled)
        XCTAssertEqual(restored.settings.dictationMode, .holdToTalk)
        XCTAssertEqual(restored.settings.theme, .dark)
    }
    func testNotesPersistSourceApplicationMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AppStore(rootURL: root)
        let note = store.addNote(
            rawText: "draft the launch email",
            cleanedText: "Draft the launch email.",
            duration: 1.8,
            sourceApplication: "Safari",
            sourceBundleIdentifier: "com.apple.Safari"
        )
        store.flush()

        let restored = AppStore(rootURL: root)
        XCTAssertEqual(restored.notes.first?.id, note.id)
        XCTAssertEqual(restored.notes.first?.sourceApplication, "Safari")
        XCTAssertEqual(restored.notes.first?.sourceBundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(restored.notes.first?.sourceLabel, "Safari")
        XCTAssertFalse(restored.notes.first?.timestampLabel.isEmpty ?? true)
    }

    func testOlderNotesDecodeWithoutSourceApplicationMetadata() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "createdAt": "2026-08-09T12:00:00Z",
          "title": "Older note",
          "rawText": "Older note",
          "cleanedText": "Older note",
          "duration": 1.0,
          "isPinned": false,
          "tags": [],
          "source": "Dictation"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note = try decoder.decode(VoiceNote.self, from: Data(json.utf8))

        XCTAssertNil(note.sourceApplication)
        XCTAssertNil(note.sourceBundleIdentifier)
        XCTAssertEqual(note.sourceLabel, "Active app unavailable")
    }
    func testLegacyAndRetiredThemesFollowSystemAppearance() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"dictationMode": "toggle"}"#.utf8))
        XCTAssertEqual(legacy.theme, .system)
        let retired = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme": "whisperFlow"}"#.utf8))
        XCTAssertEqual(retired.theme, .system)
        let dark = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme": "dark"}"#.utf8))
        XCTAssertEqual(dark.theme, .dark)
    }
 
    func testPlaceholderSpeechSettingsMigrateToOpenRouter() throws {
        let json = """
        {
          "speechProvider": "custom",
          "speechBaseURL": "https://example.com/v1",
          "speechModel": "whisper-1"
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.speechProvider, .openRouter)
        XCTAssertEqual(settings.speechBaseURL, SpeechProvider.openRouter.defaultBaseURL)
        XCTAssertEqual(settings.speechModel, SpeechProvider.openRouter.defaultModel)
    }

    func testDefaultSpeechSettingsUseOpenRouterTranscription() {
        let settings = AppSettings()
        XCTAssertEqual(settings.speechProvider, .openRouter)
        XCTAssertEqual(settings.speechModel, "mistralai/voxtral-mini-transcribe")
    }
 
    func testThemeAppearances() {
        XCTAssertNil(FlowThemeVariant.system.appearance)
        XCTAssertEqual(FlowThemeVariant.dark.appearance?.name, .darkAqua)
        XCTAssertEqual(FlowThemeVariant.light.appearance?.name, .aqua)
    }

    func testProviderDefaultsStayActionable() {
        XCTAssertEqual(SpeechProvider.deepgram.defaultBaseURL, "https://api.deepgram.com/v1")
        XCTAssertEqual(LanguageModelProvider.openRouter.defaultBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertFalse(LanguageModelProvider.anthropic.defaultModel.isEmpty)
        XCTAssertFalse(LanguageModelProvider.google.defaultModel.isEmpty)
    }

    func testGlobeShortcutRoundTrip() throws {
        var settings = AppSettings()
        settings.shortcutKeyCode = 63
        settings.shortcutModifiers = NSEvent.ModifierFlags.function.rawValue
        settings.shortcutDisplay = ShortcutFormatter.display(
            keyCode: settings.shortcutKeyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: settings.shortcutModifiers)
        )

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(restored.shortcutKeyCode, 63)
        XCTAssertEqual(restored.shortcutModifiers, NSEvent.ModifierFlags.function.rawValue)
        XCTAssertEqual(restored.shortcutDisplay, "Globe")
    }

    func testLocalCredentialRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-credentials-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try CredentialStore.save("test-secret", account: "language-model-api-key", rootURL: root)
        XCTAssertEqual(
            CredentialStore.read(account: "language-model-api-key", rootURL: root),
            "test-secret"
        )
        CredentialStore.remove(account: "language-model-api-key", rootURL: root)
        XCTAssertNil(CredentialStore.read(account: "language-model-api-key", rootURL: root))
    }

    func testUnreadableHistoryIsBackedUpBeforeNewNotesAreSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-corrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("[{broken history".utf8)
        try original.write(to: root.appendingPathComponent("notes.json"))
        let store = AppStore(rootURL: root)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNotNil(store.storageError)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("notes-unreadable-") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let note = store.addNote(rawText: "Recovered setup", cleanedText: "", duration: 1)
        XCTAssertTrue(store.hasPersistedNote(note.id))
        XCTAssertEqual(AppStore(rootURL: root).notes.first?.displayText, "Recovered setup")
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testFailedReadAndBackupBlockWritesToOriginalHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-blocked-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("notes.json")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let sentinel = history.appendingPathComponent("keep.txt")
        try Data("preserve".utf8).write(to: sentinel)
        let store = AppStore(rootURL: root)
        XCTAssertTrue(store.storageError?.contains("blocked") == true)
        var note = store.addManualNote()
        note.cleanedText = "Unsaved edit"
        XCTAssertFalse(store.updateNote(note))
        store.flush()
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserve")
        XCTAssertFalse(store.hasPersistedNote(note.id))
    }

    func testWriteFailureIsReportedAndCanRecover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(rootURL: root)
        let history = root.appendingPathComponent("notes.json")
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        var note = store.addManualNote()
        note.editedText = "Saved after retry"
        XCTAssertFalse(store.updateNote(note))
        XCTAssertNotNil(store.storageError)
        try FileManager.default.removeItem(at: history)
        XCTAssertTrue(store.updateNote(note))
        XCTAssertNil(store.storageError)
        XCTAssertEqual(AppStore(rootURL: root).notes.first?.displayText, "Saved after retry")
    }

    func testClearingEditedDictationPreservesEmptyTextAndOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(rootURL: root)
        var note = store.addNote(rawText: "Original words", cleanedText: "Polished words", duration: 2)
        note.editedText = ""
        XCTAssertTrue(store.updateNote(note))
        let restored = try XCTUnwrap(AppStore(rootURL: root).notes.first)
        XCTAssertEqual(restored.displayText, "")
        XCTAssertEqual(restored.rawText, "Original words")
        XCTAssertEqual(restored.cleanedText, "Polished words")
    }

    func testEmptyManualDraftDoesNotCreateHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-draft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(rootURL: root)
        let draft = store.addManualNote()
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertFalse(store.updateNote(draft))
        XCTAssertTrue(AppStore(rootURL: root).notes.isEmpty)
    }

    func testManualDraftSavesOnceAndCanBeClearedWithoutLosingItsIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-draft-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(rootURL: root)
        var draft = store.addManualNote()
        draft.editedText = "A thought worth keeping."
        XCTAssertTrue(store.updateNote(draft))
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.displayTitle, "A thought worth keeping.")
        draft.title = "Planning"
        draft.editedText = ""
        XCTAssertTrue(store.updateNote(draft))
        let restored = try XCTUnwrap(AppStore(rootURL: root).notes.first)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(restored.id, draft.id)
        XCTAssertEqual(restored.displayText, "")
        XCTAssertEqual(restored.title, "Planning")
    }

}
