import Foundation

struct AudioChunkDescriptor: Codable, Equatable {
    var filename: String
    var start: TimeInterval
    var duration: TimeInterval
}

enum MeetingStatus: String, Codable {
    case recording, paused, saved, transcribing, summarizing, ready, interrupted, failed
    var title: String { rawValue.capitalized }
}

struct MeetingSegment: Codable, Identifiable, Equatable {
    var id: String // Relative audio path; stable across retries.
    var track: String
    var start: TimeInterval
    var duration: TimeInterval
    var text: String
    var timestamp: String { Self.timestamp(start) }
    static func timestamp(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct MeetingSummary: Codable, Equatable {
    struct Point: Codable, Equatable, Identifiable {
        var text: String
        var sources: [String]
        var id: String { text + sources.joined() }
    }
    var overview: [Point]
    var decisions: [Point]
    var actions: [Point]

    /// Reads a model's reply leniently. Models often wrap the JSON in prose or a code fence, write a
    /// point as a bare string, or cite a segment by file name or timestamp instead of its exact ID.
    /// Citations are resolved against the transcript; when the model cited anything, points it could
    /// not tie to the transcript are dropped as likely inventions. A reply with no citations at all
    /// (a model that ignored the format) keeps its points, shown without timestamps.
    static func parse(_ response: String, segments: [MeetingSegment]) throws -> MeetingSummary {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(response[start...end].utf8)) as? [String: Any] else {
            throw MeetingError.invalidSummary
        }
        let resolve = SourceResolver(segments: segments)
        func points(_ keys: [String]) -> [(text: String, cited: [String], claimed: Bool)] {
            let raw = keys.lazy.compactMap { object[$0] as? [Any] }.first ?? []
            return raw.compactMap { item in
                let text: String
                var claimed: [String] = []
                if let string = item as? String {
                    text = string
                } else if let dict = item as? [String: Any] {
                    text = (dict["text"] ?? dict["point"] ?? dict["summary"] ?? dict["action"] ?? dict["decision"]) as? String ?? ""
                    let sources = dict["sources"] ?? dict["source"] ?? dict["segment_ids"] ?? dict["ids"]
                    claimed = (sources as? [Any])?.compactMap { "\($0)" } ?? (sources.map { ["\($0)"] } ?? [])
                } else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return (trimmed, resolve(claimed), !claimed.isEmpty)
            }
        }
        let overview = points(["overview", "summary", "key_points", "topics"])
        let decisions = points(["decisions"])
        let actions = points(["actions", "action_items", "actionItems"])
        let all = overview + decisions + actions
        let anyCited = all.contains { !$0.cited.isEmpty }
        func keep(_ list: [(text: String, cited: [String], claimed: Bool)]) -> [Point] {
            list.filter { !anyCited || !$0.cited.isEmpty }.map { Point(text: $0.text, sources: $0.cited) }
        }
        return MeetingSummary(overview: keep(overview), decisions: keep(decisions), actions: keep(actions))
    }

    /// Maps what a model cited to real segment IDs: exact ID, file name, or a [mm:ss] timestamp.
    private struct SourceResolver {
        let ids: Set<String>
        let byName: [String: String]
        let byStamp: [String: String]

        init(segments: [MeetingSegment]) {
            ids = Set(segments.map(\.id))
            var names: [String: String] = [:], stamps: [String: String] = [:]
            for segment in segments {
                let name = (segment.id as NSString).lastPathComponent
                names[name] = names[name] == nil ? segment.id : "" // Ambiguous names resolve to nothing.
                if stamps[segment.timestamp] == nil { stamps[segment.timestamp] = segment.id }
            }
            byName = names.filter { !$0.value.isEmpty }
            byStamp = stamps
        }

        func callAsFunction(_ claimed: [String]) -> [String] {
            var result: [String] = []
            for raw in claimed {
                let value = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]()\"'")))
                let value2 = value.hasPrefix("ID: ") ? String(value.dropFirst(4)) : value
                let match = ids.contains(value2) ? value2
                    : byName[(value2 as NSString).lastPathComponent]
                    ?? value2.range(of: #"\d{1,3}:\d{2}"#, options: .regularExpression).flatMap { byStamp[Self.pad(String(value2[$0]))] }
                if let match, !result.contains(match) { result.append(match) }
            }
            return result
        }

        private static func pad(_ stamp: String) -> String { stamp.count == 4 ? "0" + stamp : stamp }
    }

}

