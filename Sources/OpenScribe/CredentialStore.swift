import Foundation

enum CredentialStore {
    private static let fileName = "credentials.json"
    private static let lock = NSLock()

    static func storageURL(rootURL: URL? = nil) -> URL {
        let root = rootURL ?? applicationSupportDirectory
            .appendingPathComponent("WhisperFlow", isDirectory: true)
        return root.appendingPathComponent(fileName)
    }

    static func read(account: String, rootURL: URL? = nil) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let values = try? load(from: storageURL(rootURL: rootURL)) else { return nil }
        return values[account]
    }

    static func save(_ value: String, account: String, rootURL: URL? = nil) throws {
        lock.lock()
        defer { lock.unlock() }

        let fileURL = storageURL(rootURL: rootURL)
        let root = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        var values = try load(from: fileURL)
        values[account] = value
        let data = try JSONEncoder().encode(values)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func remove(account: String, rootURL: URL? = nil) {
        try? delete(account: account, rootURL: rootURL)
    }

    static func delete(account: String, rootURL: URL? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let fileURL = storageURL(rootURL: rootURL)
        var values = try load(from: fileURL)
        values.removeValue(forKey: account)
        try persist(values, to: fileURL)
    }

    static func readChecked(account: String, rootURL: URL? = nil) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try load(from: storageURL(rootURL: rootURL))[account]
    }

    /// Bind each old global slot once to the configuration selected before migration.
    /// Never copy a legacy key into a subsequently selected provider or overwrite a scoped key.
    static func migrateLegacy(settings: AppSettings, rootURL: URL? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let fileURL = storageURL(rootURL: rootURL)
        var values = try load(from: fileURL)
        var changed = false
        for purpose in [CredentialKey.speech, .languageModel] {
            guard let legacy = values.removeValue(forKey: purpose.rawValue) else { continue }
            changed = true
            let scope = CredentialScope(purpose, settings: settings)
            if values[scope.account] == nil { values[scope.account] = legacy }
        }
        if changed { try persist(values, to: fileURL) }
    }

    private static func persist(_ values: [String: String], to fileURL: URL) throws {
        let root = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try JSONEncoder().encode(values).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    private static func load(from fileURL: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}
