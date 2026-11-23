import XCTest
@testable import OpenScribe

/// Phones transcribing press-to-talk themselves: what the Mac shares, and how their text becomes a note.
@MainActor
final class PhoneTranscriptionTests: XCTestCase {
    private func makeApp() -> (AppController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-phone-speech-\(UUID())")
        return (AppController(rootURL: root), root)
    }

    func testSpeechSharingIsOptInByKeyAndSettingAndNeverIncludesTheWritingKey() throws {
        let (app, root) = makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(app.phoneSpeechMessage().key, "No transcription key, nothing to share")

        try app.saveSpeechCredential("sk-speech-test")
        try CredentialStore.save("sk-writing-test", account: CredentialScope(.languageModel, settings: app.settings).account, rootURL: root)
        app.updateSettings { $0.customVocabulary = ["OpenScribe", "Voxtral"] }
        let shared = app.phoneSpeechMessage()
        XCTAssertEqual(shared.t, "speech")
        XCTAssertEqual(shared.key, "sk-speech-test")
        XCTAssertEqual(shared.provider, app.settings.speechProvider.rawValue)
        XCTAssertEqual(shared.model, app.settings.speechModel)
        XCTAssertEqual(shared.url, app.settings.speechBaseURL)
        XCTAssertEqual(shared.terms?.contains("OpenScribe"), true)
        XCTAssertFalse(String(decoding: try PhoneLinkMessage.encode(shared), as: UTF8.self).contains("sk-writing-test"))

        app.updateSettings { $0.phoneTranscribesLocally = false }
        let cleared = app.phoneSpeechMessage()
        XCTAssertNil(cleared.key)
        XCTAssertNil(cleared.provider)
    }

    func testStreamingTransportIsNamedForRealtimeModels() throws {
        let (app, root) = makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        app.selectSpeechProvider(.openAI)
        app.updateSettings { $0.speechModel = "gpt-4o-mini-transcribe"; $0.automaticStreaming = true }
        try app.saveSpeechCredential("sk-openai-test")
        XCTAssertEqual(app.phoneSpeechMessage().streaming, "openAI")
        app.updateSettings { $0.automaticStreaming = false }
        XCTAssertNil(app.phoneSpeechMessage().streaming, "With streaming off the phone uses the file endpoint")
    }

    func testPhoneTextBecomesANoteThroughTheNormalPipeline() async throws {
        let (app, root) = makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        app.updateSettings { $0.cleanupEnabled = false; $0.spokenCorrections = false; $0.pasteIntoFocusedApp = false
            $0.snippets = [VoiceSnippet(trigger: "my address", replacement: "1 Infinite Loop")] }
        let session = PhoneTalkSession(id: "T1", connectionID: UUID(), phoneName: "Pixel")
        XCTAssertNil(app.phoneTextTalkStarted(session: session))
        XCTAssertEqual(app.capturePhase, .recording)
        app.phoneTalkPartial(session: session, text: "Hello from")
        XCTAssertEqual(app.currentTranscript, "Hello from")
        app.finishCapture()
        XCTAssertEqual(app.capturePhase, .recording, "The phone ends a text talk, not the Mac's shortcut")

        app.phoneTalkText(session: session, text: "  Hello from the phone  ")
        for _ in 0..<50 where app.capturePhase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(app.capturePhase, .ready)
        XCTAssertEqual(app.notes.first?.rawText.hasSuffix("Hello from the phone"), true)

        // Snippets still apply to phone text.
        let second = PhoneTalkSession(id: "T2", connectionID: UUID(), phoneName: "Pixel")
        for _ in 0..<100 where app.capturePhase != .idle { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(app.phoneTextTalkStarted(session: second))
        app.phoneTalkText(session: second, text: "my address")
        for _ in 0..<50 where app.capturePhase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        // Dictations collect in today's note; the latest entry is the expanded snippet.
        XCTAssertEqual(app.notes.first?.cleanedText.hasSuffix("1 Infinite Loop"), true)
    }

    func testEmptyPhoneTextIsDiscardedAndADroppedPhoneKeepsWhatWasHeard() async throws {
        let (app, root) = makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        app.updateSettings { $0.cleanupEnabled = false; $0.spokenCorrections = false; $0.pasteIntoFocusedApp = false }
        let empty = PhoneTalkSession(id: "E", connectionID: UUID(), phoneName: "Pixel")
        XCTAssertNil(app.phoneTextTalkStarted(session: empty))
        app.phoneTalkText(session: empty, text: "   ")
        XCTAssertEqual(app.capturePhase, .idle)
        XCTAssertTrue(app.notes.isEmpty)

        let dropped = PhoneTalkSession(id: "D", connectionID: UUID(), phoneName: "Pixel")
        XCTAssertNil(app.phoneTextTalkStarted(session: dropped))
        app.phoneTalkPartial(session: dropped, text: "Half a sentence")
        app.phoneTalkEnded(session: dropped)
        for _ in 0..<50 where app.capturePhase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(app.notes.first?.rawText.hasSuffix("Half a sentence"), true)
    }

    func testTextTalkIsRefusedWhileTheMacIsBusy() throws {
        let (app, root) = makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PhoneTalkSession(id: "A", connectionID: UUID(), phoneName: "Pixel")
        XCTAssertNil(app.phoneTextTalkStarted(session: first))
        XCTAssertEqual(app.phoneTextTalkStarted(session: PhoneTalkSession(id: "B", connectionID: UUID(), phoneName: "Other")),
                       "The Mac is already dictating.")
        app.cancelCapture()
        XCTAssertEqual(app.capturePhase, .idle)
    }
}
