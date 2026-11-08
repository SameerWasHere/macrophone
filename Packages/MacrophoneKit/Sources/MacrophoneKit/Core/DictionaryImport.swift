import Foundation

/// The Mac's Dictionary's one-time import (Nov 7 2026) from SameerOS's vocabulary file
/// (`~/.config/sameeros/vocabulary.txt`): one term per line, `#` starts a comment, and
/// `Term: sounds like, another` lines (the term is what's kept).
public enum DictionaryImport {
    public static func parse(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            if let colon = line.firstIndex(of: ":") { line = String(line[..<colon]) }
            let term = line.trimmingCharacters(in: .whitespaces)
            if !term.isEmpty { out.append(term) }
        }
        return merge([], out)
    }

    /// `a` then whatever of `b` it doesn't have (case aside), in order.
    public static func merge(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set(a.map { $0.lowercased() })
        var out = a
        for t in b where seen.insert(t.lowercased()).inserted { out.append(t) }
        return out
    }
}
