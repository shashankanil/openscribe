import Foundation

/// The normalized document shared by the local MCP server, the remote MCP server and the sync API.
/// See docs/CONTEXT-API.md. Dates always encode as ISO-8601 strings (UTC, millisecond precision),
/// regardless of the encoder's date strategy, and decode from ISO-8601 strings or reference-date numbers.
public struct ContextDocument: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case note
        case meeting
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deleted: Bool
    /// Markdown: note text, or meeting user notes.
    public var body: String
    /// Markdown or nil (meetings: overview, decisions, action items).
    public var summary: String?
    /// Plain text or nil (meetings: grouped transcript with [mm:ss] stamps).
    public var transcript: String?
    public var actionItems: [String]
    public var durationSeconds: Double
    public var tags: [String]

    public init(id: String, kind: Kind, title: String, createdAt: Date, updatedAt: Date, deleted: Bool = false,
                body: String, summary: String? = nil, transcript: String? = nil, actionItems: [String] = [],
                durationSeconds: Double = 0, tags: [String] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.body = body
        self.summary = summary
        self.transcript = transcript
        self.actionItems = actionItems
        self.durationSeconds = durationSeconds
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, createdAt, updatedAt, deleted, body, summary, transcript, actionItems, durationSeconds, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decode(StoredDate.self, forKey: .createdAt).date
        updatedAt = try c.decodeIfPresent(StoredDate.self, forKey: .updatedAt)?.date ?? createdAt
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(ContextDate.string(createdAt), forKey: .createdAt)
        try c.encode(ContextDate.string(updatedAt), forKey: .updatedAt)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(body, forKey: .body)
        try c.encode(summary, forKey: .summary) // explicit null, per contract
        try c.encode(transcript, forKey: .transcript)
        try c.encode(actionItems, forKey: .actionItems)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(tags, forKey: .tags)
    }
}

public enum ContextDate {
    /// ISO-8601 in UTC with milliseconds, e.g. `2026-11-16T15:09:43.120Z`.
    public static func string(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    public static func parse(_ text: String) -> Date? { StoredDate.parse(text) }
}
