import AudioToolbox
import Foundation

// Hear the Mac (Oct 19 2026): while a window shows on the phone with Sound on, the Mac's audio
// comes with it — captured on the Mac (ScreenCaptureKit, the whole system mix, Macrophone's own
// sounds left out), encoded as Opus in 20 ms packets (AAC-ELD where an encoder lacks Opus), and
// played on the phone through a small jitter buffer that drops what's late instead of drifting.
//
// Gated both ways: the phone names "sound" in its hello and sends `watchSound(true)` only to a Mac
// whose welcome named it; the Mac sends `macAudio` only to a phone that named it AND turned Sound
// on (an unknown message ends a session). No audio is kept anywhere; the log gets numbers only.

/// The shared rules for the Mac's sound on the phone.
public enum MacSound {
    /// Named in the hello (the phone plays `macAudio`) and in the welcome (the Mac sends it).
    public static let feature = "sound"
    public static let sampleRate = 48_000
    public static let channels = 2
    /// One packet: 20 ms.
    public static let framesPerPacket = 960
    /// The decoder's set-up goes with the first packet and every this many after (a second), so a
    /// phone that missed the first starts within a second.
    public static let configEvery = 50

    public enum Codec: String, Codable, Sendable {
        case opus
        case aacELD = "aac-eld"

        var formatID: AudioFormatID {
            switch self {
            case .opus: return kAudioFormatOpus
            case .aacELD: return kAudioFormatMPEG4AAC_ELD
            }
        }

        /// AAC-ELD's packets are 480 frames (10 ms); Opus's are what was asked.
        var framesPerPacket: Int { self == .opus ? MacSound.framesPerPacket : 480 }
    }

    /// Bits a second: clear stereo at home; half that away from home, where every packet crosses a
    /// slower path (Opus stays good down there; AAC-ELD can't go under 64k in stereo).
    public static func bitrate(remote: Bool, codec: Codec = .opus) -> Int {
        switch codec {
        case .opus: return remote ? 40_000 : 96_000
        case .aacELD: return remote ? 64_000 : 96_000
        }
    }

    /// The jitter buffer: how much the phone holds before it plays (and plays back to after a
    /// stall), and the most it lets build up before it drops the oldest. Away from home the path
    /// is burstier, so it holds more.
    public static func targetFrames(remote: Bool) -> Int { (remote ? 120 : 70) * sampleRate / 1000 }
    public static func ceilingFrames(remote: Bool) -> Int { targetFrames(remote: remote) + 90 * sampleRate / 1000 }

    /// Whether the Mac sends this phone its sound: only a phone that named the feature AND turned
    /// Sound on itself (`watchSound(true)`) — never by default, never because another phone did.
    public static func sends(phoneFeatures: Set<String>, turnedOn: Bool?) -> Bool {
        phoneFeatures.contains(feature) && turnedOn == true
    }
}

/// The phone's Sound switch (Sameer, Oct 19 2026: off by default — on a fresh install, after an
/// update, and whenever it isn't explicitly on; only a tap on Sound turns it on). Kept under its
/// own key; anything but a stored `true` reads as off.
public enum SoundSetting {
    public static let key = "watch.sound.on"
    public static let defaultOn = false

