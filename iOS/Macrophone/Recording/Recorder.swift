import Accelerate
import AVFoundation
import Foundation
import MacrophoneKit
import Speech

// The recording engine.
//
// - On-device only: every request sets `requiresOnDeviceRecognition`, and only languages
//   whose recognizer supports it are offered (Languages.onDevice).
// - Long audio: the microphone tap never stops; every ~45–55 s the request it feeds is
//   swapped for a fresh one (at a pause when there is one) and the old one is ended, so
//   the recognizer never sees one huge request. The segments' texts are stitched in order.
// - Limits (chosen, see docs/RECORDING.md): a warning at 5:00, a hard stop at 10:00.
// - Interruptions (a call, Siri, a route change, the app leaving the screen, the engine
//   resetting) stop the recording *early*: what was heard is finished, returned and sent.
// - No audio is ever written anywhere — buffers go straight from the tap to the recognizer.

/// Mic level 0…1, written on the audio thread and read by the Filament every frame.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    var level: Float { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Float) { lock.lock(); value = v; lock.unlock() }
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

    mutating func level(db: Float) -> Float {
        guard db > -120 else { return 0 }   // digital silence (the mic starting up)
        recent.append(db)
        if recent.count > 60 { recent.removeFirst(recent.count - 60) }
        let sorted = recent.sorted()
        // The room: the 10th percentile, never louder than −28 dB (a loud room still leaves a voice room to move).
        floor = min(sorted[sorted.count / 10], -28)
        if db > floor + 10 { voicePeak = max(voicePeak, db) }
        // A gentle curve lifts a quiet voice without flattening a loud one.
        return pow(min(max((db - floor - Self.margin) / Self.span, 0), 1), 0.8)
    }
}

