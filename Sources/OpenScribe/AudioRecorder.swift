import AVFoundation
import AudioToolbox
import Combine
import Foundation

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var inputLevels = Array(repeating: Float(0.04), count: 11)

    private let engine = AVAudioEngine()
    private let chunkStore = AudioChunkStore()
    private var startedAt: Date?
    private var tapInstalled = false
    private var preservesFiles = false
    var onInterruption: ((Error) -> Void)?
    private var configurationObserver: NSObjectProtocol?

    var duration: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    init() {
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, !self.engine.isRunning else { return }
                self.onInterruption?(RecorderError.noInputDevice)
            }
        }
        chunkStore.onError = { [weak self] error in
            Task { @MainActor in self?.onInterruption?(error) }
        }
        chunkStore.onLevel = { [weak self] level in
            DispatchQueue.main.async { [weak self] in
                self?.receiveMeterLevel(level)
            }
        }
    }

    func start(directoryURL: URL? = nil, timelineOrigin: TimeInterval? = nil, deviceUID: String = "", liveSink: LiveAudioSink? = nil) async throws {
        guard !isRecording else { return }
        let granted = await requestPermission()
        try Task.checkCancellation()
        guard granted else { throw RecorderError.microphonePermissionDenied }

        preservesFiles = directoryURL != nil
        let input = engine.inputNode
        do {
            let chosenID = deviceUID.isEmpty ? MicrophoneDevice.defaultDeviceID() : MicrophoneDevice.available().first(where: { $0.id == deviceUID })?.deviceID
            guard var id = chosenID, let unit = input.audioUnit else { throw RecorderError.noInputDevice }
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &id, UInt32(MemoryLayout.size(ofValue: id))) == noErr else { throw RecorderError.noInputDevice }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        let directory = directoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("openscribe-recording-\(UUID().uuidString)", isDirectory: true)
        chunkStore.liveSink = liveSink
        try chunkStore.begin(format: format, directoryURL: directory)
        inputLevel = 0
        inputLevels = Array(repeating: 0.04, count: inputLevels.count)
        isRecording = true
        startedAt = Date()

        do {
            let state = chunkStore
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
                state.updateMeter(Self.level(from: buffer))
                let timestamp = timelineOrigin.map { AVAudioTime.seconds(forHostTime: time.hostTime) - $0 }
                state.append(buffer, at: timestamp)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            isRecording = false
            chunkStore.cancel()
            stopEngine()
            startedAt = nil
            throw error
        }
    }

    func stop() throws -> RecordedAudio {
        guard isRecording else { throw RecorderError.notRecording }
        let capturedDuration = duration
        isRecording = false
        let files = chunkStore.finish()
        stopEngine()
        inputLevel = 0
        inputLevels = Array(repeating: 0.04, count: inputLevels.count)
        startedAt = nil

        if files.hadWriteError {
            if !preservesFiles { try? FileManager.default.removeItem(at: files.directoryURL) }
            throw RecorderError.audioWriteFailed
        }
        guard !files.chunkURLs.isEmpty else {
            if !preservesFiles { try? FileManager.default.removeItem(at: files.directoryURL) }
            throw RecorderError.emptyRecording
        }
        return RecordedAudio(
            chunkURLs: files.chunkURLs,
            directoryURL: files.directoryURL,
            duration: capturedDuration
        )
    }

    func cancel() {
        isRecording = false
        chunkStore.cancel()
        stopEngine()
        inputLevel = 0
        inputLevels = Array(repeating: 0.04, count: inputLevels.count)
        startedAt = nil
    }

    private func stopEngine() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.reset()
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

    deinit { if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) } }

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


enum RecorderError: LocalizedError {
    case microphonePermissionDenied
    case noInputDevice
    case notRecording
    case emptyRecording
    case audioWriteFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "Microphone access is required for dictation."
        case .noInputDevice: return "No microphone input is available."
        case .notRecording: return "There is no active recording."
        case .emptyRecording: return "The recording did not contain audio."
        case .audioWriteFailed: return "OpenScribe could not store the recording."
        }
    }
}
