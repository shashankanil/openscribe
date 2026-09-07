import Foundation

/// Presentation groups are independent of the durable upload boundaries.
/// Source audio remains addressable for citations and recovery.
struct MeetingTranscriptPassage: Identifiable, Equatable {
    let id: String
    let start: TimeInterval
    let track: String
    var text: String
    var segmentIDs: [String]
}

enum MeetingTranscript {
    static func passages(_ segments: [MeetingSegment], track: String? = nil) -> [MeetingTranscriptPassage] {
        let sorted = segments.filter { (track == nil || $0.track == track) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        // Combine each source's contiguous audio, even when the other source has matching upload times.
        var passages: [MeetingTranscriptPassage] = []
        var ends: [String: TimeInterval] = [:]
        var lastByTrack: [String: Int] = [:]
        for segment in sorted {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = lastByTrack[segment.track], let end = ends[segment.track],
               segment.start - end <= 3, segment.start - passages[index].start < 90 {
                passages[index].text += " " + text
                passages[index].segmentIDs.append(segment.id)
            } else {
                lastByTrack[segment.track] = passages.count
                passages.append(.init(id: segment.id, start: segment.start, track: segment.track, text: text, segmentIDs: [segment.id]))
            }
            ends[segment.track] = segment.start + segment.duration
        }
        return passages.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
