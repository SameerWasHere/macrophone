import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether on-device cleanup can run here, and if not, the one line that explains why.
public enum CleanupAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceOff
    case modelDownloading
    case osTooOld
    case languageNotSupported

    public var isAvailable: Bool { self == .available }

    public var explanation: String {
        switch self {
        case .available: return ""
        case .deviceNotEligible: return "Cleanup needs an iPhone that supports Apple Intelligence."
        case .appleIntelligenceOff: return "Turn on Apple Intelligence in Settings to use cleanup."
        case .modelDownloading: return "Apple Intelligence is still downloading. Cleanup will turn on when it's ready."
        case .osTooOld: return "Cleanup needs iOS 26 or later."
        case .languageNotSupported: return "Cleanup works in English only for now."
        }
    }
}

/// The result of one cleanup pass.
public struct CleanupResult: Sendable, Equatable {
    /// Nil when cleanup didn't run or its output was rejected — deliver the raw text.
    public var cleaned: String?
    /// A short reason when cleanup was skipped, for diagnostics (never contains text).
    public var skipped: String?

    public init(cleaned: String?, skipped: String? = nil) {
        self.cleaned = cleaned
        self.skipped = skipped
    }
}

/// What happened to each chunk of one cleanup — for the eval tool and tests. Holds text; never log it.
public struct CleanupTrace: Sendable {
    public struct Chunk: Sendable {
        public var input: String
        public var modelOutput: String?
        /// Why the guard turned the model's edit down (a label, never text). Nil = accepted or never produced.
        public var rejected: String?
        /// The model threw (guardrail, refusal, context size…).
        public var error: String?
        public var ms: Int = 0
    }
    public var chunks: [Chunk] = []
}

