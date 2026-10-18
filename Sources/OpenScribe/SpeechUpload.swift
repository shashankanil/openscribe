import AVFoundation
import Foundation

/// Converts a recording to 16 kHz, 16-bit mono WAV before upload. Speech models resample to this anyway,
/// so accuracy is unchanged while the upload shrinks about sixfold.
enum SpeechUpload {
    static let sampleRate = 16_000.0

    /// A temporary compact copy, or nil when the file is already compact or can't be converted (the original is sent instead).
    static func compact(_ url: URL) -> URL? {
        guard let input = try? AVAudioFile(forReading: url) else { return nil }
        let source = input.processingFormat
        let fileFormat = input.fileFormat
        if fileFormat.sampleRate <= sampleRate, fileFormat.channelCount == 1, fileFormat.commonFormat == .pcmFormatInt16 { return nil }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { return nil }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("openscribe-upload-\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: output, settings: target.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let inputCapacity: AVAudioFrameCount = 16_384
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inputCapacity),
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: target,
                                                   frameCapacity: AVAudioFrameCount(Double(inputCapacity) * sampleRate / source.sampleRate) + 1024)
            else { return nil }
            var finished = false
            while true {
                var error: NSError?
                let status = converter.convert(to: outBuffer, error: &error) { _, state in
                    if finished { state.pointee = .endOfStream; return nil }
                    do {
                        try input.read(into: inBuffer, frameCount: inputCapacity)
                    } catch { finished = true; state.pointee = .endOfStream; return nil }
                    if inBuffer.frameLength == 0 { finished = true; state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData
                    return inBuffer
                }
                if status == .error || error != nil { throw error ?? CocoaError(.fileWriteUnknown) }
                if outBuffer.frameLength > 0 { try file.write(from: outBuffer) }
                if status == .endOfStream { break }
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
    }
}
