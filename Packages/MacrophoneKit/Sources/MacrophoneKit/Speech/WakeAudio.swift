#if os(macOS)
import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import SoundAnalysis

// The wake word's ears (Nov 7 2026). Listening for a phrase all day has to cost next to nothing,
// so the work is in tiers, cheapest first (SameerOS's design, kept):
//   0. Every buffer (about 12 a second): its loudness, a noise floor that follows the room, and a
//      copy into a 3.5 s pre-roll. Nothing else — no conversion, no main thread.
//   1. Only while it's louder than the room: Apple's sound classifier asks whether it's a voice
//      (typing, music, a door don't count).
//   2. Only while a voice is heard: a SpeechAnalyzer session looks for the phrase (WakeListener).
// Audio never leaves the Mac and nothing is written to disk.

/// Where the audio comes from: the microphone, or (for tests and the bench) audio files.
public protocol WakeAudioSource: AnyObject {
    /// Starts delivering mono buffers to `push` (on an audio thread). Throws when it can't.
    func start(_ push: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
    /// Something changed under it (the default input, a device gone): the listener restarts it.
    var onChange: (@Sendable (String) -> Void)? { get set }
    /// A few words on what it's listening with ("MacBook Pro Microphone").
    var description: String { get }
}

public enum WakeAudioError: Error, Equatable {
    case noMicrophone
    /// The only input is a Bluetooth headset (AirPods): listening on it all day would switch it to
    /// its call mode and ruin its sound, so the wake word waits.
    case onlyBluetooth(String)
    case couldNotStart(String)
}

// MARK: - The feed (audio thread)

/// Everything that happens per buffer, kept cheap. Thread-safe; callbacks on a background queue.
public final class WakeFeed: NSObject, @unchecked Sendable, SNResultsObserving {
    /// The classifier heard a voice (tier 1 → 2). Background queue.
    public var onVoice: @Sendable () -> Void = {}

    private let lock = NSLock()
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFrameCount = 0
    private var maxPrerollFrames: AVAudioFrameCount = 0
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var classifying = false
    private var useClassifier = true
    /// The bench's baseline: every buffer counts as loud (no gate at all).
    private var ungated = false
    private var gate = WakeSoundGate()
    private var lastLoud: TimeInterval = -100
    private var lastVoiceSent: TimeInterval = -100
    private var currentDB: Float = -160
    private var recentDB: [Float] = []
    private var ambient: Float = -60
    private var captureDB: [Float] = []
    private var speechRef: Float = -160
    private var capturing = false
    private var sensitivity: WakeSensitivity = .normal
    /// Seconds of audio pushed — the listener's clock (the same as the wall clock for the mic,
    /// faster for a bench file played fast).
    private var clock: TimeInterval = 0
    private var lastBufferWall = Date()
    private var format: AVAudioFormat?

    private let analysisQueue = DispatchQueue(label: "macrophone.wake.analysis", qos: .utility)
    private var analyzer: SNAudioStreamAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var analyzerPosition: AVAudioFramePosition = 0
    /// Seconds the classifier has run (for the numbers).
    private var classifiedSeconds: Double = 0

    private static let speechLabels: Set<String> = [
        "speech", "conversation", "narration_monologue", "shout", "yell", "whispering", "babbling",
    ]

    public override init() { super.init() }

    public func configure(classifier: Bool, sensitivity: WakeSensitivity, ungated: Bool = false) {
        lock.withLock {
            useClassifier = classifier
            self.ungated = ungated
            self.sensitivity = sensitivity
        }
    }

    /// The listener's clock: seconds of audio heard.
    public var now: TimeInterval { lock.withLock { clock } }
    public var secondsSinceLastBuffer: TimeInterval { lock.withLock { Date().timeIntervalSince(lastBufferWall) } }
    public var classifierSeconds: Double { lock.withLock { classifiedSeconds } }
    /// The voice's loudness 0…1 while a capture runs (a quick rise, a slower fall — DeskMic's ring).
    public var level: Float { lock.withLock { smoothLevel } }
    private var smoothLevel: Float = 0
    public var roomDB: Float { lock.withLock { ambient } }

    /// Tier 1 on or off (off while a session is already transcribing — new words prove a voice).
    public func setClassifying(_ on: Bool) { lock.withLock { classifying = on } }