/// Runs cleanup with Apple's on-device model. Everything stays on this device.
public enum Cleaner {
    public static func availability(language: String) -> CleanupAvailability {
        guard language.lowercased().hasPrefix("en") else { return .languageNotSupported }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
            case .unavailable(.modelNotReady): return .modelDownloading
            case .unavailable: return .deviceNotEligible
            }
        }
        return .osTooOld
        #else
        return .osTooOld
        #endif
    }

    /// Loads the model and builds the exact session (instructions + worked examples) the next
    /// cleanup with the same level and dictionary will use, so it starts at once. Call when
    /// recording starts, and again if the level or dictionary changes before it ends.
    /// Measured on a Mac: a short dictation cleans in ~0.5 s prewarmed vs ~0.8–1.9 s without,
    /// ~3.4 s when the model had been idle.
    public static func prewarm(level: CleanupLevel, dictionary: [String]) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), case .available = SystemLanguageModel.default.availability, level != .off {
            let terms = DictionaryPass.normalize(dictionary)
            let session = makeSession(level: level, dictionary: terms)
            session.prewarm()
            Warm.shared.put(session, key: Warm.key(level, terms))
        }
        #endif
    }

    /// Cleans `raw`. Never throws: on any failure it returns `cleaned: nil` and the caller
    /// delivers the raw transcript. The dictionary casing pass runs first, deterministically.
    public static func clean(_ raw: String, level: CleanupLevel, dictionary: [String], language: String) async -> CleanupResult {
        await cleanTraced(raw, level: level, dictionary: dictionary, language: language, deadline: nil).result
    }

    /// `clean` with a time budget, for long dictations. The model runs one chunk at a time
    /// (~150–220 characters of transcript a second on an M-series Mac; parallel requests don't go faster),
    /// so a chunk that can't finish before `deadline` isn't started: it and the rest go out as
    /// spoken, and the chunks already done stay cleaned. `skipped` is "partial" when that happens.
    /// A chunk already running can overrun a little — set your own hard stop a few seconds later.
    public static func clean(_ raw: String, level: CleanupLevel, dictionary: [String], language: String, deadline: Date) async -> CleanupResult {
        await cleanTraced(raw, level: level, dictionary: dictionary, language: language, deadline: deadline).result
    }

    /// `clean`, plus what happened to each chunk — for the eval tool and tests only.
    /// The trace holds dictation text, so it must never reach diagnostics or logs.
    public static func cleanTraced(_ raw: String, level: CleanupLevel, dictionary: [String], language: String,
                                   deadline: Date? = nil) async -> (result: CleanupResult, trace: CleanupTrace) {
        var trace = CleanupTrace()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard level != .off, !trimmed.isEmpty else { return (CleanupResult(cleaned: nil, skipped: level == .off ? "off" : "empty"), trace) }
        let availability = availability(language: language)
        guard availability.isAvailable else { return (CleanupResult(cleaned: nil, skipped: "unavailable"), trace) }
        let terms = DictionaryPass.normalize(dictionary)
        let input = DictionaryPass.fixCasing(trimmed, terms: terms)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let pieces = CleanupGuard.chunks(input, level: level)
            var out = pieces
            var ranOutOfTime = false
            for (i, chunk) in pieces.enumerated() {
                if let deadline, Date().addingTimeInterval(estimatedSeconds(chunk)) > deadline {
                    ranOutOfTime = true
                    break
                }
                let r = await cleanChunk(chunk, level: level, dictionary: terms)
                out[i] = r.0
                trace.chunks.append(r.1)
            }
            let joined = out.joined(separator: level == .heavy ? "\n\n" : " ")
            if joined == input && input == trimmed { return (CleanupResult(cleaned: nil, skipped: ranOutOfTime ? "deadline" : nil), trace) }
            return (CleanupResult(cleaned: joined, skipped: ranOutOfTime ? "partial" : nil), trace)
        }
        #endif
        return (CleanupResult(cleaned: nil, skipped: "unavailable"), trace)
    }

    /// A conservative guess at one chunk's model time, from the eval's measurements.
    static func estimatedSeconds(_ chunk: String) -> TimeInterval {
        1.0 + Double(chunk.count) / 140
    }

    #if canImport(FoundationModels)
    /// One chunk through the model and the guard. Returns the text to use (the edit, or the chunk as spoken).
    @available(iOS 26.0, macOS 26.0, *)
    static func cleanChunk(_ chunk: String, level: CleanupLevel, dictionary: [String]) async -> (String, CleanupTrace.Chunk) {
        let t0 = Date()
        var step = CleanupTrace.Chunk(input: chunk)
        var text = chunk
        do {
            let edited: String
            do {
                edited = try await run(chunk, level: level, dictionary: dictionary)
            } catch where isTransient(error) {
                // Seen once in ~1,500 calls (error -1 on a chunk that succeeds on the next try).
                step.error = "retried: " + String(String(describing: error).prefix(80))
                edited = try await run(chunk, level: level, dictionary: dictionary)
                step.error = nil
            }
            step.modelOutput = edited
            switch CleanupGuard.check(original: chunk, edited: edited, level: level, dictionary: dictionary) {
            case .accept(let accepted): text = accepted
            case .reject(let why): step.rejected = why  // keep it as spoken
            }
        } catch {
            // Guardrail refusals, context overflow, model busy: keep the words as spoken.
            step.error = String(String(describing: error).prefix(160))
        }
        step.ms = Int(Date().timeIntervalSince(t0) * 1000)
        return (text, step)
    }

    /// A fresh session: the level's instructions, then the worked examples as earlier turns.
    /// `permissiveContentTransformations` because the job is transforming the user's own words —
    /// with default guardrails, profanity, grief, medical and legal dictation get refused.
    @available(iOS 26.0, macOS 26.0, *)
    static func makeSession(level: CleanupLevel, dictionary: [String]) -> LanguageModelSession {
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [.text(.init(content: CleanupPrompts.instructions(level: level, dictionary: dictionary)))],
                                                  toolDefinitions: [])),
        ]
        for (said, edited) in CleanupPrompts.examples(level: level) {
            entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: CleanupPrompts.prompt(for: said)))])))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: edited))])))
        }
        return LanguageModelSession(model: model, tools: [], transcript: Transcript(entries: entries))
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func run(_ text: String, level: CleanupLevel, dictionary: [String]) async throws -> String {
        let session = (Warm.shared.take(key: Warm.key(level, dictionary)) as? LanguageModelSession) ?? makeSession(level: level, dictionary: dictionary)
        // Greedy: the same dictation always cleans the same way, and sampling only adds drift.
        let options = GenerationOptions(samplingMode: .greedy, temperature: nil, maximumResponseTokens: max(128, text.utf8.count / 2 + 64))
        let response = try await session.respond(to: CleanupPrompts.prompt(for: text), options: options)
        return response.content
    }
    #endif

    /// Errors worth one retry: not a guardrail, refusal, context-size or language problem
    /// (those would fail the same way again). Matched by name so it works with both the
    /// iOS 26 `GenerationError` and the iOS 27 `LanguageModelError`.
    static func isTransient(_ error: Error) -> Bool {
        let d = String(describing: error).lowercased()
        return !["guardrail", "refusal", "context", "unsupported", "assets", "unsafe"].contains { d.contains($0) }
    }
}

/// Holds the one session `prewarm` built until the next cleanup with the same settings takes it.
final class Warm: @unchecked Sendable {
    static let shared = Warm()
    private let lock = NSLock()
    private var key: String?
    private var session: AnyObject?

    static func key(_ level: CleanupLevel, _ dictionary: [String]) -> String {
        level.rawValue + "|" + dictionary.joined(separator: "\u{1F}")
    }

    func put(_ session: AnyObject, key: String) {
        lock.lock(); defer { lock.unlock() }
        self.key = key
        self.session = session
    }

    func take(key: String) -> AnyObject? {
        lock.lock(); defer { lock.unlock() }
        guard self.key == key, let s = session else { return nil }
        session = nil
        self.key = nil
        return s
    }
}

/// Deterministic checks on the model's output. If an edit looks like an answer, a reply,
/// a translation, a summary that lost content, or a refusal, it's rejected and that chunk
/// goes out as spoken. Every rule has a unit test in `CleanupTests.swift`.
public enum CleanupGuard {
    /// Chunk size in characters. Smaller chunks keep the ~3B model from summarizing.
    static let maxChunk = 1_500

    public enum Verdict: Equatable, Sendable {
        case accept(String)
        case reject(String)
    }

