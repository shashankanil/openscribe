import AppKit

/// Short, softly enveloped cues, independent of the user's system alert sound.
@MainActor
final class CaptureSounds {
    enum Cue { case start, stop }
    private let startSound = CaptureSounds.makeSound(frequency: 740, ending: 940)
    private let stopSound = CaptureSounds.makeSound(frequency: 740, ending: 540)

    func play(_ cue: Cue) {
        startSound?.stop()
        stopSound?.stop()
        let sound = cue == .start ? startSound : stopSound
        sound?.volume = 0.18
        sound?.play()
    }

    private static func makeSound(frequency: Double, ending: Double) -> NSSound? {
        let rate = 44_100
        let count = 3_528 // 80 ms
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        word(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8)
        word(UInt32(count * 2))
        var phase = 0.0
        for index in 0..<count {
            let progress = Double(index) / Double(count - 1)
            phase += 2 * .pi * (frequency + (ending - frequency) * progress) / Double(rate)
            let envelope = pow(sin(.pi * progress), 2)
            word(Int16(sin(phase) * envelope * 12_000))
        }
        return NSSound(data: data)
    }
}