    /// While a capture runs, the voice's own level is learned (so "quiet" means back near the room).
    public func setCapturing(_ on: Bool) {
        lock.withLock {
            capturing = on
            smoothLevel = 0
            captureDB = []
            speechRef = -160
        }
    }

    /// Is a voice heard right now (louder than the room by 6 dB, and not far below your own
    /// speech — a noise-suppressed mic makes the room nearly silent)? SameerOS's rule.
    public func isVoice() -> Bool {
        lock.withLock {
            let line = max(ambient + 6, captureDB.count >= 6 ? speechRef - 22 : -160)
            return currentDB > line
        }
    }

    public func reset() {
        lock.withLock {
            preroll.removeAll()
            prerollFrames = 0
            sink = nil
            gate = WakeSoundGate()
            recentDB.removeAll()
            format = nil
        }
        analysisQueue.async { [self] in analyzer = nil; analyzerFormat = nil; analyzerPosition = 0 }
    }

    /// Points the audio at a session; the pre-roll goes in first (the phrase's first syllables,
    /// said before tier 2 woke).
    public func attach(_ s: @escaping (AVAudioPCMBuffer) -> Void, preroll includePreroll: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        if includePreroll { for b in preroll { s(b) } }
        sink = s
    }

    public func detach() { lock.withLock { sink = nil } }

    public func clearPreroll() {
        lock.withLock {
            preroll.removeAll()
            prerollFrames = 0
        }
    }

    /// Audio thread. `buffer` is mono float.
    public func push(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let data = buffer.floatChannelData else { return }
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-8))
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        lock.lock()
        if format != buffer.format {
            format = buffer.format
            maxPrerollFrames = AVAudioFrameCount(buffer.format.sampleRate * 3.5)
            preroll.removeAll()
            prerollFrames = 0
        }
        clock += seconds
        lastBufferWall = Date()
        let margin: Float = [WakeSensitivity.low: 12, .normal: 9, .high: 6][sensitivity] ?? 9
        if db > -120, gate.isSound(db, margin: margin) || ungated { lastLoud = clock }
        currentDB = db
        if db > -120 {
            if capturing {
                let target = min(1, max(0, (db + 55) / 40))
                smoothLevel = target > smoothLevel ? smoothLevel + (target - smoothLevel) * 0.6 : smoothLevel + (target - smoothLevel) * 0.15
                captureDB.append(db)
                if captureDB.count > 48 { captureDB.removeFirst(captureDB.count - 48) }
                let sorted = captureDB.sorted()
                speechRef = max(speechRef - 0.05, sorted[min(sorted.count - 1, sorted.count * 9 / 10)])
            } else {
                // The room: the 20th percentile of the last ~6 s.
                recentDB.append(db)
                if recentDB.count > 70 { recentDB.removeFirst(recentDB.count - 70) }
                if recentDB.count >= 8 { ambient = recentDB.sorted()[recentDB.count / 5] }
            }
        }
        preroll.append(buffer)
        prerollFrames += buffer.frameLength
        while prerollFrames > maxPrerollFrames, preroll.count > 1 { prerollFrames -= preroll.removeFirst().frameLength }
        let s = sink
        let loudNow = clock - lastLoud < 1.0
        let runClassifier = classifying && loudNow && useClassifier
        // No classifier (the bench's comparison): loudness alone wakes tier 2, at most twice a second.
        let wakeOnLoud = classifying && loudNow && !useClassifier && clock - lastVoiceSent > 0.5
        if wakeOnLoud { lastVoiceSent = clock }
        lock.unlock()
        s?(buffer)
        if wakeOnLoud { onVoice() }
        if runClassifier {
            analysisQueue.async { [self] in classify(buffer, seconds: seconds) }
        }
    }

    private func classify(_ buffer: AVAudioPCMBuffer, seconds: Double) {
        if analyzer == nil || analyzerFormat != buffer.format {
            let a = SNAudioStreamAnalyzer(format: buffer.format)
            if let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
                request.windowDuration = CMTime(seconds: 1.0, preferredTimescale: 48_000)
                request.overlapFactor = 0.5
                try? a.add(request, withObserver: self)
            }
            analyzer = a
            analyzerFormat = buffer.format
            analyzerPosition = 0
        }
        analyzer?.analyze(buffer, atAudioFramePosition: analyzerPosition)
        analyzerPosition += AVAudioFramePosition(buffer.frameLength)
        lock.withLock { classifiedSeconds += seconds }
    }

    // SNResultsObserving (analysis queue)
    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        // Short phrases fill part of the 1 s window, so their confidence runs lower than a
        // sentence's — the thresholds are set for that (SameerOS's numbers).
        let threshold: Double = lock.withLock { [WakeSensitivity.low: 0.35, .normal: 0.22, .high: 0.12][sensitivity] ?? 0.22 }
        let best = result.classifications.filter { Self.speechLabels.contains($0.identifier) }.map(\.confidence).max() ?? 0
        if best > threshold { onVoice() }
    }
}

