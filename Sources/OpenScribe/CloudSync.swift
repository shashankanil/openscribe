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
        let plan = await Task.detached(priority: .utility) {
            Self.plan(library: ContextLibrary.load(root: root), state: state.server == serverID ? state : SyncState(server: serverID), now: Date())
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
            next.lastSync = Date()
            saveState(next)
            lastSync = next.lastSync
            error = nil
            if !plan.batches.isEmpty { await refreshAccount() }
        } catch let failure as CloudError where failure == .unauthorized {
            clearSession()
            error = "Your OpenScribe Cloud session ended. Sign in again to keep syncing."
        } catch {
            self.error = "Sync paused: \(error.localizedDescription). It will retry automatically."
        }
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
        var server: String
        var entries: [String: Entry] = [:]
        var lastSync: Date?
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw CloudError.unauthorized }
        guard (200..<300).contains(status) else {
            struct Message: Decodable { let error: String? }
            throw CloudError.server(status, (try? JSONDecoder().decode(Message.self, from: data))?.error ?? "")
        }
        return data
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
