import Accelerate
import AVFoundation
import Foundation
import MacrophoneKit
import Speech

// The recording engine.
//
// - Two engines, both on-device (Oct 14 2026): SpeechAnalyzer + SpeechTranscriber (ModernSpeech,
//   iOS 26+: Apple's newer long-form model — one continuous analysis, words settle ~0.1 s after
//   the mic stops) whenever the language's model is installed; otherwise SFSpeechRecognizer with
//   `requiresOnDeviceRecognition`, while the newer model downloads for next time. Only languages
//   whose recognizer runs on the phone are offered (Languages.onDevice).
// - Long audio (the older engine): the microphone tap never stops; every ~45–55 s the request it feeds is
//   swapped for a fresh one (at a pause when there is one) and the old one is ended, so
//   the recognizer never sees one huge request. The segments' texts are stitched in order.
// - Limits (chosen, see docs/RECORDING.md): a warning at 5:00, a hard stop at 10:00.
// - Interruptions (a call, Siri, a route change, the app leaving the screen, the engine
//   resetting) stop the recording *early*: what was heard is finished, returned and sent.
// - No audio is ever written anywhere — buffers go straight from the tap to the recognizer.
// - Instant (Oct 17 2026): the mic opens the moment the finger lands — the session and engine
//   start on their own queue (never the main thread) while the analyzer starts beside them;
//   buffers heard before the recognizer is attached wait in `AudioFeed` and are handed over, so
//   the first syllable is never lost. The slow first-time work (the session's category, the input
//   unit, the speech model) is done ahead (`ready`, at launch and after each recording).

/// Mic level 0…1, written on the audio thread and read by the Filament every frame.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    var level: Float { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Float) { lock.lock(); value = v; lock.unlock() }
}

/// The words on screen, apart from the recorder's other state: a partial result redraws only
/// the views that show them (LiveWords, the destination line, the status line), not the whole
/// mic screen.
@MainActor
final class LiveTranscript: ObservableObject {
    struct Parts: Equatable {
        /// Words the recognizer has settled on.
        var settled = ""
        /// What it's hearing now — shown dimmer, revised until it settles.
        var pending = ""
        var text: String { Recorder.join(settled, pending) }
        var isEmpty: Bool { settled.isEmpty && pending.isEmpty }
    }
    @Published private(set) var parts = Parts()
    var text: String { parts.text }

    func set(settled: String, pending: String) {
        let p = Parts(settled: settled, pending: pending)
        if p != parts { parts = p }
    }
    func set(_ text: String) { set(settled: text, pending: "") }
    func clear() { set(settled: "", pending: "") }
}