/// Is a buffer "sound", relative to the room's own background (SameerOS's SoundGate)?
struct WakeSoundGate {
    private(set) var noiseFloor: Float = -60

    mutating func isSound(_ db: Float, margin: Float = 10) -> Bool {
        let threshold = max(noiseFloor + margin, -50)
        if db < noiseFloor {
            noiseFloor = noiseFloor * 0.7 + db * 0.3          // drop quickly
        } else if db < threshold {
            noiseFloor += (db - noiseFloor) * 0.05            // adapt to steady background noise
        } else {
            noiseFloor += (db - noiseFloor) * 0.002           // barely move while someone talks
        }
        return db > threshold
    }
}

// MARK: - Mono

enum WakeMono {
    /// The first channel as a mono float buffer (a copy: the engine reuses its buffers).
    static func mono(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: b.frameLength) else { return nil }
        out.frameLength = b.frameLength
        if let src = b.floatChannelData, let dst = out.floatChannelData {
            if b.format.isInterleaved, b.format.channelCount > 1 {
                let ch = Int(b.format.channelCount)
                for i in 0..<Int(b.frameLength) { dst[0][i] = src[0][i * ch] }
            } else {
                dst[0].update(from: src[0], count: Int(b.frameLength))
            }
            return out
        }
        if let src = b.int16ChannelData, let dst = out.floatChannelData {
            for i in 0..<Int(b.frameLength) { dst[0][i] = Float(src[0][i]) / 32768 }
            return out
        }
        return nil
    }
}

// MARK: - Devices (Core Audio)

/// The Mac's audio devices, read-only. Macrophone never sets a device's sample rate, its default,
/// or anything else on it.
public enum WakeAudioDevices {
    public struct Device: Equatable, Sendable {
        public let id: AudioObjectID
        public let name: String
        public let transport: UInt32
        public var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
        public var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ fallback: T) -> T {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : fallback
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return [] }
        return out
    }

    static func device(_ id: AudioObjectID) -> Device {
        Device(id: id, name: string(id, kAudioObjectPropertyName) ?? "Microphone", transport: get(id, kAudioDevicePropertyTransportType, 0))
    }

    public static var defaultInput: Device? {
        let id: AudioObjectID = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, 0)
        return id == kAudioObjectUnknown ? nil : device(id)
    }

    public static var defaultOutput: AudioObjectID {
        Self.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, 0)
    }

    public static func nominalRate(_ id: AudioObjectID) -> Double? {
        let r: Float64 = get(id, kAudioDevicePropertyNominalSampleRate, 0)
        return r > 0 ? r : nil
    }

    /// Every device with an input stream.
    public static var inputs: [Device] {
        ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).filter { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
        }.map(device)
    }

    /// The input the wake word listens on: the default, unless it's Bluetooth (AirPods) — then
    /// the Mac's own microphone, so the headset never drops to its call-quality mode.
    public static func pick(avoidBluetooth: Bool = true) -> Result<(Device, insteadOf: Device?), WakeAudioError> {
        guard let def = defaultInput else { return .failure(.noMicrophone) }
        guard avoidBluetooth, def.isBluetooth else { return .success((def, nil)) }
        if let builtIn = inputs.first(where: \.isBuiltIn) ?? inputs.first(where: { !$0.isBluetooth }) {
            return .success((builtIn, def))
        }
        return .failure(.onlyBluetooth(def.name))
    }

    /// Other apps using a microphone right now (a call, a recording), as bundle ids — Macrophone's
    /// own processes left out, and the ones in `ignoring` (another always-on listener). Core
    /// Audio's process objects, macOS 14+.
    public static func othersUsingInput(ignoring: Set<String> = []) -> [String] {
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [String] = []
        for p in ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            let running: UInt32 = get(p, kAudioProcessPropertyIsRunningInput, 0)
            guard running != 0 else { continue }
            let pid: pid_t = get(p, kAudioProcessPropertyPID, 0)
            guard pid != me else { continue }
            let bid = string(p, kAudioProcessPropertyBundleID) ?? "pid \(pid)"
            if bid.hasPrefix("com.sameer.macrophone") || ignoring.contains(bid) { continue }
            out.append(bid)
        }
        return out
    }

    /// Calls `change` (on the main queue) when the default input changes, a device comes or goes,
    /// or any process starts or stops using a microphone. Returns a token that stops it.
    public static func watch(_ change: @escaping @Sendable () -> Void) -> WakeAudioWatch {
        WakeAudioWatch(change)
    }
}

