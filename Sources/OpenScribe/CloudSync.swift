import AppKit
import Combine
import CryptoKit
import Foundation
import OpenScribeContext

/// Opt-in sync of notes and meetings to OpenScribe Cloud, which serves them to LLM clients over
/// remote MCP. Sign-in happens in the browser with Google; the server hands back an app token
/// through `openscribe://auth`. Only changed documents are uploaded, and deletions are sent as
/// tombstones. See docs/CONTEXT-API.md for the contract.
@MainActor
final class CloudSyncController: ObservableObject {
    enum Account: Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String)
    }

    /// Where OpenScribe Cloud is hosted. Settings can point at a self-hosted Worker instead.
    static let defaultServer = "https://openscribe-cloud.shashankmay6.workers.dev"
    static let callbackScheme = "openscribe"

    @Published private(set) var account: Account = .signedOut
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var documentCount: Int?
    @Published private(set) var error: String?

    private let dataRoot: URL
    private weak var app: AppController?
    private var pendingState: String?
    private var scheduled: Task<Void, Never>?
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private let urlHandler = URLEventHandler()
    private let session: URLSession

    init(dataRoot: URL, session: URLSession = .shared) {
        self.dataRoot = dataRoot
        self.session = session
    }

    func boot(app: AppController) {
        self.app = app
        urlHandler.onURL = { [weak self] url in self?.handle(url) }
        urlHandler.install()
        lastSync = loadState().lastSync
        if token != nil { account = .signedIn(email: UserDefaults.standard.string(forKey: emailKey) ?? "your account") }
        // Changes to notes or meetings schedule a sync shortly after they settle.
        Publishers.Merge(app.store.objectWillChange.map { _ in () }, app.meetings.store.objectWillChange.map { _ in () })
            .sink { [weak self] in self?.scheduleSync(after: 30) }
            .store(in: &subscriptions)
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleSync(after: 0) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if token != nil {
            Task { await refreshAccount() }
            scheduleSync(after: 5)
        }
    }

    var enabled: Bool { app?.settings.cloudSyncEnabled == true }
    var signedIn: Bool { if case .signedIn = account { return true } else { return false } }

    var server: URL {
        let custom = app?.settings.cloudServerURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = custom.isEmpty ? Self.defaultServer : custom
        return URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw) ?? URL(string: Self.defaultServer)!
    }

    /// The URL people paste into claude.ai, ChatGPT or Claude Desktop as a custom connector.
    var mcpURL: String { server.appendingPathComponent("mcp").absoluteString }

    // MARK: Sign-in

    private var credentialAccount: String { "openscribe-cloud:\(server.host ?? server.absoluteString)" }
    private var emailKey: String { "cloudAccountEmail:\(server.host ?? "")" }
    private var token: String? {
        let value = CredentialStore.read(account: credentialAccount, rootURL: dataRoot) ?? ""
        return value.isEmpty ? nil : value
    }

    func signIn() {
        let state = Self.randomToken()
        pendingState = state
        var components = URLComponents(url: server.appendingPathComponent("app/login"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "redirect_uri", value: "\(Self.callbackScheme)://auth"),
                                  URLQueryItem(name: "state", value: state)]
        guard let url = components?.url else { return }
        account = .signingIn
        error = nil
        NSWorkspace.shared.open(url)
    }

    func cancelSignIn() {
        pendingState = nil
        if account == .signingIn { account = .signedOut }
    }

    /// `openscribe://auth?token=…&state=…` from the browser after Google sign-in.
    func handle(_ url: URL) {
        guard url.scheme == Self.callbackScheme, url.host == "auth" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let expected = pendingState, value("state") == expected else {
            error = "That sign-in link didn’t come from this Mac. Try signing in again."
            return
        }
        pendingState = nil
        if let failure = value("error") {
            account = .signedOut
            error = failure == "access_denied" ? nil : "Sign-in didn’t finish (\(failure))."
            return
        }
        guard let token = value("token"), !token.isEmpty else {
            account = .signedOut
            error = "Sign-in didn’t return a session. Try again."
            return
        }
        do { try CredentialStore.save(token, account: credentialAccount, rootURL: dataRoot) }
        catch { self.error = "Couldn’t save your session: \(error.localizedDescription)"; account = .signedOut; return }
        account = .signedIn(email: "your account")
        app?.updateSettings { $0.cloudSyncEnabled = true }
        NSApp.activate(ignoringOtherApps: true)
        app?.openMainWindow()
        Task {
            await refreshAccount()
            await syncNow()
        }
    }

    func signOut() async {
        if let token { _ = try? await request("api/v1/logout", method: "POST", token: token) }
        clearSession()
        app?.updateSettings { $0.cloudSyncEnabled = false }
    }

    /// Removes everything stored in OpenScribe Cloud for this account, then signs out.
    func deleteCloudData() async -> Bool {
        guard let token else { return false }
        do {
            _ = try await request("api/v1/account", method: "DELETE", token: token)
            clearSession()
            app?.updateSettings { $0.cloudSyncEnabled = false }
            return true
        } catch {
            self.error = "Couldn’t delete your cloud data: \(error.localizedDescription)"
            return false
        }
    }

    private func clearSession() {
        CredentialStore.remove(account: credentialAccount, rootURL: dataRoot)
        UserDefaults.standard.removeObject(forKey: emailKey)
        saveState(SyncState(server: server.absoluteString))
        account = .signedOut
        documentCount = nil
        lastSync = nil
    }

    private func refreshAccount() async {
        guard let token else { return }
        do {
            let data = try await request("api/v1/me", token: token)
            struct Me: Decodable { let email: String; let documentCount: Int? }
            let me = try JSONDecoder().decode(Me.self, from: data)
            UserDefaults.standard.set(me.email, forKey: emailKey)
            account = .signedIn(email: me.email)
            documentCount = me.documentCount
        } catch let failure as CloudError where failure == .unauthorized {
            clearSession()
            error = "Your OpenScribe Cloud session ended. Sign in again to keep syncing."
        } catch {
            // Offline or server trouble: keep the session and try again later.
        }
    }

    // MARK: Sync

    func scheduleSync(after seconds: Double) {
        guard enabled, signedIn else { return }
        scheduled?.cancel()
        scheduled = Task { @MainActor [weak self] in
            if seconds > 0 { do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return } }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard enabled, let token, !syncing else { return }
        syncing = true
        defer { syncing = false }
        let root = dataRoot
        let state = loadState()
        let serverID = server.absoluteString
        // Reading and hashing every document happens off the main thread.
        let (plan, attachments) = await Task.detached(priority: .utility) {
            let library = ContextLibrary.load(root: root)
            return (Self.plan(library: library, state: state.server == serverID ? state : SyncState(server: serverID), now: Date()),
                    library.attachments)
        }.value
        var next = plan.state
        do {
            for batch in plan.batches {
                let body = try JSONEncoder().encode(["documents": batch.map(\.document)])
                let data = try await request("api/v1/documents/batch", method: "POST", token: token, body: body)
                let result = (try? JSONDecoder().decode(BatchResult.self, from: data)) ?? BatchResult(errors: [])
                let failed = Set(result.errors.map(\.index))
                for (index, item) in batch.enumerated() where !failed.contains(index) {
                    if item.document.deleted { next.entries.removeValue(forKey: item.document.id) }
                    else { next.entries[item.document.id] = item.entry }
                }
                saveState(next) // Checkpoint after each batch so an interruption resumes, not restarts.
            }
            let mediaWarning = try await syncMedia(attachments, token: token, state: &next)
            next.lastSync = Date()
            saveState(next)
            lastSync = next.lastSync
            error = mediaWarning
            if !plan.batches.isEmpty || mediaChanged { await refreshAccount() }
        } catch let failure as CloudError where failure == .unauthorized {
            clearSession()
            error = "Your OpenScribe Cloud session ended. Sign in again to keep syncing."
        } catch {
            self.error = "Sync paused: \(error.localizedDescription). It will retry automatically."
        }
    }

    // MARK: Media

    /// Progress of the current media upload, for the settings page.
    @Published private(set) var mediaProgress: String?
    private var mediaChanged = false

    struct MediaWork: Sendable, Equatable {
        var uploads: [ContextAttachment]
        var deletions: [String]
    }

    nonisolated static func mediaKey(_ attachment: ContextAttachment) -> String { "\(attachment.documentID)/\(attachment.id)" }

    /// Which attachments to upload or remove. Only documents the server already has are considered,
    /// and a file is re-sent only when its source files change. Screenshots go first: they're small.
    nonisolated static func planMedia(_ attachments: [String: [ContextAttachment]], state: SyncState,
                                      screenshots: Bool, recordings: Bool) -> MediaWork {
        let media = state.media ?? [:]
        var wanted: [String: ContextAttachment] = [:]
        for (documentID, items) in attachments where state.entries[documentID] != nil {
            for item in items where item.kind == .screenshot ? screenshots : recordings {
                wanted[mediaKey(item)] = item
            }
        }
        let uploads = wanted.values.filter { media[mediaKey($0)]?.stamp != $0.sourceStamp }
            .sorted { ($0.kind == .screenshot ? 0 : 1, $0.createdAt) < ($1.kind == .screenshot ? 0 : 1, $1.createdAt) }
        // Documents that were deleted take their files with them on the server; just forget those.
        let deletions = media.keys.filter { key in
            wanted[key] == nil && state.entries[String(key.split(separator: "/").first ?? "")] != nil
        }.sorted()
        return MediaWork(uploads: uploads, deletions: deletions)
    }

    /// Returns a warning to show when some files couldn't be uploaded.
    private func syncMedia(_ attachments: [String: [ContextAttachment]], token: String, state: inout SyncState) async throws -> String? {
        mediaChanged = false
        defer { mediaProgress = nil }
        // Forget files whose document is gone; the server removed them with the document.
        state.media = (state.media ?? [:]).filter { state.entries[String($0.key.split(separator: "/").first ?? "")] != nil }
        let settings = app?.settings
        let work = Self.planMedia(attachments, state: state, screenshots: settings?.cloudSyncScreenshots ?? true,
                                  recordings: settings?.cloudSyncRecordings ?? true)
        for key in work.deletions {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            _ = try await request("api/v1/attachments/\(Self.pathComponent(parts[0]))/\(Self.pathComponent(parts[1]))", method: "DELETE", token: token)
            state.media?.removeValue(forKey: key)
            mediaChanged = true
            saveState(state)
        }
        var warning: String?
        for (index, attachment) in work.uploads.enumerated() {
            guard enabled, signedIn else { return warning }
            mediaProgress = work.uploads.count > 1 ? "Uploading files (\(index + 1) of \(work.uploads.count))" : "Uploading a file"
            let key = Self.mediaKey(attachment)
            let stamp = attachment.sourceStamp
            let encoded: CloudMedia.Encoded
            do {
                encoded = try await Task.detached(priority: .utility) { try await CloudMedia.encode(attachment) }.value
            } catch {
                // An unreadable file won't get better by retrying; try again when it changes.
                state.media = (state.media ?? [:]).merging([key: .init(stamp: stamp, sha256: "", bytes: 0)]) { $1 }
                saveState(state)
                continue
            }
            defer { try? FileManager.default.removeItem(at: encoded.url) }
            if let existing = state.media?[key], existing.sha256 == encoded.sha256 {
                state.media?[key]?.stamp = stamp // Same bytes as last time.
                saveState(state)
                continue
            }
            guard encoded.bytes <= CloudMedia.maximumUploadBytes else {
                state.media = (state.media ?? [:]).merging([key: .init(stamp: stamp, sha256: "", bytes: 0)]) { $1 }
                saveState(state)
                continue
            }
            do {
                try await upload(attachment, encoded: encoded, token: token)
            } catch let CloudError.server(status, message) where status == 413 {
                if message == "quota_exceeded" {
                    return "OpenScribe Cloud storage is full, so new screenshots and recordings aren’t uploading. Notes and meetings still sync."
                }
                warning = "A file was too large to upload."
                continue
            } catch let CloudError.server(status, _) where status == 404 || status == 415 || status == 400 {
                continue // The document isn't on the server yet, or the file was refused; retry on the next sync.
            }
            var media = state.media ?? [:]
            media[key] = .init(stamp: stamp, sha256: encoded.sha256, bytes: encoded.bytes)
            state.media = media
            mediaChanged = true
            saveState(state)
        }
        return warning
    }

    private func upload(_ attachment: ContextAttachment, encoded: CloudMedia.Encoded, token: String) async throws {
        let path = "api/v1/attachments/\(Self.pathComponent(attachment.documentID))/\(Self.pathComponent(attachment.id))"
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = "PUT"
        request.timeoutInterval = 600
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(encoded.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(attachment.kind.rawValue, forHTTPHeaderField: "X-OpenScribe-Kind")
        request.setValue(encoded.sha256, forHTTPHeaderField: "X-OpenScribe-Sha256")
        request.setValue(ContextDate.string(attachment.createdAt), forHTTPHeaderField: "X-OpenScribe-Created-At")
        if attachment.durationSeconds > 0 { request.setValue(String(format: "%.1f", attachment.durationSeconds), forHTTPHeaderField: "X-OpenScribe-Duration") }
        let caption = String(attachment.caption.prefix(500))
        if !caption.isEmpty, let encodedCaption = caption.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            request.setValue(encodedCaption, forHTTPHeaderField: "X-OpenScribe-Caption")
        }
        let (data, response) = try await session.upload(for: request, fromFile: encoded.url)
        try Self.check(response, data: data)
    }

    nonisolated private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? value
    }

    struct PlannedDocument: Sendable {
        var document: ContextDocument
        var entry: SyncState.Entry
    }

    struct Plan: Sendable {
        var batches: [[PlannedDocument]]
        var state: SyncState
    }

    /// Works out what changed since the last sync. Pure, so it can be tested without a server.
    nonisolated static func plan(library: ContextLibrary, state: SyncState, now: Date) -> Plan {
        var changed: [PlannedDocument] = []
        var present = Set<String>()
        for var document in library.documents where !document.deleted {
            present.insert(document.id)
            document = fitted(document)
            let hash = fingerprint(document)
            guard state.entries[document.id]?.hash != hash else { continue }
            // Local edits don't always move `updatedAt`, so a changed document is stamped now; the
            // server only replaces what it has with something newer.
            document.updatedAt = max(document.updatedAt, now)
            changed.append(PlannedDocument(document: document, entry: .init(hash: hash, kind: document.kind.rawValue, createdAt: document.createdAt)))
        }
        for (id, entry) in state.entries where !present.contains(id) {
            let tombstone = ContextDocument(id: id, kind: ContextDocument.Kind(rawValue: entry.kind) ?? .note, title: "",
                                            createdAt: entry.createdAt, updatedAt: now, deleted: true, body: "")
            changed.append(PlannedDocument(document: tombstone, entry: entry))
        }
        // Stay well inside the server's limits: 200 documents and 5 MB per request.
        var batches: [[PlannedDocument]] = []
        var current: [PlannedDocument] = []
        var bytes = 0
        for item in changed {
            let size = (try? JSONEncoder().encode(item.document).count) ?? 0
            if !current.isEmpty && (current.count >= 150 || bytes + size > 4_000_000) {
                batches.append(current); current = []; bytes = 0
            }
            current.append(item)
            bytes += size
        }
        if !current.isEmpty { batches.append(current) }
        return Plan(batches: batches, state: state)
    }

    /// Very long meetings are trimmed to fit a single stored row.
    nonisolated static func fitted(_ document: ContextDocument) -> ContextDocument {
        var document = document
        let limit = 1_500_000
        if let transcript = document.transcript, transcript.utf8.count > limit {
            document.transcript = String(transcript.prefix(limit)) + "\n\n[Transcript trimmed for sync. The full text is on the Mac.]"
        }
        if document.body.utf8.count > limit { document.body = String(document.body.prefix(limit)) }
        return document
    }

    /// A hash of everything except `updatedAt`, which changes on every sync.
    nonisolated static func fingerprint(_ document: ContextDocument) -> String {
        var copy = document
        copy.updatedAt = copy.createdAt
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(copy)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: State

    struct SyncState: Codable, Sendable, Equatable {
        struct Entry: Codable, Sendable, Equatable {
            var hash: String
            var kind: String
            var createdAt: Date
        }
        struct MediaEntry: Codable, Sendable, Equatable {
            /// `ContextAttachment.sourceStamp` when this was last handled.
            var stamp: String
            /// Empty when the file couldn't be prepared; it's retried once the source changes.
            var sha256: String
            var bytes: Int
        }
        var server: String
        var entries: [String: Entry] = [:]
        var lastSync: Date?
        /// Uploaded attachments by "documentID/attachmentID". Optional so older state files still load.
        var media: [String: MediaEntry]?
    }

    private var stateURL: URL { dataRoot.appendingPathComponent("cloud-sync.json") }

    private func loadState() -> SyncState {
        (try? JSONDecoder().decode(SyncState.self, from: Data(contentsOf: stateURL))) ?? SyncState(server: server.absoluteString)
    }

    private func saveState(_ state: SyncState) {
        try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    // MARK: Networking

    enum CloudError: LocalizedError, Equatable {
        case unauthorized
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Signed out"
            case let .server(code, message): return message.isEmpty ? "OpenScribe Cloud returned \(code)" : message
            }
        }
    }

    private struct BatchResult: Decodable {
        struct Failure: Decodable { let index: Int }
        var errors: [Failure]
        init(errors: [Failure]) { self.errors = errors }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            errors = try container.decodeIfPresent([Failure].self, forKey: .errors) ?? []
        }
        private enum CodingKeys: String, CodingKey { case errors }
    }

    // MARK: Phone Link (docs/PHONE-LINK.md, "OpenScribe Cloud: relay and images")

    /// The server and app token for Phone Link's relay and images, or nil when not signed in with Google.
    var linkAccess: (server: URL, token: String)? {
        guard signedIn, let token else { return nil }
        return (server, token)
    }

    /// A token for one paired phone, tied to this account. Minting again revokes the phone's previous token.
    func mintPhoneToken(deviceID: String, name: String) async throws -> String {
        guard let token else { throw CloudError.unauthorized }
        struct Body: Encodable { let deviceId: String; let name: String }
        struct Reply: Decodable { let token: String }
        let data = try await request("api/v1/link/devices", method: "POST", token: token,
                                     body: try JSONEncoder().encode(Body(deviceId: deviceID, name: name)))
        return try JSONDecoder().decode(Reply.self, from: data).token
    }

    func revokePhoneToken(deviceID: String) async {
        guard let token else { return }
        _ = try? await request("api/v1/link/devices/\(Self.pathComponent(deviceID))", method: "DELETE", token: token)
    }

    /// Stores an encrypted clipboard image for two days and returns its id.
    func uploadLinkBlob(_ blob: Data) async throws -> String {
        guard let token else { throw CloudError.unauthorized }
        var request = URLRequest(url: server.appendingPathComponent("api/v1/link/blobs"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: blob)
        try Self.check(response, data: data)
        struct Reply: Decodable { let id: String }
        return try JSONDecoder().decode(Reply.self, from: data).id
    }

    func downloadLinkBlob(_ id: String) async throws -> Data {
        guard let token else { throw CloudError.unauthorized }
        return try await request("api/v1/link/blobs/\(Self.pathComponent(id))", token: token)
    }

    private func request(_ path: String, method: String = "GET", token: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return data
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw CloudError.unauthorized }
        guard (200..<300).contains(status) else {
            struct Message: Decodable { let error: String? }
            throw CloudError.server(status, (try? JSONDecoder().decode(Message.self, from: data))?.error ?? "")
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Local MCP

    /// The bundled stdio MCP server, if this build includes it.
    static var localServerURL: URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "openscribe-mcp"),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        // `swift run` / development builds sit next to the helper in .build.
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("openscribe-mcp")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    static var claudeDesktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// Adds (or updates) the `openscribe` entry in Claude Desktop's config, keeping everything else
    /// and leaving a backup of the previous file beside it.
    static func installInClaudeDesktop(server: URL) throws {
        let url = claudeDesktopConfigURL
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Claude Desktop’s config isn’t valid JSON, so it was left unchanged."])
            }
            config = existing
            try data.write(to: url.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.backup.json"), options: .atomic)
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["openscribe"] = ["command": server.path]
        config["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

/// Receives `openscribe://` links. Registered as the GetURL Apple Event handler so it works without
/// a SwiftUI window scene.
private final class URLEventHandler: NSObject {
    var onURL: (@MainActor (URL) -> Void)?

    func install() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handle(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        MainActor.assumeIsolated { onURL?(url) }
    }
}
