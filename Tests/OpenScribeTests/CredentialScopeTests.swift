import XCTest
@testable import OpenScribe

final class CredentialScopeTests: XCTestCase {
    private func withStore(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testProvidersAndPurposesKeepIndependentKeys() throws {
        try withStore { root in
            let router = AppSettings()
            var mistral = router
            mistral.speechProvider = .mistral; mistral.speechBaseURL = SpeechProvider.mistral.defaultBaseURL
            try CredentialStore.save("router-speech", account: CredentialScope(.speech, settings: router).account, rootURL: root)
            try CredentialStore.save("router-cleanup", account: CredentialScope(.languageModel, settings: router).account, rootURL: root)
            XCTAssertNil(CredentialStore.read(for: .speech, settings: mistral, rootURL: root))
            try CredentialStore.save("mistral-speech", account: CredentialScope(.speech, settings: mistral).account, rootURL: root)
            XCTAssertEqual(CredentialStore.read(for: .speech, settings: router, rootURL: root), "router-speech")
            XCTAssertEqual(CredentialStore.read(for: .languageModel, settings: router, rootURL: root), "router-cleanup")
            XCTAssertEqual(CredentialStore.read(for: .speech, settings: mistral, rootURL: root), "mistral-speech")
            try CredentialStore.delete(account: CredentialScope(.speech, settings: mistral).account, rootURL: root)
            XCTAssertNil(CredentialStore.read(for: .speech, settings: mistral, rootURL: root))
            XCTAssertEqual(CredentialStore.read(for: .speech, settings: router, rootURL: root), "router-speech")
        }
    }

    func testEquivalentEndpointsShareKeysButOtherHostsPathsAndPortsDoNot() {
        var settings = AppSettings(); settings.speechProvider = .custom; settings.speechBaseURL = "https://example.com/v1"
        let original = CredentialScope(.speech, settings: settings).account
        settings.speechBaseURL = " HTTPS://EXAMPLE.COM:443/v1/ "
        XCTAssertEqual(CredentialScope(.speech, settings: settings).account, original)
        for url in ["http://example.com/v1", "https://example.com:8443/v1", "https://example.com/v2", "https://another.example/v1"] {
            settings.speechBaseURL = url
            XCTAssertNotEqual(CredentialScope(.speech, settings: settings).account, original)
        }
        settings.speechBaseURL = "https://example.com/v1"; settings.speechModel = "another-model"
        XCTAssertEqual(CredentialScope(.speech, settings: settings).account, original)
    }

    func testLegacyKeysMigrateOnceWithoutCrossProviderFallback() throws {
        try withStore { root in
            let original = AppSettings()
            try CredentialStore.save("legacy-speech", account: CredentialKey.speech.rawValue, rootURL: root)
            try CredentialStore.save("legacy-cleanup", account: CredentialKey.languageModel.rawValue, rootURL: root)
            try CredentialStore.migrateLegacy(settings: original, rootURL: root)
            XCTAssertEqual(CredentialStore.read(for: .speech, settings: original, rootURL: root), "legacy-speech")
            XCTAssertEqual(CredentialStore.read(for: .languageModel, settings: original, rootURL: root), "legacy-cleanup")
            XCTAssertNil(CredentialStore.read(account: CredentialKey.speech.rawValue, rootURL: root))
            var changed = original; changed.speechProvider = .openAI; changed.speechBaseURL = SpeechProvider.openAI.defaultBaseURL
            try CredentialStore.migrateLegacy(settings: changed, rootURL: root)
            XCTAssertNil(CredentialStore.read(for: .speech, settings: changed, rootURL: root))
            XCTAssertEqual(CredentialStore.read(for: .speech, settings: original, rootURL: root), "legacy-speech")
        }
    }

    func testMigrationDoesNotOverwriteScopedCredentialOrResurrectDeletedKey() throws {
        try withStore { root in
            let settings = AppSettings(); let scope = CredentialScope(.speech, settings: settings)
            try CredentialStore.save("old", account: CredentialKey.speech.rawValue, rootURL: root)
            try CredentialStore.save("new", account: scope.account, rootURL: root)
            try CredentialStore.migrateLegacy(settings: settings, rootURL: root)
            XCTAssertEqual(CredentialStore.read(for: .speech, settings: settings, rootURL: root), "new")
            try CredentialStore.delete(account: scope.account, rootURL: root)
            try CredentialStore.migrateLegacy(settings: settings, rootURL: root)
            XCTAssertNil(CredentialStore.read(for: .speech, settings: settings, rootURL: root))
        }
    }

    func testStorageFailuresAreReportedAndDoNotOverwriteCorruptFile() throws {
        try withStore { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = CredentialStore.storageURL(rootURL: root)
            let original = Data("invalid-json".utf8)
            try original.write(to: file)
            XCTAssertThrowsError(try CredentialStore.readChecked(account: "test", rootURL: root))
            XCTAssertThrowsError(try CredentialStore.save("new", account: "test", rootURL: root))
            XCTAssertThrowsError(try CredentialStore.delete(account: "test", rootURL: root))
            XCTAssertThrowsError(try CredentialStore.migrateLegacy(settings: AppSettings(), rootURL: root))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testCredentialsRemainPrivateAndOutsideRecordingSettings() throws {
        try withStore { root in
            let settings = AppSettings()
            try CredentialStore.save("private-test-secret", account: CredentialScope(.speech, settings: settings).account, rootURL: root)
            let attributes = try FileManager.default.attributesOfItem(atPath: CredentialStore.storageURL(rootURL: root).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
            XCTAssertFalse(encoded.contains("private-test-secret"))
        }
    }
}