/// Core Audio property listeners for the wake word (removed on `stop` / deinit).
public final class WakeAudioWatch: @unchecked Sendable {
    private var blocks: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var processBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private let change: @Sendable () -> Void
    private let lock = NSLock()

    init(_ change: @escaping @Sendable () -> Void) {
        self.change = change
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices, kAudioHardwarePropertyProcessObjectList] {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                if sel == kAudioHardwarePropertyProcessObjectList { self?.watchProcesses() }
                DispatchQueue.main.async { change() }
            }
            if AudioObjectAddPropertyListenerBlock(sys, &a, DispatchQueue.main, block) == noErr { blocks.append((sys, a, block)) }
        }
        watchProcesses()
    }

    /// Each process's "running input" flag (a call starting in an app that was already open).
    private func watchProcesses() {
        lock.lock(); defer { lock.unlock() }
        let now = Set(WakeAudioDevices.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList))
        for p in now where processBlocks[p] == nil {
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let change = self.change
            let block: AudioObjectPropertyListenerBlock = { _, _ in DispatchQueue.main.async { change() } }
            if AudioObjectAddPropertyListenerBlock(p, &a, DispatchQueue.main, block) == noErr { processBlocks[p] = block }
        }
        for (p, block) in processBlocks where !now.contains(p) {
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(p, &a, DispatchQueue.main, block)
            processBlocks[p] = nil
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        for (obj, addr, block) in blocks {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(obj, &a, DispatchQueue.main, block)
        }
        blocks.removeAll()
        for (p, block) in processBlocks {
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(p, &a, DispatchQueue.main, block)
        }
        processBlocks.removeAll()
    }

    deinit { stop() }
}

// MARK: - The microphone

/// The microphone for the wake word: AVAudioEngine on the picked input (the default, or the Mac's
/// own when the default is Bluetooth), large buffers (4096 frames: ~12 wake-ups a second for us
/// and coreaudiod, not ~94), the input only — and the output's sample rate checked after the start
/// (SameerOS found an always-on mic could move it: opening a headset's mic flips it to its call
/// profile; the cure is not opening a Bluetooth mic, the check is the safety net).
public final class WakeMicSource: WakeAudioSource, @unchecked Sendable {
    public var onChange: (@Sendable (String) -> Void)?
    public var log: (@Sendable (String) -> Void)?
    public private(set) var device: WakeAudioDevices.Device?
    /// The Bluetooth input it stepped around, if any.
    public private(set) var avoided: WakeAudioDevices.Device?
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private let queue = DispatchQueue(label: "macrophone.wake.mic", qos: .userInitiated)

    public init() {}

    public var description: String {
        guard let device else { return "no microphone" }
        return avoided.map { "\(device.name) (not \($0.name))" } ?? device.name
    }

    public func start(_ push: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let picked: (WakeAudioDevices.Device, insteadOf: WakeAudioDevices.Device?)
        switch WakeAudioDevices.pick() {
        case .success(let p): picked = p
        case .failure(let e): throw e
        }
        device = picked.0
        avoided = picked.insteadOf
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if picked.insteadOf != nil || picked.0.id != WakeAudioDevices.defaultInput?.id {
            do { try input.auAudioUnit.setDeviceID(picked.0.id) } catch { throw WakeAudioError.couldNotStart("device") }
        }
        if let unit = input.audioUnit {
            var frames: UInt32 = 4096
            AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw WakeAudioError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let m = WakeMono.mono(buffer) { push(m) }
        }
        let output = WakeAudioDevices.defaultOutput
        let rateBefore = WakeAudioDevices.nominalRate(output)
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw WakeAudioError.couldNotStart(error.localizedDescription)
        }
        if let before = rateBefore, let after = WakeAudioDevices.nominalRate(output), abs(after - before) > 1 {
            log?("wake: the output moved from \(Int(before)) to \(Int(after)) Hz when the mic opened")
        }
        self.engine = engine
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.onChange?("the audio configuration changed")
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
    }
}

