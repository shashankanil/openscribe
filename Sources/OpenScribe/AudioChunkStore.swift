import AVFoundation
import Foundation

struct RecordedAudio {
    let chunkURLs: [URL]
    let directoryURL: URL
    let duration: TimeInterval

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

struct AudioCaptureFiles {
    let chunkURLs: [URL]
    let directoryURL: URL
    let hadWriteError: Bool
}

final class AudioChunkStore: @unchecked Sendable {
    private let lock = NSLock()
    private let chunkDuration: TimeInterval

    private var directoryURL: URL?
    private var formatSettings: [String: Any] = [:]
    private var chunkFrameLimit: AVAudioFramePosition = 1
    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var currentFrameCount: AVAudioFramePosition = 0
    private var nextChunkIndex = 0
    private var chunkURLs: [URL] = []
    private var isActive = false
    private var hadWriteError = false
    private var lastMeterDelivery = Date.distantPast

    var onLevel: ((Float) -> Void)?

    init(chunkDuration: TimeInterval = 15) {
        self.chunkDuration = max(1, chunkDuration)
    }

    func begin(format: AVAudioFormat, directoryURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        self.directoryURL = directoryURL
        formatSettings = format.settings
        chunkFrameLimit = AVAudioFramePosition(max(1, Int64(format.sampleRate * chunkDuration)))
        currentFile = nil
        currentURL = nil
        currentFrameCount = 0
        nextChunkIndex = 0
        chunkURLs = []
        hadWriteError = false
        isActive = true
        lastMeterDelivery = .distantPast
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard isActive else { return }
        if currentFile == nil {
            do {
                try openNextChunkLocked()
            } catch {
                hadWriteError = true
                isActive = false
                NSLog("OpenScribe audio chunk creation error: %@", error.localizedDescription)
                return
            }
        }

        guard let currentFile else { return }
        do {
            try currentFile.write(from: buffer)
            currentFrameCount += AVAudioFramePosition(buffer.frameLength)
            if currentFrameCount >= chunkFrameLimit {
                closeCurrentChunkLocked()
            }
        } catch {
            hadWriteError = true
            isActive = false
            NSLog("OpenScribe audio write error: %@", error.localizedDescription)
        }
    }

    func finish() -> AudioCaptureFiles {
        lock.lock()
        defer { lock.unlock() }

        isActive = false
        closeCurrentChunkLocked()
        return AudioCaptureFiles(
            chunkURLs: chunkURLs,
            directoryURL: directoryURL ?? FileManager.default.temporaryDirectory,
            hadWriteError: hadWriteError
        )
    }

    func cancel() {
        lock.lock()
        isActive = false
        closeCurrentChunkLocked()
        let directory = directoryURL
        resetLocked()
        lock.unlock()

        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func updateMeter(_ level: Float) {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        guard now.timeIntervalSince(lastMeterDelivery) >= 0.03 else { return }
        lastMeterDelivery = now
        onLevel?(level)
    }

    private func openNextChunkLocked() throws {
        guard let directoryURL else { return }
        let filename = String(format: "chunk-%05d.wav", nextChunkIndex)
        let url = directoryURL.appendingPathComponent(filename)
        currentFile = try AVAudioFile(forWriting: url, settings: formatSettings)
        currentURL = url
        currentFrameCount = 0
        nextChunkIndex += 1
    }

    private func closeCurrentChunkLocked() {
        if let currentURL {
            if currentFrameCount > 0 {
                chunkURLs.append(currentURL)
            } else {
                try? FileManager.default.removeItem(at: currentURL)
            }
        }
        currentFile = nil
        currentURL = nil
        currentFrameCount = 0
    }

    private func resetLocked() {
        directoryURL = nil
        formatSettings = [:]
        chunkFrameLimit = 1
        currentFile = nil
        currentURL = nil
        currentFrameCount = 0
        nextChunkIndex = 0
        chunkURLs = []
        hadWriteError = false
        isActive = false
        lastMeterDelivery = .distantPast
    }
}
