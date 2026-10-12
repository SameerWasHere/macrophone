import Foundation
import MacrophoneKit

/// Runs the messy-dictation test set through the real on-device model and checks each
/// output against the sample's expectations. Exit code 0 = every MEANING check passed
/// (the Milestone 3 gate); quality misses are reported but don't fail the run.
///
/// Sample schema (`Tests/MacrophoneKitTests/CleanupSamples.json`):
/// - `must_contain` / `must_not_contain`: meaning checks — key facts survive, the instruction
///   inside the dictation is not answered or executed. Checked at every level.
/// - `should_contain` / `should_not_contain`: quality checks — the level did its job
///   (filler gone, false start resolved at medium+, kept at light).
/// - `light` / `medium` / `heavy`: per-level additions with the same four keys.
/// - `unchanged`: already-clean input; the word-level edit ratio must stay tiny.
/// - `expect_raw`: cleanup must be skipped (e.g. language gating) — `language` sets the locale.
/// Patterns are case-insensitive and whole-word at alphanumeric edges; `a || b` means any of;
/// `re:…` is a case-sensitive regular expression.
struct CleanupExpect: Codable {
    var mustContain: [String]?
    var mustNotContain: [String]?
    var shouldContain: [String]?
    var shouldNotContain: [String]?

    enum CodingKeys: String, CodingKey {
        case mustContain = "must_contain", mustNotContain = "must_not_contain"
        case shouldContain = "should_contain", shouldNotContain = "should_not_contain"
    }
}

struct CleanupSample: Codable {
    var id: String
    var category: String?
    var input: String
    var levels: [CleanupLevel]?
    var dictionary: [String]?
    var language: String?
    var unchanged: Bool?
    var expectRaw: Bool?
    var note: String?
    var mustContain: [String]?
    var mustNotContain: [String]?
    var shouldContain: [String]?
    var shouldNotContain: [String]?
    var light: CleanupExpect?
    var medium: CleanupExpect?
    var heavy: CleanupExpect?

    enum CodingKeys: String, CodingKey {
        case id, category, input, levels, dictionary, language, unchanged, note, light, medium, heavy
        case expectRaw = "expect_raw"
        case mustContain = "must_contain", mustNotContain = "must_not_contain"
        case shouldContain = "should_contain", shouldNotContain = "should_not_contain"
    }

    func expect(_ level: CleanupLevel) -> CleanupExpect {
        let l: CleanupExpect? = level == .light ? light : level == .medium ? medium : level == .heavy ? heavy : nil
        return CleanupExpect(mustContain: (mustContain ?? []) + (l?.mustContain ?? []),
                             mustNotContain: (mustNotContain ?? []) + (l?.mustNotContain ?? []),
                             shouldContain: (shouldContain ?? []) + (l?.shouldContain ?? []),
                             shouldNotContain: (shouldNotContain ?? []) + (l?.shouldNotContain ?? []))
    }
}

enum CleanupEval {
    struct Row {
        var id: String, category: String, level: CleanupLevel, chars: Int, ms: Int
        var meaning: [String], quality: [String]
        var rawKept: Bool, refused: Bool, rejectReasons: [String], errors: [String]
        var editRatio: Double, added: Double
    }