/// The tap's side: which request the buffers go to, plus level and pause detection.
final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var scale = LevelScale()
    private var lastLoud = Date.distantPast
    private var lastBuffer = Date.distantPast
    let meter: LevelMeter

    init(meter: LevelMeter) { self.meter = meter }

    /// Points the tap at a new request and returns the old one (to be ended).
    func swap(_ r: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock(); defer { lock.unlock() }
        let old = request
        request = r
        if r == nil { meter.set(0) }
        return old
    }

    /// A fresh recording: forget the last room.
    func reset() {
        lock.lock(); scale = LevelScale(); lastLoud = .distantPast; lock.unlock()
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
        lock.unlock()
        r?.append(buffer)

        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(ch, 1, &rms, vDSP_Length(n))
        let db = 20 * log10(max(rms, 1e-8))
        lock.lock()
        let x = scale.level(db: db)
        let now = Date()
        lastBuffer = now
        if x > 0.22 { lastLoud = now }
        lock.unlock()
        // Raw (per buffer): the Filament smooths it — attack fast, release slow — at its frame rate.
        meter.set(x)
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
    /// Everything heard so far, stitched across segments.
    @Published private(set) var transcript = ""
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
        var text = ""
        var done = false
        let startedAt = Date()
        init(index: Int, request: SFSpeechAudioBufferRecognitionRequest) { self.index = index; self.request = request }
    }

    private let engine = AVAudioEngine()
    private lazy var feed = AudioFeed(meter: meter)
    private var recognizer: SFSpeechRecognizer?
    private var language = "en-US"
    private var contextual: [String] = []
    private var autoStopDelay: TimeInterval?
    private var segments: [Segment] = []
    private var segmentStartedAt = Date()
    private var lastWordsAt: Date?
    private var failures = 0
    private var tapInstalled = false
    private var generation = 0
    private var tick: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// A stop that arrived while the mic was still starting (a quick second tap).
    private var pendingStop: StopReason?
    /// Seconds of voice heard (the simulator's stand-in words).
    private var voiced: TimeInterval = 0

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
        do {
            try await begin(language: language, contextualStrings: contextualStrings, autoStopAfter: autoStopAfter)
        } catch {
            teardownAudio()
            segments.forEach { $0.task?.cancel() }
            segments.removeAll()
            phase = .idle
            log?.add("recording failed to start: \(error)")
            throw error
        }
        if let stop = pendingStop {
            pendingStop = nil
            self.stop(stop)
        }
    }

    private func begin(language: String, contextualStrings: [String], autoStopAfter: TimeInterval?) async throws {
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

        if Self.micOnly {
            recognizer = nil
        } else {
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: language)), r.supportsOnDeviceRecognition else {
                throw StartError.languageNotOnDevice
            }
            guard r.isAvailable else { throw StartError.recognizerBusy }
            recognizer = r
        }
        self.language = language
        contextual = Array(contextualStrings.prefix(DictionaryPass.maxTerms))
        autoStopDelay = autoStopAfter

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw StartError.audio
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A zero format (a call holds the mic) would raise an exception Swift can't catch.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw StartError.noInput }

        generation += 1
        segments.removeAll()
        transcript = ""
        lastWordsAt = nil
        failures = 0
        softCapReached = false
        voiced = 0
        feed.reset()
        _ = feed.swap(newSegment().request)
        segmentStartedAt = Date()

        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(feed))
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch { throw StartError.audio }

        startedAt = Date()
        phase = .recording
        observe()
        startTicking()
        log?.add("recording started (\(language), \(contextual.count) hints)")
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    private nonisolated static func tapBlock(_ feed: AudioFeed) -> AVAudioNodeTapBlock {
        { buffer, _ in feed.consume(buffer) }
    }

    private nonisolated static func resultHandler(_ owner: Recorder, index: Int, generation: Int) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let final = (result?.isFinal ?? false) || error != nil
            let ns = error as NSError?
            let code = ns?.code
            let domain = ns?.domain
            Task { @MainActor in owner?.update(index: index, generation: generation, text: text, final: final, errorCode: code, errorDomain: domain) }
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

    private func update(index: Int, generation g: Int, text: String?, final: Bool, errorCode: Int?, errorDomain: String? = nil) {
        guard g == generation, index < segments.count else { return }
        let seg = segments[index]
        if let text, !text.isEmpty, text != seg.text {
            seg.text = text
            if phase == .recording { lastWordsAt = Date() }
            transcript = stitched()
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

    private func stitched() -> String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
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
        if Self.micOnly, let words = Self.micWords {
            // The real mic, stand-in words: one word per ~0.28 s of voice, so the screen goes from
            // listening to capturing exactly as speech starts.
            if meter.level > 0.2 { voiced += 0.1 }
            let shown = min(words.count, Int(voiced / 0.28))
            let text = words.prefix(shown).joined(separator: " ")
            if text != transcript { transcript = text; lastWordsAt = Date() }
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
        teardownAudio()
        feed.swap(nil)?.endAudio()
        let g = generation
        let count = segments.count
        let lv = feed.levels
        log?.add("recording stopped (\(reason.logName), \(Int(duration))s, \(count) segment(s)); mic: room \(Int(lv.room)) dB, voice \(lv.voice > -150 ? "\(Int(lv.voice)) dB" : "none")")

        Task { [weak self] in
            guard let self else { return }
            // The recognizer finishes the last words after endAudio; give it a moment.
            let deadline = Date().addingTimeInterval(reason.isEarly ? 2.0 : 3.0)
            while Date() < deadline, self.generation == g, self.segments.contains(where: { !$0.done && $0.task != nil }) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard self.generation == g else { return }
            if self.segments.contains(where: { !$0.done }) { self.log?.add("recognizer slow to finish; using what it had") }
            let raw = self.stitched()
            self.segments.forEach { $0.task?.cancel() }
            self.segments.removeAll()
            self.generation += 1
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.phase = .idle
            self.startedAt = nil
            self.onFinish?(Outcome(raw: raw, duration: duration, reason: reason, language: self.language, segments: count))
        }
    }

    private func teardownAudio() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
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
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
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
        let words = text.split(separator: " ").map(String.init)
        Task { [weak self] in
            var t = 0.0
            var shown = 0
            while let self, self.phase == .recording, t < seconds {
                t += 0.05
                // Syllables (~5 a second) inside phrases, a breath every few seconds (Hey Claude's stand-in voice).
                let phrase = max(0, sin(t * 2.1)) > 0.15 ? 1.0 : 0.12
                let v = max(0, sin(t * 5.3)) * (0.6 + 0.35 * sin(t * 0.9)) * phrase + 0.04
                self.meter.set(Float(min(max(v, 0), 1)))
                if shown < words.count, Int(t * 6) > shown { shown += 1; self.transcript = words.prefix(shown).joined(separator: " ") }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Puts words on screen as if they had just been heard.
    func debugShow(_ text: String) { transcript = text }

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
