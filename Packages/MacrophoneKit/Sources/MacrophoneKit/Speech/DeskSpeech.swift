#if os(macOS)
import AVFoundation
import Foundation
import Speech

// The Mac's speech (Nov 7 2026): Apple's on-device SpeechAnalyzer + SpeechTranscriber, the same
// engine and the same pattern as the iPhone's (iOS/Macrophone/Recording/ModernSpeech.swift) — an
// analyzer made ahead (the model loaded, the format set) so at the press only the input stream
// starts, volatile words while you talk, settled words at the end. Audio never leaves the Mac.
// Desk dictation (hold 🌐) and the wake word share it; it lives in the package so `mpctl
// wake-bench` runs the very same code headless. The phone's copy lives in the iOS target.

/// Takes the mic's buffers on the audio thread and hands them to the analyzer in its format.
@available(macOS 26.0, *)
public final class DeskAnalyzerSink: @unchecked Sendable {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    init(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        self.continuation = continuation
        self.target = format
    }

    public func feed(_ buffer: AVAudioPCMBuffer) {
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

    public func finish() { continuation.finish() }
}

/// What an analysis reports beyond the words.
public struct DeskSpeechOptions: Sendable, Hashable {
    /// The recognizer's confidence per word (settled words only) — the wake word's check.
    public var confidence: Bool
    /// Its second guesses (settled words only) — High sensitivity looks for the phrase there too.
    public var alternatives: Bool
    public init(confidence: Bool = false, alternatives: Bool = false) {
        self.confidence = confidence
        self.alternatives = alternatives
    }
    public static let plain = DeskSpeechOptions()
}

@available(macOS 26.0, *)
public struct DeskPreparedAnalyzer {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let format: AVAudioFormat
    let language: String
    let options: DeskSpeechOptions
    var contextual: [String]
}

/// One analyzer made ahead for the next analysis. Desk dictation has one (`shared`), the wake
/// word's listener another (`wake`), so neither ever waits for the other's.
@available(macOS 26.0, *)
public actor DeskWarmAnalyzer {
    public static let shared = DeskWarmAnalyzer()
    public static let wake = DeskWarmAnalyzer()
    private var prepared: DeskPreparedAnalyzer?
    private var building: Task<DeskPreparedAnalyzer?, Never>?
    private var buildID = 0

    public init() {}

    public func warm(language: String, options: DeskSpeechOptions = .plain, contextual: [String] = []) async {
        guard building == nil else { return }
        if var p = prepared, p.language == language, p.options == options {
            if p.contextual != contextual {
                await DeskSpeech.setContext(contextual, on: p.analyzer)
                p.contextual = contextual
                prepared = p
            }
            return
        }
        prepared = nil
        buildID += 1
        let id = buildID
        let task = Task { await DeskSpeech.prepare(language: language, options: options, contextual: contextual) }
        building = task
        let p = await task.value
        if buildID == id, building != nil { building = nil; prepared = p }
    }

    func take(language: String, options: DeskSpeechOptions) async -> (DeskPreparedAnalyzer, warm: Bool)? {
        if let task = building {
            let p = await task.value
            if building != nil { building = nil; buildID += 1 }
            prepared = nil
            return p.flatMap { $0.language == language && $0.options == options ? ($0, false) : nil }
        }
        guard let p = prepared, p.language == language, p.options == options else { return nil }
        prepared = nil
        return (p, true)
    }

    /// Lets the analyzer made ahead go (the wake word turned off: its model can leave memory).
    public func drop() {
        building?.cancel()
        building = nil
        buildID += 1
        prepared = nil
    }
}

/// One analysis. `onText` gets the settled words and the ones still being decided.
@available(macOS 26.0, *)
public final class DeskSpeech: @unchecked Sendable {
    public let sink: DeskAnalyzerSink
    private let analyzer: SpeechAnalyzer
    private var results: Task<Void, Never>?
    private let lock = NSLock()
    private var settled = ""
    private var pending = ""
    /// Settled characters' confidence: (character range in `settled`, confidence).
    private var confidences: [(Range<Int>, Double)] = []
    /// Each settled piece's character range and the recognizer's other readings of it.
    private var pieces: [(Range<Int>, [String])] = []
    private var ended = false
    private var waiter: CheckedContinuation<Void, Never>?

    private init(analyzer: SpeechAnalyzer, sink: DeskAnalyzerSink) {
        self.analyzer = analyzer
        self.sink = sink
    }

    public var text: String { lock.withLock { Self.join(settled, pending) } }
    public var settledText: String { lock.withLock { settled } }

    public static func join(_ a: String, _ b: String) -> String {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines), y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty { return y }
        if y.isEmpty { return x }
        return x + " " + y
    }

    /// The least confidence over these settled characters (nil = no settled word there yet, or
    /// confidence wasn't asked for).
    public func confidence(over range: Range<Int>) -> Double? {
        lock.withLock {
            let hits = confidences.filter { $0.0.overlaps(range) }.map(\.1)
            return hits.min()
        }
    }

