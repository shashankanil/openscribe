import Foundation

/// Transport-independent MCP (JSON-RPC 2.0) message handler for the OpenScribe context tools.
/// Feed it one newline-delimited message at a time; it returns the response line, or nil for notifications.
public final class MCPServer {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverName = "openscribe"
    public static let serverVersion = "0.5.0"

    public static let instructions = """
    Read-only access to the user's OpenScribe notes (dictations, day notes, written notes) and recorded meetings \
    (summaries, decisions, action items, the user's notes and transcripts). Use `search` to find things by topic, \
    `list_recent` for what happened lately, `fetch` or `get_meeting` for full details, and `list_action_items` for follow-ups.
    """

    private let cache: ContextLibraryCache
    private let log: (String) -> Void
    private let now: () -> Date
    public private(set) var negotiatedVersion: String?

    public init(root: URL, log: @escaping (String) -> Void = { _ in }, now: @escaping () -> Date = Date.init) {
        cache = ContextLibraryCache(root: root)
        self.log = log
        self.now = now
    }

    enum RPCError: Error {
        case parse, invalidRequest, methodNotFound(String), invalidParams(String), internalError(String)

        var code: Int {
            switch self {
            case .parse: return -32700
            case .invalidRequest: return -32600
            case .methodNotFound: return -32601
            case .invalidParams: return -32602
            case .internalError: return -32603
            }
        }

        var message: String {
            switch self {
            case .parse: return "Parse error"
            case .invalidRequest: return "Invalid Request"
            case .methodNotFound(let method): return "Method not found: \(method)"
            case .invalidParams(let detail): return "Invalid params: \(detail)"
            case .internalError(let detail): return "Internal error: \(detail)"
            }
        }
    }

    /// Handles one line of input. Returns the serialized response, or nil when no response is due.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return Self.errorResponse(id: .null, .parse).serialized()
        }
        if case .array(let batch) = message {
            guard !batch.isEmpty else { return Self.errorResponse(id: .null, .invalidRequest).serialized() }
            let responses = batch.compactMap(handle(message:))
            return responses.isEmpty ? nil : JSONValue.array(responses).serialized()
        }
        return handle(message: message)?.serialized()
    }

    public func handle(message: JSONValue) -> JSONValue? {
        guard case .object(let object) = message else { return Self.errorResponse(id: .null, .invalidRequest) }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            // A response from the client (we never send requests) or garbage.
            if object["result"] != nil || object["error"] != nil { return nil }
            return Self.errorResponse(id: id ?? .null, .invalidRequest)
        }
        if let id, !Self.isValidID(id) { return Self.errorResponse(id: .null, .invalidRequest) }
        let params = object["params"]?.objectValue ?? [:]
        guard let id else {
            handleNotification(method, params: params)
            return nil
        }
        do {
            let result = try dispatch(method, params: params)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let error as RPCError {
            return Self.errorResponse(id: id, error)
        } catch {
            return Self.errorResponse(id: id, .internalError(error.localizedDescription))
        }
    }

    private static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .int, .double: return true
        default: return false
        }
    }

    private func handleNotification(_ method: String, params: [String: JSONValue]) {
        switch method {
        case "notifications/initialized": log("client initialized")
        case "notifications/cancelled": break // requests are answered synchronously
        default: log("ignoring notification \(method)")
        }
    }

    private func dispatch(_ method: String, params: [String: JSONValue]) throws -> JSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.supportedProtocolVersions[0]
            negotiatedVersion = version
            if let client = params["clientInfo"]?["name"]?.stringValue { log("initialize from \(client), protocol \(version)") }
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(Self.serverName), "title": "OpenScribe", "version": .string(Self.serverVersion)],
                "instructions": .string(Self.instructions),
            ]
        case "ping":
            return [:]
        case "tools/list":
            var tools = ContextTools.definitions
            if negotiatedVersion == "2024-11-05" || negotiatedVersion == "2025-03-26" {
                // outputSchema/title arrived in 2025-06-18; strip for older clients.
                tools = tools.map { tool in
                    guard case .object(var object) = tool else { return tool }
                    object["outputSchema"] = nil
                    object["title"] = nil
                    return .object(object)
                }
            }
            return ["tools": .array(tools)]
        case "tools/call":
            guard let name = params["name"]?.stringValue else { throw RPCError.invalidParams("missing tool name") }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .some(.null): arguments = [:]
            case .some(.object(let object)): arguments = object
            default: throw RPCError.invalidParams("`arguments` must be an object")
            }
            let snapshot = cache.snapshot()
            for warning in snapshot.library.warnings { log("warning: \(warning)") }
            do {
                var result = try ContextTools.call(name, arguments: arguments, library: snapshot.library, index: snapshot.index, now: now())
                if negotiatedVersion == "2024-11-05" || negotiatedVersion == "2025-03-26" { result.structured = nil }
                return result.json
            } catch ContextTools.CallError.unknownTool(let tool) {
                throw RPCError.invalidParams("unknown tool \(tool)")
            }
        default:
            throw RPCError.methodNotFound(method)
        }
    }

    static func errorResponse(id: JSONValue, _ error: RPCError) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(error.code), "message": .string(error.message)]]
    }
}
