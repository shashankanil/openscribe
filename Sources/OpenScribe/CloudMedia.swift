import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import OpenScribeContext
import UniformTypeIdentifiers

/// Prepares attachments for OpenScribe Cloud: screenshots become JPEGs no larger than 2048 px, and
/// a meeting's WAV chunks (microphone and system audio) are mixed into one small mono AAC file.
enum CloudMedia {
    struct Encoded {
        var url: URL
        var contentType: String
        var sha256: String
        var bytes: Int
    }

    enum EncodeError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case let .unreadable(detail): return detail }
        }
    }

    /// The server accepts up to 95 MB per file; 48 kbps speech fits about four hours.
    static let maximumUploadBytes = 95_000_000

    static func encode(_ attachment: ContextAttachment) async throws -> Encoded {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("openscribe-media-\(UUID().uuidString)")
            .appendingPathExtension(attachment.kind == .screenshot ? "jpg" : "m4a")
        do {
            switch attachment.kind {
            case .screenshot:
                guard let source = attachment.parts.first?.url else { throw EncodeError.unreadable("The screenshot file is missing.") }
                try jpeg(from: source, to: output)
            case .recording:
                try await mixdown(attachment.parts, to: output)
            }
            let bytes = (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Encoded(url: output, contentType: attachment.kind == .screenshot ? "image/jpeg" : "audio/mp4",
                           sha256: try sha256(of: output), bytes: bytes)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // MARK: Images

    static func jpeg(from source: URL, to output: URL, maxPixel: Int = 2048, quality: Double = 0.82) throws {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw EncodeError.unreadable("Couldn’t read \(source.lastPathComponent).")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EncodeError.unreadable("Couldn’t convert \(source.lastPathComponent).")
        }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EncodeError.unreadable("Couldn’t write the screenshot.") }
    }

    // MARK: Audio

    /// Lays each chunk on its track's timeline (silence fills gaps), then mixes both tracks to mono AAC.
    static func mixdown(_ parts: [ContextAttachment.Part], to output: URL) async throws {
        let composition = AVMutableComposition()
        let byTrack = Dictionary(grouping: parts) { $0.track ?? "microphone" }
        for (_, chunks) in byTrack.sorted(by: { $0.key < $1.key }) {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var end = CMTime.zero
            for chunk in chunks.sorted(by: { $0.start < $1.start }) {
                let asset = AVURLAsset(url: chunk.url)
                guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                      let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
                let start = CMTime(seconds: chunk.start, preferredTimescale: 48_000)
                if start > end {
                    track.insertEmptyTimeRange(CMTimeRange(start: end, end: start))
                    end = start
                }
                // Chunks never overlap in practice; if one does, it follows the previous one instead.
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: end)
                end = end + duration
            }
        }
        let tracks = composition.tracks(withMediaType: .audio).filter { !$0.segments.isEmpty }
        guard !tracks.isEmpty else { throw EncodeError.unreadable("The recording has no readable audio.") }

        let reader = try AVAssetReader(asset: composition)
        let mix = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 32_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(mix) else { throw EncodeError.unreadable("Couldn’t mix the recording.") }
        reader.add(mix)

        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 32_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EncodeError.unreadable("Couldn’t encode the recording.") }
        writer.add(input)

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? EncodeError.unreadable("Couldn’t start encoding the recording.")
        }
        writer.startSession(atSourceTime: .zero)
        while let buffer = mix.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard input.append(buffer) else { break }
        }
        input.markAsFinished()
        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? writer.error ?? EncodeError.unreadable("Encoding the recording failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? EncodeError.unreadable("Encoding the recording failed.")
        }
    }

    // MARK: Hashing

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
