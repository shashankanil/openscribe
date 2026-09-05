import AVFoundation
import Foundation

/// A socket follows each durable 15-second section. PCM leaves immediately; the WAV is
/// retained until its final transcript is checkpointed. A failed stream never becomes a partial success.
final class LiveAudioPipeline: @unchecked Sendable {
    private struct Section {
        let input: AsyncThrowingStream<Data, Error>.Continuation
        let task: Task<String, Error>
    }
    typealias Runner = @Sendable (StreamingCapability, String, AsyncThrowingStream<Data, Error>, @escaping @Sendable (String) -> Void) async throws -> String
    private let run: Runner
    private let lock = NSLock()
    private let capability: StreamingCapability
    private let apiKey: String
    private let onPartial: @Sendable (URL, String) -> Void
    private let onFallback: @Sendable () -> Void
    private var sections: [URL: Section] = [:]
    private var stopped = false

    init(capability: StreamingCapability, apiKey: String,
         run: @escaping Runner = { capability, key, audio, partial in
             try await RealtimeTranscription(capability: capability, apiKey: key, onPartial: partial).run(audio: audio)
         },
         onPartial: @escaping @Sendable (URL, String) -> Void = { _, _ in },
         onFallback: @escaping @Sendable () -> Void = {}) {
        self.run = run
        self.capability = capability
        self.apiKey = apiKey
        self.onPartial = onPartial
        self.onFallback = onFallback
    }

    func makeSink() -> LiveAudioSink { LiveAudioSink(pipeline: self, rate: capability.sampleRate) }

    fileprivate func append(_ data: Data, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        if sections[url] == nil {
            // Bound queued sections if the consumer or network stops making progress.
            guard sections.count < 8 else { disableLocked(); return }
            let channel = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(200))
            let capability = self.capability, key = apiKey, partial = onPartial, run = self.run
            let task = Task {
                return try await run(capability, key, channel.stream) { partial(url, $0) }
            }
            sections[url] = Section(input: channel.continuation, task: task)
        }
        if case .dropped = sections[url]?.input.yield(data) { disableLocked() }
    }

    fileprivate func close(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        sections[url]?.input.finish()
    }

    fileprivate func fail() { lock.lock(); defer { lock.unlock() }; disableLocked() }

    private func disableLocked() {
        guard !stopped else { return }
        stopped = true
        for section in sections.values { section.input.finish(throwing: URLError(.networkConnectionLost)); section.task.cancel() }
        onFallback()
    }

    private func section(for url: URL) -> Section? {
        lock.lock(); defer { lock.unlock() }
        return sections[url]
    }
    private func remove(_ url: URL) { lock.lock(); defer { lock.unlock() }; sections[url] = nil }

    /// nil means file transcription is required, including after stream failure.
    func result(for url: URL) async throws -> String? {
        guard let section = section(for: url) else { return nil }
        defer { remove(url) }
        do {
            let text = try await withTaskCancellationHandler { try await section.task.value }
                onCancel: { section.task.cancel() }
            try Task.checkCancellation()
            return text
        } catch {
            try Task.checkCancellation()
            fail()
            return nil
        }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        for section in sections.values { section.input.finish(); section.task.cancel() }
        sections.removeAll()
    }
    deinit { cancel() }
}

/// Accessed only under its AudioChunkStore's lock; never retains borrowed capture buffers.
final class LiveAudioSink {
    private let pipeline: LiveAudioPipeline
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var url: URL?

    init(pipeline: LiveAudioPipeline, rate: Double) {
        self.pipeline = pipeline
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
    }

    func append(_ buffer: AVAudioPCMBuffer, url: URL) {
        self.url = url
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: outputFormat) }
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate)) + 64) else { pipeline.fail(); return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil else { pipeline.fail(); return }
        if let pointer = output.int16ChannelData?.pointee {
            pending.append(Data(bytes: pointer, count: Int(output.frameLength) * 2))
        }
        let packetBytes = Int(outputFormat.sampleRate / 10) * 2 // 100 ms, bounded queue = 20 seconds.
        while pending.count >= packetBytes {
            pipeline.append(Data(pending.prefix(packetBytes)), url: url)
            pending.removeFirst(packetBytes)
        }
    }

    func close(_ url: URL) {
        // Flush the converter's delayed samples before ending this section.
        if let converter, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) {
            var error: NSError?
            repeat {
                output.frameLength = 0
                let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                if status == .error || error != nil { pipeline.fail(); break }
                if let pointer = output.int16ChannelData?.pointee, output.frameLength > 0 {
                    pending.append(Data(bytes: pointer, count: Int(output.frameLength) * 2))
                }
                if status == .endOfStream || output.frameLength == 0 { break }
            } while true
        }
        if !pending.isEmpty { pipeline.append(pending, url: url) }
        pipeline.close(url)
        pending.removeAll(keepingCapacity: true)
        converter = nil
        self.url = nil
    }
}
