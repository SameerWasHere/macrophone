#if os(macOS)
import AVFoundation
import Foundation

/// The wake word's listener (Nov 7 2026): audio in (`WakeAudioSource`), the cheap tiers
/// (`WakeFeed`), and — only while a voice is heard — a SpeechAnalyzer session looking for the
/// phrase. When it hears it, the *same* session keeps going as the capture (no restart, so no
/// word is lost in the hand-over), until a pause, ending words, Esc or the desk key. Sessions are
/// short and recycled (at most 45 s; 4 s without new words ends one), so memory stays flat over
/// days. A wake is checked again once its words settle (the recognizer's confidence in the name,
/// at High its second guesses too); one that doesn't hold up is withdrawn and nothing pastes.
///
/// Times are the audio's own clock (seconds heard), so a bench file played at twice real time
/// behaves the same. The listener never pastes: it reports events; the app lands the words.
@available(macOS 26.0, *)
@MainActor
public final class WakeListener {
    public struct Settings: Equatable, Sendable {
        public var phrase: String = WakePhrase.defaultText
        public var sensitivity: WakeSensitivity = .normal
        public var endings: WakeEndingWords = .default
        /// Quiet after the last word that lands it.
        public var endSilence: TimeInterval = 2.0
        public var language: String = "en-US"
        /// The person's own words (names, jargon), as the recognizer's context.
        public var dictionary: [String] = []
        /// Tier 1 (the voice classifier). Off = loudness alone starts a session (the bench's comparison).
        public var classifier: Bool = true
        /// The bench's baseline: no tiers — a session whenever one can run (what listening without them costs).
        public var ungated = false
        public init() {}
    }

    public enum Event: Sendable, Equatable {
        /// The phrase was heard: chime, pill.
        case woke(UUID)
        /// The words after the phrase so far.
        case words(UUID, settled: String, pending: String)
        /// It wasn't the phrase after all (the words settled differently, or with too little
        /// confidence): nothing pastes.
        case withdrawn(UUID)
        /// Esc / the desk key's Esc / `cancelCapture()`.
        case cancelled(UUID)
        /// The phrase and then nothing.
        case nothingSaid(UUID)
        /// Done: `raw` is everything said after the phrase; the outcome says what to do with it.
        case finished(UUID, raw: String, outcome: WakeOutcome, seconds: TimeInterval)
    }

    /// Numbers for the log and the bench (never words).
    public struct Stats: Sendable, Equatable {
        public var voiceTriggers = 0
        public var scans = 0
        public var scanSeconds: Double = 0
        public var recycled = 0
        public var wakes = 0
        public var withdrawn = 0
        public var finished = 0
        public var nothingSaid = 0
        public var restarts = 0
        public init() {}
    }

    public var onEvent: (Event) -> Void = { _ in }
    public var log: (String) -> Void = { _ in }
    public private(set) var stats = Stats()
    public private(set) var isRunning = false
    /// Desk dictation has the mic's attention (🌐 held): no scans.
    public private(set) var suspended = false
    public var isCapturing: Bool { scan?.capture != nil && scan?.done == false }
    public var currentCaptureID: UUID? { isCapturing ? scan?.id : nil }
    public var classifierSeconds: Double { feed.classifierSeconds }
    public var roomDB: Float { feed.roomDB }

    public private(set) var settings = Settings()
    private var matcher = WakeMatcher(phrase: WakePhrase(WakePhrase.defaultText), sensitivity: .normal)
    private let source: WakeAudioSource
    private let feed = WakeFeed()
    private var scan: Scan?
    private var ticker: Timer?
    private var tickInterval: TimeInterval = 0
    private var health: Timer?
    private var restartTask: Task<Void, Never>?

    private final class Scan {
        let id = UUID()
        var speech: DeskSpeech?
        let startedAt: TimeInterval
        var lastWordsAt: TimeInterval
        var lastWords: [String] = []
        var lastText = ""
        var capture: WakeCapture?
        var captureStart: TimeInterval = 0
        var anchor = 0
        var verified = false
        var finishing = false
        var done = false
        init(at t: TimeInterval) { startedAt = t; lastWordsAt = t }
    }

