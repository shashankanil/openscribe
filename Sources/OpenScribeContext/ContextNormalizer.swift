import Foundation

/// Converts stored app records into normalized `ContextDocument`s.
enum ContextNormalizer {
    struct NormalizedNote {
        var document: ContextDocument
        var searchExtra: String
    }

    // MARK: Notes

    static func document(for note: StoredNote, fallbackDate: Date) -> NormalizedNote? {
        let createdAt = note.createdAt ?? note.captures?.compactMap(\.createdAt).min() ?? fallbackDate
        let updatedAt = max(note.lastCapturedAt ?? createdAt, createdAt)
        var extras: [String] = []
        let body: String
        if let captures = note.captures, note.editedText == nil {
            body = timeline(captures, extras: &extras)
        } else {
            body = note.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            for capture in note.captures ?? [] where capture.isVisible {
                if let recognized = capture.recognizedText, !recognized.isEmpty { extras.append(recognized) }
            }
        }
        let title = note.displayTitle
        if body.isEmpty && title == "Untitled note" && extras.isEmpty { return nil }
        if let app = note.sourceApplication, !app.isEmpty { extras.append(app) }
        let document = ContextDocument(
            id: note.id,
            kind: .note,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            body: body,
            durationSeconds: note.duration,
            tags: note.tags
        )
        return NormalizedNote(document: document, searchExtra: extras.joined(separator: "\n"))
    }

    /// A day note rendered as a markdown timeline of its visible entries, oldest first.
    private static func timeline(_ captures: [StoredCapture], extras: inout [String]) -> String {
        let visible = captures.filter(\.isVisible)
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        var blocks: [String] = []
        for capture in visible {
            let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var heading = capture.createdAt.map(timeLabel) ?? "Entry"
            if let app = capture.sourceApplication?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
                heading += " · \(app)"
                extras.append(app)
            }
            var lines: [String] = []
            switch capture.entryKind {
            case "screenshot":
                heading += " · Screenshot"
                if let recognized = capture.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines), !recognized.isEmpty {
                    extras.append(recognized)
                    let excerpt = recognized.count > 600 ? String(recognized.prefix(600)) + "…" : recognized
                    lines.append("> Text in screenshot: " + excerpt.split(whereSeparator: \.isNewline).joined(separator: " "))
                }
            case "meeting":
                heading += " · Meeting"
                let title = capture.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = title.isEmpty ? "Meeting" : title
                lines.append(capture.meetingID.map { "\(name) (meeting id: \($0))" } ?? name)
            case "text":
                heading += " · Written"
            default:
                break
            }
            if !text.isEmpty { lines.append(text) }
            if lines.isEmpty { continue }
            blocks.append("### \(heading)\n\n" + lines.joined(separator: "\n\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: Meetings

    static func document(for meeting: StoredMeeting, id: String, modified: Date) -> ContextDocument {
        let createdAt = meeting.createdAt ?? modified
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = self.transcript(meeting)
        return ContextDocument(
            id: id,
            kind: .meeting,
            title: title.isEmpty ? "Untitled meeting" : title,
            createdAt: createdAt,
            updatedAt: max(createdAt, modified),
            body: meeting.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            summary: summaryMarkdown(meeting),
            transcript: transcript.isEmpty ? nil : transcript,
            actionItems: (meeting.summary?.actions ?? []).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            durationSeconds: meeting.duration,
            tags: []
        )
    }

    /// Mirrors `MeetingRecord.markdown`'s summary sections.
    static func summaryMarkdown(_ meeting: StoredMeeting) -> String? {
        guard let summary = meeting.summary else { return nil }
        let stamps = Dictionary(meeting.segments.map { ($0.id, timestamp($0.start)) }, uniquingKeysWith: { first, _ in first })
        var sections: [String] = []
        for (heading, points) in [("Summary", summary.overview), ("Decisions", summary.decisions), ("Action items", summary.actions)] {
            let lines = points.compactMap { point -> String? in
                let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let refs = point.sources.compactMap { stamps[$0] }.joined(separator: ", ")
                return refs.isEmpty ? "- \(text)" : "- \(text) [\(refs)]"
            }
            sections.append("## \(heading)\n\n" + (lines.isEmpty ? "None identified." : lines.joined(separator: "\n")))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Mirrors `MeetingRecord.transcript`.
    static func transcript(_ meeting: StoredMeeting) -> String {
        passages(meeting.segments).map {
            "[\(timestamp($0.start))] \($0.track == "microphone" ? meeting.microphoneLabel : meeting.systemLabel)\n\($0.text)"
        }.joined(separator: "\n\n")
    }

    struct Passage: Equatable {
        var id: String
        var start: Double
        var track: String
        var text: String
    }

    /// Mirrors `MeetingTranscript.passages`: merge each track's contiguous segments
    /// (gap ≤ 3 s, passage shorter than 90 s), then order by start time.
    static func passages(_ segments: [StoredSegment]) -> [Passage] {
        let sorted = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        var passages: [Passage] = []
        var ends: [String: Double] = [:]
        var lastByTrack: [String: Int] = [:]
        for segment in sorted {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = lastByTrack[segment.track], let end = ends[segment.track],
               segment.start - end <= 3, segment.start - passages[index].start < 90 {
                passages[index].text += " " + text
            } else {
                lastByTrack[segment.track] = passages.count
                passages.append(Passage(id: segment.id, start: segment.start, track: segment.track, text: text))
            }
            ends[segment.track] = segment.start + segment.duration
        }
        return passages.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    /// Mirrors `MeetingSegment.timestamp`.
    static func timestamp(_ seconds: Double) -> String {
        let seconds = seconds.isFinite ? Int(min(max(0, seconds), 1e9)) : 0
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
