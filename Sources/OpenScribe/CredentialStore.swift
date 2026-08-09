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
        lock.lock()
        defer { lock.unlock() }

        let fileURL = storageURL(rootURL: rootURL)
        guard var values = try? load(from: fileURL) else { return }
        values.removeValue(forKey: account)
        guard !values.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
