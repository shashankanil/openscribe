import AVFoundation
import Foundation

struct DictationJob: Codable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var settings: AppSettings
    var sourceApplication: String?
    var sourceBundleIdentifier: String?
    var transcripts: [String: String] = [:]
}

@MainActor
final class DictationRecoveryStore {
    let root: URL
    private(set) var jobs: [DictationJob] = []
    private(set) var error: String?

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperFlow/DictationRecovery")
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            for directory in try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
                do {
                    let job = try JSONDecoder().decode(DictationJob.self, from: Data(contentsOf: directory.appendingPathComponent("job.json")))
                    if job.id.uuidString == directory.lastPathComponent { jobs.append(job) }
                } catch { self.error = "An interrupted recording could not be loaded. Its files were preserved." }
            }
            jobs.sort { $0.createdAt < $1.createdAt }
        } catch { self.error = error.localizedDescription }
    }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    func audioDirectory(_ id: UUID) -> URL { directory(id).appendingPathComponent("audio") }
    func save(_ job: DictationJob) throws {
        try FileManager.default.createDirectory(at: directory(job.id), withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: directory(job.id).appendingPathComponent("job.json"), options: .atomic)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
        else { jobs.append(job) }
    }
    func remove(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory(id))
        jobs.removeAll { $0.id == id }
    }
    func completedAudio(_ id: UUID, excluding: Set<String>) throws -> [URL] {
        let base = audioDirectory(id).standardizedFileURL.resolvingSymlinksInPath()
        return try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).filter { url in
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(base.path + "/"), canonical.pathExtension == "wav", !excluding.contains(url.lastPathComponent),
                  let data = try? Data(contentsOf: url.appendingPathExtension("json")),
                  let descriptor = try? JSONDecoder().decode(AudioChunkDescriptor.self, from: data) else { return false }
            return descriptor.duration > 0
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func recording(_ id: UUID) throws -> RecordedAudio {
        let base = audioDirectory(id).standardizedFileURL.resolvingSymlinksInPath()
        let files = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter { url in
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                return canonical.path.hasPrefix(base.path + "/") && canonical.pathExtension == "wav"
                    && ((try? AVAudioFile(forReading: canonical).length) ?? 0) > 0
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw RecorderError.emptyRecording }
        let duration = files.reduce(0.0) { total, url in
            guard let file = try? AVAudioFile(forReading: url) else { return total }
            return total + Double(file.length) / file.processingFormat.sampleRate
        }
        return RecordedAudio(chunkURLs: files, directoryURL: base, duration: duration)
    }
}
