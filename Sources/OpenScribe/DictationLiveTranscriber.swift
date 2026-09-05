import Foundation

@MainActor
final class DictationLiveTranscriber {
    private let store: DictationRecoveryStore
    private let transcribe: (URL, AppSettings) async throws -> String
    private var task: Task<Void, Never>?
    private var running = false
    var onProgress: ((String, Int) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(store: DictationRecoveryStore, transcribe: @escaping (URL, AppSettings) async throws -> String) {
        self.store = store
        self.transcribe = transcribe
    }

    func start(_ id: UUID) {
        guard task == nil else { return }
        running = true
        task = Task { [weak self] in
            guard let self else { return }
            while running, !Task.isCancelled {
                do {
                    if try await !processNext(id) { try await Task.sleep(nanoseconds: 1_000_000_000) }
                } catch {
                    if !Task.isCancelled { onFailure?(error) }
                    return
                }
            }
        }
    }

    @discardableResult
    func processNext(_ id: UUID) async throws -> Bool {
        guard let job = store.jobs.first(where: { $0.id == id }),
              let file = try store.completedAudio(id, excluding: Set(job.transcripts.keys)).first else { return false }
        let text = try await transcribe(file, job.settings)
        try Task.checkCancellation()
        guard var latest = store.jobs.first(where: { $0.id == id }) else { return false }
        latest.transcripts[file.lastPathComponent] = text
        try store.save(latest)
        let assembled = latest.transcripts.keys.sorted().compactMap { latest.transcripts[$0] }.joined(separator: " ")
        onProgress?(assembled, latest.transcripts.count)
        return true
    }

    func finish() async { running = false; await task?.value; task = nil }
    func cancel() { running = false; task?.cancel() }
}