    public static func isOn(in defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: key) as? Bool) == true
    }

    /// Only the Sound toggle calls this.
    public static func set(_ on: Bool, in defaults: UserDefaults) {
        if on { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// One packet of the Mac's sound. About 50 a second.
public struct MacAudioPacket: Codable, Sendable, Equatable {
    /// Per stream, from 1: one missing or out of order is late.
    public var seq: Int
    /// A new stream (the Mac started sending again): the phone starts its buffer over.
    public var stream: UInt32
    /// Where the packet's first frame sits in the stream, in frames: a jump is a gap (the Mac had
    /// nothing to send, or it started over), not lost audio.
    public var sampleTime: Int64
    public var codec: MacSound.Codec
    /// The encoded audio: one Opus packet (20 ms), or AAC-ELD's access units.
    public var packets: [Data]
    /// The decoder's set-up (the encoder's magic cookie), with the first packet and every
    /// `MacSound.configEvery`.
    public var config: Data?
    /// The Mac's clock when it went (seconds since 1970): with the phone's, the wire's share of the
    /// delay, where the two clocks agree (they keep network time).
    public var sentAt: Double
    /// Seconds from capture to sending on the Mac (the capture's buffering and the packet's 20 ms).
    public var macDelay: Double
    public var bitrate: Int

    public init(seq: Int, stream: UInt32, sampleTime: Int64, codec: MacSound.Codec, packets: [Data], config: Data?,
                sentAt: Double, macDelay: Double, bitrate: Int) {
        self.seq = seq
        self.stream = stream
        self.sampleTime = sampleTime
        self.codec = codec
        self.packets = packets
        self.config = config
        self.sentAt = sentAt
        self.macDelay = macDelay
        self.bitrate = bitrate
    }

    /// Whether this packet carries the decoder's set-up.
    public static func carriesConfig(seq: Int) -> Bool { seq == 1 || (seq - 1) % MacSound.configEvery == 0 }
}

public enum AudioCodecError: Error, Equatable {
    case encoder(OSStatus)
    case decoder(OSStatus)
}

// MARK: Encoding (the Mac, mpctl)

private let pcmFormat = AudioStreamBasicDescription(
    mSampleRate: Float64(MacSound.sampleRate), mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: UInt32(4 * MacSound.channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * MacSound.channels),
    mChannelsPerFrame: UInt32(MacSound.channels), mBitsPerChannel: 32, mReserved: 0)

private func compressedFormat(_ codec: MacSound.Codec) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: Float64(MacSound.sampleRate), mFormatID: codec.formatID, mFormatFlags: 0,
                                mBytesPerPacket: 0, mFramesPerPacket: UInt32(codec.framesPerPacket), mBytesPerFrame: 0,
                                mChannelsPerFrame: UInt32(MacSound.channels), mBitsPerChannel: 0, mReserved: 0)
}

/// The bytes a converter's input callback hands over: one buffer, kept alive by its owner.
private final class ConverterFeed {
    var pointer: UnsafeMutableRawPointer?
    var bytes = 0
    /// Frames (PCM in) or 1 (a packet in) waiting to be taken.
    var count: UInt32 = 0
    var description = AudioStreamPacketDescription()
}

/// The converter asked for more than there is: "nothing more for now" (the encoder keeps what it
/// has and gives it on the next call).
private let noMoreForNow: OSStatus = 0x6E6F6D72 // 'nomr'

/// Interleaved stereo float at 48 kHz in, packets out (Opus 20 ms, or AAC-ELD 10 ms). One caller at
/// a time (the Mac's audio queue).
public final class MacAudioEncoder: @unchecked Sendable {
    public let codec: MacSound.Codec
    public let bitrate: Int
    /// The decoder's set-up.
    public let cookie: Data
    public var framesPerPacket: Int { codec.framesPerPacket }
    private let converter: AudioConverterRef
    private let maxPacket: Int
    private var fifo: [Float] = []
    private let feed = ConverterFeed()
    private let input: UnsafeMutablePointer<Float>
    private var output: [UInt8]

    /// Opus where the system has it, else AAC-ELD.
    public static func make(bitrate remote: Bool) throws -> MacAudioEncoder {
        if let e = try? MacAudioEncoder(codec: .opus, bitrate: MacSound.bitrate(remote: remote, codec: .opus)) { return e }
        return try MacAudioEncoder(codec: .aacELD, bitrate: MacSound.bitrate(remote: remote, codec: .aacELD))
    }

