import Foundation

/// A word fixed while it was being said (Nov 3 2026, Sameer chose "fix a word before it goes"):
/// its place among the settled words, what the recognizer heard, and what it should be — empty
/// to take it out. Applied to the final words before cleanup and sending.
struct WordFix: Equatable {
    var index: Int
    var original: String
    var replacement: String
}

enum WordFixes {
    /// The words of a text (runs of non-space), as ranges into it.
    static func words(_ text: String) -> [NSRange] {
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: "\\S+") else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }

    /// The fixes put into a text: each at its place when the word there is still the one fixed,
    /// else at the first unfixed word that is; a taken-out word takes one space with it.
    static func apply(_ fixes: [WordFix], to text: String) -> String {
        guard !fixes.isEmpty else { return text }
        let ns = text as NSString
        let ranges = words(text)
        var edits: [(NSRange, String)] = []
        var used = Set<Int>()
        for f in fixes {
            func matches(_ i: Int) -> Bool { !used.contains(i) && ns.substring(with: ranges[i]) == f.original }
            guard let i = (f.index < ranges.count && matches(f.index)) ? f.index : ranges.indices.first(where: matches) else { continue }
            used.insert(i)
            edits.append((ranges[i], f.replacement))
        }
        let out = NSMutableString(string: text)
        for (r, rep) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            var range = r
            if rep.isEmpty {
                // Taken out: the space after it (or before it, at the end) goes too.
                if NSMaxRange(range) < out.length, out.substring(with: NSRange(location: NSMaxRange(range), length: 1)) == " " { range.length += 1 }
                else if range.location > 0, out.substring(with: NSRange(location: range.location - 1, length: 1)) == " " { range.location -= 1; range.length += 1 }
            }
            out.replaceCharacters(in: range, with: rep)
        }
        return (out as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
