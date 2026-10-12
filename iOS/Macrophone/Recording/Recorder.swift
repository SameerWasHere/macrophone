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

/// The tap's side: which request the buffers go to, plus level and pause detection.
final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var smoothed: Float = 0
    private var lastLoud = Date.distantPast
    private var lastBuffer = Date.distantPast
    let meter: LevelMeter

    init(meter: LevelMeter) { self.meter = meter }

    /// Points the tap at a new request and returns the old one (to be ended).
    func swap(_ r: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock(); defer { lock.unlock() }
        let old = request
        request = r
        if r == nil { smoothed = 0; meter.set(0) }
        return old
    }

    /// Seconds since the voice was last above the quiet line.
    var quietFor: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastLoud) }

    /// Called on the audio thread for every buffer.
    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let r = request
        lock.unlock()
        r?.append(buffer)

        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(n))
        let db = 20 * log10(max(rms, 0.000_01))
        let x = min(max((db + 52) / 40, 0), 1)
        lock.lock()
        // Attack fast, release slow: it breathes with speech instead of flickering.
        smoothed += (x - smoothed) * (x > smoothed ? 0.6 : 0.12)
        let s = smoothed
        let now = Date()
        lastBuffer = now
        if x > 0.32 { lastLoud = now }
        lock.unlock()
        meter.set(s)
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

        var isEarly: Bool { if case .interrupted = self { return true }; return false }
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
            case .micDenied: return "Macrophone can't use the microphone. Turn it on in Settings › Macrophone."
            case .speechDenied: return "Speech recognition is off for Macrophone. Turn it on in Settings › Macrophone."
            case .languageNotOnDevice: return "This language can't be transcribed on this iPhone. Pick another in Settings."
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

        guard let r = SFSpeechRecognizer(locale: Locale(identifier: language)), r.supportsOnDeviceRecognition else {
            throw StartError.languageNotOnDevice
        }
        guard r.isAvailable else { throw StartError.recognizerBusy }
        recognizer = r
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
            let code = (error as NSError?)?.code
            Task { @MainActor in owner?.update(index: index, generation: generation, text: text, final: final, errorCode: code) }
        }
    }

    private func newSegment() -> Segment {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = contextual
        let seg = Segment(index: segments.count, request: req)
        segments.append(seg)
        seg.task = recognizer?.recognitionTask(with: req, resultHandler: Self.resultHandler(self, index: seg.index, generation: generation))
        return seg
    }

    private func update(index: Int, generation g: Int, text: String?, final: Bool, errorCode: Int?) {
        guard g == generation, index < segments.count else { return }
        let seg = segments[index]
        if let text, !text.isEmpty, text != seg.text {
            seg.text = text
            if phase == .recording { lastWordsAt = Date() }
            transcript = stitched()
        }
        guard final, !seg.done else { return }
        seg.done = true
        if let errorCode { log?.add("segment \(index) ended with code \(errorCode)") }
        // The live segment ended on its own while still recording: keep listening in a new one.
        if phase == .recording, index == segments.count - 1 {
            if errorCode != nil, Date().timeIntervalSince(seg.startedAt) < 1.5 { failures += 1 } else { failures = 0 }
            if failures >= 4 {
                log?.add("recognizer keeps failing; stopping")
                stop(.interrupted("Speech recognition stopped"))
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
        log?.add("recording stopped (\(reason.logName), \(Int(duration))s, \(count) segment(s))")

        Task { [weak self] in
            guard let self else { return }
            // The recognizer finishes the last words after endAudio; give it a moment.
            let deadline = Date().addingTimeInterval(reason.isEarly ? 2.0 : 3.0)
            while Date() < deadline, self.generation == g, self.segments.contains(where: { !$0.done }) {
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
                let v = 0.45 + 0.35 * sin(t * 7) * sin(t * 2.3) + 0.15 * sin(t * 13)
                self.meter.set(Float(min(max(v, 0.05), 1)))
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
        }
    }
}