    public init(codec: MacSound.Codec, bitrate: Int) throws {
        self.codec = codec
        var inFormat = pcmFormat
        var outFormat = compressedFormat(codec)
        var c: AudioConverterRef?
        var status = AudioConverterNew(&inFormat, &outFormat, &c)
        guard status == noErr, let c else { throw AudioCodecError.encoder(status) }
        converter = c
        // The nearest rate the encoder takes.
        var size: UInt32 = 0
        var chosen = UInt32(bitrate)
        if AudioConverterGetPropertyInfo(c, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr, size > 0 {
            var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
            if AudioConverterGetProperty(c, kAudioConverterApplicableEncodeBitRates, &size, &ranges) == noErr {
                let rates = ranges.map { UInt32($0.mMinimum) }.filter { $0 > 0 }
                if let best = rates.min(by: { abs(Int($0) - bitrate) < abs(Int($1) - bitrate) }) { chosen = best }
            }
        }
        status = AudioConverterSetProperty(c, kAudioConverterEncodeBitRate, 4, &chosen)
        if status != noErr { AudioConverterDispose(c); throw AudioCodecError.encoder(status) }
        self.bitrate = Int(chosen)
        var maxOut: UInt32 = 0
        size = 4
        AudioConverterGetProperty(c, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxOut)
        maxPacket = max(Int(maxOut), 1536)
        output = [UInt8](repeating: 0, count: maxPacket)
        var cookieSize: UInt32 = 0
        var cookie = Data()
        if AudioConverterGetPropertyInfo(c, kAudioConverterCompressionMagicCookie, &cookieSize, nil) == noErr, cookieSize > 0 {
            cookie = Data(count: Int(cookieSize))
            let got = cookie.withUnsafeMutableBytes { AudioConverterGetProperty(c, kAudioConverterCompressionMagicCookie, &cookieSize, $0.baseAddress!) }
            if got != noErr { cookie = Data() } else { cookie = cookie.prefix(Int(cookieSize)) }
        }
        self.cookie = cookie
        input = .allocate(capacity: codec.framesPerPacket * MacSound.channels)
    }

    deinit {
        AudioConverterDispose(converter)
        input.deallocate()
    }

    /// Frames waiting for a whole packet.
    public var buffered: Int { fifo.count / MacSound.channels }

    /// Forget what's waiting and start the encoder over (a gap in the capture).
    public func reset() {
        fifo.removeAll(keepingCapacity: true)
        AudioConverterReset(converter)
    }

    /// Adds interleaved stereo frames and returns the packets they completed (an encoder may hold
    /// the first one or two while it primes).
    public func encode(_ interleaved: UnsafeBufferPointer<Float>) -> [Data] {
        fifo.append(contentsOf: interleaved)
        var out: [Data] = []
        let n = framesPerPacket * MacSound.channels
        while fifo.count >= n {
            fifo.withUnsafeBufferPointer { p in input.update(from: p.baseAddress!, count: n) }
            fifo.removeFirst(n)
            feed.pointer = UnsafeMutableRawPointer(input)
            feed.bytes = n * 4
            feed.count = UInt32(framesPerPacket)
            if let p = fillOne() { out.append(p) }
        }
        return out
    }

    public func encode(_ interleaved: [Float]) -> [Data] { interleaved.withUnsafeBufferPointer { encode($0) } }

    private func fillOne() -> Data? {
        var packets: UInt32 = 1
        var desc = AudioStreamPacketDescription()
        let max = maxPacket
        let status: OSStatus = output.withUnsafeMutableBytes { ob in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(MacSound.channels), mDataByteSize: UInt32(max), mData: ob.baseAddress))
            return AudioConverterFillComplexBuffer(converter, { _, ioCount, ioData, _, user in
                let f = Unmanaged<ConverterFeed>.fromOpaque(user!).takeUnretainedValue()
                guard f.count > 0, let p = f.pointer else { ioCount.pointee = 0; return noMoreForNow }
                ioCount.pointee = f.count
                ioData.pointee.mBuffers.mData = p
                ioData.pointee.mBuffers.mDataByteSize = UInt32(f.bytes)
                ioData.pointee.mBuffers.mNumberChannels = UInt32(MacSound.channels)
                f.count = 0
                return noErr
            }, Unmanaged.passUnretained(feed).toOpaque(), &packets, &list, &desc)
        }
        guard status == noErr || status == noMoreForNow, packets > 0, desc.mDataByteSize > 0 else { return nil }
        let start = Int(desc.mStartOffset), len = Int(desc.mDataByteSize)
        return Data(output[start..<start + len])
    }
}

// MARK: Decoding (the phone, mpctl)

/// Packets in, interleaved stereo float at 48 kHz out. One caller at a time.
public final class MacAudioDecoder: @unchecked Sendable {
    public let codec: MacSound.Codec
    private let converter: AudioConverterRef
    private let feed = ConverterFeed()
    private var packetBytes: UnsafeMutableRawPointer
    private var packetCapacity = 2048
    private var pcm: [Float]

    public init(codec: MacSound.Codec, config: Data?) throws {
        self.codec = codec
        var inFormat = compressedFormat(codec)
        var outFormat = pcmFormat
        var c: AudioConverterRef?
        var status = AudioConverterNew(&inFormat, &outFormat, &c)
        guard status == noErr, let c else { throw AudioCodecError.decoder(status) }
        if let config, !config.isEmpty {
            status = config.withUnsafeBytes { AudioConverterSetProperty(c, kAudioConverterDecompressionMagicCookie, UInt32(config.count), $0.baseAddress!) }
            if status != noErr { AudioConverterDispose(c); throw AudioCodecError.decoder(status) }
        }
        converter = c
        packetBytes = .allocate(byteCount: packetCapacity, alignment: 16)
        pcm = [Float](repeating: 0, count: codec.framesPerPacket * MacSound.channels)
    }