    /// Splits long dictations at sentence boundaries so each piece fits the model's context
    /// and stays short enough to be edited, not summarized. Unpunctuated speech (one huge
    /// "sentence") falls back to splitting at word boundaries.
    public static func chunks(_ text: String, level: CleanupLevel) -> [String] {
        guard text.count > maxChunk else { return [text] }
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            guard let s else { return }
            if s.count <= maxChunk { sentences.append(s) } else { sentences += splitAtWords(s) }
        }
        var pieces: [String] = []
        var current = ""
        for s in sentences {
            if current.count + s.count > maxChunk, !current.isEmpty {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            current += s
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(current.trimmingCharacters(in: .whitespaces)) }
        return pieces
    }

    /// Splits text with no sentence ends into roughly equal word-boundary pieces under `maxChunk`,
    /// preferring to cut before a word that usually starts a new thought ("and", "so", "but"…).
    static func splitAtWords(_ s: String) -> [String] {
        let words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let parts = Int((Double(s.count) / Double(maxChunk)).rounded(.up))
        let target = s.count / max(parts, 1)
        let breakers: Set<String> = ["and", "so", "but", "also", "oh", "okay", "anyway", "then", "because", "which", "number"]
        var out: [String] = []
        var cur: [String] = []
        var len = 0
        for w in words {
            let lw = w.lowercased()
            if len >= target - 120, breakers.contains(lw) || len >= target, !cur.isEmpty {
                out.append(cur.joined(separator: " ") + " ")
                cur = []; len = 0
            }
            cur.append(w); len += w.count + 1
        }
        if !cur.isEmpty { out.append(cur.joined(separator: " ")) }
        return out
    }

    /// Returns the edited text tidied (tags/quotes/preamble stripped), or nil to reject it.
    public static func accept(original: String, edited: String, level: CleanupLevel, dictionary: [String]) -> String? {
        if case .accept(let s) = check(original: original, edited: edited, level: level, dictionary: dictionary) { return s }
        return nil
    }

    /// `accept`, with the reason when the edit is rejected. Reasons are fixed labels (safe for diagnostics).
    public static func check(original: String, edited: String, level: CleanupLevel, dictionary: [String]) -> Verdict {
        guard level != .off else { return .reject("off") }
        let e = tidy(edited, original: original, level: level)
        guard !e.isEmpty else { return .reject("empty") }
        let o = original
        let ol = Text.fold(o), el = Text.fold(e)

        // 1. A refusal or an assistant's reply ("Sure! …", "I can't help with that") the speaker didn't say.
        if Text.refusals.contains(where: { el.contains($0) && !ol.contains($0) }) { return .reject("refusal") }
        if let opener = Text.replyOpeners.first(where: { el.hasPrefix($0) }), !ol.prefix(60).contains(opener) { return .reject("reply") }

        // 2. Code or markdown the speaker can't have dictated means it did the task — including
        //    command-line flags nobody said ("in the default namespace" → "-n default").
        if e.contains("```") && !o.contains("```") { return .reject("code") }
        if Text.hasFlag(e), !Text.hasFlag(o), !Text.words(o).contains(where: { ["dash", "hyphen", "minus", "flag", "flags"].contains($0) }) {
            return .reject("code")
        }

        // 3. A worked example's words must never show up in an edit (a replayed prefix was already dropped).
        if Text.leaksExample(edited: e, original: o, level: level) { return .reject("example leaked") }

        // 4. Length: light/medium only remove; heavy restructures but keeps content.
        let on = Double(max(o.count, 1)), en = Double(e.count)
        switch level {
        case .off: return .reject("off")
        case .light, .medium:
            if en > on * 1.25 + 20 { return .reject("too long") }
            if en < on * (level == .light ? 0.45 : 0.35) && on > 60 { return .reject("too short") }
        case .heavy:
            if en > on * 1.6 + 40 { return .reject("too long") }
            if en < on * 0.3 && on > 80 { return .reject("too short") }
        }

        // 5. Exact things survive exactly: dictionary terms, URLs, emails, paths, code identifiers.
        for t in dictionary where Text.containsWord(o, t) && !Text.containsWord(e, t) { return .reject("dictionary term lost") }
        for t in Text.technicalTokens(o) where !e.contains(t) { return .reject("identifier lost") }

        // 6. Every number survives, unless (medium/heavy) the speaker retracted it ("5, no wait, 6").
        if let lost = Text.lostNumber(original: o, edited: e, allowRetracted: level != .light) { _ = lost; return .reject("number lost") }

        // 7. Words: an edit re-uses the speaker's words. New content words mean it answered,
        //    translated or embellished; missing ones mean it summarized or dropped a point.
        //    Allowances: words a dictionary fix replaced ("post gress" → "Postgres"), and
        //    (medium/heavy) the words of a retracted false start.
        let st = wordStats(original: o, edited: e, dictionary: dictionary)
        // Words a dictionary fix replaced must sound like the term ("cube control" → kubectl);
        // anything else that went missing still counts.
        let newTerms = dictionary.filter { Text.containsWord(e, $0) && !Text.containsWord(o, $0) }
        let fixedAway = st.dropped.filter { d in newTerms.contains { Text.soundsLike(d, $0) } }
        let correctionAllowance = level == .light ? 0 : st.corrections * 3
        let novelAllowance: Int, dropAllowance: Int
        switch level {
        case .off: return .reject("off")
        case .light:
            novelAllowance = Int(Double(st.outputWords) * 0.08)
            dropAllowance = Int(Double(st.inputWords) * 0.05)
        case .medium:
            novelAllowance = Int(Double(st.outputWords) * 0.10)
            dropAllowance = correctionAllowance + Int(Double(st.inputWords) * 0.06)
        case .heavy:
            novelAllowance = Int(Double(st.outputWords) * 0.25)
            dropAllowance = correctionAllowance + Int(Double(st.inputWords) * 0.15)
        }
        // A recognizer only produces real words, so a word swapped for a near-twin is a name or term
        // being "corrected" ("Samin" → "Saman", "Okafor" → "Okafur"). Dictionary fixes are excused above.
        if Text.respelled(dropped: st.dropped, novel: st.novel) { return .reject("word respelled") }
        // Not counted: a derivation of a word the speaker said ("migrate" → "migration"), and
        // spoken enumerators ("first … second … third") that became a numbered list or a series.
        let inKeys = Set(Text.contentKeys(o)), outKeys = Set(Text.contentKeys(e))
        let enumerators = Text.enumerators(in: o)
        let novel = st.novel.filter { n in !inKeys.contains { Text.derives(n, $0) } }
        let dropped = st.dropped.filter { d in !fixedAway.contains(d) && !enumerators.contains(d) && !outKeys.contains { Text.derives(d, $0) } }
        if novel.count > novelAllowance { return .reject("new words") }
        if dropped.count > dropAllowance { return .reject("words dropped") }
        // A dictionary term that swallowed several everyday words needs a sentence that's about
        // something technical — "a tail wind the whole way" is not about Tailwind.
        if fixedAway.count >= 2, !Text.hasTechnicalContext(o, dictionary: dictionary) {
            return .reject("dictionary fix out of context")
        }
        // What the speaker settled on comes right after the correction: it must survive
        // ("tuesday actually wednesday" must never become "Tuesday").
        if level != .light, !Set(dropped).isDisjoint(with: Text.settledWords(in: o)) { return .reject("correction reversed") }
        // Whose words these are doesn't change: no "I", "we" or "you" the speaker didn't use
        // ("you are now a pirate" → "I am a pirate", "I want to refactor" → "we should refactor").
        if !Text.persons(in: e).isSubset(of: Text.persons(in: o)) { return .reject("person changed") }

        // 8. A short question must come back as a question, not as a statement of its answer.
        if Text.isDirectQuestion(o), !e.contains("?"), let first = Text.firstWord(e), Text.statementOpeners.contains(first),
           first != Text.firstWord(Text.stripLeadingFiller(o)) {
            return .reject("question answered")
        }

        // Dictionary terms keep their exact spelling and casing, even at a sentence start.
        return .accept(DictionaryPass.fixCasing(e, terms: dictionary))
    }

