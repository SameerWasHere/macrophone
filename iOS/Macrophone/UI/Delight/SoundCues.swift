import AudioToolbox
import Foundation

/// The app's few sounds (Delight, Nov 8 2026): soft, short, Mac-like — glass tinks for a landing,
/// a breath of air for a send, the same tinks falling for an undo, a plucked string for the Thread,
/// a small arpeggio for a milestone or a pairing. Matched to the haptics that already say each
/// thing (`Haptics`), never instead of them.
///
/// - **Synthesised here, no assets:** each is rendered once into Caches as a 16-bit WAV (a few
///   milliseconds of work, off the main thread) and played as a system sound.
/// - **System sounds on purpose:** they follow the Ring / Silent switch (silent = nothing), play
///   beside whatever the app's audio session is doing (the Mac's sound, a podcast) without taking
///   it over, and cost nothing to fire. Their loudness is baked into the waveforms (−13 dBFS at
///   the peak, quieter than a keyboard click).
/// - **Off-able:** Settings › Appearance › Sounds (`settings.sounds`, on unless turned off).
/// - **Never while the mic is open:** nothing listens to them (no "listening" sound — it would
///   land in the first syllable the recognizer hears; the haptic and the edge's glow say it).
enum SoundCues {
    enum Cue: String, CaseIterable {
        case landed, sent, undo, milestone, paired
        case pluck0, pluck1, pluck2, pluck3, pluck4
    }

    /// Settings › Appearance › Sounds.
    static let key = "settings.sounds"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// A string on the Thread, by where it was plucked: G major pentatonic, low on the left.
    static func pluck(at u: Double) -> Cue {
        let all: [Cue] = [.pluck0, .pluck1, .pluck2, .pluck3, .pluck4]
        return all[min(all.count - 1, max(0, Int(u * Double(all.count))))]
    }

    static func play(_ cue: Cue) {
        guard enabled else { return }
        queue.async {
            guard let id = soundID(cue) else { return }
            AudioServicesPlaySystemSound(id)
        }
    }

    /// Renders every cue ahead (a launch calls this a few seconds in), so the first play is instant.
    static func prepare() {
        guard enabled else { return }
        queue.async { for c in Cue.allCases { _ = soundID(c) } }
    }

    // MARK: Files

    private static let queue = DispatchQueue(label: "macrophone.sounds", qos: .utility)
    private nonisolated(unsafe) static var ids: [Cue: SystemSoundID] = [:]
    private static let version = 1

    private static func soundID(_ cue: Cue) -> SystemSoundID? {
        if let id = ids[cue] { return id }
        guard let url = file(cue) else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        ids[cue] = id
        return id
    }