    deinit {
        AudioConverterDispose(converter)
        packetBytes.deallocate()
    }

    /// The frames one packet decodes to (interleaved stereo). Nil when it doesn't decode.
    public func decode(_ packet: Data) -> [Float]? {
        guard !packet.isEmpty else { return nil }
        if packet.count > packetCapacity {
            packetBytes.deallocate()
            packetCapacity = packet.count
            packetBytes = .allocate(byteCount: packetCapacity, alignment: 16)
        }
        packet.withUnsafeBytes { packetBytes.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        feed.pointer = packetBytes
        feed.bytes = packet.count
        feed.count = 1
        feed.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        let frames = codec.framesPerPacket
        var ioFrames = UInt32(frames)
        let status: OSStatus = pcm.withUnsafeMutableBytes { ob in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(MacSound.channels), mDataByteSize: UInt32(frames * MacSound.channels * 4), mData: ob.baseAddress))
            return AudioConverterFillComplexBuffer(converter, { _, ioCount, ioData, outDesc, user in
                let f = Unmanaged<ConverterFeed>.fromOpaque(user!).takeUnretainedValue()
                guard f.count > 0, let p = f.pointer else { ioCount.pointee = 0; return noMoreForNow }
                ioCount.pointee = 1
                ioData.pointee.mBuffers.mData = p
                ioData.pointee.mBuffers.mDataByteSize = UInt32(f.bytes)
                ioData.pointee.mBuffers.mNumberChannels = UInt32(MacSound.channels)
                if let outDesc { outDesc.pointee = withUnsafeMutablePointer(to: &f.description) { $0 } }
                f.count = 0
                return noErr
            }, Unmanaged.passUnretained(feed).toOpaque(), &ioFrames, &list, nil)
        }
        guard status == noErr || status == noMoreForNow, ioFrames > 0 else { return nil }
        return Array(pcm.prefix(Int(ioFrames) * MacSound.channels))
    }

    /// Every packet of a `MacAudioPacket`, decoded in order.
    public func decode(_ p: MacAudioPacket) -> [Float]? {
        var all: [Float] = []
        for d in p.packets {
            guard let f = decode(d) else { return nil }
            all += f
        }
        return all
    }
}

// MARK: Packets (the Mac, mpctl)

/// The Mac's side for one phone: captured frames in, numbered packets out, with the gaps and the
/// stream's start marked so the phone can tell lost audio from silence. One caller at a time.
public final class MacAudioSender: @unchecked Sendable {
    public let encoder: MacAudioEncoder
    public let stream = UInt32.random(in: 1...UInt32.max)
    public private(set) var seq = 0
    /// Where the encoder's next packet starts (frames in the stream), and where the next captured
    /// frame is expected.
    private var nextPacketAt: Int64?
    private var expected: Int64?
    /// The capture's clock for one position, so each packet knows how long ago it was heard.
    private var anchor: (position: Int64, at: Double)?
    public private(set) var gaps = 0

    public init(remote: Bool) throws { encoder = try .make(bitrate: remote) }
    public init(encoder: MacAudioEncoder) { self.encoder = encoder }

    /// Frames heard at `position` (frames since the capture began) at `capturedAt` (seconds since
    /// 1970), interleaved stereo. Returns the packets ready to go, stamped with `now`.
    public func packets(_ interleaved: UnsafeBufferPointer<Float>, at position: Int64, capturedAt: Double, now: Double) -> [MacAudioPacket] {
        let frames = Int64(interleaved.count / MacSound.channels)
        // A jump (the capture paused, or nothing played and it sent nothing): start the encoder
        // over there, so the packets after it say where they really are.
        if let e = expected, abs(position - e) > Int64(encoder.framesPerPacket / 2) {
            encoder.reset()
            nextPacketAt = nil
            gaps += 1
        }
        if nextPacketAt == nil { nextPacketAt = position }
        expected = position + frames
        anchor = (position + frames, capturedAt + Double(frames) / Double(MacSound.sampleRate))
        let out = encoder.encode(interleaved)
        return out.map { data in
            seq += 1
            let at = nextPacketAt ?? position
            nextPacketAt = at + Int64(encoder.framesPerPacket)
            // When the packet's first frame was heard (the anchor less the frames after it): the
            // packet's own 20 ms counts, as the person hears its start that much later.
            let heardAt = anchor.map { $0.at - Double($0.position - at) / Double(MacSound.sampleRate) } ?? capturedAt
            return MacAudioPacket(seq: seq, stream: stream, sampleTime: at, codec: encoder.codec, packets: [data],
                                  config: MacAudioPacket.carriesConfig(seq: seq) ? encoder.cookie : nil,
                                  sentAt: now, macDelay: max(0, now - heardAt), bitrate: encoder.bitrate)
        }
    }

