import AVFoundation
import Combine
import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []
    @Published private(set) var storageError: String?
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow/Meetings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            for directory in try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
                do {
                    var record = try JSONDecoder().decode(MeetingRecord.self, from: Data(contentsOf: directory.appendingPathComponent("meeting.json")))
                    guard record.id.uuidString == directory.lastPathComponent else { continue }
                    if [.recording, .paused, .transcribing, .summarizing].contains(record.status) {
                        record.status = .interrupted
                        record.lastError = "Interrupted session. Saved audio and completed transcript sections are available for recovery."
                    }
                    meetings.append(record)
                } catch { storageError = "A meeting could not be loaded. Its files have been preserved: \(error.localizedDescription)" }
            }
            meetings.sort { $0.createdAt > $1.createdAt }
        } catch { storageError = error.localizedDescription }
    }

    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func record(_ id: UUID) -> MeetingRecord? { meetings.first { $0.id == id } }

    func save(_ record: MeetingRecord) throws {
        let directory = directory(for: record.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            try data.write(to: directory.appendingPathComponent("meeting.json"), options: .atomic)
            if let index = meetings.firstIndex(where: { $0.id == record.id }) { meetings[index] = record }
            else { meetings.insert(record, at: 0) }
            storageError = nil
        } catch {
            storageError = "Meeting changes could not be saved: \(error.localizedDescription)"
            throw error
        }
    }

    func audioURL(meetingID: UUID, relativePath: String) -> URL? {
        let base = directory(for: meetingID).standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/"), url.pathExtension == "wav" else { return nil }
        return url
    }

    func audioChunks(for id: UUID) throws -> [MeetingSegment] { try audioInventory(for: id).chunks }

    func audioInventory(for id: UUID, finalizedOnly: Bool = false, excluding: Set<String> = []) throws -> (chunks: [MeetingSegment], unreadable: Int) {
        let base = directory(for: id).standardizedFileURL.resolvingSymlinksInPath()
        guard let iterator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return ([], 0) }
        var unreadable = 0
        var chunks: [MeetingSegment] = []
        for case let url as URL in iterator where url.pathExtension == "wav" {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(base.path + "/") else { continue }
            let relative = String(canonical.path.dropFirst(base.path.count + 1))
            if excluding.contains(relative) { continue }
            let metadata = try? JSONDecoder().decode(AudioChunkDescriptor.self, from: Data(contentsOf: url.appendingPathExtension("json")))
            if finalizedOnly && (metadata?.duration ?? 0) <= 0 { continue }
            guard let safeURL = audioURL(meetingID: id, relativePath: relative) else { continue }
            // A crash can leave the final open WAV unreadable; retain it and recover the closed chunks.
            guard let audio = try? AVAudioFile(forReading: safeURL), audio.length > 0 else { unreadable += 1; continue }
            let parts = relative.split(separator: "/")
            guard parts.count == 3, ["microphone", "system"].contains(String(parts[1])) else { continue }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            chunks.append(MeetingSegment(id: relative, track: String(parts[1]), start: metadata?.start ?? 0, duration: duration, text: ""))
        }
        return (chunks.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }, unreadable)
    }

    func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory(for: id))
        meetings.removeAll { $0.id == id }
    }
}