struct MeetingRecord: Codable, Identifiable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var duration: TimeInterval = 0
    var status: MeetingStatus = .recording
    var summarizeOnStop = true
    var liveTranscription: Bool?
    var includesMicrophone = true
    var includesSystemAudio = true
    var settings: AppSettings
    var segments: [MeetingSegment] = []
    var summary: MeetingSummary?
    var recoveryNotice: String?
    var lastError: String?
    var microphoneLabel = "Microphone"
    var systemLabel = "System audio"
    /// What the user wrote during or after the meeting.
    var userNotes: String?
    /// The transcript was too short to summarize automatically; waiting for the user to decide.
    var summaryNeedsConfirmation: Bool?

    var wordCount: Int { segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }

    var transcript: String {
        MeetingTranscript.passages(segments).map {
            "[\(MeetingSegment.timestamp($0.start))] \($0.track == "microphone" ? microphoneLabel : systemLabel)\n\($0.text)"
        }.joined(separator: "\n\n")
    }
    var markdown: String {
        var result = "# \(title)\n\n\(createdAt.formatted())\n\n"
        if let notes = userNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            result += "## My notes\n\n\(notes)\n\n"
        }
        if let summary {
            for (heading, points) in [("Summary", summary.overview), ("Decisions", summary.decisions), ("Action items", summary.actions)] {
                result += "## \(heading)\n\n"
                result += points.isEmpty ? "None identified.\n\n" : points.map { point in
                    let stamps = point.sources.compactMap { id in segments.first { $0.id == id }?.timestamp }.joined(separator: ", ")
                    return stamps.isEmpty ? "- \(point.text)" : "- \(point.text) [\(stamps)]"
                }.joined(separator: "\n") + "\n\n"
            }
        }
        return result + "## Transcript\n\n" + transcript
    }
}


extension MeetingRecord {
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration, status, summarizeOnStop, liveTranscription
        case includesMicrophone, includesSystemAudio, settings, segments, summary
        case recoveryNotice, lastError, microphoneLabel, systemLabel, userNotes, summaryNeedsConfirmation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        settings = try values.decode(AppSettings.self, forKey: .settings)
        duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        status = try values.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .saved
        summarizeOnStop = try values.decodeIfPresent(Bool.self, forKey: .summarizeOnStop) ?? true
        liveTranscription = try values.decodeIfPresent(Bool.self, forKey: .liveTranscription)
        includesMicrophone = try values.decodeIfPresent(Bool.self, forKey: .includesMicrophone) ?? true
        includesSystemAudio = try values.decodeIfPresent(Bool.self, forKey: .includesSystemAudio) ?? true
        segments = try values.decodeIfPresent([MeetingSegment].self, forKey: .segments) ?? []
        summary = try values.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        recoveryNotice = try values.decodeIfPresent(String.self, forKey: .recoveryNotice)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        microphoneLabel = try values.decodeIfPresent(String.self, forKey: .microphoneLabel) ?? "Microphone"
        systemLabel = try values.decodeIfPresent(String.self, forKey: .systemLabel) ?? "System audio"
        userNotes = try values.decodeIfPresent(String.self, forKey: .userNotes)
        summaryNeedsConfirmation = try values.decodeIfPresent(Bool.self, forKey: .summaryNeedsConfirmation)
    }
}

enum MeetingError: LocalizedError {
    case noSource, noAudio, invalidSummary, unavailableDisplay
    var errorDescription: String? {
        switch self {
        case .noSource: return "Choose microphone, system audio, or both."
        case .noAudio: return "No readable audio was found. Check the selected sources and permissions."
        case .invalidSummary: return "The language model didn’t return a summary OpenScribe could read. Your transcript is safe; try again, or pick a different model in Settings → AI → API & Models."
        case .unavailableDisplay: return "System audio capture needs an available display and Screen & System Audio Recording access."
        }
    }
}