/// The audio session and engine on their own serial queue: opening and closing the mic never
/// holds the main thread, and `ready` does the slow first-time work (the session's category, the
/// input unit) at launch rather than at the tap.
final class MicHardware: @unchecked Sendable {
    let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "macrophone.mic", qos: .userInteractive)
    private var configured = false
    private var tapInstalled = false

    /// Ahead of the tap: the session's category, once. (Not the input node: touched before the
    /// session is active it keeps a zero format, and the mic then can't open — seen on the simulator.)
    func ready() {
        queue.async { try? self.configure() }
    }

    private func configure() throws {
        // Set again after the Mac's sound had the session as `.playback` (MacAudioPlayer).
        guard !configured || AVAudioSession.sharedInstance().category != .record else { return }
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        configured = true
    }

    /// Activates the session, taps the input and starts the engine. Milliseconds for the log.
    func open(_ feed: AudioFeed) async throws -> (session: Int, engine: Int) {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<(session: Int, engine: Int), Error>) in
            queue.async {
                do { c.resume(returning: try self.openNow(feed)) } catch { c.resume(throwing: error) }
            }
        }
    }

    private func openNow(_ feed: AudioFeed) throws -> (session: Int, engine: Int) {
        let t0 = Date()
        do {
            try configure()
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw Recorder.StartError.audio
        }
        let t1 = Date()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A zero format (a call holds the mic) would raise an exception Swift can't catch.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Recorder.StartError.noInput }
        if tapInstalled { input.removeTap(onBus: 0) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Recorder.tapBlock(feed))
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw Recorder.StartError.audio
        }
        return (Int(t1.timeIntervalSince(t0) * 1000), Int(Date().timeIntervalSince(t1) * 1000))
    }

    /// Stops the engine and lets the session go (other apps' audio resumes).
    func close() {
        queue.async {
            if self.engine.isRunning { self.engine.stop() }
            if self.tapInstalled {
                self.engine.inputNode.removeTap(onBus: 0)
                self.tapInstalled = false
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Loudness → 0…1 against the room, not against a fixed dB line (the Mac's Hey Claude rule).
///
/// Why: the recorder runs the session in `.measurement` mode (no automatic gain, the cleanest
/// signal for the recognizer), where an iPhone's speech can sit anywhere from about −50 to −20 dBFS
/// depending on the mic, the room and the distance. The old fixed −52…−12 dB scale (then smoothed
/// twice, releasing slowly) left a quiet or distant voice near the bottom of it — on the simulator's
/// mic a voice peaking 13 dB over the room (−46 dBFS) read 0.15 — under a Filament whose voice swell was smaller than its
/// resting S. Here the floor is the room's own quiet (a low percentile of the last few seconds, so a
/// voice can't drag it up); 4 dB over it is the first movement and 28 dB over it is full scale, on a
/// gentle curve. Pure, so it can be checked without a mic.
struct LevelScale {
    /// Recent loudness, newest last (~4–6 s of buffers).
    private var recent: [Float] = []
    private(set) var floor: Float = -62
    /// The loudest recent voice, for diagnostics (not content: a number).
    private(set) var voicePeak: Float = -160

    static let span: Float = 24
    static let margin: Float = 4

    /// `warming`: the mic's first half second, while it ramps up from silence. It's not the room
    /// (it would hold the floor down for seconds) and not a voice (it would read as a shout).
    mutating func level(db: Float, warming: Bool = false) -> Float {
        guard db > -120, !warming else { return 0 }
        recent.append(db)
        if recent.count > 60 { recent.removeFirst(recent.count - 60) }
        let sorted = recent.sorted()
        // The room: the 10th percentile, between −75 dB (a mic still ramping up isn't a room) and
        // −28 dB (a loud room still leaves a voice room to move).
        floor = min(max(sorted[sorted.count / 10], -75), -28)
        // The next few buffers only learn the room.
        guard recent.count > 3 else { return 0 }
        if db > floor + 10 { voicePeak = max(voicePeak, db) }
        // A gentle curve lifts a quiet voice without flattening a loud one.
        return pow(min(max((db - floor - Self.margin) / Self.span, 0), 1), 0.8)
    }
}

/// The tap's side: which request the buffers go to, plus level and pause detection.
final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// The newer engine's input (set instead of `request`).
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var scale = LevelScale()
    private var lastLoud = Date.distantPast
    private var lastBuffer = Date.distantPast
    private var openedAt = Date.distantPast
    /// Audio heard before a recognizer was attached (the mic opens first; the analyzer starts
    /// beside it), handed over in order the moment one is. Copies, so the tap's buffers are never kept.
    private var held: [AVAudioPCMBuffer] = []
    private var holding = false
    /// About twelve seconds of 1024-frame buffers at 48 kHz — far more than a start ever takes.
    static let holdLimit = 600
    let meter: LevelMeter

    init(meter: LevelMeter) { self.meter = meter }

    /// Points the tap at a new request and returns the old one (to be ended). Audio held while
    /// nothing was attached goes into the new one first.
    func swap(_ r: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock(); defer { lock.unlock() }
        let old = request
        request = r
        if let r { for b in takeHeld() { r.append(b) } } else { stopHolding(); meter.set(0) }
        return old
    }

    /// Points the tap at the newer engine (nil detaches it). Held audio goes in first.
    func setSink(_ s: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        sink = s
        if let s { for b in takeHeld() { s(b) } } else { stopHolding(); meter.set(0) }
    }

    /// Seconds of audio waiting for a recognizer (a number for the log).
    var heldSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return held.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
    }

    /// Under the lock, so nothing arriving on the audio thread can jump the queue.
    private func takeHeld() -> [AVAudioPCMBuffer] {
        let h = held
        held.removeAll()
        holding = false
        return h
    }

    private func stopHolding() {
        held.removeAll()
        holding = false
    }

    /// A fresh recording: forget the last room, and keep what's heard until a recognizer is attached.
    func reset() {
        lock.lock()
        scale = LevelScale(); lastLoud = .distantPast; openedAt = Date()
        held.removeAll(); holding = true
        lock.unlock()
        meter.set(0)
    }

    /// Seconds since the voice was last above the quiet line.
    var quietFor: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastLoud) }

    /// The room and the loudest voice heard, in dBFS (diagnostics only).
    var levels: (room: Float, voice: Float) { lock.lock(); defer { lock.unlock() }; return (scale.floor, scale.voicePeak) }

    /// Called on the audio thread for every buffer.
    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let r = request
        let k = sink
        var kept = false
        if r == nil, k == nil, holding {
            if held.count < Self.holdLimit, let copy = Self.copy(buffer) { held.append(copy) }
            kept = true
        }
        lock.unlock()
        if !kept { if let k { k(buffer) } else { r?.append(buffer) } }

        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(ch, 1, &rms, vDSP_Length(n))
        let db = 20 * log10(max(rms, 1e-8))
        lock.lock()
        let now = Date()
        let x = scale.level(db: db, warming: now.timeIntervalSince(openedAt) < 0.5)
        lastBuffer = now
        if x > 0.22 { lastLoud = now }
        lock.unlock()
        // Raw (per buffer): the Filament smooths it — attack fast, release slow — at its frame rate.
        meter.set(x)
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        out.frameLength = b.frameLength
        let src = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
        }
        return out
    }
}