    public func packets(_ interleaved: [Float], at position: Int64, capturedAt: Double, now: Double) -> [MacAudioPacket] {
        interleaved.withUnsafeBufferPointer { packets($0, at: position, capturedAt: capturedAt, now: now) }
    }
}

/// A test tone for `mpctl serve` and the Mac's debug hook: short beeps, alternating 440 and 660 Hz,
/// a quarter second on and off — easy to hear, easy to see in a level meter.
public struct TestTone: Sendable {
    public var amplitude: Float = 0.25
    private var frame: Int64 = 0

    public init() {}

    /// The next `frames` frames, interleaved stereo.
    public mutating func next(frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * MacSound.channels)
        let rate = Double(MacSound.sampleRate)
        let beep = Int64(MacSound.sampleRate / 4)
        for i in 0..<frames {
            let f = frame + Int64(i)
            let k = f / beep
            guard k % 2 == 0 else { continue }
            let hz = (k / 2) % 2 == 0 ? 440.0 : 660.0
            // A short ramp at each edge: no click.
            let into = Double(f % beep), ramp = min(1, min(into, Double(beep) - into) / 240)
            let v = Float(sin(2 * .pi * hz * Double(f) / rate) * ramp) * amplitude
            out[i * 2] = v
            out[i * 2 + 1] = v
        }
        frame += Int64(frames)
        return out
    }
}

// MARK: The jitter buffer (the phone, mpctl)

/// What the phone holds between the wire and the speaker, pure: decoded frames are pushed as
/// packets land and pulled by the output a few milliseconds at a time. It starts playing once it
/// holds `target` frames; when it runs dry it plays silence and fills to `target` again (a resync);
/// when it holds more than `ceiling` — a burst after a stall — it drops the oldest back to
/// `target`, so the sound never drifts behind the picture. A packet older than one played is
/// dropped; a new stream starts it over.
public struct SoundJitter: Sendable {
    public struct Stats: Sendable, Equatable {
        public var packets = 0
        /// Ran dry while audio was coming (not a gap the Mac marked).
        public var underruns = 0
        /// Packets dropped as late (out of order, or older than what played), and frames dropped
        /// to stay near the target after a burst.
        public var late = 0
        public var trimmedFrames = 0
        /// The Mac had nothing to send for a while (the next packet says where it really is).
        public var gaps = 0
        /// Filled to the target again (after running dry, a gap, or a new stream).
        public var resyncs = 0
        public init() {}
    }

    public let target: Int
    public let ceiling: Int
    public private(set) var stats = Stats()
    public private(set) var playing = false
    private var ring: [Float]
    private let capacity: Int
    private var readIndex = 0
    private var count = 0
    private var lastSeq = 0
    private var stream: UInt32?
    private var expected: Int64?
    /// It ran dry just now: if the next packet shows a gap, that was the Mac going quiet, not an underrun.
    private var dryPending = false

    public init(target: Int, ceiling: Int) {
        self.target = target
        self.ceiling = max(ceiling, target)
        capacity = max(ceiling, target) + MacSound.sampleRate / 2
        ring = [Float](repeating: 0, count: capacity * MacSound.channels)
    }

    /// Frames held.
    public var buffered: Int { count }

    public enum Push: Equatable, Sendable { case accepted, late, restarted }

    /// A packet's frames (interleaved stereo).
    @discardableResult
    public mutating func push(_ samples: [Float], seq: Int, stream: UInt32, sampleTime: Int64) -> Push {
        var result = Push.accepted
        if self.stream != stream {
            if self.stream != nil { stats.resyncs += 1 }
            self.stream = stream
            clear()
            lastSeq = 0
            expected = nil
            result = .restarted
        } else if seq <= lastSeq {
            stats.late += 1
            return .late
        }
        if let e = expected, sampleTime > e + Int64(MacSound.framesPerPacket / 2) {
            stats.gaps += 1
            if dryPending { stats.underruns -= 1 }
        }
        dryPending = false
        lastSeq = seq
        stats.packets += 1
        let frames = samples.count / MacSound.channels
        expected = sampleTime + Int64(frames)
        write(samples, frames: frames)
        if count > ceiling {
            let drop = count - target
            readIndex = (readIndex + drop) % capacity
            count -= drop
            stats.trimmedFrames += drop
        }
        if !playing, count >= target { playing = true }
        return result
    }

