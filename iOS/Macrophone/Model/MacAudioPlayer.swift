import AVFoundation
import Combine
import MacrophoneKit
import UIKit
import os

/// The Mac's sound in the window view (Oct 19 2026). Off by default and every time it isn't
/// explicitly on (`SoundSetting`, Sameer's rule): only a tap on Sound turns it on, and only then
/// does this phone ask the Mac for it (`watchSound(true)`) — the Mac sends nothing otherwise.
///
/// While on, it plays only when all of it holds: a window shows (the watch is live or starting),
/// the app is in front, the mic is closed, and the Mac names MacSound.feature. Anything else stops
/// it and tells the Mac; it comes back by itself when they hold again.
///
/// The audio session: `.playback` with `.mixWithOthers`, only while the sound plays. Playback, not
/// ambient, because the person turned Sound on — the silent switch silencing what they just asked
/// for would read as broken; mixing, so the Mac never stops a podcast already playing here. When
/// the mic opens it stops at once (the recorder sets its own `.record` session), and resumes a
/// moment after the mic closes.
@MainActor
final class MacAudioPlayer: ObservableObject {
    /// The Sound switch (remembered; off unless the person turned it on).
    @Published private(set) var isOn: Bool
    /// The connected Mac sends its sound.
    @Published private(set) var macCanPlay = false
    /// Playing now (every condition holds).
    @Published private(set) var playing = false

    private let core = SoundCore()
    private weak var client: LinkClient?
    private var watching = false
    private var micOpen = false
    private var foreground = true
    private var remote = false
    private var bag = Set<AnyCancellable>()
    private var micClosed: Task<Void, Never>?

    var log: DiagnosticLog? {
        didSet { core.log = log }
    }

    init() {
        isOn = SoundSetting.isOn(in: .standard)
        #if DEBUG
        // MACROPHONE_SOUND=1 holds it on for a run (nothing stored — a real launch reads off).
        if DebugHooks.env["MACROPHONE_SOUND"] == "1" { isOn = true }
        #endif
        let nc = NotificationCenter.default
        nc.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in self?.setForeground(false) }.store(in: &bag)
        nc.publisher(for: UIApplication.willEnterForegroundNotification).sink { [weak self] _ in self?.setForeground(true) }.store(in: &bag)
    }

    /// The link the packets come over (again after the client is made anew).
    func attach(_ client: LinkClient) {
        self.client = client
        let core = self.core
        client.onMacAudio = { core.receive($0) }
        update()
    }

    /// What decides whether it plays: the window, the mic, the path, the link.
    func bind(watcher: Watcher, recorderPhase: AnyPublisher<Recorder.Phase, Never>, remote: AnyPublisher<Bool, Never>,
              link: AnyPublisher<LinkClient.State, Never>) {
        watcher.$isOpen.combineLatest(watcher.$phase)
            .map { open, phase in open && (phase == .live || phase == .starting) }
            .removeDuplicates()
            .sink { [weak self] in self?.watching = $0; self?.update() }
            .store(in: &bag)
        recorderPhase.map { $0 != .idle }.removeDuplicates().sink { [weak self] open in
            guard let self else { return }
            self.recorderActive = open
            if open { self.micOpening() } else { self.micDidClose() }
        }.store(in: &bag)
        remote.removeDuplicates().sink { [weak self] r in
            guard let self, r != self.remote else { return }
            self.remote = r
            // Away from home: a lower bitrate from the Mac and a deeper buffer here.
            if self.playing { self.restart() }
        }.store(in: &bag)
        link.sink { [weak self] _ in self?.update() }.store(in: &bag)
    }

    /// The Sound button — the only way it turns on.
    func toggle() {
        isOn.toggle()
        SoundSetting.set(isOn, in: .standard)
        Haptics.tick()
        log?.add("sound \(isOn ? "on" : "off")")
        update()
    }

    /// The mic is about to open: stop now, before the recorder takes the session.
    func micOpening() {
        micClosed?.cancel()
        if !micOpen {
            micOpen = true
            update()
        }
        // The mic didn't open after all (a permission, a call): the sound comes back.
        micClosed = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, !self.recorderActive else { return }
            self.micOpen = false
            self.update()
        }
    }
    private var recorderActive = false

    private func micDidClose() {
        micClosed?.cancel()
        // A moment after the mic lets go of the session.
        micClosed = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.micOpen = false
            self.update()
        }
    }

    private func setForeground(_ f: Bool) {
        foreground = f
        update()
    }

    private func update() {
        let can = client?.macCanPlaySound ?? false
        if can != macCanPlay { macCanPlay = can }
        let want = isOn && watching && !micOpen && foreground && can
        guard want != playing else { return }
        playing = want
        if want {
            core.start(remote: remote)
            _ = client?.watchSound(true)
        } else {
            _ = client?.watchSound(false)
            core.stop(deactivate: !micOpen)
        }
    }

    private func restart() {
        _ = client?.watchSound(false)
        core.stop(deactivate: false)
        core.start(remote: remote)
        _ = client?.watchSound(true)
    }
}