    /// The other readings of the settled piece holding this character.
    public func alternatives(at offset: Int) -> [String] {
        lock.withLock { pieces.first { $0.0.contains(offset) }?.1 ?? [] }
    }

    static func transcriber(for language: String, options: DeskSpeechOptions) async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { return nil }
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults, .fastResults]
        if options.alternatives { reporting.insert(.alternativeTranscriptions) }
        let attributes: Set<SpeechTranscriber.ResultAttributeOption> = options.confidence ? [.transcriptionConfidence] : []
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: reporting, attributeOptions: attributes)
    }

    /// Whether this Mac can transcribe the language at all.
    public static func supports(_ language: String) async -> Bool {
        await transcriber(for: language, options: .plain) != nil
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
                    log?("speech: model downloading")
                    try await request.downloadAndInstall()
                    log?("speech: model installed")
                }
            } catch {
                log?("speech: model download failed")
            }
        }
    }

    static func setContext(_ contextual: [String], on analyzer: SpeechAnalyzer) async {
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextual
        try? await analyzer.setContext(context)
    }

    /// An analyzer with the model loaded and the format set — the slow part, done ahead of the
    /// press. Nil when the engine can't run right now.
    static func prepare(language: String, options: DeskSpeechOptions = .plain, contextual: [String] = [],
                        log: (@Sendable (String) -> Void)? = nil) async -> DeskPreparedAnalyzer? {
        guard let transcriber = await transcriber(for: language, options: options),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        fetchIfNeeded(transcriber, language: language, log: log)
        let analyzerOptions: SpeechAnalyzer.Options
        if #available(macOS 27.0, *) {
            analyzerOptions = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering, ignoresResourceLimits: false)
        } else {
            analyzerOptions = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)
        if !contextual.isEmpty { await setContext(contextual, on: analyzer) }
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            return nil
        }
        return DeskPreparedAnalyzer(transcriber: transcriber, analyzer: analyzer, format: format, language: language,
                                    options: options, contextual: contextual)
    }

    public static func warm(language: String, slot: DeskWarmAnalyzer = .shared, options: DeskSpeechOptions = .plain,
                            contextual: [String] = []) async {
        await slot.warm(language: language, options: options, contextual: contextual)
    }

    /// Starts an analysis, on the analyzer made ahead in `slot` when there is one.
    public static func start(language: String, slot: DeskWarmAnalyzer = .shared, options: DeskSpeechOptions = .plain,
                             contextual: [String] = [],
                             onText: @escaping @Sendable (_ settled: String, _ pending: String) -> Void) async -> (DeskSpeech, warm: Bool)? {
        var warm = false
        var prepared: DeskPreparedAnalyzer?
        if let (p, w) = await slot.take(language: language, options: options) { prepared = p; warm = w }
        if prepared == nil { prepared = await prepare(language: language, options: options, contextual: contextual) }
        guard let p = prepared else { return nil }
        if p.contextual != contextual { await setContext(contextual, on: p.analyzer) }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let engine = DeskSpeech(analyzer: p.analyzer, sink: DeskAnalyzerSink(continuation: continuation, format: p.format))
        let transcriber = p.transcriber
        let options = p.options
        engine.results = Task { [weak engine] in
            do {
                for try await result in transcriber.results {
                    guard let engine else { return }
                    let parts: (String, String) = engine.lock.withLock {
                        if result.isFinal {
                            engine.append(result, options: options)
                            engine.pending = ""
                        } else {
                            engine.pending = String(result.text.characters)
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

    /// A settled piece joins the words; its confidences and other readings are kept by character
    /// (in the lock).
    private func append(_ result: SpeechTranscriber.Result, options: DeskSpeechOptions) {
        let words = String(result.text.characters)
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lead = words.prefix { $0.isWhitespace || $0.isNewline }.count
        let joined = Self.join(settled, trimmed)
        let base = joined.count - trimmed.count
        settled = joined
        if options.confidence {
            let chars = result.text.characters
            for run in result.text.runs {
                guard let c = run.transcriptionConfidence else { continue }
                let lo = chars.distance(from: chars.startIndex, to: run.range.lowerBound) - lead
                let hi = chars.distance(from: chars.startIndex, to: run.range.upperBound) - lead
                let a = max(0, lo), b = min(trimmed.count, hi)
                if a < b { confidences.append(((base + a)..<(base + b), c)) }
            }
        }
        if options.alternatives, result.alternatives.count > 1 {
            pieces.append(((base)..<(base + trimmed.count), result.alternatives.dropFirst().map { String($0.characters) }))
            if pieces.count > 40 { pieces.removeFirst(pieces.count - 40) }
        }
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
    public func finish(timeout: TimeInterval) async -> String {
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

    /// Stop now, dropping everything (Esc, a tap, a shortcut, a wake scan that heard nothing).
    public func cancel() {
        sink.finish()
        results?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
        end()
    }
}
#endif