// MARK: - Files (tests, the bench, the DEBUG hook)

/// Plays audio files as if they were the microphone: 48 kHz mono in 4096-frame buffers, at real
/// time (or `speed` times it), with room tone between them and under them.
public final class WakeFileSource: WakeAudioSource, @unchecked Sendable {
    public var onChange: (@Sendable (String) -> Void)?
    /// A file starts (index, url) / everything has played (not called when looping).
    public var onFile: (@Sendable (Int, URL) -> Void)?
    public var onEnd: (@Sendable () -> Void)?
    public let files: [URL]
    public let loop: Bool
    public let gap: TimeInterval
    public let speed: Double
    /// Room tone, dBFS (nil = digital silence).
    public let noiseDB: Float?
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    public init(files: [URL], loop: Bool = false, gap: TimeInterval = 2.5, speed: Double = 1, noiseDB: Float? = -62) {
        self.files = files
        self.loop = loop
        self.gap = gap
        self.speed = speed
        self.noiseDB = noiseDB
    }

    public var description: String { "\(files.count) audio file\(files.count == 1 ? "" : "s")" }

    public func start(_ push: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        lock.withLock { running = true }
        let t = Thread { [self] in run(push) }
        t.qualityOfService = .userInitiated
        t.start()
        thread = t
    }

    public func stop() { lock.withLock { running = false } }

    private var isRunning: Bool { lock.withLock { running } }

    private func run(_ push: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let fmt = Self.format
        let chunk: AVAudioFrameCount = 4096
        var noise = WakeNoise()
        let start = Date()
        var sent: Double = 0
        func emit(_ b: AVAudioPCMBuffer) {
            if let level = noiseDB { noise.add(to: b, db: level) }
            push(b)
            sent += Double(b.frameLength) / fmt.sampleRate
            let due = start.addingTimeInterval(sent / speed).timeIntervalSinceNow
            if due > 0 { Thread.sleep(forTimeInterval: due) }
        }
        func silence(_ seconds: TimeInterval) {
            var left = AVAudioFrameCount(seconds * fmt.sampleRate)
            while left > 0, isRunning {
                let n = min(chunk, left)
                guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
                b.frameLength = n
                if let d = b.floatChannelData { d[0].update(repeating: 0, count: Int(n)) }
                emit(b)
                left -= n
            }
        }
        silence(1.5)
        repeat {
            if files.isEmpty { silence(gap) }
            for (i, url) in files.enumerated() {
                guard isRunning else { return }
                onFile?(i, url)
                guard let file = try? AVAudioFile(forReading: url),
                      let conv = AVAudioConverter(from: file.processingFormat, to: fmt) else { continue }
                var done = false
                while !done, isRunning {
                    guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
                    var err: NSError?
                    conv.convert(to: out, error: &err) { n, status in
                        guard let inb = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n),
                              (try? file.read(into: inb, frameCount: n)) != nil, inb.frameLength > 0 else {
                            status.pointee = .endOfStream
                            return nil
                        }
                        status.pointee = .haveData
                        return inb
                    }
                    if out.frameLength == 0 { done = true; break }
                    emit(out)
                    if out.frameLength < chunk { done = true }
                }
                silence(gap)
            }
        } while loop && isRunning
        if isRunning { onEnd?() }
    }
}

/// Soft room tone (pink-ish noise) at a level.
struct WakeNoise {
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0
    private var seed: UInt32 = 0x1234_5678

    mutating func add(to buffer: AVAudioPCMBuffer, db: Float) {
        guard let d = buffer.floatChannelData else { return }
        let gain = powf(10, db / 20) * 3
        for i in 0..<Int(buffer.frameLength) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            d[0][i] += (b0 + b1 + b2 + white * 0.1848) * 0.05 * gain
        }
    }
}
#endif
