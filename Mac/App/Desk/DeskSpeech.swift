import AVFoundation
import Foundation
import Speech

// Desk dictation's speech (Nov 7 2026): Apple's on-device SpeechAnalyzer + SpeechTranscriber,
// the same engine and the same pattern as the iPhone's (iOS/Macrophone/Recording/ModernSpeech.swift)
// — an analyzer made ahead (the model loaded, the format set) so at the press only the input
// stream starts, volatile words while you talk, settled words at the end. Audio never leaves
// the Mac. A copy rather than a shared file: the phone's lives in the iOS target.

/// Takes the mic's buffers on the audio thread and hands them to the analyzer in its format.
@available(macOS 26.0, *)
final class DeskAnalyzerSink: @unchecked Sendable {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    init(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        self.continuation = continuation
        self.target = format
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { convert(buffer) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    func finish() { continuation.finish() }
}

@available(macOS 26.0, *)
struct DeskPreparedAnalyzer {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let format: AVAudioFormat
    let language: String
}

/// The one analyzer made ahead for the next desk dictation.
@available(macOS 26.0, *)
actor DeskWarmAnalyzer {
    static let shared = DeskWarmAnalyzer()
    private var prepared: DeskPreparedAnalyzer?
    private var building: Task<DeskPreparedAnalyzer?, Never>?
    private var buildID = 0

    func warm(language: String) async {
        guard building == nil else { return }
        if let p = prepared, p.language == language { return }
        prepared = nil
        buildID += 1
        let id = buildID
        let task = Task { await DeskSpeech.prepare(language: language) }
        building = task
        let p = await task.value
        if buildID == id, building != nil { building = nil; prepared = p }
    }

    func take(language: String) async -> (DeskPreparedAnalyzer, warm: Bool)? {
        if let task = building {
            let p = await task.value
            if building != nil { building = nil; buildID += 1 }
            prepared = nil
            return p.flatMap { $0.language == language ? ($0, false) : nil }
        }
        guard let p = prepared, p.language == language else { return nil }
        prepared = nil
        return (p, true)
    }
}

/// One desk dictation's analysis. `onText` gets the settled words and the ones still being decided.
@available(macOS 26.0, *)
final class DeskSpeech: @unchecked Sendable {
    let sink: DeskAnalyzerSink
    private let analyzer: SpeechAnalyzer
    private var results: Task<Void, Never>?
    private let lock = NSLock()
    private var settled = ""
    private var pending = ""
    private var ended = false
    private var waiter: CheckedContinuation<Void, Never>?

    private init(analyzer: SpeechAnalyzer, sink: DeskAnalyzerSink) {
        self.analyzer = analyzer
        self.sink = sink
    }

    var text: String { lock.withLock { Self.join(settled, pending) } }

    static func join(_ a: String, _ b: String) -> String {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines), y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty { return y }
        if y.isEmpty { return x }
        return x + " " + y
    }

    static func transcriber(for language: String) async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { return nil }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                 reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    /// Whether this Mac can transcribe the language at all (nil = can't).
    static func supports(_ language: String) async -> Bool {
        await transcriber(for: language) != nil
    }

    private static let fetchLock = NSLock()
    nonisolated(unsafe) private static var fetching: Set<String> = []

    /// Downloads the language's model in the background when the system says it isn't there
    /// (macOS often shares one with the system's own dictation, so this is rare).
    static func fetchIfNeeded(_ transcriber: SpeechTranscriber, language: String, log: (@Sendable (String) -> Void)?) {
        let started = fetchLock.withLock { fetching.insert(language).inserted }
        guard started else { return }
        Task.detached(priority: .utility) {
            defer { _ = fetchLock.withLock { fetching.remove(language) } }
            let status = await AssetInventory.status(forModules: [transcriber])
            guard status == .supported || status == .downloading else { return }
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    log?("desk: speech model downloading")
                    try await request.downloadAndInstall()
                    log?("desk: speech model installed")
                }
            } catch {
                log?("desk: speech model download failed")
            }
        }
    }

    /// An analyzer with the model loaded and the format set — the slow part, done ahead of the
    /// press. Nil when the engine can't run right now.
    static func prepare(language: String, log: (@Sendable (String) -> Void)? = nil) async -> DeskPreparedAnalyzer? {
        guard let transcriber = await transcriber(for: language),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        fetchIfNeeded(transcriber, language: language, log: log)
        let options: SpeechAnalyzer.Options
        if #available(macOS 27.0, *) {
            options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering, ignoresResourceLimits: false)
        } else {
            options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            return nil
        }
        return DeskPreparedAnalyzer(transcriber: transcriber, analyzer: analyzer, format: format, language: language)
    }

    static func warm(language: String) async {
        await DeskWarmAnalyzer.shared.warm(language: language)
    }

    /// Starts an analysis for one dictation, on the analyzer made ahead when there is one.
    static func start(language: String,
                      onText: @escaping @Sendable (_ settled: String, _ pending: String) -> Void) async -> (DeskSpeech, warm: Bool)? {
        var warm = false
        var prepared: DeskPreparedAnalyzer?
        if let (p, w) = await DeskWarmAnalyzer.shared.take(language: language) { prepared = p; warm = w }
        if prepared == nil { prepared = await prepare(language: language) }
        guard let p = prepared else { return nil }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let engine = DeskSpeech(analyzer: p.analyzer, sink: DeskAnalyzerSink(continuation: continuation, format: p.format))
        let transcriber = p.transcriber
        engine.results = Task { [weak engine] in
            do {
                for try await result in transcriber.results {
                    guard let engine else { return }
                    let words = String(result.text.characters)
                    let parts: (String, String) = engine.lock.withLock {
                        if result.isFinal {
                            engine.settled = join(engine.settled, words)
                            engine.pending = ""
                        } else {
                            engine.pending = words
                        }
                        return (engine.settled, engine.pending)
                    }
                    onText(parts.0, parts.1)
                }
            } catch {}
            engine?.end()
        }
        do {
            try await p.analyzer.start(inputSequence: stream)
        } catch {
            engine.results?.cancel()
            return nil
        }
        return (engine, warm)
    }

    private func end() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock {
            ended = true
            let w = waiter
            waiter = nil
            return w
        }
        c?.resume()
    }

    /// The mic stopped: settle the last words. Returns everything heard.
    func finish(timeout: TimeInterval) async -> String {
        sink.finish()
        let analyzer = self.analyzer
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let over: Bool = lock.withLock {
                if ended { return true }
                waiter = c
                return false
            }
            if over { c.resume(); return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                self?.end()
            }
        }
        return text
    }

    /// Stop now, dropping everything (Esc, a tap, a shortcut).
    func cancel() {
        sink.finish()
        results?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
        end()
    }
}
