import AVFoundation
import CoreMedia
import XCTest
@testable import OpenScribe

final class SystemAudioTests: XCTestCase {
    func testSystemPCMBufferIsWrittenWithTimelineMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("system-audio-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let audio = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        audio.frameLength = 480
        for channel in 0..<2 { for frame in 0..<480 { audio.floatChannelData![channel][frame] = 0.15 } }
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                       presentationTimeStamp: CMTime(seconds: 5, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 480,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let sampleBuffer = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: audio.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(sampleBuffer), noErr)
        let receiver = SystemAudioReceiver(directory: directory, origin: 2)
        receiver.append(sampleBuffer)
        XCTAssertFalse(receiver.finish())
        let url = directory.appendingPathComponent("chunk-00000.wav")
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 480)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        let readback = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480))
        try file.read(into: readback)
        XCTAssertEqual(readback.floatChannelData![0][100], 0.15, accuracy: 0.001)
        XCTAssertEqual(readback.floatChannelData![1][100], 0.15, accuracy: 0.001)
        let meta = try JSONDecoder().decode(AudioChunkDescriptor.self, from: Data(contentsOf: url.appendingPathExtension("json")))
        XCTAssertEqual(meta.start, 3, accuracy: 0.001)
        XCTAssertEqual(meta.duration, 0.01, accuracy: 0.001)
    }
}
