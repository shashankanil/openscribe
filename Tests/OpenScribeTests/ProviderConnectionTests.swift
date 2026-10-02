import XCTest
@testable import OpenScribe

@MainActor
final class ProviderConnectionTests: XCTestCase {
    func testBrowsingAndCancellingDraftKeepsActiveConfiguration() {
        let original = AppSettings()
        var draft = ProviderConnectionDraft(purpose: .speech, settings: original)
        draft.select(SpeechProvider.groq.rawValue)
        draft.model = "another-model"
        XCTAssertEqual(original.speechProvider, .openRouter)
        XCTAssertEqual(original.speechModel, SpeechProvider.openRouter.defaultModel)
        var current = original
        current.microphoneDeviceUID = "changed-while-editor-was-open"
        current.languageModel = "keep-this-writing-model"
        let applied = draft.applying(to: current)
        XCTAssertEqual(applied.speechProvider, .groq)
        XCTAssertEqual(applied.speechModel, "another-model")
        XCTAssertEqual(applied.microphoneDeviceUID, current.microphoneDeviceUID)
        XCTAssertEqual(applied.languageModel, current.languageModel)
    }

    func testConnectionRequiresKeyAndValidServerBeforeItBecomesActive() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AppController(rootURL: root)
        let original = controller.settings
        var draft = ProviderConnectionDraft(purpose: .speech, settings: original)
        draft.select(SpeechProvider.groq.rawValue)
        XCTAssertThrowsError(try controller.saveConnection(draft, key: ""))
        XCTAssertEqual(controller.settings, original)
        draft.endpoint = "file:///tmp/server"
        XCTAssertThrowsError(try controller.saveConnection(draft, key: "test-key"))
        XCTAssertEqual(controller.settings, original)
        draft.endpoint = SpeechProvider.groq.defaultBaseURL
        try controller.saveConnection(draft, key: " test-key ")
        XCTAssertEqual(controller.settings.speechProvider, .groq)
        XCTAssertEqual(AppStore(rootURL: root).settings.speechProvider, .groq)
        XCTAssertEqual(CredentialStore.read(for: .speech, settings: controller.settings, rootURL: root), "test-key")
        XCTAssertNil(CredentialStore.read(for: .languageModel, settings: controller.settings, rootURL: root))
        // Editing the model keeps the existing key when the key field is left blank.
        draft.model = "different-model"
        try controller.saveConnection(draft, key: "")
        XCTAssertEqual(controller.settings.speechModel, "different-model")
    }

    func testReuseIsExplicitAndRequiresTheSameProviderAndEndpoint() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AppController(rootURL: root)
        let speech = ProviderConnectionDraft(purpose: .speech, settings: controller.settings)
        try controller.saveConnection(speech, key: "speech-test-key")
        var writing = ProviderConnectionDraft(purpose: .languageModel, settings: controller.settings)
        XCTAssertThrowsError(try controller.saveConnection(writing, key: ""))
        try controller.saveConnection(writing, key: "", reuseKey: true)
        XCTAssertEqual(controller.credential(for: .languageModel), "speech-test-key")
        writing.select(LanguageModelProvider.anthropic.rawValue)
        XCTAssertThrowsError(try controller.saveConnection(writing, key: "", reuseKey: true))
        XCTAssertEqual(controller.settings.languageModelProvider, .openRouter)
    }

    func testFailedSettingsWriteKeepsThePreviousConnectionActive() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AppController(rootURL: root)
        let original = controller.settings
        let path = root.appendingPathComponent("settings.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        var draft = ProviderConnectionDraft(purpose: .speech, settings: original)
        draft.select(SpeechProvider.groq.rawValue)
        XCTAssertThrowsError(try controller.saveConnection(draft, key: "test-key"))
        XCTAssertEqual(controller.settings, original)
        XCTAssertNotNil(controller.store.storageError)
        try FileManager.default.removeItem(at: path)
        try controller.saveConnection(draft, key: "")
        XCTAssertEqual(controller.settings.speechProvider, .groq)
        XCTAssertNil(controller.store.storageError)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-connection-\(UUID())")
    }
}