    static func run(file: String?, level: String?, only: String?) async -> Int32 {
        let quiet = ProcessInfo.processInfo.environment["CLEANUP_EVAL_QUIET"] != nil  // print only WEAK/FAIL rows
        let path = file ?? "Tests/MacrophoneKitTests/CleanupSamples.json"
        guard let data = FileManager.default.contents(atPath: path) else { print("Couldn't read samples at \(path)"); return 2 }
        let samples: [CleanupSample]
        do { samples = try JSONDecoder().decode([CleanupSample].self, from: data) } catch { print("Bad samples file: \(error)"); return 2 }
        let availability = Cleaner.availability(language: "en-US")
        guard availability.isAvailable else { print("Model unavailable: \(availability.explanation)"); return 2 }

        let filters = only?.split(separator: ",").map(String.init) ?? []
        func selected(_ s: CleanupSample) -> Bool {
            filters.isEmpty || filters.contains { f in
                f.hasSuffix("*") ? (s.id.hasPrefix(f.dropLast()) || (s.category ?? "") == f.dropLast()) : (s.id == f || s.category == f)
            }
        }
        var rows: [Row] = []
        let started = Date()
        // CLEANUP_EVAL_PREWARM=none measures a cold first call; =wait gives prewarm 3s, like the app
        // does while the user is still speaking. Default: prewarm and go.
        switch ProcessInfo.processInfo.environment["CLEANUP_EVAL_PREWARM"] {
        case "none": break
        case "wait":
            let first = samples.first(where: selected)
            Cleaner.prewarm(level: level.flatMap(CleanupLevel.init(rawValue:)) ?? first?.levels?.first ?? .light, dictionary: first?.dictionary ?? [])
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        default: Cleaner.prewarm(level: .medium, dictionary: [])
        }
        for s in samples where selected(s) {
            let levels = level.flatMap(CleanupLevel.init(rawValue:)).map { [$0] } ?? s.levels ?? [.light, .medium, .heavy]
            for l in levels {
                let t0 = Date()
                // CLEANUP_EVAL_DEADLINE=<seconds> exercises the time-budget overload (partial cleanup).
                let deadline = ProcessInfo.processInfo.environment["CLEANUP_EVAL_DEADLINE"].flatMap(Double.init).map { Date().addingTimeInterval($0) }
                let (r, trace) = await Cleaner.cleanTraced(s.input, level: l, dictionary: s.dictionary ?? [], language: s.language ?? "en-US", deadline: deadline)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let out = r.cleaned ?? s.input
                let e = s.expect(l)
                var meaning: [String] = [], quality: [String] = []
                if s.expectRaw == true {
                    if r.cleaned != nil { meaning.append("cleaned text that should have been skipped") }
                } else {
                    for m in e.mustContain ?? [] where !matches(out, m) { meaning.append("missing “\(m)”") }
                    for m in e.mustNotContain ?? [] where matches(out, m) { meaning.append("contains “\(m)”") }
                    for m in e.shouldContain ?? [] where !matches(out, m) { quality.append("missing “\(m)”") }
                    for m in e.shouldNotContain ?? [] where matches(out, m) { quality.append("still has “\(m)”") }
                }
                let ratio = editRatio(s.input, out)
                let added = addedRatio(s.input, out, dictionary: s.dictionary ?? [])
                if s.unchanged == true {
                    let bound = l == .heavy ? 0.25 : 0.12
                    if ratio > bound { quality.append(String(format: "clean input changed (edit %.2f > %.2f)", ratio, bound)) }
                }
                if l == .light, s.expectRaw != true, added > 0.2 {
                    quality.append(String(format: "light added words (%.0f%%)", added * 100))
                }
                let rejects = trace.chunks.compactMap(\.rejected)
                let errors = trace.chunks.compactMap(\.error)
                let refused = !errors.isEmpty || rejects.contains("refusal")
                if refused { quality.append("refused / model error") }
                if s.expectRaw != true, !(rejects + errors).isEmpty { quality.append("raw kept: \((rejects + errors).joined(separator: ", "))") }
                rows.append(Row(id: s.id, category: s.category ?? "-", level: l, chars: s.input.count, ms: ms, meaning: meaning, quality: quality,
                                rawKept: r.cleaned == nil, refused: refused, rejectReasons: rejects, errors: errors, editRatio: ratio, added: added))

                let mark = !meaning.isEmpty ? "FAIL" : !quality.isEmpty ? "WEAK" : "PASS"
                if quiet && mark == "PASS" { continue }
                print("\(mark) [\(s.id) · \(l.rawValue) · \(ms)ms · edit \(String(format: "%.2f", ratio))]\(r.cleaned == nil ? " (raw kept)" : "")\(r.skipped.map { " (\($0))" } ?? "")")
                print("   in:  \(s.input)")
                print("   out: \(out.replacingOccurrences(of: "\n", with: "⏎ "))")
                for c in trace.chunks where c.rejected != nil || c.error != nil {
                    print("   ✗ chunk \(c.input.count)ch: \(c.rejected.map { "rejected (\($0))" } ?? "error \(c.error ?? "")")")
                    if let m = c.modelOutput, c.rejected != nil { print("     model: \(m.replacingOccurrences(of: "\n", with: "⏎ "))") }
                }
                if let c = trace.chunks.first, let m = c.modelOutput, trace.chunks.count == 1 {
                    let st = CleanupGuard.wordStats(original: c.input, edited: m, dictionary: s.dictionary ?? [])
                    print("   words: in \(st.inputWords) out \(st.outputWords) · new \(st.novel) · dropped \(st.dropped) · fixes \(st.newTerms) · corrections \(st.corrections)")
                }
                if !meaning.isEmpty { print("   meaning: \(meaning.joined(separator: "; "))") }
                if !quality.isEmpty { print("   quality: \(quality.joined(separator: "; "))") }
            }
        }
        summarize(rows, seconds: Int(Date().timeIntervalSince(started)))
        return rows.contains { !$0.meaning.isEmpty } ? 1 : 0
    }

