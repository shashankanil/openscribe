import Foundation
import XCTest
@testable import WhisperFlow

@MainActor
final class AppStoreTests: XCTestCase {
    func testNotesAndSettingsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisperflow-test-\(UUID().uuidString)")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisperflow-source-\(UUID().uuidString)")
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
    func testLegacySettingsDefaultToWhisperFlowTheme() throws {
        let json = """
        {
          "dictationMode": "toggle"
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.theme, .whisperFlow)
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
 
    func testWhisperlightThemePresentation() {
        XCTAssertEqual(FlowThemeVariant.whisperFlow.title, "Whisperlight")
        XCTAssertEqual(FlowThemeVariant.whisperFlow.detail, "Warm paper, lavender, and mint.")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisperflow-credentials-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try CredentialStore.save("test-secret", account: "language-model-api-key", rootURL: root)
        XCTAssertEqual(
            CredentialStore.read(account: "language-model-api-key", rootURL: root),
            "test-secret"
        )
        CredentialStore.remove(account: "language-model-api-key", rootURL: root)
        XCTAssertNil(CredentialStore.read(account: "language-model-api-key", rootURL: root))
    }
}
