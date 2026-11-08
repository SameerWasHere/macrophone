import AppKit

/// The wake word's chimes (Nov 7 2026, SameerOS's Chime, quieter and shorter): two soft notes
/// rising when the phrase is heard, falling when the words land, one low note when it's dropped.
/// Synthesized in code — a fundamental, a quiet octave, a fast attack and a bell's decay — so
/// there's no audio file. Played through NSSound: nothing about the output device changes.
@MainActor
enum Chime {
    private static let wakeSound = make([(783.99, 0), (1174.66, 0.07)])   // G5 → D6
    private static let landedSound = make([(1174.66, 0), (880.0, 0.07)])  // D6 → A5
    private static let cancelSound = make([(523.25, 0)], length: 0.22)    // C5

    static func wake(_ on: Bool) { if on { play(wakeSound) } }
    static func landed(_ on: Bool) { if on { play(landedSound) } }
    static func cancel(_ on: Bool) { if on { play(cancelSound) } }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }

    private static func make(_ notes: [(freq: Double, delay: Double)], length: Double = 0.26, volume: Float = 0.22) -> NSSound? {
        let rate = 44_100.0
        let total = (notes.map(\.delay).max() ?? 0) + length
        let count = Int(rate * total)
        var samples = [Double](repeating: 0, count: count)
        for note in notes {
            let start = Int(note.delay * rate)
            for i in start..<count {
                let t = Double(i - start) / rate
                let envelope = min(t / 0.005, 1) * exp(-t * 16)
                samples[i] += (sin(2 * .pi * note.freq * t) + 0.15 * sin(4 * .pi * note.freq * t)) * envelope
            }
        }
        let peak = samples.map(abs).max() ?? 1
        let pcm = samples.map { Int16(($0 / peak) * 0.55 * Double(Int16.max)) }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count * 2))
        pcm.forEach { append($0) }
        let sound = NSSound(data: data)
        sound?.volume = volume
        return sound
    }
}