@MainActor
final class Recorder: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, finishing }

    enum StopReason: Equatable {
        case user
        case autoStop
        case hardCap
        /// Something outside the app ended it. The words are kept and sent; the item says "stopped early".
        case interrupted(String)
        /// The recognizer kept failing (e.g. its on-device assets aren't there). What was heard is kept.
        case recognizerFailed

        var isEarly: Bool {
            switch self {
            case .interrupted, .recognizerFailed: return true
            default: return false
            }
        }
    }

    struct Outcome {
        var raw: String
        var duration: TimeInterval
        var reason: StopReason
        var language: String
        var segments: Int
    }

    enum StartError: Error, Equatable {
        case micDenied
        case speechDenied
        case languageNotOnDevice
        case recognizerBusy
        case noInput
        case audio

        var message: String {
            switch self {
            case .micDenied: return "The microphone is off for Macrophone. Turn it on to dictate."
            case .speechDenied: return "Speech recognition is off for Macrophone. Turn it on to dictate."
            case .languageNotOnDevice: return "This iPhone can't transcribe that language by itself. Pick another in Settings › Language."
            case .recognizerBusy: return "Speech recognition isn't ready yet. Try again in a moment."
            case .noInput: return "No microphone is available right now — is a call using it?"
            case .audio: return "The microphone couldn't start. Try again."
            }
        }
        var needsSettings: Bool { self == .micDenied || self == .speechDenied }
    }

    // Limits. The recognizer is fed in segments, so these are about the person, not the engine.
    static let segmentTarget: TimeInterval = 45
    static let segmentMax: TimeInterval = 55
    static let softCap: TimeInterval = 5 * 60
    static let hardCap: TimeInterval = 10 * 60

    @Published private(set) var phase: Phase = .idle
    /// The words on screen (settled, then the ones still being decided), observed by the views that draw them.
    let words = LiveTranscript()
    /// Everything heard so far, stitched across segments.
    var transcript: String { words.text }
    /// The first word has shown (once per recording; the Filament goes from listening to live).
    @Published private(set) var hasWords = false
    /// When the mic opened (the timer counts from here).
    @Published private(set) var startedAt: Date?
    @Published private(set) var softCapReached = false

    let meter = LevelMeter()
    var log: DiagnosticLog?
    /// Called once per recording, after the recognizer has finished.
    var onFinish: ((Outcome) -> Void)?

    private final class Segment {
        let index: Int
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        /// Everything this segment heard: the utterances the recognizer already moved past,
        /// then the one it's on now.
        var text: String { Recorder.join(committed, current) }
        /// Utterances before the recognizer's last restart (see `TranscriptReset`).
        var committed = ""
        /// The recognizer's current result — it only ever covers the utterance it's on.
        var current = ""
        /// Where (seconds into this segment's audio) the current result starts and ends.
        var currentStart: Double?
        var currentEnd: Double = 0
        var done = false
        let startedAt = Date()
        init(index: Int, request: SFSpeechAudioBufferRecognitionRequest) { self.index = index; self.request = request }
    }

    private let hardware = MicHardware()
    private lazy var feed = AudioFeed(meter: meter)
    private var recognizer: SFSpeechRecognizer?
    /// The newer engine for this recording (a ModernSpeech on iOS 26+), when it's the one running.
    private var modern: AnyObject?
    private var language = "en-US"
    private var contextual: [String] = []
    private var autoStopDelay: TimeInterval?
    private var segments: [Segment] = []
    private var segmentStartedAt = Date()
    private var lastWordsAt: Date?
    private var failures = 0
    private var generation = 0
    private var tick: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// A stop that arrived while the mic was still starting (a quick second tap).
    private var pendingStop: StopReason?
    /// Seconds of voice heard (the simulator's stand-in words).
    private var voiced: TimeInterval = 0
    private var peakLevel: Float = 0
    private var lastLevelLog = Date.distantPast
    /// When the mic was asked for, so the log can say how long it took to open (a number, no words).
    private var openedAt = Date()
    /// Numbers for the log: when the first words showed, how many updates, the gaps between them.
    private var firstWordsAt: Date?
    private var wordUpdates = 0
    private var lastWordsUpdate = Date.distantPast
    private var wordGaps: [Int] = []

    /// DEBUG, simulator: the real microphone without the recognizer (it can't load its assets
    /// there), so the Filament can be proven against a real voice. `MACROPHONE_MIC_ONLY=1`;
    /// `MACROPHONE_MIC_WORDS=<text>` shows those words as the voice comes in.
    static var micOnly: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["MACROPHONE_MIC_ONLY"] == "1"
        #else
        return false
        #endif
    }
    static var micWords: [String]? {
        ProcessInfo.processInfo.environment["MACROPHONE_MIC_WORDS"].map { $0.split(separator: " ").map(String.init) }
    }

    var isActive: Bool { phase != .idle }

    // MARK: Permissions

    static var micStatus: AVAudioApplication.recordPermission { AVAudioApplication.shared.recordPermission }
    static var speechStatus: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    static func requestMic() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static func requestSpeech() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    // MARK: Start

    func start(language: String, contextualStrings: [String], autoStopAfter: TimeInterval?) async throws {
        guard phase == .idle else { return }
        phase = .starting
        pendingStop = nil
        openedAt = Date()
        do {
            try await begin(language: language, contextualStrings: contextualStrings, autoStopAfter: autoStopAfter)
        } catch {
            hardware.close()
            segments.forEach { $0.task?.cancel() }
            segments.removeAll()
            if #available(iOS 26.0, *), let m = modern as? ModernSpeech { m.cancel() }
            modern = nil
            feed.setSink(nil)
            phase = .idle
            log?.add("recording failed to start: \(error)")
            throw error
        }
        if let stop = pendingStop {
            pendingStop = nil
            self.stop(stop)
        }
    }

    /// DEBUG: `MACROPHONE_AUDIO_FILE=<path>` — that file stands in for the microphone (no mic,
    /// no permission prompts), played at real speed; the recording stops a moment after it ends.
    static var audioFile: String? {
        #if DEBUG
        // A bare name is in the app's Documents (copied there with devicectl).
        return ProcessInfo.processInfo.environment["MACROPHONE_AUDIO_FILE"].map {
            $0.hasPrefix("/") ? $0 : NSHomeDirectory() + "/Documents/" + $0
        }
        #else
        return nil
        #endif
    }

    private func begin(language: String, contextualStrings: [String], autoStopAfter: TimeInterval?) async throws {
        if Self.audioFile == nil {
        switch Self.micStatus {
        case .granted: break
        case .denied: throw StartError.micDenied
        default: guard await Self.requestMic() else { throw StartError.micDenied }
        }
        switch Self.speechStatus {
        case .authorized: break
        case .notDetermined: guard await Self.requestSpeech() else { throw StartError.speechDenied }
        default: throw StartError.speechDenied
        }
        }

        // The newer engine when its model is on the phone; else the older one (and fetch the model).
        var useModern = false
        if !Self.micOnly, #available(iOS 26.0, *) {
            let log = self.log
            if let known = ModernSpeech.isInstalled(language) { useModern = known }
            else { useModern = await ModernSpeech.isReady(language) { log?.add($0) } }
        }
        recognizer = nil
        if !Self.micOnly, !useModern { try useOlderRecognizer(language) }
        self.language = language
        contextual = Array(contextualStrings.prefix(DictionaryPass.maxTerms))
        autoStopDelay = autoStopAfter

        generation += 1
        segments.removeAll()
        words.clear()
        hasWords = false
        lastWordsAt = nil
        failures = 0
        softCapReached = false
        voiced = 0
        feed.reset()
        firstWordsAt = nil
        wordUpdates = 0
        wordGaps.removeAll()
        modern = nil
        let g = generation
        let hints = contextual

        // The analyzer starts beside the mic, not after it; the feed holds what's heard meanwhile.
        var analyzer: Task<(AnyObject, Bool)?, Never>?
        if useModern, #available(iOS 26.0, *) {
            analyzer = Task { [weak self] in
                guard let m = await ModernSpeech.start(language: language, contextualStrings: hints,
                                                       onText: { s, p in self?.heard(settled: s, pending: p, generation: g) }) else { return nil }
                return (m.0, m.warm)
            }
        } else {
            _ = feed.swap(newSegment().request)
        }
        segmentStartedAt = Date()

        if let fileInput = Self.audioFile {
            playFile(fileInput)
            log?.add("test file playing \(Int(Date().timeIntervalSince(openedAt) * 1000)) ms after the tap")
        } else {
            do {
                let t = try await hardware.open(feed)
                log?.add("mic open \(Int(Date().timeIntervalSince(openedAt) * 1000)) ms after the tap (session \(t.session) ms, engine \(t.engine) ms)")
            } catch {
                // The analyzer starting beside it has nothing to listen to: let it go.
                if let analyzer, #available(iOS 26.0, *) {
                    Task { if let (m, _) = await analyzer.value, let m = m as? ModernSpeech { m.cancel() } }
                }
                throw error
            }
        }
        startedAt = Date()
        observe()

        var engineNote = "SFSpeechRecognizer"
        if let analyzer, #available(iOS 26.0, *) {
            if let (m, warm) = await analyzer.value, generation == g, let m = m as? ModernSpeech {
                let held = feed.heldSeconds
                modern = m
                feed.setSink { m.sink.feed($0) }
                engineNote = "SpeechAnalyzer, \(warm ? "made ahead" : "made now"), listening \(Int(Date().timeIntervalSince(openedAt) * 1000)) ms after the tap, \(String(format: "%.2f", held)) s held for it"
            } else if generation == g {
                log?.add("newer speech engine couldn't start; using the older one")
                try useOlderRecognizer(language)
                _ = feed.swap(newSegment().request)
            } else {
                return
            }
        }
        phase = .recording
        startTicking()
        log?.add("recording started (\(language), \(contextual.count) hints, \(engineNote))")
    }

    /// DEBUG stand-in microphone: the file's buffers at real speed, then a stop.
    private func playFile(_ path: String) {
        let feed = self.feed
        let g = generation
        Task.detached { [weak self] in
            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return }
            let fmt = file.processingFormat
            while true {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024) else { break }
                do { try file.read(into: buf, frameCount: 1024) } catch { break }
                if buf.frameLength == 0 { break }
                feed.consume(buf)
                try? await Task.sleep(nanoseconds: UInt64(Double(buf.frameLength) / fmt.sampleRate * 1e9))
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run { if self?.generation == g { self?.stop(.user) } }
        }
    }

    private func useOlderRecognizer(_ language: String) throws {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: language)), r.supportsOnDeviceRecognition else {
            throw StartError.languageNotOnDevice
        }
        guard r.isAvailable else { throw StartError.recognizerBusy }
        recognizer = r
    }

    /// The newer engine's words so far: settled, and the ones still being decided.
    private func heard(settled: String, pending: String, generation g: Int) {
        guard g == generation, phase == .recording || phase == .finishing || phase == .starting else { return }
        let before = words.parts
        words.set(settled: settled, pending: pending)
        guard words.parts != before else { return }
        noteWords()
        if phase == .recording { lastWordsAt = Date() }
    }

    /// One more update of the words on screen (timing only, nothing of what was said).
    private func noteWords() {
        let now = Date()
        if !hasWords, !words.parts.isEmpty { hasWords = true }
        if firstWordsAt == nil { firstWordsAt = now }
        else { wordGaps.append(Int(now.timeIntervalSince(lastWordsUpdate) * 1000)) }
        lastWordsUpdate = now
        wordUpdates += 1
    }

    private var wordsTimingLine: String {
        guard let first = firstWordsAt else { return "no words" }
        let sorted = wordGaps.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        return "first words \(Int(first.timeIntervalSince(openedAt) * 1000)) ms after the tap, \(wordUpdates) updates, median gap \(median) ms"
    }

    /// Ahead of the next recording: the audio session's category and input unit, and the newer
    /// engine's analyzer with the model loaded (fetching the model when it isn't on the phone).
    /// At launch, when the app comes back, and after every recording.
    func ready(language: String, contextualStrings: [String]) {
        guard Self.audioFile == nil else { return }
        // Nothing touches the hardware before he has allowed the mic (no prompt from here).
        if Self.micStatus == .granted { hardware.ready() }
        guard #available(iOS 26.0, *), !Self.micOnly else { return }
        let log = self.log
        let hints = Array(contextualStrings.prefix(DictionaryPass.maxTerms))
        Task(priority: .utility) {
            guard await ModernSpeech.isReady(language, log: { log?.add($0) }) else { return }
            let t0 = Date()
            await ModernSpeech.warm(language: language, contextualStrings: hints)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if ms > 20 { log?.add("speech engine ready ahead in \(ms) ms") }
        }
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    nonisolated static func tapBlock(_ feed: AudioFeed) -> AVAudioNodeTapBlock {
        { buffer, _ in feed.consume(buffer) }
    }

    private nonisolated static func resultHandler(_ owner: Recorder, index: Int, generation: Int) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let words = result?.bestTranscription.segments
            let start = words?.first.map { $0.timestamp }
            let end = words?.last.map { $0.timestamp + $0.duration } ?? 0
            let final = (result?.isFinal ?? false) || error != nil
            let ns = error as NSError?
            let code = ns?.code
            let domain = ns?.domain
            Task { @MainActor in owner?.update(index: index, generation: generation, text: text, start: start, end: end, final: final, errorCode: code, errorDomain: domain) }
        }
    }

    private func newSegment() -> Segment {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        #if DEBUG && targetEnvironment(simulator)
        // The simulator often can't load on-device speech assets (error 300). For exercising the
        // pipeline only, MACROPHONE_SIM_SERVER_SPEECH=1 lets it use Apple's server instead.
        if ProcessInfo.processInfo.environment["MACROPHONE_SIM_SERVER_SPEECH"] == "1" { req.requiresOnDeviceRecognition = false }
        #endif
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = contextual
        let seg = Segment(index: segments.count, request: req)
        segments.append(seg)
        seg.task = recognizer?.recognitionTask(with: req, resultHandler: Self.resultHandler(self, index: seg.index, generation: generation))
        return seg
    }

    private func update(index: Int, generation g: Int, text: String?, start: Double? = nil, end: Double = 0,
                        final: Bool, errorCode: Int?, errorDomain: String? = nil) {
        guard g == generation, index < segments.count else { return }
        let seg = segments[index]
        if let text, !text.isEmpty, text != seg.current {
            // After a pause the on-device recognizer quietly starts a new utterance: its next
            // result holds only the new words. Keep what it heard before instead of losing it.
            if TranscriptReset.isRestart(previous: seg.current, previousStart: seg.currentStart, previousEnd: seg.currentEnd,
                                         next: text, nextStart: start) {
                seg.committed = Recorder.join(seg.committed, seg.current)
                log?.add("recognizer started a new utterance after a pause; kept the earlier words")
            }
            // Some results (often the final one) repeat the whole segment, earlier words included:
            // then they're no longer separate.
            if !seg.committed.isEmpty, TranscriptReset.repeats(committed: seg.committed, in: text) { seg.committed = "" }
            seg.current = text
            seg.currentStart = start
            seg.currentEnd = end
            if phase == .recording { lastWordsAt = Date() }
            let parts = stitchedParts()
            words.set(settled: parts.settled, pending: parts.pending)
            noteWords()
        }
        guard final, !seg.done else { return }
        seg.done = true
        if let errorCode { log?.add("segment \(index) ended with \(errorDomain ?? "?") \(errorCode)") }
        // The live segment ended on its own while still recording: keep listening in a new one.
        if phase == .recording, index == segments.count - 1 {
            if errorCode != nil, Date().timeIntervalSince(seg.startedAt) < 1.5 { failures += 1 } else { failures = 0 }
            if failures >= 4 {
                log?.add("recognizer keeps failing; stopping")
                stop(.recognizerFailed)
                return
            }
            rotate()
        }
    }

    nonisolated static func join(_ a: String, _ b: String) -> String {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines), y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty { return y }
        if y.isEmpty { return x }
        return x + " " + y
    }

    private func stitched() -> String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The older engine's words: everything before the utterance it's on, and that one (still changing).
    private func stitchedParts() -> (settled: String, pending: String) {
        guard let live = segments.last else { return ("", "") }
        let earlier = segments.dropLast().map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        return (Self.join(earlier, live.committed), live.current)
    }

    /// Starts a fresh request for the tap and ends the old one. The mic never stops.
    private func rotate() {
        let seg = newSegment()
        let old = feed.swap(seg.request)
        old?.endAudio()
        segmentStartedAt = Date()
        log?.add("segment \(seg.index) started")
    }

    private func startTicking() {
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.onTick()
            }
        }
    }

    private func onTick() {
        guard phase == .recording, let startedAt else { return }
        #if DEBUG
        if Self.micOnly {
            // Proof against a real voice: once a second, the loudest level and the room (numbers only).
            peakLevel = max(peakLevel, meter.level)
            if Date().timeIntervalSince(lastLevelLog) >= 1 {
                let lv = feed.levels
                log?.add(String(format: "mic level %.2f (room %.0f dB, voice %.0f dB)", peakLevel, lv.room, lv.voice))
                peakLevel = 0
                lastLevelLog = Date()
            }
        }
        if Self.micOnly, let standIn = Self.micWords {
            // The real mic, stand-in words: one word per ~0.28 s of voice, so the screen goes from
            // listening to capturing exactly as speech starts.
            if meter.level > 0.2 { voiced += 0.1 }
            let shown = min(standIn.count, Int(voiced / 0.28))
            let text = standIn.prefix(shown).joined(separator: " ")
            if text != transcript { words.set(text); hasWords = !text.isEmpty; lastWordsAt = Date() }
        }
        #endif
        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        if elapsed >= Self.hardCap { stop(.hardCap); return }
        if elapsed >= Self.softCap, !softCapReached { softCapReached = true; log?.add("soft cap reached") }
        if let delay = autoStopDelay, let last = lastWordsAt, now.timeIntervalSince(last) >= delay {
            stop(.autoStop)
            return
        }
        guard modern == nil else { return }
        let seg = now.timeIntervalSince(segmentStartedAt)
        if (seg >= Self.segmentTarget && feed.quietFor >= 0.35) || seg >= Self.segmentMax { rotate() }
    }

    // MARK: Stop

    func stop(_ reason: StopReason = .user) {
        switch phase {
        case .starting:
            pendingStop = reason
            return
        case .recording:
            break
        default:
            return
        }
        phase = .finishing
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        tick?.cancel()
        tick = nil
        removeObservers()
        hardware.close()
        feed.swap(nil)?.endAudio()
        feed.setSink(nil)
        let g = generation
        let count = max(segments.count, modern == nil ? 0 : 1)
        let lv = feed.levels
        log?.add("recording stopped (\(reason.logName), \(Int(duration))s, \(modern == nil ? "\(count) segment(s)" : "SpeechAnalyzer")); mic: room \(Int(lv.room)) dB, voice \(lv.voice > -150 ? "\(Int(lv.voice)) dB" : "none"); \(wordsTimingLine)")

        if #available(iOS 26.0, *), let m = modern as? ModernSpeech {
            modern = nil
            Task { [weak self] in
                let t0 = Date()
                let raw = await m.finish(timeout: reason.isEarly ? 2.0 : 3.0)
                guard let self, self.generation == g else { return }
                self.log?.add("words settled in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                if !raw.isEmpty { self.words.set(raw) }
                self.generation += 1
                self.phase = .idle
                self.startedAt = nil
                self.onFinish?(Outcome(raw: raw, duration: duration, reason: reason, language: self.language, segments: 1))
                self.ready(language: self.language, contextualStrings: self.contextual)
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            // The recognizer finishes the last words after endAudio; give it a moment.
            let t0 = Date()
            let deadline = Date().addingTimeInterval(reason.isEarly ? 2.0 : 3.0)
            while Date() < deadline, self.generation == g, self.segments.contains(where: { !$0.done && $0.task != nil }) {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard self.generation == g else { return }
            if self.segments.contains(where: { !$0.done && $0.task != nil }) { self.log?.add("recognizer slow to finish; using what it had") }
            self.log?.add("words settled in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            let raw = self.stitched()
            self.segments.forEach { $0.task?.cancel() }
            self.segments.removeAll()
            self.generation += 1
            self.phase = .idle
            self.startedAt = nil
            self.onFinish?(Outcome(raw: raw, duration: duration, reason: reason, language: self.language, segments: count))
            self.ready(language: self.language, contextualStrings: self.contextual)
        }
    }

    // MARK: Interruptions

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.stop(.interrupted("A call or another app took the microphone")) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
            MainActor.assumeIsolated { self?.stop(.interrupted("The microphone changed")) }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: hardware.engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(.interrupted("The microphone changed")) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(.interrupted("Audio was reset by iOS")) }
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: Debug

    #if DEBUG
    /// Drives the screen as if someone were talking: levels, words appearing, a timer.
    func simulate(_ text: String, seconds: TimeInterval = 600) {
        phase = .recording
        startedAt = Date().addingTimeInterval(-14)
        self.words.clear()
        hasWords = false
        let spoken = text.split(separator: " ").map(String.init)
        Task { [weak self] in
            var t = 0.0
            var shown = 0
            while let self, self.phase == .recording, t < seconds {
                t += 0.05
                // Syllables (~5 a second) inside phrases, a breath every few seconds (Hey Claude's stand-in voice).
                let phrase = max(0, sin(t * 2.1)) > 0.15 ? 1.0 : 0.12
                let v = max(0, sin(t * 5.3)) * (0.6 + 0.35 * sin(t * 0.9)) * phrase + 0.04
                self.meter.set(Float(min(max(v, 0), 1)))
                if shown < spoken.count, Int(t * 6) > shown {
                    shown += 1
                    // The last two words still being decided, like a real partial result.
                    let settled = spoken.prefix(max(0, shown - 2)).joined(separator: " ")
                    self.words.set(settled: settled, pending: spoken[max(0, shown - 2)..<shown].joined(separator: " "))
                    self.hasWords = true
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Puts words on screen as if they had just been heard.
    func debugShow(_ text: String) { words.set(text); hasWords = !text.isEmpty }

    func endSimulation() {
        phase = .idle
        startedAt = nil
        meter.set(0)
    }
    #endif
}

extension Recorder.StopReason {
    var logName: String {
        switch self {
        case .user: return "user"
        case .autoStop: return "auto-stop"
        case .hardCap: return "limit"
        case .interrupted: return "interrupted"
        case .recognizerFailed: return "recognizer failed"
        }
    }
}

/// Tells a recognizer that started over (a new utterance after a pause) from one that is just
/// revising the words it's on. Pure, so it's unit-tested.
enum TranscriptReset {
    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    /// True when `text` begins with the words already kept (the recognizer re-included them).
    static func repeats(committed: String, in text: String) -> Bool {
        let c = words(committed), t = words(text)
        guard !c.isEmpty, t.count >= c.count else { return false }
        let n = c.count
        let same = (0..<n).filter { c[$0] == t[$0] }.count
        return Double(same) >= Double(n) * 0.8
    }

    static func isRestart(previous: String, previousStart: Double?, previousEnd: Double, next: String, nextStart: Double?) -> Bool {
        let a = words(previous), b = words(next)
        guard !a.isEmpty, !b.isEmpty else { return false }
        // Best signal: the new result's first word starts after the old result's audio ended.
        if let s0 = nextStart, let p0 = previousStart, previousEnd > 0, s0 > p0 + 0.05, s0 >= previousEnd - 0.25 { return true }
        // Otherwise: a revision keeps the beginning (it grows or corrects words). A restart
        // doesn't: it is shorter and its first words aren't the old first words.
        if b.count > a.count { return false }
        let n = min(3, a.count, b.count)
        let samePositions = (0..<n).filter { a[$0] == b[$0] }.count
        if samePositions > 0 { return false }
        // A one-word shift at the start ("okay so" → "so") is still a revision.
        if a.count > 1, b.first == a[1] { return false }
        if b.count > 1, a.first == b[1] { return false }
        return a.count >= 2
    }
}