    private static func file(_ cue: Cue) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("Sounds", isDirectory: true)
        let url = dir.appendingPathComponent("\(cue.rawValue)-v\(version).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples = SoundSynth.render(cue)
        do { try SoundSynth.wav(samples).write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}

/// The waveforms, pure (`SoundCues`): sample-level synthesis at 44.1 kHz, mono.
enum SoundSynth {
    static let rate = 44_100.0

    static func render(_ cue: SoundCues.Cue) -> [Float] {
        switch cue {
        case .landed:
            // Two glass tinks a fifth apart, rising: E6 then B6.
            var s = buffer(0.55)
            tink(&s, at: 0, freq: 1318.5, amp: 1, tau: 0.12)
            tink(&s, at: 0.065, freq: 1975.5, amp: 0.8, tau: 0.17)
            return normalized(s, peak: 0.22)
        case .sent:
            // A breath of air rising (noise swept up through a resonant band), then one tink.
            var s = buffer(0.6)
            whoosh(&s, at: 0, length: 0.24, from: 450, to: 4200, amp: 0.55)
            tink(&s, at: 0.17, freq: 1760, amp: 1, tau: 0.16)
            return normalized(s, peak: 0.2)
        case .undo:
            // The landing's tinks, falling: B6 then E6, softer.
            var s = buffer(0.5)
            tink(&s, at: 0, freq: 1975.5, amp: 0.8, tau: 0.09)
            tink(&s, at: 0.07, freq: 1318.5, amp: 1, tau: 0.14)
            return normalized(s, peak: 0.16)
        case .milestone:
            // G5 · B5 · D6 · G6, a small arpeggio that rings.
            var s = buffer(1.2)
            for (i, f) in [783.99, 987.77, 1174.66, 1567.98].enumerated() {
                tink(&s, at: Double(i) * 0.075, freq: f, amp: 0.85 + 0.05 * Double(i), tau: 0.32)
            }
            return normalized(s, peak: 0.2)
        case .paired:
            // Two notes meeting: D6 and A6, the second a breath later, both ringing.
            var s = buffer(1.0)
            tink(&s, at: 0, freq: 1174.66, amp: 1, tau: 0.3)
            tink(&s, at: 0.11, freq: 1760, amp: 0.9, tau: 0.34)
            return normalized(s, peak: 0.2)
        case .pluck0: return pluck(196.00)
        case .pluck1: return pluck(220.00)
        case .pluck2: return pluck(246.94)
        case .pluck3: return pluck(293.66)
        case .pluck4: return pluck(329.63)
        }
    }

    private static func buffer(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }

    /// A struck glass: the note, its octave and an inharmonic shimmer (2.76×) that dies first; a
    /// 3 ms attack so it never clicks.
    private static func tink(_ s: inout [Float], at t0: Double, freq: Double, amp: Double, tau: Double) {
        let start = Int(t0 * rate)
        let partials: [(mult: Double, amp: Double, tau: Double)] = [(1, 1, tau), (2, 0.22, tau * 0.6), (2.76, 0.1, tau * 0.35)]
        for i in start..<s.count {
            let t = Double(i - start) / rate
            let attack = min(1, t / 0.003)
            var v = 0.0
            for p in partials { v += p.amp * sin(2 * .pi * freq * p.mult * t) * exp(-t / p.tau) }
            s[i] += Float(amp * attack * v)
        }
    }

    /// Air: white noise through a state-variable band-pass whose centre sweeps from `from` to
    /// `to` (exponentially), under a bell-shaped swell.
    private static func whoosh(_ s: inout [Float], at t0: Double, length: Double, from: Double, to: Double, amp: Double) {
        var rng = SystemRandomNumberGenerator()
        let start = Int(t0 * rate), n = Int(length * rate)
        var low = 0.0, band = 0.0
        let q = 1.6
        for k in 0..<n where start + k < s.count {
            let x = Double(k) / Double(n)
            let fc = from * pow(to / from, x)
            let f = 2 * sin(.pi * fc / rate)
            let noise = Double.random(in: -1...1, using: &rng)
            low += f * band
            let high = noise - low - band / q
            band += f * high
            let swell = pow(sin(.pi * x), 2)
            s[start + k] += Float(amp * swell * band)
        }
    }

    /// A plucked string (Karplus–Strong): a burst of softened noise circulating in a delay line
    /// one period long, averaged a little each pass, with a quiet sine under it for warmth.
    private static func pluck(_ freq: Double) -> [Float] {
        var s = buffer(1.3)
        let n = max(2, Int((rate / freq).rounded()))
        var rng = SystemRandomNumberGenerator()
        var line = (0..<n).map { _ in Double.random(in: -1...1, using: &rng) }
        // A finger, not a pick: the first burst is softened.
        for _ in 0..<2 { for i in 0..<n { line[i] = 0.5 * (line[i] + line[(i + 1) % n]) } }
        var idx = 0
        let decay = 0.9965
        for i in 0..<s.count {
            let t = Double(i) / rate
            let next = (idx + 1) % n
            let v = line[idx]
            line[idx] = decay * 0.5 * (line[idx] + line[next])
            idx = next
            let body = 0.35 * sin(2 * .pi * freq * t) * exp(-t / 0.45)
            let fade = i > s.count - 2000 ? Double(s.count - i) / 2000 : 1
            s[i] = Float((v + body) * min(1, t / 0.002) * fade)
        }
        return normalized(s, peak: 0.21)
    }

    private static func normalized(_ s: [Float], peak: Float) -> [Float] {
        let m = s.map(abs).max() ?? 1
        guard m > 0 else { return s }
        let k = peak / m
        // The last few milliseconds always fade to silence (no click at the end).
        let tail = min(s.count, 600)
        return s.enumerated().map { i, v in
            let edge = i >= s.count - tail ? Float(s.count - i) / Float(tail) : 1
            return v * k * edge
        }
    }

    /// 16-bit little-endian PCM in a RIFF/WAVE container.
    static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for v in samples {
            let c = Int16(max(-1, min(1, v)) * Float(Int16.max))
            u16(UInt16(bitPattern: c))
        }
        return d
    }
}
