import Foundation

/// The five read-only MCP tools defined in docs/CONTEXT-API.md.
public enum ContextTools {
    public struct Result: Equatable, Sendable {
        public var text: String
        public var structured: JSONValue?
        public var isError: Bool

        public static func error(_ message: String) -> Result { Result(text: message, structured: nil, isError: true) }

        /// MCP `CallToolResult`.
        public var json: JSONValue {
            var object: [String: JSONValue] = ["content": [["type": "text", "text": .string(text)]]]
            if let structured { object["structuredContent"] = structured }
            if isError { object["isError"] = true }
            return .object(object)
        }
    }

    public enum CallError: Error, Equatable {
        case unknownTool(String)
    }

    /// Transcripts longer than this are cut, with a note, in tool output.
    public static let transcriptLimit = 60_000
    /// Bodies longer than this are cut in `list_recent` (use `fetch` for the full text).
    public static let listBodyLimit = 2_000

    public static let names = ["search", "fetch", "list_recent", "get_meeting", "list_action_items"]

    // MARK: Definitions

    public static var definitions: [JSONValue] {
        let readOnly: JSONValue = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        let kindSchema: JSONValue = ["type": "string", "enum": ["note", "meeting"], "description": "Restrict to notes or meetings."]
        return [
            [
                "name": "search",
                "title": "Search notes and meetings",
                "description": "Search the user's OpenScribe notes (dictations, day notes, written notes) and meetings (summaries, action items, notes, transcripts). Returns ranked results with a snippet; call `fetch` with a result id for the full document.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words or a phrase to search for."],
                        "kind": kindSchema,
                        "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10, "description": "Maximum results (1–50)."],
                    ],
                    "required": ["query"],
                ],
                "outputSchema": [
                    "type": "object",
                    "properties": ["results": ["type": "array", "items": searchResultSchema]],
                    "required": ["results"],
                ],
                "annotations": readOnly,
            ],
            [
                "name": "fetch",
                "title": "Fetch a note or meeting",
                "description": "Fetch one OpenScribe note or meeting by id (from `search` or `list_recent`), with its full text, summary, action items and transcript. Transcripts over 60,000 characters are truncated.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Document id."]],
                    "required": ["id"],
                ],
                "outputSchema": documentSchema,
                "annotations": readOnly,
            ],
            [
                "name": "list_recent",
                "title": "List recent notes and meetings",
                "description": "List the user's notes and meetings updated in the last `days` days, newest first, without transcripts.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "kind": kindSchema,
                        "days": ["type": "integer", "minimum": 1, "default": 7, "description": "Look-back window in days."],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 20, "description": "Maximum documents."],
                    ],
                ],
                "outputSchema": [
                    "type": "object",
                    "properties": ["documents": ["type": "array", "items": documentSchema]],
                    "required": ["documents"],
                ],
                "annotations": readOnly,
            ],
            [
                "name": "get_meeting",
                "title": "Get a meeting",
                "description": "Get a meeting's title, date, duration, summary, action items and the user's notes; set `includeTranscript` for the transcript (truncated at 60,000 characters).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Meeting id."],
                        "includeTranscript": ["type": "boolean", "default": false, "description": "Include the transcript."],
                    ],
                    "required": ["id"],
                ],
                "outputSchema": meetingSchema,
                "annotations": readOnly,
            ],
            [
                "name": "list_action_items",
                "title": "List action items",
                "description": "List action items from meeting summaries in the last `days` days, newest meeting first, with the meeting id, title and date.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "days": ["type": "integer", "minimum": 1, "default": 14, "description": "Look-back window in days."],
                    ],
                ],
                "outputSchema": [
                    "type": "object",
                    "properties": [
                        "actionItems": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "text": ["type": "string"],
                                    "meetingId": ["type": "string"],
                                    "meetingTitle": ["type": "string"],
                                    "meetingDate": ["type": "string", "format": "date-time"],
                                ],
                                "required": ["text", "meetingId", "meetingTitle", "meetingDate"],
                            ],
                        ],
                    ],
                    "required": ["actionItems"],
                ],
                "annotations": readOnly,
            ],
        ]
    }

    static let nullableString: JSONValue = ["type": ["string", "null"]]
    static let dateTime: JSONValue = ["type": "string", "format": "date-time"]
    static let stringArray: JSONValue = ["type": "array", "items": ["type": "string"]]

    static var searchResultSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "id": ["type": "string"],
                "kind": ["type": "string", "enum": ["note", "meeting"]],
                "title": ["type": "string"],
                "createdAt": dateTime,
                "snippet": ["type": "string"],
            ],
            "required": ["id", "kind", "title", "createdAt", "snippet"],
        ]
    }

    static var documentSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "id": ["type": "string"],
                "kind": ["type": "string", "enum": ["note", "meeting"]],
                "title": ["type": "string"],
                "createdAt": dateTime,
                "updatedAt": dateTime,
                "deleted": ["type": "boolean"],
                "body": ["type": "string"],
                "summary": nullableString,
                "transcript": nullableString,
                "actionItems": stringArray,
                "durationSeconds": ["type": "number"],
                "tags": stringArray,
            ],
            "required": ["id", "kind", "title", "createdAt", "updatedAt", "deleted", "body", "summary", "transcript", "actionItems", "durationSeconds", "tags"],
        ]
    }

    static var meetingSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "id": ["type": "string"],
                "title": ["type": "string"],
                "createdAt": dateTime,
                "updatedAt": dateTime,
                "durationSeconds": ["type": "number"],
                "status": ["type": "string"],
                "summary": nullableString,
                "actionItems": stringArray,
                "notes": ["type": "string"],
                "transcript": nullableString,
                "transcriptTruncated": ["type": "boolean"],
            ],
            "required": ["id", "title", "createdAt", "updatedAt", "durationSeconds", "status", "summary", "actionItems", "notes", "transcript", "transcriptTruncated"],
        ]
    }

    // MARK: Calling

    /// Runs a tool. Argument problems and missing documents are tool errors (`isError: true`);
    /// an unknown tool name throws `CallError.unknownTool` (a protocol error).
    public static func call(_ name: String, arguments: [String: JSONValue], library: ContextLibrary, index: SearchIndex? = nil,
                            now: Date = Date()) throws -> Result {
        switch name {
        case "search": return search(arguments, index: index ?? SearchIndex(library: library), now: now)
        case "fetch": return fetch(arguments, library: library)
        case "list_recent": return listRecent(arguments, library: library, now: now)
        case "get_meeting": return getMeeting(arguments, library: library)
        case "list_action_items": return listActionItems(arguments, library: library, now: now)
        default: throw CallError.unknownTool(name)
        }
    }

    private enum ArgumentError: Error { case message(String) }

    private static func kind(_ arguments: [String: JSONValue]) throws -> ContextDocument.Kind? {
        guard let value = arguments["kind"], !value.isNull else { return nil }
        guard let raw = value.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() else {
            throw ArgumentError.message("`kind` must be \"note\" or \"meeting\".")
        }
        if raw.isEmpty || raw == "all" || raw == "any" { return nil }
        guard let kind = ContextDocument.Kind(rawValue: raw) else { throw ArgumentError.message("`kind` must be \"note\" or \"meeting\".") }
        return kind
    }

    private static func integer(_ arguments: [String: JSONValue], _ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = arguments[key], !raw.isNull else { return value }
        guard let number = raw.intValue else { throw ArgumentError.message("`\(key)` must be an integer.") }
        return min(max(number, range.lowerBound), range.upperBound)
    }

    private static func requiredString(_ arguments: [String: JSONValue], _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ArgumentError.message("`\(key)` is required and must be a non-empty string.")
        }
        return value
    }

    private static func guarded(_ body: () throws -> Result) -> Result {
        do { return try body() }
        catch ArgumentError.message(let message) { return .error(message) }
        catch { return .error(error.localizedDescription) }
    }

    static func search(_ arguments: [String: JSONValue], index: SearchIndex, now: Date) -> Result {
        guarded {
            guard let query = arguments["query"]?.stringValue else { throw ArgumentError.message("`query` is required and must be a string.") }
            let kind = try kind(arguments)
            let limit = try integer(arguments, "limit", default: 10, range: 1...50)
            let hits = index.search(query, kind: kind, limit: limit, now: now)
            let results: [JSONValue] = hits.map {
                ["id": .string($0.id), "kind": .string($0.kind.rawValue), "title": .string($0.title),
                 "createdAt": .string(ContextDate.string($0.createdAt)), "snippet": .string($0.snippet)]
            }
            let structured: JSONValue = ["results": .array(results)]
            // Text mirrors the structured result as JSON (MCP recommendation; ChatGPT connector format).
            return Result(text: structured.serialized(), structured: structured, isError: false)
        }
    }

    static func fetch(_ arguments: [String: JSONValue], library: ContextLibrary) -> Result {
        guarded {
            let id = try requiredString(arguments, "id")
            guard var document = library.document(id: id) else {
                throw ArgumentError.message("No note or meeting with id \(id). Use `search` or `list_recent` to find ids.")
            }
            document.transcript = document.transcript.map { truncateTranscript($0).text }
            return Result(text: markdown(document, status: library.meetingInfo[document.id]?.status),
                          structured: try JSONValue.encoding(document), isError: false)
        }
    }

    static func listRecent(_ arguments: [String: JSONValue], library: ContextLibrary, now: Date) -> Result {
        guarded {
            let kind = try kind(arguments)
            let days = try integer(arguments, "days", default: 7, range: 1...36_500)
            let limit = try integer(arguments, "limit", default: 20, range: 1...100)
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            let recent = library.documents
                .filter { !$0.deleted && (kind == nil || $0.kind == kind) && $0.updatedAt >= cutoff }
                .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
                .prefix(limit)
                .map { document -> ContextDocument in
                    var document = document
                    document.transcript = nil
                    if document.body.count > listBodyLimit {
                        document.body = String(document.body.prefix(listBodyLimit)) + "\n\n[… truncated; call `fetch` for the full text]"
                    }
                    return document
                }
            var lines = ["\(recent.count) \(kind.map { $0.rawValue + "s" } ?? "documents") updated in the last \(days) day\(days == 1 ? "" : "s")."]
            for document in recent {
                var line = "\n## \(document.title)\n\nid: \(document.id) · \(document.kind.rawValue) · created \(readable(document.createdAt))"
                if document.updatedAt.timeIntervalSince(document.createdAt) > 60 { line += " · updated \(readable(document.updatedAt))" }
                if document.durationSeconds > 0 { line += " · \(duration(document.durationSeconds))" }
                if !document.tags.isEmpty { line += " · tags: \(document.tags.joined(separator: ", "))" }
                let preview = SearchIndex.excerpt(plainPreview(document.summary ?? document.body), length: 300)
                if !preview.isEmpty { line += "\n\n" + preview }
                if !document.actionItems.isEmpty { line += "\n\nAction items:\n" + document.actionItems.map { "- \($0)" }.joined(separator: "\n") }
                lines.append(line)
            }
            let structured: JSONValue = ["documents": .array(try recent.map { try JSONValue.encoding($0) })]
            return Result(text: lines.joined(separator: "\n"), structured: structured, isError: false)
        }
    }

    static func getMeeting(_ arguments: [String: JSONValue], library: ContextLibrary) -> Result {
        guarded {
            let id = try requiredString(arguments, "id")
            let includeTranscript = arguments["includeTranscript"]?.boolValue ?? false
            guard let document = library.document(id: id), document.kind == .meeting else {
                if library.document(id: id) != nil { throw ArgumentError.message("\(id) is a note, not a meeting. Use `fetch` instead.") }
                throw ArgumentError.message("No meeting with id \(id). Use `search` with kind \"meeting\" or `list_recent` to find ids.")
            }
            let status = library.meetingInfo[document.id]?.status ?? "saved"
            var transcript: String?
            var truncated = false
            if includeTranscript, let full = document.transcript {
                let cut = truncateTranscript(full)
                transcript = cut.text
                truncated = cut.truncated
            }
            let structured: JSONValue = [
                "id": .string(document.id),
                "title": .string(document.title),
                "createdAt": .string(ContextDate.string(document.createdAt)),
                "updatedAt": .string(ContextDate.string(document.updatedAt)),
                "durationSeconds": .double(document.durationSeconds),
                "status": .string(status),
                "summary": document.summary.map(JSONValue.string) ?? .null,
                "actionItems": .array(document.actionItems.map(JSONValue.string)),
                "notes": .string(document.body),
                "transcript": transcript.map(JSONValue.string) ?? .null,
                "transcriptTruncated": .bool(truncated),
            ]
            var shown = document
            shown.transcript = transcript
            var text = markdown(shown, status: status)
            if !includeTranscript && document.transcript != nil {
                text += "\n\n(Transcript available: call `get_meeting` with includeTranscript: true.)"
            }
            return Result(text: text, structured: structured, isError: false)
        }
    }

    static func listActionItems(_ arguments: [String: JSONValue], library: ContextLibrary, now: Date) -> Result {
        guarded {
            let days = try integer(arguments, "days", default: 14, range: 1...36_500)
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            let meetings = library.documents
                .filter { !$0.deleted && $0.kind == .meeting && $0.createdAt >= cutoff && !$0.actionItems.isEmpty }
                .sorted { $0.createdAt > $1.createdAt }
            var items: [JSONValue] = []
            var lines: [String] = []
            for meeting in meetings {
                lines.append("\n## \(meeting.title) (\(readable(meeting.createdAt)), id: \(meeting.id))\n")
                for item in meeting.actionItems {
                    items.append(["text": .string(item), "meetingId": .string(meeting.id), "meetingTitle": .string(meeting.title),
                                  "meetingDate": .string(ContextDate.string(meeting.createdAt))])
                    lines.append("- \(item)")
                }
            }
            let header = "\(items.count) action item\(items.count == 1 ? "" : "s") from \(meetings.count) meeting\(meetings.count == 1 ? "" : "s") in the last \(days) day\(days == 1 ? "" : "s")."
            return Result(text: ([header] + lines).joined(separator: "\n"), structured: ["actionItems": .array(items)], isError: false)
        }
    }

    // MARK: Formatting

    public static func truncateTranscript(_ transcript: String, limit: Int = transcriptLimit) -> (text: String, truncated: Bool) {
        guard transcript.count > limit else { return (transcript, false) }
        var cut = transcript.index(transcript.startIndex, offsetBy: limit)
        if let boundary = transcript[..<cut].range(of: "\n\n", options: .backwards), transcript.distance(from: boundary.lowerBound, to: cut) < 4_000 {
            cut = boundary.lowerBound
        }
        let shown = transcript.distance(from: transcript.startIndex, to: cut)
        let note = "\n\n[Transcript truncated: showing the first \(shown) of \(transcript.count) characters. "
            + "For a narrower result, call `get_meeting` (summary and action items without the transcript) or `search` for specific words to find the relevant part.]"
        return (String(transcript[..<cut]) + note, true)
    }

    /// The document as markdown for the model.
    public static func markdown(_ document: ContextDocument, status: String? = nil) -> String {
        var meta = ["id: \(document.id)", document.kind.rawValue, "created \(readable(document.createdAt))"]
        if document.updatedAt.timeIntervalSince(document.createdAt) > 60 { meta.append("updated \(readable(document.updatedAt))") }
        if document.durationSeconds > 0 { meta.append("duration \(duration(document.durationSeconds))") }
        if let status, document.kind == .meeting, status != "ready" { meta.append("status \(status)") }
        if !document.tags.isEmpty { meta.append("tags: \(document.tags.joined(separator: ", "))") }
        var parts = ["# \(document.title)", meta.joined(separator: " · ")]
        switch document.kind {
        case .note:
            parts.append(document.body.isEmpty ? "_(empty)_" : document.body)
        case .meeting:
            if !document.body.isEmpty { parts.append("## My notes\n\n" + document.body) }
            if let summary = document.summary { parts.append(summary) } else { parts.append("_No summary yet._") }
            if let transcript = document.transcript { parts.append("## Transcript\n\n" + transcript) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Drops markdown heading markers and "None identified." placeholders so a collapsed preview reads naturally.
    static func plainPreview(_ markdown: String) -> String {
        markdown.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#") {
                text = String(text.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text + " —"
            }
            return text == "None identified." ? nil : text
        }.joined(separator: " ")
    }

    static func readable(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm xxx"
        return formatter.string(from: date)
    }

    static func duration(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(min(max(0, seconds), 1e9).rounded()) : 0
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}