/// The playback itself, off the main actor: packets land on the link's queue, are decoded there
/// and pushed into the jitter buffer; the output pulls from it on the audio thread. One lock
/// (an unfair lock, held only to copy frames) between the two.
final class SoundCore: @unchecked Sendable {
    var log: DiagnosticLog?
    private let queue = DispatchQueue(label: "macrophone.mac-sound", qos: .userInteractive)
    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`:
    private var jitter = SoundJitter(target: MacSound.targetFrames(remote: false), ceiling: MacSound.ceilingFrames(remote: false))
    private var active = false
    private var latency = SoundLatency()
    private var outputDelay = 0.0
    // The link's queue only:
    private var decoder: MacAudioDecoder?
    private var decoderStream: UInt32?
    private var decodeMicros: [Int] = []
    private var bytes = 0
    // `queue` only:
    private var engine: AVAudioEngine?
    private var startedAt = Date()
    private var observers: [NSObjectProtocol] = []
    /// Interleaved frames the output copies out of the buffer (the audio thread only).
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * MacSound.channels)

    #if DEBUG
    private static let timing = DebugHooks.env["MACROPHONE_SOUND_TIMING"] == "1"
    #else
    private static let timing = false
    #endif

    deinit { scratch.deallocate() }

    func start(remote: Bool) {
        queue.async { self.startNow(remote: remote) }
    }

    func stop(deactivate: Bool) {
        lock.withLock { active = false }
        queue.async { self.stopNow(deactivate: deactivate) }
    }

    private func startNow(remote: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // Small output buffers: the sound lands sooner (the jitter buffer does the holding).
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            log?.add("sound: the audio session didn't start")
            return
        }
        let engine = self.engine ?? makeEngine()
        lock.withLock {
            jitter = SoundJitter(target: MacSound.targetFrames(remote: remote), ceiling: MacSound.ceilingFrames(remote: remote))
            latency = SoundLatency()
            outputDelay = session.outputLatency + session.ioBufferDuration
            active = true
        }
        decodeMicros = []
        bytes = 0
        startedAt = Date()
        do {
            engine.prepare()
            try engine.start()
        } catch {
            log?.add("sound: the output didn't start")
        }
    }

    private func stopNow(deactivate: Bool) {
        engine?.stop()
        let (stats, summary, count) = lock.withLock { () -> (SoundJitter.Stats, String, Int) in
            let r = (jitter.stats, latency.summary, latency.count)
            jitter.reset()
            return r
        }
        if count > 0 {
            let d = decodeMicros.sorted()
            let seconds = max(1, Date().timeIntervalSince(startedAt))
            log?.add("sound: \(stats.packets) packets, \(Int(Double(bytes * 8) / seconds / 1000)) kbps · latency estimate \(summary) · "
                     + "underruns \(stats.underruns) · late \(stats.late) · trimmed \(stats.trimmedFrames * 1000 / MacSound.sampleRate) ms · "
                     + "gaps \(stats.gaps) · resyncs \(stats.resyncs) · decode median \(d.isEmpty ? 0 : d[d.count / 2]) µs")
        }
        // Let the session go only when it's still this one (the mic's recorder may have it now).
        if deactivate, AVAudioSession.sharedInstance().category == .playback {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(MacSound.sampleRate), channels: AVAudioChannelCount(MacSound.channels))!
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, list -> OSStatus in
            self.render(Int(frameCount), into: UnsafeMutableAudioBufferListPointer(list))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        self.engine = engine
        let nc = NotificationCenter.default
        // A route change (headphones, a call) rebuilds the output: start again if still wanted.
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.resumeIfWanted() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.queue.async { self?.resumeIfWanted() }
        })
        return engine
    }

    private func resumeIfWanted() {
        guard lock.withLock({ active }), let engine, !engine.isRunning,
              AVAudioSession.sharedInstance().category == .playback else { return }
        lock.withLock { jitter.reset() }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    /// The audio thread: frames out of the buffer, split into the output's two channels.
    private func render(_ frames: Int, into list: UnsafeMutableAudioBufferListPointer) {
        guard list.count >= 2, let left = list[0].mData?.assumingMemoryBound(to: Float.self),
              let right = list[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        var done = 0
        while done < frames {
            let n = min(frames - done, 4096)
            lock.withLock { _ = jitter.pull(into: scratch, frames: n) }
            for i in 0..<n {
                left[done + i] = scratch[i * 2]
                right[done + i] = scratch[i * 2 + 1]
            }
            done += n
        }
    }

    /// The link's queue: a packet from the Mac.
    func receive(_ p: MacAudioPacket) {
        guard lock.withLock({ active }) else { return }
        let arrived = Date().timeIntervalSince1970
        let t0 = DispatchTime.now()
        // A new stream is a new encoder: its decoder is made from the set-up it sends.
        if decoder == nil || decoderStream != p.stream || decoder?.codec != p.codec {
            guard let config = p.config else { return }
            decoder = try? MacAudioDecoder(codec: p.codec, config: config)
            decoderStream = p.stream
        }
        guard let samples = decoder?.decode(p) else { return }
        if decodeMicros.count < 20_000 { decodeMicros.append(Int((DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1000)) }
        bytes += p.packets.reduce(0) { $0 + $1.count }
        let line: String? = lock.withLock {
            let held = jitter.buffered
            jitter.push(samples, seq: p.seq, stream: p.stream, sampleTime: p.sampleTime)
            // The packet's first frame plays after what was held before it (the target, while filling).
            let buffered = jitter.playing ? held : max(held, jitter.target)
            latency.add(.init(mac: p.macDelay, wire: SoundLatency.wire(sentAt: p.sentAt, arrivedAt: arrived),
                              buffer: Double(buffered) / Double(MacSound.sampleRate), output: outputDelay))
            guard Self.timing, p.seq % 50 == 0 else { return nil }
            let s = jitter.stats
            return "[sound] #\(p.seq) held \(jitter.buffered * 1000 / MacSound.sampleRate) ms · latency \(latency.summary) · underruns \(s.underruns) · late \(s.late) · gaps \(s.gaps)"
        }
        if let line { print(line); fflush(stdout) }
    }
}
