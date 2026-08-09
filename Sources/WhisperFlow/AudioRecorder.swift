import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var inputLevels = Array(repeating: Float(0.04), count: 11)

    private let engine = AVAudioEngine()
    private let captureState = CaptureState()
    private var fileURL: URL?
    private var startedAt: Date?
    private var tapInstalled = false
    private var prepareTask: Task<Void, Error>?

    var duration: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    init() {
        captureState.onLevel = { [weak self] level in
            DispatchQueue.main.async { [weak self] in
                self?.receiveMeterLevel(level)
            }
        }
    }

    func prepare() async throws {
        if engine.isRunning && tapInstalled {
            return
        }
        if let prepareTask {
            try await prepareTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.configureAndStartEngine()
        }
        prepareTask = task
        do {
            try await task.value
            prepareTask = nil
        } catch {
            prepareTask = nil
            throw error
        }
    }

    func start() async throws {
        guard !isRecording else { return }
        try await prepare()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperflow-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        fileURL = url
        captureState.setFile(file)
        startedAt = Date()
        inputLevel = 0
        inputLevels = Array(repeating: 0.04, count: inputLevels.count)
        isRecording = true
    }

    func stop() throws -> (audio: Data, duration: TimeInterval) {
        guard isRecording else { throw RecorderError.notRecording }
        let capturedDuration = duration
        isRecording = false
        captureState.setFile(nil)
        inputLevel = 0
        inputLevels = Array(repeating: 0.04, count: inputLevels.count)

        guard let fileURL else { throw RecorderError.emptyRecording }
        self.fileURL = nil
        let data = try Data(contentsOf: fileURL)
        try? FileManager.default.removeItem(at: fileURL)
        guard !data.isEmpty else { throw RecorderError.emptyRecording }
        return (data, capturedDuration)
    }

    func cancel() {
        isRecording = false
        captureState.setFile(nil)
        inputLevel = 0
        inputLevels = Array(repeating: 0.04, count: inputLevels.count)
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }

    private func configureAndStartEngine() async throws {
        let granted = await requestPermission()
        guard granted else { throw RecorderError.microphonePermissionDenied }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        if !tapInstalled {
            let state = captureState
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                state.updateMeter(Self.level(from: buffer))
                state.write(buffer)
            }
            tapInstalled = true
        }

        engine.prepare()
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    private func receiveMeterLevel(_ level: Float) {
        guard isRecording else {
            if inputLevel != 0 {
                inputLevel = 0
                inputLevels = Array(repeating: 0.04, count: inputLevels.count)
            }
            return
        }

        let smoothed = (inputLevel * 0.35) + (level * 0.65)
        inputLevel = smoothed
        inputLevels = Array(inputLevels.dropFirst()) + [smoothed]
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return 0
        }

        let samples = channelData[0]
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = samples[index]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameCount))
        return min(1, max(0, (rms - 0.003) * 18))
    }

    private func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }
}

private final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var lastMeterDelivery = Date.distantPast
    var onLevel: ((Float) -> Void)?

    func setFile(_ file: AVAudioFile?) {
        lock.lock()
        self.file = file
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        do {
            try file.write(from: buffer)
        } catch {
            NSLog("WhisperFlow audio write error: %@", error.localizedDescription)
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
}

enum RecorderError: LocalizedError {
    case microphonePermissionDenied
    case noInputDevice
    case notRecording
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "Microphone access is required for dictation."
        case .noInputDevice: return "No microphone input is available."
        case .notRecording: return "There is no active recording."
        case .emptyRecording: return "The recording did not contain audio."
        }
    }
}
