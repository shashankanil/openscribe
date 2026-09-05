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

    func validated(segmentIDs: Set<String>) throws -> MeetingSummary {
        for point in overview + decisions + actions {
            guard !point.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !point.sources.isEmpty, point.sources.allSatisfy(segmentIDs.contains) else {
                throw MeetingError.invalidSummary
            }
        }
        return self
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

    var transcript: String {
        segments.sorted { $0.start < $1.start }.map {
            "[\($0.timestamp)] \($0.track == "microphone" ? microphoneLabel : systemLabel)\n\($0.text)"
        }.joined(separator: "\n\n")
    }
    var markdown: String {
        var result = "# \(title)\n\n\(createdAt.formatted())\n\n"
        if let summary {
            for (heading, points) in [("Summary", summary.overview), ("Decisions", summary.decisions), ("Action items", summary.actions)] {
                result += "## \(heading)\n\n"
                result += points.isEmpty ? "None identified.\n\n" : points.map { point in
                    let stamps = point.sources.compactMap { id in segments.first { $0.id == id }?.timestamp }.joined(separator: ", ")
                    return "- \(point.text) [\(stamps)]"
                }.joined(separator: "\n") + "\n\n"
            }
        }
        return result + "## Transcript\n\n" + transcript
    }
}

enum MeetingError: LocalizedError {
    case noSource, noAudio, invalidSummary, unavailableDisplay
    var errorDescription: String? {
        switch self {
        case .noSource: return "Choose microphone, system audio, or both."
        case .noAudio: return "No readable audio was found. Check the selected sources and permissions."
        case .invalidSummary: return "The summary contained missing or invalid transcript references. Your transcript is safe; try summarizing again."
        case .unavailableDisplay: return "System audio capture needs an available display and Screen & System Audio Recording access."
        }
    }
}