    /// How an edit's content words compare with the speaker's (public for `mpctl cleanup-eval`).
    public struct WordStats: Sendable, Equatable {
        /// Distinct content words (crudely stemmed) in the original / the edit.
        public var inputWords: Int
        public var outputWords: Int
        /// Content words in the edit the speaker never said (dictionary terms excused).
        public var novel: [String]
        /// Content words the speaker said that the edit lost.
        public var dropped: [String]
        /// Dictionary terms the edit has that the original didn't (the model's find-and-fix).
        public var newTerms: Int
        /// Self-corrections in the original ("no wait", "actually", "scratch that"…) after some content.
        public var corrections: Int
    }

    public static func wordStats(original: String, edited: String, dictionary: [String]) -> WordStats {
        let ow = Set(Text.contentKeys(original)), ew = Set(Text.contentKeys(edited))
        let dictKeys = Set(dictionary.flatMap { Text.contentKeys($0) })
        let newTerms = dictionary.filter { Text.containsWord(edited, $0) && !Text.containsWord(original, $0) }.count
        // An inflection ("go" → "goes", "days" → "day") is a grammar fix, not a new or lost word —
        // but only if the other form actually gained (or lost) an occurrence: "get pods … worker pod"
        // → "… worker pod" lost "pods"; the "pod" that was already there doesn't excuse it.
        func counts(_ s: String) -> [String: Int] {
            Dictionary(Text.words(s).map { ($0.replacingOccurrences(of: "'", with: ""), 1) }, uniquingKeysWith: +)
        }
        let inCount = counts(original), outCount = counts(edited)
        func related(_ k: String, _ w: String) -> Bool {
            w != k && w.count >= 2 && (k.hasPrefix(w) || w.hasPrefix(k)) && abs(k.count - w.count) <= (w.count < 4 ? 2 : 3)
        }
        func inflectedAway(_ k: String) -> Bool {   // k was dropped; did a related form gain an occurrence?
            outCount.contains { w, n in related(k, w) && n > inCount[w, default: 0] }
        }
        func inflectedFrom(_ k: String) -> Bool {   // k is new; did a related form lose an occurrence?
            inCount.contains { w, n in related(k, w) && n > outCount[w, default: 0] }
        }
        return WordStats(inputWords: ow.count, outputWords: ew.count,
                         novel: ew.subtracting(ow).subtracting(dictKeys).filter { !inflectedFrom($0) }.sorted(),
                         dropped: ow.subtracting(ew).subtracting(dictKeys).filter { !inflectedAway($0) }.sorted(),
                         newTerms: newTerms, corrections: Text.corrections(in: original))
    }