    public init(source: WakeAudioSource) {
        self.source = source
        feed.onVoice = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.voiceHeard() } }
        }
        source.onChange = { [weak self] why in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.restartSoon(why) } }
        }
    }

    public var sourceDescription: String { source.description }
    /// The microphone, when that's the source (what it picked, what it stepped around).
    public var micSource: WakeMicSource? { source as? WakeMicSource }
    /// The voice's loudness, 0…1, smoothed (the pill's ring).
    public var level: Float { feed.level }

    private var speechOptions: DeskSpeechOptions {
        DeskSpeechOptions(confidence: settings.sensitivity.minimumConfidence > 0, alternatives: settings.sensitivity == .high)
    }

    private var contextual: [String] {
        var seen = Set<String>()
        return (WakePhrase(settings.phrase).contextualStrings + settings.endings.all + settings.dictionary)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: On and off

    /// Opens the source and listens. Throws what the source threw (no microphone, only AirPods).
    public func start(_ settings: Settings) throws {
        apply(settings)
        guard !isRunning else { return }
        feed.reset()
        let feed = self.feed
        try source.start { feed.push($0) }
        isRunning = true
        feed.setClassifying(!suspended)
        warm()
        startHealth()
        log("wake: listening on \(source.description)")
    }

    public func update(_ settings: Settings) {
        let old = self.settings
        apply(settings)
        if isRunning, old.phrase != settings.phrase || old.dictionary != settings.dictionary || old.endings != settings.endings
            || old.sensitivity != settings.sensitivity || old.language != settings.language {
            warm()
        }
    }

    private func apply(_ s: Settings) {
        settings = s
        matcher = WakeMatcher(phrase: WakePhrase(s.phrase), sensitivity: s.sensitivity)
        feed.configure(classifier: s.classifier, sensitivity: s.sensitivity, ungated: s.ungated)
    }

    /// Lets the mic go (the orange dot goes) and drops any scan or capture.
    public func stop() {
        guard isRunning else { return }
        if let s = scan { drop(s) }
        restartTask?.cancel()
        source.stop()
        feed.reset()
        isRunning = false
        stopTicking()
        health?.invalidate()
        health = nil
        log("wake: stopped")
    }

    /// 🌐 is held for desk dictation: scanning stops (a capture already going is the app's to merge).
    public func suspend() {
        suspended = true
        if let s = scan, s.capture == nil { drop(s) }
        feed.setClassifying(false)
    }

    public func resume() {
        suspended = false
        feed.clearPrerollSoon()
        feed.setClassifying(isRunning && scan == nil)
    }

    private func warm() {
        let language = settings.language, options = speechOptions, ctx = contextual
        Task.detached(priority: .utility) { await DeskSpeech.warm(language: language, slot: .wake, options: options, contextual: ctx) }
    }

    // MARK: The capture, from outside

    /// Esc: the capture is dropped, nothing pastes.
    public func cancelCapture() {
        guard let s = scan, s.capture != nil, !s.done else { return }
        drop(s)
        feed.clearPrerollSoon()
        onEvent(.cancelled(s.id))
    }

    /// The desk key tapped (or released) during a capture: land it now.
    public func finishCapture() {
        guard let s = scan, s.capture != nil, !s.finishing, !s.done else { return }
        finish(s)
    }

    /// The desk key held during a capture: only its release ends it.
    public func setHeld(_ held: Bool) {
        guard let s = scan, s.capture != nil else { return }
        s.capture?.held = held
    }

    // MARK: Scans

    private func voiceHeard() {
        stats.voiceTriggers += 1
        guard isRunning, !suspended, scan == nil else { return }
        startScan()
    }

    private func startScan() {
        let s = Scan(at: feed.now)
        scan = s
        stats.scans += 1
        feed.setClassifying(false)
        startTicking(0.1)
        let language = settings.language, options = speechOptions, ctx = contextual
        Task { [weak self] in
            let r = await DeskSpeech.start(language: language, slot: .wake, options: options, contextual: ctx) { settled, pending in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(s, settled: settled, pending: pending) } }
            }
            guard let self else { r?.0.cancel(); return }
            guard let (speech, _) = r else {
                if self.scan === s { self.log("wake: the speech engine didn't start"); self.end(s) }
                return
            }
            guard self.scan === s, !s.done else { speech.cancel(); return }
            s.speech = speech
            self.feed.attach(speech.sink.feed)
        }
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    private func heard(_ s: Scan, settled: String, pending: String) {
        guard scan === s, !s.done, !s.finishing else { return }
        let full = DeskSpeech.join(settled, pending)
        let now = feed.now
        let w = Self.words(full)
        if w != s.lastWords { s.lastWords = w; s.lastWordsAt = now }
        s.lastText = full
        if var c = s.capture {
            let cmd = matcher.command(in: full, anchoredAt: s.anchor).command
            c.heard(cmd, at: now)
            s.capture = c
            report(s, settled: settled, command: cmd)
            verify(s, settled: settled)
            return
        }
        let low = settings.sensitivity.waitsForSettledWords
        guard let hit = matcher.matches(in: low ? settled : full).last else { return }
        if low {
            guard confidenceHolds(s, hit) else { return }
            s.verified = true
        }
        begin(s, hit: hit, full: full, settled: settled)
    }

    private func begin(_ s: Scan, hit: WakeHit, full: String, settled: String) {
        let now = feed.now
        s.anchor = hit.wordsBefore
        let cmd = matcher.command(in: full, anchoredAt: s.anchor).command
        var config = WakeCapture.Config(endSilence: settings.endSilence)
        config.maxDuration = 180
        s.capture = WakeCapture(config: config, words: settings.endings, command: cmd, at: now)
        s.captureStart = now
        stats.wakes += 1
        feed.setCapturing(true)
        startTicking(0.05)
        onEvent(.woke(s.id))
        report(s, settled: settled, command: cmd)
        verify(s, settled: settled)
    }

    /// The pill's words: what's settled of the command, and the rest still being decided.
    private func report(_ s: Scan, settled: String, command: String) {
        let settledCmd = Self.words(settled).count > s.anchor ? matcher.command(in: settled, anchoredAt: s.anchor).command : ""
        if !settledCmd.isEmpty, command.hasPrefix(settledCmd) {
            onEvent(.words(s.id, settled: settledCmd, pending: String(command.dropFirst(settledCmd.count)).trimmingCharacters(in: .whitespaces)))
        } else {
            onEvent(.words(s.id, settled: "", pending: command))
        }
    }

    private func confidenceHolds(_ s: Scan, _ hit: WakeHit) -> Bool {
        let need = settings.sensitivity.minimumConfidence
        guard need > 0, let c = s.speech?.confidence(over: hit.nameRange) else { return true }
        return c >= need
    }

    /// Once the phrase's words settle: the phrase must still be there (or, at High, in the
    /// recognizer's second guesses) with enough confidence — else the wake is withdrawn.
    private func verify(_ s: Scan, settled: String) {
        guard !s.verified, let speech = s.speech else { return }
        switch check(s, settled: settled, speech: speech, final: false) {
        case .some(true): s.verified = true
        case .some(false): withdraw(s)
        case .none: break
        }
    }

    /// true = it holds, false = it doesn't, nil = its words haven't settled yet.
    private func check(_ s: Scan, settled: String, speech: DeskSpeech, final: Bool) -> Bool? {
        let settledWords = Self.words(settled).count
        if let h = matcher.command(in: settled, anchoredAt: s.anchor).hit {
            return confidenceHolds(s, h)
        }
        guard final || settledWords >= s.anchor + 2 else { return nil }
        if settings.sensitivity == .high {
            let offset = Self.offset(ofWord: max(0, s.anchor - 1), in: settled)
            if speech.alternatives(at: offset).contains(where: { !matcher.matches(in: $0).isEmpty }) { return true }
        }
        // Settled shorter than the phrase at the end: nothing to check against — trust the words.
        if final, settledWords < s.anchor { return true }
        return false
    }

    private static func offset(ofWord n: Int, in text: String) -> Int {
        var count = 0, inWord = false
        for (i, ch) in text.enumerated() {
            let w = ch.isLetter || ch.isNumber || ch == "'"
            if w, !inWord { if count == n { return i }; count += 1 }
            inWord = w
        }
        return max(0, text.count - 1)
    }

    private func withdraw(_ s: Scan) {
        stats.withdrawn += 1
        log("wake: withdrawn (the phrase didn't hold up as the words settled)")
        drop(s)
        feed.clearPrerollSoon()
        onEvent(.withdrawn(s.id))
    }

    private func finish(_ s: Scan) {
        s.finishing = true
        stopTicking()
        feed.detach()
        let started = s.captureStart
        Task { [weak self] in
            let text = await s.speech?.finish(timeout: 1.2) ?? s.lastText
            guard let self, self.scan === s, !s.done else { return }
            let seconds = self.feed.now - started
            if !s.verified, let speech = s.speech, self.check(s, settled: speech.settledText, speech: speech, final: true) == false {
                self.withdraw(s)
                return
            }
            let cmd = self.matcher.command(in: text, anchoredAt: s.anchor).command
            let outcome = WakeEndings.parse(cmd, words: self.settings.endings)
            self.stats.finished += 1
            self.end(s)
            self.feed.clearPrerollSoon()
            self.onEvent(.finished(s.id, raw: cmd, outcome: outcome, seconds: seconds))
        }
    }

    private func nothingSaid(_ s: Scan) {
        stats.nothingSaid += 1
        drop(s)
        feed.clearPrerollSoon()
        onEvent(.nothingSaid(s.id))
    }

    /// Cancels a scan's session and ends it.
    private func drop(_ s: Scan) {
        s.speech?.cancel()
        end(s)
    }

    private func end(_ s: Scan) {
        guard !s.done else { return }
        s.done = true
        stats.scanSeconds += max(0, feed.now - s.startedAt)
        if scan === s { scan = nil }
        feed.detach()
        feed.setCapturing(false)
        feed.setClassifying(isRunning && !suspended)
        stopTicking()
        if isRunning { warm() }
    }

    // MARK: Time

    private func startTicking(_ interval: TimeInterval) {
        if ticker != nil, tickInterval == interval { return }
        ticker?.invalidate()
        tickInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval / 2
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        tickInterval = 0
    }

    private func tick() {
        guard let s = scan, !s.done else { stopTicking(); return }
        let now = feed.now
        if var c = s.capture {
            guard !s.finishing else { return }
            if feed.isVoice() { c.voice(at: now) }
            s.capture = c
            switch c.decide(at: now) {
            case .finish?: finish(s)
            case .nothingSaid?: nothingSaid(s)
            case nil: break
            }
            return
        }
        let quiet = now - max(s.lastWordsAt, s.startedAt)
        let running = now - s.startedAt
        if quiet > 4 {
            drop(s)
        } else if (running > 10 && quiet > 0.8) || running > 45 {
            // Keep sessions short: start again at a pause (the pre-roll carries the last 3.5 s,
            // so a phrase said right at the cut is still heard).
            stats.recycled += 1
            drop(s)
            startScan()
        }
    }

    // MARK: Health

    private func startHealth() {
        health?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                if self.feed.secondsSinceLastBuffer > 4 { self.restartSoon("no audio for 4 s") }
            }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        health = t
    }

    /// The source changed under us (AirPods connected, the default input switched, the mic went
    /// quiet): start it again, a moment later so a burst of changes is one restart.
    private func restartSoon(_ why: String) {
        guard isRunning else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            if let s = self.scan {
                let id = s.id, capturing = s.capture != nil
                self.drop(s)
                if capturing { self.onEvent(.cancelled(id)) }
            }
            self.source.stop()
            self.feed.reset()
            self.stats.restarts += 1
            do {
                let feed = self.feed
                try self.source.start { feed.push($0) }
                self.feed.setClassifying(!self.suspended)
                self.log("wake: restarted (\(why)) on \(self.source.description)")
            } catch {
                self.isRunning = false
                self.health?.invalidate()
                self.log("wake: couldn't restart (\(why))")
                self.onFailure?(error)
            }
        }
    }

    /// The source stopped and couldn't start again (the mic went away, only AirPods left).
    public var onFailure: ((Error) -> Void)?
}

extension WakeFeed {
    /// After a capture or a withdrawn wake: the pre-roll still holds the phrase just handled —
    /// the next session mustn't hear it again.
    func clearPrerollSoon() { clearPreroll() }
}
#endif
