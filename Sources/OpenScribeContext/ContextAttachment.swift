import Foundation

/// A file that belongs to a document: a screenshot in a day note, or a meeting's recording.
/// Attachments are listed beside documents rather than inside them, so a document's text (and its
/// sync fingerprint) doesn't change when a file is re-encoded.
public struct ContextAttachment: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case screenshot
        case recording
    }

    /// One audio file of a recording, placed on the meeting timeline.
    public struct Part: Equatable, Sendable {
        public var url: URL
        /// "microphone" or "system"; nil for screenshots.
        public var track: String?
        /// Seconds from the start of the meeting.
        public var start: Double

        public init(url: URL, track: String?, start: Double) {
            self.url = url
            self.track = track
            self.start = start
        }
    }

    /// Unique within its document: the capture id for screenshots, "recording" for meetings.
    public var id: String
    public var documentID: String
    public var kind: Kind
    public var createdAt: Date
    public var caption: String
    public var durationSeconds: Double
    public var parts: [Part]

    public init(id: String, documentID: String, kind: Kind, createdAt: Date, caption: String = "",
                durationSeconds: Double = 0, parts: [Part]) {
        self.id = id
        self.documentID = documentID
        self.kind = kind
        self.createdAt = createdAt
        self.caption = caption
        self.durationSeconds = durationSeconds
        self.parts = parts
    }

    public static let recordingID = "recording"

    /// Changes whenever any underlying file changes (path, size or modification date).
    /// Read fresh each time: `URL.resourceValues` caches per URL instance and would miss edits.
    public var sourceStamp: String {
        parts.map { part -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: part.url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(part.url.lastPathComponent):\(size):\(Int(modified * 1000))"
        }.joined(separator: "|")
    }

    public var totalBytes: Int {
        parts.reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.url.path))?[.size] as? NSNumber)?.intValue ?? 0) }
    }

    /// Image MIME type for a screenshot file on disk.
    public var localContentType: String {
        switch parts.first?.url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "wav": return "audio/wav"
        default: return "image/png"
        }
    }
}

enum AttachmentScanner {
    /// Screenshots referenced by a day note's visible captures.
    static func screenshots(in note: StoredNote, documentID: String, root: URL) -> [ContextAttachment] {
        let folder = root.appendingPathComponent("Attachments", isDirectory: true).standardizedFileURL
        return (note.captures ?? []).compactMap { capture in
            guard capture.isVisible, capture.entryKind == "screenshot",
                  let name = capture.attachment?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let url = folder.appendingPathComponent(name).standardizedFileURL
            // Never follow a reference out of the Attachments folder.
            guard url.path.hasPrefix(folder.path + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
            let caption = [capture.sourceApplication, capture.text.isEmpty ? nil : capture.text]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " · ")
            return ContextAttachment(id: capture.id, documentID: documentID, kind: .screenshot,
                                     createdAt: capture.createdAt ?? note.createdAt ?? Date(), caption: caption,
                                     parts: [.init(url: url, track: nil, start: 0)])
        }
    }

    /// Statuses whose audio is complete. A meeting that's still recording is left alone.
    static let finishedStatuses: Set<String> = ["saved", "transcribing", "summarizing", "ready", "interrupted", "failed"]

    private struct ChunkInfo: Decodable { var start: Double? }

    /// A meeting's audio chunks: `Meetings/<id>/<session>/<track>/chunk-N.wav`, placed by their sidecar start time.
    static func recording(meetingDirectory: URL, documentID: String, status: String, title: String,
                          createdAt: Date, duration: Double) -> ContextAttachment? {
        guard finishedStatuses.contains(status) else { return nil }
        let fm = FileManager.default
        var parts: [ContextAttachment.Part] = []
        let sessions = (try? fm.contentsOfDirectory(at: meetingDirectory, includingPropertiesForKeys: nil)) ?? []
        for session in sessions {
            for track in ["microphone", "system"] {
                let folder = session.appendingPathComponent(track, isDirectory: true)
                let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.pathExtension.lowercased() == "wav" {
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size > 44 else { continue } // Header only: nothing recorded.
                    let info = (try? Data(contentsOf: file.appendingPathExtension("json")))
                        .flatMap { try? JSONDecoder().decode(ChunkInfo.self, from: $0) }
                    parts.append(.init(url: file, track: track, start: max(0, info?.start ?? 0)))
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        parts.sort { $0.start == $1.start ? $0.url.path < $1.url.path : $0.start < $1.start }
        return ContextAttachment(id: ContextAttachment.recordingID, documentID: documentID, kind: .recording,
                                 createdAt: createdAt, caption: title, durationSeconds: duration, parts: parts)
    }
}