    static func summarize(_ rows: [Row], seconds: Int) {
        print("\n── Summary (\(seconds)s) ─────────────────────────────")
        for l in [CleanupLevel.light, .medium, .heavy] {
            let r = rows.filter { $0.level == l }
            guard !r.isEmpty else { continue }
            let meaningOK = r.filter { $0.meaning.isEmpty }.count
            let allOK = r.filter { $0.meaning.isEmpty && $0.quality.isEmpty }.count
            let raw = r.filter { $0.rawKept }.count
            let refused = r.filter { $0.refused }.count
            let ms = r.map(\.ms).sorted()
            print("\(l.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) meaning \(meaningOK)/\(r.count) · full \(allOK)/\(r.count) · raw kept \(raw) · refused/errors \(refused) · p50 \(pct(ms, 0.5))ms p90 \(pct(ms, 0.9))ms")
            for (name, range) in [("<150ch", 0..<150), ("150–600ch", 150..<600), (">600ch", 600..<Int.max)] {
                let b = r.filter { range.contains($0.chars) }.map(\.ms).sorted()
                if !b.isEmpty { print("          \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) n=\(b.count) p50 \(pct(b, 0.5))ms p90 \(pct(b, 0.9))ms") }
            }
        }
        let reasons = rows.flatMap(\.rejectReasons) + rows.flatMap(\.errors).map { "error: " + String($0.prefix(60)) }
        if !reasons.isEmpty {
            print("guard rejections / errors: " + Dictionary(grouping: reasons, by: { $0 }).map { "\($0.key) ×\($0.value.count)" }.sorted().joined(separator: " · "))
        }
        let failing = rows.filter { !$0.meaning.isEmpty }
        if !failing.isEmpty { print("meaning failures: " + failing.map { "\($0.id)·\($0.level.rawValue)" }.joined(separator: ", ")) }
        let weak = rows.filter { $0.meaning.isEmpty && !$0.quality.isEmpty }
        if !weak.isEmpty { print("quality misses: " + weak.map { "\($0.id)·\($0.level.rawValue)" }.joined(separator: ", ")) }
    }

    static func pct(_ sorted: [Int], _ p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    // MARK: - Matching

    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        let full = normalize(text)
        return pattern.components(separatedBy: " || ").contains { alt in
            // Inline-code backticks are formatting, not content: `Result` type ≡ Result type.
            let text = alt.contains("`") ? full : full.replacingOccurrences(of: "`", with: "")
            if alt.hasPrefix("re:") {
                return text.range(of: String(alt.dropFirst(3)), options: .regularExpression) != nil
            }
            let p = normalize(alt)
            let isWord: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber } ?? false }
            var re = NSRegularExpression.escapedPattern(for: p)
            if isWord(p.first) { re = "(?<![\\p{L}\\p{N}])" + re }
            if isWord(p.last) { re += "(?![\\p{L}\\p{N}])" }
            return text.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    // MARK: - Edit metrics

    /// Lowercased words with contractions expanded and digit grouping removed, so
    /// "what's" ≡ "what is" and "50,000" ≡ "50000" for the edit metrics.
    static func words(_ s: String) -> [String] {
        var s = normalize(s).lowercased()
        s = s.replacingOccurrences(of: "(?<=\\d),(?=\\d{3})", with: "", options: .regularExpression)
        for (a, b) in [("can't", "can not"), ("won't", "will not"), ("n't", " not"), ("'re", " are"), ("'ll", " will"), ("'ve", " have"),
                       ("'m", " am"), ("'d", " would"), ("let's", "let us"), ("gonna", "going to"), ("wanna", "want to"), ("cannot", "can not")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        s = s.replacingOccurrences(of: "\\b(it|that|what|there|here|he|she|who|where)'s\\b", with: "$1 is", options: .regularExpression)
        guard let re = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:'[\\p{L}]+)?") else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    /// Word-level Levenshtein distance divided by the input's word count.
    static func editRatio(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty else { return y.isEmpty ? 0 : 1 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in stride(from: 1, through: y.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[y.count]) / Double(x.count)
    }

    /// Share of output words that weren't in the input (light should only remove).
    static func addedRatio(_ input: String, _ output: String, dictionary: [String]) -> Double {
        var pool = Dictionary(words(input).map { ($0, 1) }, uniquingKeysWith: +)
        let dict = Set(dictionary.flatMap { words($0) })
        let out = words(output)
        guard !out.isEmpty else { return 0 }
        var added = 0
        for w in out {
            if let n = pool[w], n > 0 { pool[w] = n - 1 } else if !dict.contains(w) { added += 1 }
        }
        return Double(added) / Double(out.count)
    }
}