    /// Strips what models wrap around an edit: our tags, quotes, "Here is the edited text:" lines,
    /// and trailing "Note: …" commentary the speaker didn't say.
    static func tidy(_ edited: String, original: String, level: CleanupLevel = .medium) -> String {
        var e = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<dictation>", "</dictation>", "<transcript>", "</transcript>"] { e = e.replacingOccurrences(of: tag, with: "") }
        e = e.trimmingCharacters(in: .whitespacesAndNewlines)
        // On a chunk that starts mid-thought the model sometimes replays a worked example's answer
        // (usually first), then edits the chunk. The speaker never said it: drop exactly that text.
        let spoken = Text.words(original).joined(separator: " ")
        for (_, example) in CleanupPrompts.examples(level: level) where e.count > example.count && e.contains(example) {
            guard !spoken.contains(Text.words(example).joined(separator: " ")) else { continue }
            e = e.replacingOccurrences(of: example, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            while e.contains("\n\n\n") { e = e.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
            while e.contains("  ") { e = e.replacingOccurrences(of: "  ", with: " ") }
        }
        let ol = Text.fold(original)
        // A first line that announces the edit.
        if let nl = e.firstIndex(of: "\n") {
            let first = Text.fold(String(e[..<nl])).trimmingCharacters(in: .whitespaces)
            if first.hasSuffix(":"), Text.preambleWords.contains(where: { first.contains($0) }), !ol.contains(first.dropLast()) {
                e = String(e[nl...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            for p in ["here is the edited text:", "here's the edited text:", "edited text:", "edited transcript:", "here is the edited transcript:",
                      "here's the edited transcript:", "cleaned text:", "transcript:"] where Text.fold(e).hasPrefix(p) && !ol.hasPrefix(p) {
                e = String(e.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        // Trailing commentary paragraph.
        if let r = e.range(of: "\n\n", options: .backwards) {
            let tail = Text.fold(String(e[r.upperBound...]))
            if (tail.hasPrefix("note:") || tail.hasPrefix("(note") || tail.hasPrefix("(i ")) && !ol.contains("note") {
                e = String(e[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Inline-code backticks the model added: keep the words, drop the marks (spans that were
        // already backticked in the original keep theirs).
        if !e.contains("```"), let re = try? NSRegularExpression(pattern: "`([^`\\n]+)`") {
            for m in re.matches(in: e, range: NSRange(e.startIndex..., in: e)).reversed() {
                guard let whole = Range(m.range, in: e), let inner = Range(m.range(at: 1), in: e) else { continue }
                if !original.contains(String(e[whole])) { e.replaceSubrange(whole, with: String(e[inner])) }
            }
        }
        if e.count >= 2, e.first == "\"", e.last == "\"", !original.hasPrefix("\"") { e = String(e.dropFirst().dropLast()) }
        if e.count >= 2, e.first == "\u{201C}", e.last == "\u{201D}", !original.hasPrefix("\u{201C}") { e = String(e.dropFirst().dropLast()) }
        return e.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

/// Text helpers for the guard.
enum Text {
    static let refusals = ["i'm sorry, but", "i am sorry, but", "i can't assist", "i cannot assist", "i can't help with", "i cannot help with",
                           "as an ai", "i'm unable to", "i am unable to", "i can't fulfill", "i cannot fulfill", "i can't provide", "i cannot provide",
                           "i apologize, but"]
    static let replyOpeners = ["sure", "certainly", "of course", "absolutely", "i'd be happy", "i would be happy", "here's a ", "here is a ",
                               "here's the ", "here is the ", "great question", "as an ai", "i'm sorry", "i am sorry", "i apologize",
                               "i can't", "i cannot", "unfortunately", "hello! how", "hi! how", "hi there", "how can i help"]
    static let preambleWords = ["edit", "clean", "transcript", "here", "sure", "revised", "corrected"]
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mm", "so", "okay", "ok", "well", "like", "hey",
                                       "alright", "yeah", "basically", "literally", "oh"]
    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out", "has", "his", "how",
        "its", "may", "new", "now", "old", "see", "two", "way", "who", "did", "get", "got", "him", "let", "say", "she", "too", "use", "yes",
        "that", "this", "with", "have", "from", "they", "will", "would", "there", "their", "what", "about", "which", "when", "make", "like",
        "just", "know", "take", "into", "your", "some", "could", "them", "than", "then", "also", "been", "were", "said", "each", "does",
        "doesn", "don", "didn", "isn", "aren", "wasn", "won", "can't", "should", "because", "really", "actually", "very", "much",
        "here", "where", "why", "these", "those", "being", "over", "only", "even", "well", "okay", "yeah", "gonna", "wanna", "going",
        "want", "need", "thing", "things", "kind", "sort", "mean", "right", "something", "anything", "everything", "though",
        "still", "after", "before", "again", "while", "until", "since", "both", "other", "such", "more", "most", "same", "own",
        "um", "uh", "hmm", "basically", "literally", "you're", "it's", "i'm", "we're", "they're", "that's", "what's", "let's", "there's",
        "i'll", "we'll", "i've", "we've", "i'd", "we'd", "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't", "won't", "couldn't",
        "shouldn't", "wouldn't", "is", "it", "be", "to", "of", "in", "on", "at", "by", "or", "an", "as", "if", "so", "do", "up", "we",
        "my", "me", "he", "no", "go", "us", "am", "oh", "a", "i", "please", "thanks", "hey",
    ]
    static let numberWords: Set<String> = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                                           "twelve", "fifteen", "twenty", "thirty", "forty", "fifty", "hundred", "thousand", "million",
                                           "billion", "half", "dozen", "percent", "dollars", "dollar"]

    /// Lowercased, curly quotes straightened.
    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
    }

    static func containsWord(_ text: String, _ word: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return text.range(of: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func words(_ s: String) -> [String] {
        let f = fold(s)
        guard let re = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:'[\\p{L}]+)?") else { return [] }
        return re.matches(in: f, range: NSRange(f.startIndex..., in: f)).compactMap { Range($0.range, in: f).map { String(f[$0]) } }
    }

    /// Content words reduced to a crude stem, so "sorts"/"sorted"/"sorting" match.
    /// Apostrophes are dropped first ("let's" ≡ "lets"), so curly/straight/missing ones all agree.
    static func contentKeys(_ s: String) -> [String] {
        words(s).compactMap { w -> String? in
            var w = w
            if let base = contractionBase(w) { w = base }
            w = w.replacingOccurrences(of: "'", with: "")
            for (a, b) in [("gonna", "going"), ("wanna", "want"), ("gotta", "got"), ("kinda", "kind"), ("cause", "because"), ("till", "until")] where w == a { w = b }
            guard w.count >= 3, !bareStopwords.contains(w), !numberWords.contains(w), !fillers.contains(w), !spokenSymbols.contains(w),
                  w.first?.isNumber != true else { return nil }
            return stem(w)
        }
    }

    /// "doesn't" → "does", "Sam's" → "sam", "we'll" → "we"; nil when there's no contraction.
    static func contractionBase(_ w: String) -> String? {
        for suf in ["n't", "'s", "'re", "'ll", "'ve", "'d", "'m"] where w.hasSuffix(suf) && w.count > suf.count {
            return w == "can't" ? "can" : w == "won't" ? "will" : String(w.dropLast(suf.count))
        }
        return nil
    }

    /// Words a speaker says for a symbol ("dash dash force", "header dot tsx") — the edit may write the symbol.
    static let spokenSymbols: Set<String> = ["dash", "dot", "slash", "backslash", "underscore", "colon", "semicolon", "tilde", "hash",
                                             "hashtag", "star", "asterisk", "ampersand", "pipe", "caret", "bracket", "brackets", "brace",
                                             "braces", "paren", "parens", "parenthesis", "quote", "quotes", "comma", "period", "hyphen",
                                             "equals", "plus", "minus", "backtick", "newline"]

    static let bareStopwords: Set<String> = Set(stopwords.map { $0.replacingOccurrences(of: "'", with: "") })

    /// First words of a statement — an edit of a question that starts like this answered it.
    static let statementOpeners: Set<String> = ["yes", "no", "the", "it", "it's", "its", "there", "there's", "that", "that's", "this", "a",
                                                "an", "they", "he", "she", "i", "we", "you", "currently", "in", "to", "paris"]

    /// Self-corrections that follow some content: "tuesday actually wednesday", "50000 scratch that 60000".
    static func corrections(in s: String) -> Int {
        let f = fold(s)
        guard let re = try? NSRegularExpression(pattern: correctionPattern) else { return 0 }
        return re.matches(in: f, range: NSRange(f.startIndex..., in: f)).filter { m in
            guard let r = Range(m.range, in: f) else { return false }
            return words(String(f[..<r.lowerBound])).contains { !fillers.contains($0) }
        }.count
    }

    /// A rough consonant skeleton: "cube" → "kb", "kubectl" → "kbktl", "gress" → "grs".
    static func skeleton(_ w: String) -> [Character] {
        var s = w.lowercased().replacingOccurrences(of: "ph", with: "f").replacingOccurrences(of: "x", with: "ks")
        s = String(s.map { c -> Character in
            switch c { case "c", "q": return "k"; case "z": return "s"; default: return c }
        })
        return s.filter { $0.isLetter && !"aeiouhwy".contains($0) }
    }

    /// Does a dropped word sound like part of a dictionary term? Most of its consonants appear,
    /// in order, in the term's ("control" in "kubectl": k-t-l; "pods" in "CrashLoopBackOff": no).
    static func soundsLike(_ word: String, _ term: String) -> Bool {
        let w = skeleton(word), t = skeleton(term)
        guard !w.isEmpty, !t.isEmpty else { return false }
        var dp = Array(repeating: Array(repeating: 0, count: t.count + 1), count: w.count + 1)
        for i in 1...w.count { for j in 1...t.count { dp[i][j] = w[i - 1] == t[j - 1] ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1]) } }
        return Double(dp[w.count][t.count]) >= Double(w.count) * 0.6
    }

    /// Which grammatical persons a text speaks in: "1" (I/me/my), "1p" (we/us/our), "2" (you/your).
    static func persons(in s: String) -> Set<String> {
        var out = Set<String>()
        for w in words(s) {
            switch w {
            case "i", "me", "my", "mine", "myself", "i'm", "i'll", "i've", "i'd": out.insert("1")
            case "we", "us", "our", "ours", "ourselves", "we're", "we'll", "we've", "we'd": out.insert("1p")
            case "you", "your", "yours", "yourself", "you're", "you'll", "you've", "you'd", "ya": out.insert("2")
            default: break
            }
        }
        return out
    }

    /// "migration" from "migrate", "configuration" from "configure": a shared stem of 5+ letters
    /// covering most of the shorter word.
    static func derives(_ a: String, _ b: String) -> Bool {
        guard a != b, a.count >= 5, b.count >= 5 else { return false }
        let common = zip(a, b).prefix(while: { $0 == $1 }).count
        return common >= 5 && Double(common) >= Double(min(a.count, b.count)) * 0.7
    }

    /// Ordinals used to enumerate ("first … second …"): only when two or more appear.
    static func enumerators(in s: String) -> Set<String> {
        let ordinals: Set<String> = ["first", "second", "third", "fourth", "fifth", "sixth", "lastly", "finally"]
        let found = Set(words(s)).intersection(ordinals)
        return found.count >= 2 ? Set(found.map(stem)) : []
    }

    /// A command-line flag: " -n", " --force".
    static func hasFlag(_ s: String) -> Bool {
        s.range(of: "(^|\\s)--?[A-Za-z][\\w-]*", options: .regularExpression) != nil
    }

    /// Words that make a sentence plausibly about software (or another dictionary term, a digit,
    /// an identifier) — the context a sound-alike dictionary fix needs.
    static let technicalWords: Set<String> = [
        "app", "apps", "api", "code", "server", "database", "db", "deploy", "deployment", "build", "built", "page", "site", "website",
        "project", "file", "files", "repo", "branch", "commit", "push", "pull", "merge", "test", "tests", "function", "component",
        "run", "install", "namespace", "pod", "pods", "cluster", "frontend", "backend", "auth", "login", "query", "table", "framework",
        "library", "package", "version", "config", "logs", "log", "terminal", "command", "script", "simulator", "css", "styles",
        "ui", "ux", "design", "data", "model", "prompt", "bug", "error", "crash", "staging", "production", "prod", "docker",
        "container", "cloud", "endpoint", "service", "users", "user", "profiles", "stack", "uses", "using", "store", "stored",
        "landing", "dashboard", "workflow", "pipeline", "ci", "release", "ios", "android", "mac", "web", "browser", "sdk", "cli",
        "claim", "claims", "policy", "invoice", "account", "form", "patient", "dose", "mg", "prescription", "contract",
    ]

    static func hasTechnicalContext(_ s: String, dictionary: [String]) -> Bool {
        if s.contains(where: \.isNumber) || !technicalTokens(s).isEmpty { return true }
        if dictionary.contains(where: { containsWord(s, $0) }) { return true }
        return !Set(words(s)).isDisjoint(with: technicalWords)
    }

    /// A dropped word and a new word that differ by a few letters (2, or a third of the word):
    /// "samin" → "saman", "northwind" → "northwest". "migrate" → "migration" is too far apart to count.
    static func respelled(dropped: [String], novel: [String]) -> Bool {
        for d in dropped where d.count >= 4 {
            for n in novel where n.count >= 4 && n.first == d.first && abs(n.count - d.count) <= 2 {
                if editDistance(Array(d), Array(n)) <= max(2, min(d.count, n.count) / 3) { return true }
            }
        }
        return false
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[b.count]
    }

    static let correctionPattern = "\\b(no wait|no no|nope|no|actually|i mean|sorry|scratch that|wait|make that|or rather|correction)\\b"

    /// The content words right after each self-correction — what the speaker settled on.
    static func settledWords(in s: String) -> Set<String> {
        let f = fold(s)
        guard let re = try? NSRegularExpression(pattern: correctionPattern) else { return [] }
        var out = Set<String>()
        for m in re.matches(in: f, range: NSRange(f.startIndex..., in: f)) {
            guard let r = Range(m.range, in: f), words(String(f[..<r.lowerBound])).contains(where: { !fillers.contains($0) }) else { continue }
            let cues: Set<String> = ["no", "nope", "wait", "actually", "i", "mean", "sorry", "scratch", "that", "make", "rather", "or", "correction", "um", "uh"]
            let after = words(String(f[r.upperBound...])).drop(while: { cues.contains($0) }).joined(separator: " ")
            out.formUnion(contentKeys(after).prefix(3))
        }
        return out
    }

    /// True when a five-word run from the level's worked examples (with at least two content words)
    /// shows up in an edit of text that didn't say it — a replayed or paraphrased example.
    static func leaksExample(edited: String, original: String, level: CleanupLevel) -> Bool {
        let e = " " + words(edited).joined(separator: " ") + " ", o = " " + words(original).joined(separator: " ") + " "
        for (_, example) in CleanupPrompts.examples(level: level) {
            let w = words(example)
            guard w.count >= 5 else { continue }
            for i in 0...(w.count - 5) {
                let gram = Array(w[i..<(i + 5)])
                guard contentKeys(gram.joined(separator: " ")).count >= 2 else { continue }
                let phrase = " " + gram.joined(separator: " ") + " "
                if e.contains(phrase) && !o.contains(phrase) { return true }
            }
        }
        return false
    }

    /// Strips one inflection. No truncation: "northwind" and "northwest" must stay different words.
    static func stem(_ w: String) -> String {
        var s = w
        for suf in ["ing", "ed", "es", "ly", "s"] where s.count > suf.count + 3 && s.hasSuffix(suf) {
            s = String(s.dropLast(suf.count)); break
        }
        return s
    }

    /// URLs, emails, paths, file names and code identifiers (camelCase, PascalCase with inner
    /// capitals, snake_case) — things an edit must keep character for character.
    static func technicalTokens(_ s: String) -> [String] {
        let patterns = [
            "https?://[^\\s]+",
            "[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+",
            "(?<![\\w/])(?:[\\w.-]+/)+[\\w.-]+",                 // a/b/c paths
            "\\b[A-Za-z_][\\w-]*\\.(?:tsx?|jsx?|swift|py|rb|go|rs|java|kt|json|ya?ml|toml|md|txt|sh|css|html|sql|env|plist|lock)\\b",
            "\\b[a-z]+[A-Z][A-Za-z0-9]*\\b",                       // camelCase
            "\\b[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*\\b",               // PascalCase with inner capitals
            "\\b[A-Za-z0-9]+_[A-Za-z0-9_]+\\b",                    // snake_case / SCREAMING_CASE
        ]
        var out: [String] = []
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range, in: s) else { continue }
                var t = String(s[r])
                while let last = t.last, ".,;:!?)".contains(last) { t.removeLast() }
                if t.count >= 3 { out.append(t) }
            }
        }
        return out
    }

    struct NumberToken { var text: String; var digits: String; var range: Range<String.Index> }

    static func numberTokens(_ s: String) -> [NumberToken] {
        guard let re = try? NSRegularExpression(pattern: "\\d+(?:[.,:/-]\\d+)*") else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let r = Range(m.range, in: s) else { return nil }
            let t = String(s[r])
            return NumberToken(text: t, digits: t.filter(\.isNumber), range: r)
        }
    }

    /// The first number in `original` that `edited` dropped, if any. "2,000" ≡ "2000", "7 30" ≡ "7:30".
    /// With `allowRetracted`, a number followed closely by a correction ("5, no wait, 6") may go.
    static func lostNumber(original: String, edited: String, allowRetracted: Bool) -> String? {
        let outTokens = numberTokens(edited)
        var have = Set(outTokens.map(\.digits))
        for t in outTokens { for run in t.text.split(whereSeparator: { !$0.isNumber }) { have.insert(String(run)) } }
        for t in numberTokens(original) where !have.contains(t.digits) {
            let runs = t.text.split(whereSeparator: { !$0.isNumber }).map(String.init)
            if runs.count > 1, runs.allSatisfy({ have.contains($0) }) { continue }
            if allowRetracted {
                let after = fold(String(original[t.range.upperBound...].prefix(40)))
                if after.range(of: "\\b(no|nope|actually|i mean|sorry|scratch that|wait|make that|rather|correction|not)\\b", options: .regularExpression) != nil { continue }
            }
            return t.text
        }
        return nil
    }

    static func stripLeadingFiller(_ s: String) -> String {
        var ws = words(s)
        while let f = ws.first, fillers.contains(f) { ws.removeFirst() }
        return ws.joined(separator: " ")
    }

    static func firstWord(_ s: String) -> String? { words(s).first }

    /// A short dictation that is plainly a question to someone ("what's the capital of France",
    /// "can you hear me") — the kind a model is most tempted to answer.
    static func isDirectQuestion(_ s: String) -> Bool {
        let w = words(stripLeadingFiller(s))
        guard w.count >= 2, w.count <= 25 else { return false }
        let wh: Set<String> = ["what", "what's", "how", "why", "when", "where", "who", "which", "whats"]
        let aux: Set<String> = ["is", "are", "was", "do", "does", "did", "can", "could", "would", "will", "should", "has", "have"]
        let subj: Set<String> = ["you", "it", "i", "we", "they", "he", "she", "this", "that", "there", "the", "my", "your"]
        if wh.contains(w[0]) { return w[0] == "what's" || w[0] == "whats" || aux.contains(w[1]) || w[1] == "time" || w[1] == "much" || w[1] == "many" }
        return aux.contains(w[0]) && subj.contains(w[1])
    }
}

/// Deterministic dictionary help that needs no model: restores the exact spelling and casing
/// of a dictionary term the recognizer produced in a different case ("Kubectl" → "kubectl").
public enum DictionaryPass {
    public static let maxTerms = 50

    public static func fixCasing(_ text: String, terms: [String]) -> String {
        var out = text
        for term in terms.prefix(maxTerms) where !term.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: term))
        }
        return out
    }

    /// Cleans user input for the dictionary: trimmed, de-duplicated, at most 50, each ≤ 40 chars.
    public static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in terms {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, s.count <= 40, seen.insert(s.lowercased()).inserted else { continue }
            out.append(s)
            if out.count == maxTerms { break }
        }
        return out
    }
}
