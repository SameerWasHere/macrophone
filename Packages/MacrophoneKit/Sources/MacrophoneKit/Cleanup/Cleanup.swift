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

    /// Warms the model so the first cleanup after a recording is fast. Call when recording starts.
    public static func prewarm(level: CleanupLevel, dictionary: [String]) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), case .available = SystemLanguageModel.default.availability, level != .off {
            let s = LanguageModelSession(instructions: CleanupPrompts.instructions(level: level, dictionary: dictionary))
            s.prewarm()
        }
        #endif
    }

    /// Cleans `raw`. Never throws: on any failure it returns `cleaned: nil` and the caller
    /// delivers the raw transcript. The dictionary casing pass runs first, deterministically.
    public static func clean(_ raw: String, level: CleanupLevel, dictionary: [String], language: String) async -> CleanupResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard level != .off, !trimmed.isEmpty else { return CleanupResult(cleaned: nil, skipped: level == .off ? "off" : "empty") }
        let availability = availability(language: language)
        guard availability.isAvailable else { return CleanupResult(cleaned: nil, skipped: "unavailable") }
        let input = DictionaryPass.fixCasing(trimmed, terms: dictionary)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            var out: [String] = []
            for chunk in CleanupGuard.chunks(input, level: level) {
                do {
                    let edited = try await run(chunk, level: level, dictionary: dictionary)
                    guard let accepted = CleanupGuard.accept(original: chunk, edited: edited, level: level, dictionary: dictionary) else {
                        out.append(chunk)  // this chunk's edit looked wrong — keep it as spoken
                        continue
                    }
                    out.append(accepted)
                } catch {
                    // Guardrail refusals, context overflow, model busy: keep the words as spoken.
                    out.append(chunk)
                }
            }
            let joined = out.joined(separator: level == .heavy ? "\n\n" : " ")
            return CleanupResult(cleaned: joined == input && input == trimmed ? nil : joined, skipped: nil)
        }
        #endif
        return CleanupResult(cleaned: nil, skipped: "unavailable")
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    static func run(_ text: String, level: CleanupLevel, dictionary: [String]) async throws -> String {
        let session = LanguageModelSession(instructions: CleanupPrompts.instructions(level: level, dictionary: dictionary))
        let options = GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: max(256, text.count))
        let response = try await session.respond(to: CleanupPrompts.prompt(for: text), options: options)
        return response.content
    }
    #endif
}

/// Deterministic checks on the model's output. If an edit looks like an answer, a
/// summary that lost content, or a refusal, it's rejected and the raw text goes out.
public enum CleanupGuard {
    static let maxChunk = 2_400

    /// Splits long dictations at sentence boundaries so each piece fits the model's context.
    public static func chunks(_ text: String, level: CleanupLevel) -> [String] {
        guard text.count > maxChunk else { return [text] }
        var pieces: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            guard let s else { return }
            if current.count + s.count > maxChunk, !current.isEmpty {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            current += s
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(current.trimmingCharacters(in: .whitespaces)) }
        return pieces
    }

    /// Returns the edited text tidied (tags/quotes/preamble stripped), or nil to reject it.
    public static func accept(original: String, edited: String, level: CleanupLevel, dictionary: [String]) -> String? {
        var e = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<dictation>", "</dictation>"] { e = e.replacingOccurrences(of: tag, with: "") }
        e = e.trimmingCharacters(in: .whitespacesAndNewlines)
        let preambles = ["here is the edited text:", "here's the edited text:", "edited text:", "here is the cleaned up text:",
                         "here's the cleaned-up text:", "here is the text:", "sure! here", "sure, here"]
        let lower = e.lowercased()
        for p in preambles where lower.hasPrefix(p) {
            if let nl = e.firstIndex(of: "\n") { e = String(e[nl...]).trimmingCharacters(in: .whitespacesAndNewlines) }
            else { e = String(e.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            break
        }
        if e.count >= 2, e.first == "\"", e.last == "\"", !original.hasPrefix("\"") { e = String(e.dropFirst().dropLast()) }
        guard !e.isEmpty else { return nil }

        let refusals = ["i'm sorry", "i am sorry", "i can't assist", "i cannot assist", "i can't help with", "as an ai"]
        let olower = original.lowercased()
        if refusals.contains(where: { e.lowercased().hasPrefix($0) && !olower.contains($0) }) { return nil }

        // Code fences or markdown the speaker can't have dictated means it answered.
        if e.contains("```") && !original.contains("```") { return nil }

        // Length: light/medium only remove; heavy restructures but keeps content.
        let o = Double(max(original.count, 1)), n = Double(e.count)
        switch level {
        case .off: return nil
        case .light, .medium:
            if n > o * 1.25 + 20 { return nil }
            if n < o * 0.35 && o > 60 { return nil }
        case .heavy:
            if n > o * 1.6 + 40 { return nil }
            if n < o * 0.3 && o > 80 { return nil }
        }

        // Every dictionary term the speaker said must survive.
        for t in dictionary where original.range(of: t, options: .caseInsensitive) != nil {
            if e.range(of: t, options: .caseInsensitive) == nil { return nil }
        }
        // Every number the speaker said must survive (as digits or words is fine — digits only checked).
        for num in numbers(in: original) where !numbers(in: e).contains(num) { return nil }
        return e
    }

    static func numbers(in s: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: "\\d+(?:[.,:]\\d+)*") else { return [] }
        return Set(re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } })
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
