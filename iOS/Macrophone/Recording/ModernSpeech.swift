import AVFoundation
import Foundation
import Speech

// The newer speech engine (Oct 14 2026): SpeechAnalyzer + SpeechTranscriber, Apple's on-device
// long-form model (iOS 26+). Faster than SFSpeechRecognizer, one continuous analysis for the
// whole recording — no 45-second segments, no recognizer restarting after a pause — and audio
// never leaves the phone. Used whenever this iPhone has the model for the language installed;
// otherwise the Recorder uses SFSpeechRecognizer (on-device) for that recording and the model is
// fetched in the background for next time. Speech/AVFoundation only, so a Mac harness can
// compile this file as-is.

/// Takes the microphone's buffers on the audio thread and hands them to the analyzer in the
/// format it wants (converted here; the tap's buffers are never held on to).
@available(iOS 26.0, macOS 26.0, *)
final class AnalyzerSink: @unchecked Sendable {
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

/// One recording's analysis. `onText` gets everything heard so far (settled words, then the
/// ones still being decided), on the main actor.
@available(iOS 26.0, macOS 26.0, *)
final class ModernSpeech: @unchecked Sendable {
    let sink: AnalyzerSink
    private let analyzer: SpeechAnalyzer
    private var results: Task<Void, Never>?
    private let lock = NSLock()
    private var settled = ""
    private var pending = ""
    /// The results sequence ended (the analyzer finished, or failed).
    private var ended = false

    /// Which engine runs, for diagnostics.
    static let name = "SpeechAnalyzer"

    private init(analyzer: SpeechAnalyzer, sink: AnalyzerSink) {
        self.analyzer = analyzer
        self.sink = sink
    }

    /// Everything heard: settled words, then the ones still being decided.
    var text: String { lock.withLock { Self.join(settled, pending) } }

    static func join(_ a: String, _ b: String) -> String {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines), y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty { return y }
        if y.isEmpty { return x }
        return x + " " + y
    }

    /// The transcriber for a language, when this device has it (nil = use the older engine).
    static func transcriber(for language: String) async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { return nil }
        // Volatile results show words as they're spoken; fast results trade a little look-ahead
        // for less delay — right for words appearing under the mic.
        return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                 reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    /// Whether the model for this language is on the phone. When it isn't (but could be),
    /// starts fetching it so the next recording uses it.
    static func isReady(_ language: String, log: ((String) -> Void)? = nil) async -> Bool {
        guard SpeechTranscriber.isAvailable else { log?("newer speech engine: not on this device"); return false }
        guard let t = await transcriber(for: language) else { log?("newer speech engine: no model for \(language)"); return false }
        switch await AssetInventory.status(forModules: [t]) {
        case .installed: return true
        case .supported, .downloading:
            log?("newer speech engine: model not on the phone yet")
            fetch(language, log: log)
            return false
        default:
            log?("newer speech engine: \(language) unsupported")
            return false
        }
    }

    private static let fetching = Fetching()
    private final class Fetching: @unchecked Sendable {
        let lock = NSLock()
        var languages: Set<String> = []
    }

    /// Downloads the language's model in the background (Apple's servers; once per language).
    static func fetch(_ language: String, log: ((String) -> Void)? = nil) {
        let f = fetching
        let started = f.lock.withLock { f.languages.insert(language).inserted }
        guard started else { return }
        Task.detached(priority: .utility) {
            defer { _ = f.lock.withLock { f.languages.remove(language) } }
            guard let t = await transcriber(for: language) else { return }
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                    log?("speech model downloading")
                    try await request.downloadAndInstall()
                    log?("speech model installed")
                }
            } catch {
                log?("speech model download failed")
            }
        }
    }

    /// Starts an analysis for one recording. Nil when the newer engine can't run right now
    /// (the Recorder then uses the older one).
    static func start(language: String, contextualStrings: [String], onText: @escaping @MainActor (String) -> Void) async -> ModernSpeech? {
        guard let transcriber = await transcriber(for: language),
              await AssetInventory.status(forModules: [transcriber]) == .installed,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        let options: SpeechAnalyzer.Options
        if #available(iOS 27.0, macOS 27.0, *) {
            // Keep the model loaded between recordings while the app is open: the next one starts at once.
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
        if !contextualStrings.isEmpty {
            // His names and terms, as hints (the dictionary pass after cleanup still applies).
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(context)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let engine = ModernSpeech(analyzer: analyzer, sink: AnalyzerSink(continuation: continuation, format: format))
        engine.results = Task { [weak engine] in
            do {
                for try await result in transcriber.results {
                    guard let engine else { return }
                    let words = String(result.text.characters)
                    engine.lock.withLock {
                        if result.isFinal {
                            engine.settled = join(engine.settled, words)
                            engine.pending = ""
                        } else {
                            engine.pending = words
                        }
                    }
                    let all = engine.text
                    await onText(all)
                }
            } catch {}
            if let engine { engine.lock.withLock { engine.ended = true } }
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            engine.results?.cancel()
            return nil
        }
        return engine
    }

    /// The mic stopped: settle the last words. Returns everything heard. `timeout` bounds the wait.
    func finish(timeout: TimeInterval) async -> String {
        sink.finish()
        let analyzer = self.analyzer
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let over = lock.withLock { ended }
            if over { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return text
    }

    /// Stop now, dropping anything unsettled (an abandoned start).
    func cancel() {
        sink.finish()
        results?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
