import Foundation

// Lenient mirrors of the app's on-disk Codable models (Sources/OpenScribe/Models.swift and
// MeetingModels.swift). Unknown keys are ignored, every field is optional, and a single
// malformed element in an array is skipped instead of failing the whole file.
//
// Dates: `notes.json` is written with `.iso8601` (strings); `meeting.json` uses Foundation's
// default (seconds since 2001-01-01). `StoredDate` accepts either, plus fractional seconds.

struct StoredDate: Decodable {
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSinceReferenceDate: seconds)
        } else if let text = try? container.decode(String.self), let parsed = Self.parse(text) {
            date = parsed
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date")
        }
    }

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(trimmed, strategy: Date.ISO8601FormatStyle()) { return date }
        if let date = try? Date(trimmed, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return nil
    }
}

/// Decodes an array, dropping elements that fail to decode.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(JSONValue.self) // skip the malformed element
            }
        }
        elements = result
    }
}

private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    func lenientDate(_ key: Key) -> Date? { lenient(StoredDate.self, key)?.date }

    func lenientArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T]? { lenient(LossyArray<T>.self, key)?.elements }

    func lenientNumber(_ key: Key) -> Double? {
        if let value = lenient(Double.self, key) { return value }
        return lenient(String.self, key).flatMap(Double.init)
    }

    func lenientID(_ key: Key) -> String? {
        guard let raw = lenient(String.self, key)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)?.uuidString ?? raw
    }
}

struct StoredCapture: Decodable {
    var id: String
    var createdAt: Date?
    var title: String
    var rawText: String
    var text: String
    var duration: Double
    var sourceApplication: String?
    var kind: String?
    var attachment: String?
    var meetingID: String?
    var recognizedText: String?
    var superseded: Bool?

    var entryKind: String { kind ?? "dictation" }
    var isVisible: Bool { superseded != true }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, title, rawText, text, duration, sourceApplication, kind, attachment, meetingID, recognizedText, superseded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientID(.id) ?? UUID().uuidString
        createdAt = c.lenientDate(.createdAt)
        title = c.lenient(String.self, .title) ?? ""
        rawText = c.lenient(String.self, .rawText) ?? ""
        text = c.lenient(String.self, .text) ?? ""
        duration = c.lenientNumber(.duration) ?? 0
        sourceApplication = c.lenient(String.self, .sourceApplication)
        kind = c.lenient(String.self, .kind)
        attachment = c.lenient(String.self, .attachment)
        meetingID = c.lenientID(.meetingID)
        recognizedText = c.lenient(String.self, .recognizedText)
        superseded = c.lenient(Bool.self, .superseded)
    }
}

struct StoredNote: Decodable {
    var id: String
    var createdAt: Date?
    var title: String
    var rawText: String
    var cleanedText: String
    var editedText: String?
    var duration: Double
    var isPinned: Bool
    var tags: [String]
    var source: String
    var sourceApplication: String?
    var captures: [StoredCapture]?

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, title, rawText, cleanedText, editedText, duration, isPinned, tags, source, sourceApplication, captures
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientID(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: decoder.codingPath, debugDescription: "Note without id"))
        }
        self.id = id
        createdAt = c.lenientDate(.createdAt)
        title = c.lenient(String.self, .title) ?? ""
        rawText = c.lenient(String.self, .rawText) ?? ""
        cleanedText = c.lenient(String.self, .cleanedText) ?? ""
        editedText = c.lenient(String.self, .editedText)
        duration = c.lenientNumber(.duration) ?? 0
        isPinned = c.lenient(Bool.self, .isPinned) ?? false
        tags = c.lenientArray(String.self, .tags) ?? []
        source = c.lenient(String.self, .source) ?? "Dictation"
        sourceApplication = c.lenient(String.self, .sourceApplication)
        // Mirror `VoiceNote.captures`: absent means "not a day note", present (even empty) means day note.
        captures = c.contains(.captures) && !((try? c.decodeNil(forKey: .captures)) ?? true)
            ? (c.lenientArray(StoredCapture.self, .captures) ?? [])
            : nil
    }

    var isDailyNote: Bool { captures != nil }

    /// Mirrors `VoiceNote.displayText`.
    var displayText: String {
        if isDailyNote && editedText == nil { return cleanedText }
        return editedText ?? (cleanedText.isEmpty ? rawText : cleanedText)
    }

    /// Mirrors `VoiceNote.displayTitle`.
    var displayTitle: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name != "Untitled note" { return name }
        let firstLine = displayText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? "Untitled note" : String(words.prefix(64))
    }

    /// Mirrors `VoiceNote.lastCapturedAt` (captures are kept sorted oldest first).
    var lastCapturedAt: Date? {
        let dates = (captures ?? []).compactMap(\.createdAt) + [createdAt].compactMap { $0 }
        return dates.max()
    }
}

struct StoredSegment: Decodable {
    var id: String
    var track: String
    var start: Double
    var duration: Double
    var text: String

    private enum CodingKeys: String, CodingKey { case id, track, start, duration, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? ""
        track = c.lenient(String.self, .track) ?? "microphone"
        start = c.lenientNumber(.start) ?? 0
        duration = c.lenientNumber(.duration) ?? 0
        text = c.lenient(String.self, .text) ?? ""
    }

    init(id: String, track: String, start: Double, duration: Double, text: String) {
        self.id = id; self.track = track; self.start = start; self.duration = duration; self.text = text
    }
}

struct StoredSummaryPoint: Decodable {
    var text: String
    var sources: [String]

    private enum CodingKeys: String, CodingKey { case text, sources }

    init(from decoder: Decoder) throws {
        // Tolerate a bare string as a point.
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.text = text; sources = []; return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.lenient(String.self, .text) ?? ""
        sources = c.lenientArray(String.self, .sources) ?? []
    }
}

struct StoredSummary: Decodable {
    var overview: [StoredSummaryPoint]
    var decisions: [StoredSummaryPoint]
    var actions: [StoredSummaryPoint]

    private enum CodingKeys: String, CodingKey { case overview, decisions, actions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overview = c.lenientArray(StoredSummaryPoint.self, .overview) ?? []
        decisions = c.lenientArray(StoredSummaryPoint.self, .decisions) ?? []
        actions = c.lenientArray(StoredSummaryPoint.self, .actions) ?? []
    }
}

struct StoredMeeting: Decodable {
    var id: String?
    var title: String
    var createdAt: Date?
    var duration: Double
    var status: String
    var segments: [StoredSegment]
    var summary: StoredSummary?
    var userNotes: String?
    var microphoneLabel: String
    var systemLabel: String

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration, status, segments, summary, userNotes, microphoneLabel, systemLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientID(.id)
        title = c.lenient(String.self, .title) ?? ""
        createdAt = c.lenientDate(.createdAt)
        duration = c.lenientNumber(.duration) ?? 0
        status = c.lenient(String.self, .status) ?? "saved"
        segments = c.lenientArray(StoredSegment.self, .segments) ?? []
        summary = c.lenient(StoredSummary.self, .summary)
        userNotes = c.lenient(String.self, .userNotes)
        microphoneLabel = c.lenient(String.self, .microphoneLabel) ?? "Microphone"
        systemLabel = c.lenient(String.self, .systemLabel) ?? "System audio"
    }
}
