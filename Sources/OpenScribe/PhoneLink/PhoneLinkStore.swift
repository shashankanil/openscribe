import Foundation

/// A phone paired with this Mac. The secret authenticates and encrypts every session with it.
struct PairedPhone: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var secret: Data
    var createdAt: Date
    /// Nil until the phone first connects. Slots that never connect expire.
    var lastSeen: Date?
    /// The phone's OpenScribe Cloud token and the server it's for, minted while signed in with Google.
    var cloudToken: String?
    var cloudServer: String?
    /// The phone app install that uses this slot, from its `auth`.
    var installID: String?

    var hasConnected: Bool { lastSeen != nil }
}

/// Paired phones, in `PhoneLink/devices.json` (0600) under the app's data folder, plus this Mac's stable link ID.
final class PhoneLinkStore {
    static let pendingLifetime: TimeInterval = 10 * 60

    private struct File: Codable {
        var macID: String
        var phones: [PairedPhone]
    }

    private let url: URL
    private let lock = NSLock()
    private var file: File

    init(root: URL) {
        url = root.appendingPathComponent("PhoneLink", isDirectory: true).appendingPathComponent("devices.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder.phoneLink.decode(File.self, from: data) {
            file = decoded
        } else {
            file = File(macID: UUID().uuidString, phones: [])
        }
    }

    var macID: String { lock.withLock { file.macID } }
    var phones: [PairedPhone] { lock.withLock { file.phones } }

    func phone(_ id: String) -> PairedPhone? { lock.withLock { file.phones.first { $0.id == id } } }

    /// A fresh slot for the next phone that scans the pairing code.
    func createPendingPhone(now: Date = Date()) throws -> PairedPhone {
        try lock.withLock {
            file.phones.removeAll { !$0.hasConnected && now.timeIntervalSince($0.createdAt) > Self.pendingLifetime }
            let phone = PairedPhone(id: UUID().uuidString, name: "New phone", secret: PhoneLinkProtocol.randomBytes(PhoneLinkProtocol.keyLength),
                                    createdAt: now, lastSeen: nil)
            file.phones.append(phone)
            try persistLocked()
            return phone
        }
    }

    /// The secret for a connecting phone, or nil if it isn't paired or its unused pairing code has expired.
    func secret(for id: String, now: Date = Date()) -> Data? {
        lock.withLock {
            guard let phone = file.phones.first(where: { $0.id == id }) else { return nil }
            if !phone.hasConnected && now.timeIntervalSince(phone.createdAt) > Self.pendingLifetime { return nil }
            return phone.secret
        }
    }

    /// Records which install uses a slot and returns the other slots the same install used before (it paired again).
    func claim(_ id: String, installID: String) -> [PairedPhone] {
        lock.withLock {
            guard let index = file.phones.firstIndex(where: { $0.id == id }) else { return [] }
            file.phones[index].installID = installID
            let stale = file.phones.filter { $0.id != id && $0.installID == installID }
            file.phones.removeAll { $0.id != id && $0.installID == installID }
            try? persistLocked()
            return stale
        }
    }

    func markSeen(_ id: String, name: String?, now: Date = Date()) {
        lock.withLock {
            guard let index = file.phones.firstIndex(where: { $0.id == id }) else { return }
            file.phones[index].lastSeen = now
            if let name, !name.isEmpty { file.phones[index].name = String(name.prefix(80)) }
            try? persistLocked()
        }
    }

    func cloudToken(for id: String, server: String) -> String? {
        lock.withLock { file.phones.first { $0.id == id && $0.cloudServer == server }?.cloudToken }
    }

    func setCloudToken(_ token: String, for id: String, server: String) {
        lock.withLock {
            guard let index = file.phones.firstIndex(where: { $0.id == id }) else { return }
            file.phones[index].cloudToken = token
            file.phones[index].cloudServer = server
            try? persistLocked()
        }
    }

    /// After signing out the tokens belong to an account this Mac no longer uses.
    func clearCloudTokens() {
        lock.withLock {
            for index in file.phones.indices { file.phones[index].cloudToken = nil; file.phones[index].cloudServer = nil }
            try? persistLocked()
        }
    }

    func remove(_ id: String) throws {
        try lock.withLock {
            file.phones.removeAll { $0.id == id }
            try persistLocked()
        }
    }

    /// Drops a slot that was never used, such as when the pairing sheet closes before a phone connects.
    func discardIfUnused(_ id: String) {
        lock.withLock {
            guard file.phones.contains(where: { $0.id == id && !$0.hasConnected }) else { return }
            file.phones.removeAll { $0.id == id }
            try? persistLocked()
        }
    }

    private func persistLocked() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder.phoneLink.encode(file).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension JSONEncoder {
    static var phoneLink: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var phoneLink: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
