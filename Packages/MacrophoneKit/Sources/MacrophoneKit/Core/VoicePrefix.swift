import Foundation

/// The pause rule shared by spoken app names (`SpokenTarget`): a lead-in counts only when it's
/// followed by punctuation (the recognizer's pause) or the words "colon"/"comma", so "messages
/// from the server…" never matches.
enum VoicePrefix {
    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }

    static func strip(_ prefix: String, from text: String) -> String? {
        let lower = text.lowercased()
        guard lower.hasPrefix(prefix) else { return nil }
        var rest = Substring(text.dropFirst(prefix.count))
        let separators: [String] = [",", ":", ".", ";", "!", "—", " -", " colon", " comma"]
        guard let sep = separators.first(where: { rest.lowercased().hasPrefix($0) }) else { return nil }
        rest = rest.dropFirst(sep.count)
        let lead = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;.-—"))
        let body = String(rest.drop { $0.unicodeScalars.allSatisfy { lead.contains($0) } })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return body.prefix(1).uppercased() + body.dropFirst()
    }
}

