import Foundation
import MacrophoneKit

// The Mac's sound, proven without a Mac's capture (Oct 19 2026): `mpctl serve` answers a phone's
// `watchSound(true)` with a test tone through the same sender the Mac app uses (encoder, numbers,
// gaps, the 20 ms pace); `mpctl watch --sound` is the phone — it decodes each packet, keeps the
// same jitter buffer, drains it at the speaker's pace, and prints the latency estimate and the
// underruns as numbers. `--sound-gap S` (serve) pauses the tone for S seconds halfway through a
// minute, to see a gap marked instead of counted as an underrun.

/// Serve: one tone per phone that turned Sound on.
final class ToneServer: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func set(_ on: Bool, for peer: UUID, server: LinkServer) {
        lock.sync { tasks.removeValue(forKey: peer) }?.cancel()
        let named = Set(server.phones(with: MacSound.feature).contains(peer) ? [MacSound.feature] : [])
        guard MacSound.sends(phoneFeatures: named, turnedOn: on) else { stdout("SOUND off"); return }
        let remote = server.isRemote(peer)
        guard let sender = try? MacAudioSender(remote: remote) else { stdout("SOUND no encoder"); return }
        stdout("SOUND on: \(sender.encoder.codec.rawValue) \(sender.encoder.bitrate / 1000) kbps\(remote ? " (away from home)" : "")")
        let gap = flag("--sound-gap").flatMap(Double.init)
        let task = Task.detached(priority: .high) {
            var tone = TestTone()
            let start = Date()
            var position: Int64 = 0
            var sent = 0
            let chunk = 480
            while !Task.isCancelled {
                // A capture hands over 10 ms at a time; the sender packs them into 20 ms packets.
                let due = start.addingTimeInterval(Double(position + Int64(chunk)) / Double(MacSound.sampleRate))
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                let elapsed = Date().timeIntervalSince(start)
                if let gap, elapsed > 3, elapsed < 3 + gap {
                    // Nothing playing: the capture sends nothing, and the position moves on.
                    position += Int64(chunk)
                    _ = tone.next(frames: chunk)
                    continue
                }
                let frames = tone.next(frames: chunk)
                let now = Date().timeIntervalSince1970
                for p in sender.packets(frames, at: position, capturedAt: now - 0.010, now: now) {
                    await server.send(.macAudio(p), to: peer)
                    sent += 1
                }
                position += Int64(chunk)
            }
            stdout("SOUND stopped after \(sent) packets, \(sender.gaps) gaps")
        }
        lock.sync { tasks[peer] = task }
    }
}

/// The phone side for `mpctl watch --sound`: decode, buffer, drain at 48 kHz, count.
final class SoundListener: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder: MacAudioDecoder?
    private var decoderStream: UInt32?
    private var jitter: SoundJitter
    private var latency = SoundLatency()
    private var bytes = 0
    private var bitrate = 0
    private var codec = ""
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mpctl.sound", qos: .userInteractive)
    private var buffer = [Float](repeating: 0, count: 480 * 2)
    private var decodeMicros: [Int] = []

    init(remote: Bool) {
        jitter = SoundJitter(target: MacSound.targetFrames(remote: remote), ceiling: MacSound.ceilingFrames(remote: remote))
    }

    func start() {
        // The speaker: 10 ms a tick, as an output unit pulls.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.01, repeating: 0.01, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            _ = self.buffer.withUnsafeMutableBufferPointer { self.jitter.pull(into: $0.baseAddress!, frames: 480) }
            self.lock.unlock()
        }
        t.resume()
        timer = t
    }

    func receive(_ p: MacAudioPacket) {
        let arrived = Date().timeIntervalSince1970
        let t0 = DispatchTime.now()
        lock.lock()
        defer { lock.unlock() }
        // A new stream is a new encoder: its decoder is made from the set-up it sends.
        if decoder == nil || decoderStream != p.stream {
            guard let config = p.config else { return }
            decoder = try? MacAudioDecoder(codec: p.codec, config: config)
            decoderStream = p.stream
        }
        guard let samples = decoder?.decode(p) else { return }
        decodeMicros.append(Int((DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1000))
        let held = jitter.buffered
        jitter.push(samples, seq: p.seq, stream: p.stream, sampleTime: p.sampleTime)
        bytes += p.packets.reduce(0) { $0 + $1.count }
        bitrate = p.bitrate
        codec = p.codec.rawValue
        // The packet's first frame plays after what was held before it (or the target, while filling).
        let buffered = jitter.playing ? held : max(held, jitter.target)
        latency.add(.init(mac: p.macDelay, wire: SoundLatency.wire(sentAt: p.sentAt, arrivedAt: arrived),
                          buffer: Double(buffered) / Double(MacSound.sampleRate), output: 0))
    }

    func finish(seconds: Double) -> Int {
        timer?.cancel()
        lock.lock()
        defer { lock.unlock() }
        let s = jitter.stats
        let d = decodeMicros.sorted()
        stdout("SOUND \(s.packets) packets (\(codec), \(bitrate / 1000) kbps asked, \(Int(Double(bytes * 8) / max(seconds, 1) / 1000)) kbps sent)"
               + " · latency \(latency.summary) · underruns \(s.underruns) · late \(s.late) · trimmed \(s.trimmedFrames * 1000 / MacSound.sampleRate) ms"
               + " · gaps \(s.gaps) · resyncs \(s.resyncs) · decode median \(d.isEmpty ? 0 : d[d.count / 2]) µs")
        return s.packets
    }
}
