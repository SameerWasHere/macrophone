import AVFoundation
import Foundation

/// The Mac's microphone for desk dictation (Nov 7 2026). Opened at the press on its own queue
/// (never on the main thread); what it hears before the recognizer is attached is held and handed
/// over in order the moment it is (the iPhone's AudioFeed pattern), so the first syllable is never
/// lost. The level is kept for the pill's ring. Nothing is recorded to disk.
final class DeskMic: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "macrophone.desk.mic", qos: .userInteractive)
    private let lock = NSLock()
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var held: [AVAudioPCMBuffer] = []
    private var holding = false
    private var running = false
    private var level: Float = 0
    /// About twelve seconds of buffers — far more than a start ever takes.
    private static let holdLimit = 600

    static var authorization: AVAuthorizationStatus {
        #if DEBUG
        if debugFile != nil { return .authorized }
        #endif
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    #if DEBUG
    /// MACROPHONE_DESK_SIMULATE: an audio file stands in for the mic, played in real time through
    /// the same path (held until the recognizer attaches, the level, the sink).
    nonisolated(unsafe) static var debugFile: URL?
    private var playing = false
    private func play(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let file = try? AVAudioFile(forReading: url) else { return }
            lock.withLock { playing = true }
            while lock.withLock({ playing }), file.framePosition < file.length {
                guard let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024),
                      (try? file.read(into: b, frameCount: 1024)) != nil, b.frameLength > 0 else { break }
                consume(b)
                usleep(useconds_t(Double(b.frameLength) / file.processingFormat.sampleRate * 1_000_000))
            }
        }
    }
    #endif

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// 0…1, smoothed — the voice's loudness for the ring.
    var currentLevel: Float { lock.withLock { level } }

    /// Opens the mic. `done` gets the milliseconds it took, or nil when it couldn't open.
    func open(done: @escaping @Sendable (Int?) -> Void) {
        lock.withLock { held.removeAll(); holding = true; sink = nil; level = 0 }
        let t0 = Date()
        #if DEBUG
        if let url = Self.debugFile { play(url); done(0); return }
        #endif
        queue.async { [self] in
            if running { done(0); return }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { done(nil); return }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.consume(buffer)
            }
            engine.prepare()
            do {
                try engine.start()
                running = true
                done(Int(Date().timeIntervalSince(t0) * 1000))
            } catch {
                input.removeTap(onBus: 0)
                done(nil)
            }
        }
    }

    /// Points the mic at the recognizer; what was held goes in first.
    func attach(_ s: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        sink = s
        let h = held
        held.removeAll()
        holding = false
        for b in h { s(b) }
    }

    /// Seconds of audio waiting for the recognizer (for the log).
    var heldSeconds: Double {
        lock.withLock { held.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate } }
    }

    /// Closes the mic (off the main thread). `keepHeld`: the dictation is finishing and its
    /// recognizer may not be attached yet — what was heard stays for `attach`; the recognizer
    /// already attached keeps what it has.
    func close(keepHeld: Bool = false, done: (@Sendable () -> Void)? = nil) {
        lock.withLock {
            if keepHeld {
                holding = false
            } else {
                sink = nil
                held.removeAll()
                holding = false
            }
            level = 0
            #if DEBUG
            playing = false
            #endif
        }
        queue.async { [self] in
            if running {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                running = false
            }
            done?()
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(buffer)
        lock.lock()
        // A quick rise, a slower fall — a ring that breathes, not one that flickers.
        let target = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 55) / 40))
        level = target > level ? level + (target - level) * 0.6 : level + (target - level) * 0.15
        let s = sink
        if s == nil, holding, held.count < Self.holdLimit, let copy = Self.copy(buffer) { held.append(copy) }
        lock.unlock()
        s?(buffer)
    }

    private static func rms(_ b: AVAudioPCMBuffer) -> Float {
        guard let data = b.floatChannelData, b.frameLength > 0 else { return 0 }
        let n = Int(b.frameLength)
        var sum: Float = 0
        let ch = data[0]
        var i = 0
        while i < n { let v = ch[i]; sum += v * v; i += 2 }
        return sqrt(sum / Float(max(1, n / 2)))
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let channels = Int(b.format.channelCount)
        if let src = b.floatChannelData, let dst = c.floatChannelData {
            for i in 0..<channels { dst[i].update(from: src[i], count: Int(b.frameLength)) }
            return c
        }
        if let src = b.int16ChannelData, let dst = c.int16ChannelData {
            for i in 0..<channels { dst[i].update(from: src[i], count: Int(b.frameLength)) }
            return c
        }
        return nil
    }
}
