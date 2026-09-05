import AVFoundation
import CoreMedia
import ScreenCaptureKit

@MainActor
final class SystemAudioRecorder: NSObject, SCStreamDelegate {
    private var stream: SCStream?
    private var receiver: SystemAudioReceiver?
    private let queue = DispatchQueue(label: "OpenScribe.meeting.system-audio")
    var onFailure: ((Error) -> Void)?

    func start(directory: URL, timelineOrigin: TimeInterval, liveSink: LiveAudioSink? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first else { throw MeetingError.unavailableDisplay }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // No screen output is registered or stored. ScreenCaptureKit still requires a display filter.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let receiver = SystemAudioReceiver(directory: directory, origin: timelineOrigin, liveSink: liveSink)
        receiver.onFailure = { [weak self] error in
            Task { @MainActor in self?.onFailure?(error) }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: queue)
        self.receiver = receiver
        self.stream = stream
        do { try await stream.startCapture() }
        catch {
            self.stream = nil
            self.receiver = nil
            throw error
        }
    }

    func stop() async throws {
        guard let stream else { return }
        self.stream = nil
        var stopError: Error?
        do { try await stream.stopCapture() } catch { stopError = error }
        let receiver = self.receiver
        self.receiver = nil
        let writeError = queue.sync { receiver?.finish() }
        if let stopError { throw stopError }
        if writeError == true { throw RecorderError.audioWriteFailed }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard self?.stream === stream else { return }
            self?.onFailure?(error)
        }
    }
}

final class SystemAudioReceiver: NSObject, SCStreamOutput {
    private let store = AudioChunkStore()
    private let directory: URL
    private let origin: TimeInterval
    private var started = false
    private var failed = false
    var onFailure: ((Error) -> Void)?

    init(directory: URL, origin: TimeInterval, liveSink: LiveAudioSink? = nil) {
        self.directory = directory
        self.origin = origin
        super.init()
        store.liveSink = liveSink
        store.onError = { [weak self] error in self?.failed = true; self?.onFailure?(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        append(sampleBuffer)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, !failed,
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let list = AudioBufferList.allocate(maximumBuffers: Int(format.channelCount))
        defer { free(list.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
            bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
            bufferListSize: MemoryLayout<AudioBufferList>.size + max(0, Int(format.channelCount) - 1) * MemoryLayout<AudioBuffer>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil) else {
            failed = true
            onFailure?(RecorderError.audioWriteFailed)
            return
        }
        do {
            if !started { try store.begin(format: format, directoryURL: directory); started = true }
            store.append(buffer, at: sampleBuffer.presentationTimeStamp.seconds - origin)
        } catch { failed = true; onFailure?(error) }
        withExtendedLifetime(block) {}
    }

    func finish() -> Bool {
        guard started else { return failed }
        return store.finish().hadWriteError || failed
    }
}