    /// Fills `frames` frames (interleaved stereo) for the output; returns how many were audio (the
    /// rest is silence).
    public mutating func pull(into out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard playing else {
            out.update(repeating: 0, count: frames * MacSound.channels)
            return 0
        }
        let n = min(frames, count)
        var copied = 0
        while copied < n {
            let run = min(n - copied, capacity - readIndex)
            ring.withUnsafeBufferPointer { r in
                (out + copied * MacSound.channels).update(from: r.baseAddress! + readIndex * MacSound.channels, count: run * MacSound.channels)
            }
            readIndex = (readIndex + run) % capacity
            copied += run
        }
        count -= n
        if n < frames {
            (out + n * MacSound.channels).update(repeating: 0, count: (frames - n) * MacSound.channels)
            playing = false
            stats.underruns += 1
            stats.resyncs += 1
            dryPending = true
        }
        return n
    }

    /// Start over (Sound off, the window closed).
    public mutating func reset() {
        clear()
        stream = nil
        lastSeq = 0
        expected = nil
        dryPending = false
    }

    private mutating func clear() {
        readIndex = 0
        count = 0
        playing = false
    }

    private mutating func write(_ samples: [Float], frames: Int) {
        // More than the ring holds: keep the newest.
        var start = 0
        var n = frames
        if n > capacity { start = n - capacity; n = capacity }
        // Full: the oldest make room.
        let overflow = count + n - capacity
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacity
            count -= overflow
            stats.trimmedFrames += overflow
        }
        var writeIndex = (readIndex + count) % capacity
        var written = 0
        samples.withUnsafeBufferPointer { s in
            ring.withUnsafeMutableBufferPointer { r in
                while written < n {
                    let run = min(n - written, capacity - writeIndex)
                    (r.baseAddress! + writeIndex * MacSound.channels).update(from: s.baseAddress! + (start + written) * MacSound.channels, count: run * MacSound.channels)
                    writeIndex = (writeIndex + run) % capacity
                    written += run
                }
            }
        }
        count += n
    }
}

/// The delay from the Mac's speaker to the phone's, estimated per packet, and how it went — numbers
/// only, for the log line when the sound stops.
public struct SoundLatency: Sendable {
    public struct Sample: Sendable {
        public var mac: Double
        /// The wire, by the two clocks (nil when they disagree by more than a second).
        public var wire: Double?
        public var buffer: Double
        public var output: Double
        public var total: Double { mac + (wire ?? 0) + buffer + output }
        public init(mac: Double, wire: Double?, buffer: Double, output: Double) {
            self.mac = mac; self.wire = wire; self.buffer = buffer; self.output = output
        }
    }

    private(set) var samples: [Sample] = []
    public init() {}

    public var count: Int { samples.count }

    public mutating func add(_ s: Sample) {
        if samples.count >= 30_000 { samples.removeFirst(10_000) }
        samples.append(s)
    }

    /// The wire's share from the two clocks: arrival − sent, kept only when it's plausible.
    public static func wire(sentAt: Double, arrivedAt: Double) -> Double? {
        let d = arrivedAt - sentAt
        return (-0.005...1).contains(d) ? max(0, d) : nil
    }

    private static func ms(_ v: Double) -> Int { Int((v * 1000).rounded()) }
    private static func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
    private static func p95(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[min(a.count - 1, a.count * 95 / 100)] }

    /// "median 112 ms, p95 140 ms (Mac 31, wire 4, buffer 66, output 11)".
    public var summary: String {
        guard !samples.isEmpty else { return "no packets" }
        let totals = samples.map(\.total)
        let wires = samples.compactMap(\.wire)
        return "median \(Self.ms(Self.median(totals))) ms, p95 \(Self.ms(Self.p95(totals))) ms (Mac \(Self.ms(Self.median(samples.map(\.mac)))), "
            + "wire \(wires.isEmpty ? "unknown" : String(Self.ms(Self.median(wires)))), buffer \(Self.ms(Self.median(samples.map(\.buffer)))), "
            + "output \(Self.ms(Self.median(samples.map(\.output)))))"
    }

    public var medianMilliseconds: Int { Self.ms(Self.median(samples.map(\.total))) }
}
