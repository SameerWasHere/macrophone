import Foundation

// The window is asking (Oct 16 2026): when the bottom of a watched window shows a question with a
// short list of answers — Claude Code's "Do you want to make this edit? ❯ 1. Yes / 2. … / 3. No",
// Codex's approvals, a "(y/n)" — the Mac reads it off the picture (on the Mac, with Vision) and
// the phone shows the answers as buttons in place of Esc · ↑ · ↓ · Return. A tap is the keys that
// answer it: the arrows from the highlighted answer to the tapped one, then Return; or the letter,
// then Return. When the reading is unsure there's no prompt, and the keys stay.

/// A question the window is asking, with the answers to show as buttons.
public struct WatchPrompt: Codable, Sendable, Equatable {
    public struct Choice: Codable, Sendable, Equatable {
        /// "Yes, and don't ask again this session" — the words on screen, without the number.
        public var label: String
        /// The number shown before it, when there is one.
        public var number: Int?
        /// For a typed answer: the letter that gives it ("y"). Nil for a menu answer.
        public var key: String?

        public init(label: String, number: Int? = nil, key: String? = nil) {
            self.label = label
            self.number = number
            self.key = key
        }
    }

    public enum Style: String, Codable, Sendable {
        /// A list moved with the arrows and picked with Return (Claude Code, Codex).
        case menu
        /// A letter then Return ("(y/n)").
        case typed
        /// Controls the Mac presses itself (a question card's choices and Submit, Allow / Deny).
        case pressed
    }

    /// "Do you want to make this edit to AuthView.swift?" — nil when it couldn't be read.
    public var question: String?
    public var choices: [Choice]
    /// The answer the arrows are on now (menus).
    public var highlighted: Int?
    public var style: Style

    public init(question: String?, choices: [Choice], highlighted: Int?, style: Style) {
        self.question = question
        self.choices = choices
        self.highlighted = highlighted
        self.style = style
    }

    /// Names this prompt, so a tap answers the one it was shown for and never a newer one.
    public var id: String {
        var h: UInt64 = 0xcbf29ce484222325
        let text = ([question ?? ""] + choices.map(\.label)).joined(separator: "\u{1F}")
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// The keys that pick `index`: arrows from the highlighted answer, then Return; or the letter,
    /// then Return. Nil when it can't be answered safely.
    public func keys(for index: Int) -> [PromptKey]? {
        guard choices.indices.contains(index) else { return nil }
        switch style {
        case .menu:
            guard let from = highlighted else { return nil }
            let d = index - from
            return Array(repeating: d > 0 ? .down : .up, count: abs(d)) + [.returnKey]
        case .typed:
            guard let k = choices[index].key else { return nil }
            return [.character(k), .returnKey]
        case .pressed:
            return nil
        }
    }
}

public enum PromptKey: Equatable, Sendable {
    case up, down, returnKey
    case character(String)
}

/// A line of text read off the window: where it starts and how far down, as fractions of the window
/// (0…1, top-left origin).
public struct ReadLine: Equatable, Sendable {
    public var text: String
    public var minX: Double
    public var midY: Double

    public init(text: String, minX: Double, midY: Double) {
        self.text = text
        self.minX = minX
        self.midY = midY
    }
}

public enum PromptReader {
    /// Marks a terminal menu draws before the highlighted answer — and what text recognition
    /// usually turns "❯" into.
    static let markers: Set<Character> = ["❯", ">", "›", "»", "→", "▸", "▶", "➤", "*", "•", ")"]

    /// Reads a prompt off the lines at the bottom of a window. Nil unless it's sure: the answers
    /// are the last numbered list (1, 2, 3 …) near the bottom, and either one is marked highlighted
    /// or a question sits right above — a numbered list in an agent's reply isn't a prompt.
    public static func read(_ lines: [ReadLine]) -> WatchPrompt? {
        let sorted = lines
            .map { ReadLine(text: tidy($0.text), minX: $0.minX, midY: $0.midY) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.midY < $1.midY }
        guard !sorted.isEmpty else { return nil }
        return menu(sorted) ?? typed(sorted)
    }

    /// Recognition puts a space after the dot in a file name ("AuthView. swift"): take it out.
    static func tidy(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.contains(". ") else { return t }
        return t.replacingOccurrences(of: #"(\w)\. (swift|js|jsx|ts|tsx|py|rb|go|rs|java|kt|md|json|ya?ml|toml|html|css|scss|sh|txt|c|h|m|cpp|lock)\b"#,
                                      with: "$1.$2", options: .regularExpression)
    }

    // MARK: Menus

    private struct Numbered {
        var index: Int        // in `lines`
        var number: Int
        var label: String
        var marked: Bool
        var minX: Double
    }

    /// "❯ 1. Yes" → (1, "Yes", marked). "2) No" → (2, "No"). The mark may be glued on (">1.").
    static func numbered(_ s: String) -> (number: Int, label: String, marked: Bool)? {
        var rest = Substring(s)
        var marked = false
        while let c = rest.first, markers.contains(c) || c == " " {
            if c != " " { marked = true }
            rest = rest.dropFirst()
        }
        // Text recognition reads a "1" as "l", "I" or "|" often enough to matter.
        guard let d = rest.first, let n = d.wholeNumberValue ?? (["l", "I", "|", "i"].contains(d) ? 1 : nil), n >= 1 else { return nil }
        rest = rest.dropFirst()
        if let more = rest.first, more.isNumber { return nil }   // "12 lines changed", "2026 …"
        guard let sep = rest.first, sep == "." || sep == ")" || sep == ":" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 120 else { return nil }
        return (n, label, marked)
    }

    private static func menu(_ lines: [ReadLine]) -> WatchPrompt? {
        // The last run of 1, 2, 3 … from the bottom up; a line that doesn't number may sit
        // between two answers (a wrapped label), and is joined to the one above it.
        var found: [Numbered] = []
        var i = lines.count - 1
        var trailing = 0
        while i >= 0 {
            if let n = numbered(lines[i].text) {
                if let first = found.first, n.number != first.number - 1 { break }
                found.insert(Numbered(index: i, number: n.number, label: n.label, marked: n.marked, minX: lines[i].minX), at: 0)
                if n.number == 1 { break }
            } else if found.isEmpty {
                trailing += 1
                if trailing > 4 { return nil }   // the list isn't at the bottom: not a question now
            } else if found.count >= 1, i == found[0].index - 1, i > 0, numbered(lines[i - 1].text) != nil {
                // A wrapped label: belongs to the answer above it.
            } else {
                break
            }
            i -= 1
        }
        guard found.count >= 2, found.count <= 6, found.first?.number == 1 else { return nil }

        // Wrapped labels: join any lines between one answer and the next.
        var choices: [WatchPrompt.Choice] = []
        for (k, n) in found.enumerated() {
            var label = n.label
            let end = k + 1 < found.count ? found[k + 1].index : n.index + 1
            if end > n.index + 1 {
                for j in (n.index + 1)..<end { label += " " + lines[j].text }
            }
            // Text recognition reads a comma as a full stop often: "Yes. and don't ask again".
            for w in ["and", "but", "or", "then"] { label = label.replacingOccurrences(of: ". \(w) ", with: ", \(w) ") }
            choices.append(.init(label: label, number: n.number))
        }

        // The highlighted answer: the one with a mark, else the one that starts further left
        // (the mark recognition dropped still takes room).
        var highlighted: Int?
        let marked = found.indices.filter { found[$0].marked }
        if marked.count == 1 {
            highlighted = marked[0]
        } else if marked.isEmpty {
            let xs = found.map(\.minX).sorted()
            let median = xs[xs.count / 2]
            let left = found.indices.filter { found[$0].minX < median - 0.012 }
            if left.count == 1 { highlighted = left[0] }
        }

        // The question: a line just above the first answer that ends in "?" — or in the "7" text
        // recognition sometimes makes of one, when it opens like a question.
        var question: String?
        let top = found[0].index
        for j in stride(from: top - 1, through: max(0, top - 3), by: -1) {
            if let q = asQuestion(lines[j].text) { question = q; break }
        }
        // A list with neither a highlighted answer nor a question is someone's numbered text.
        guard highlighted != nil || question != nil else { return nil }
        // Unmarked (recognition can drop the "❯" and the menu aligns the numbers): a menu opens on
        // its first answer, and from the phone only these buttons move it.
        return WatchPrompt(question: question, choices: choices, highlighted: highlighted ?? 0, style: .menu)
    }

    static let questionStarts = ["do ", "does ", "would ", "should ", "can ", "allow ", "proceed", "are ", "is ",
                                 "want ", "run ", "continue", "overwrite ", "apply ", "make ", "delete ", "approve "]

    /// The line as a question, or nil.
    static func asQuestion(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("?") { return t }
        let lower = t.lowercased()
        guard t.count >= 6, questionStarts.contains(where: lower.hasPrefix) else { return nil }
        return t.hasSuffix("7") ? tidy(String(t.dropLast()) + "?") : nil
    }

    // MARK: (y/n)

    private static let yesNo = ["(y/n)", "[y/n]", "(y/N)", "[y/N]", "(Y/n)", "[Y/n]", "(yes/no)", "[yes/no]"]

    private static func typed(_ lines: [ReadLine]) -> WatchPrompt? {
        // Only the last few lines: an old "(y/n)" up the scrollback is already answered.
        for line in lines.suffix(3).reversed() {
            for mark in yesNo {
                guard let r = line.text.range(of: mark, options: .caseInsensitive) else { continue }
                let q = line.text[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                return WatchPrompt(question: q.isEmpty ? nil : q,
                                   choices: [.init(label: "Yes", key: "y"), .init(label: "No", key: "n")],
                                   highlighted: nil, style: .typed)
            }
        }
        return nil
    }
}

/// A window on the Mac is asking something and nobody's looking at it (Oct 16 2026): the phone
/// buzzes, and a tap opens that window with the answers as buttons.
public struct Attention: Codable, Sendable, Equatable {
    /// The window, to watch it.
    public var ref: TargetRef
    /// "Claude", "Terminal".
    public var appName: String
    /// "Terminal — codex ~/api" — tells two windows of one app apart.
    public var title: String
    /// "Do you want to make this edit to AuthView.swift?" — nil when it couldn't be read.
    public var question: String?
    public var promptID: String

    public init(ref: TargetRef, appName: String, title: String, question: String?, promptID: String) {
        self.ref = ref
        self.appName = appName
        self.title = title
        self.question = question
        self.promptID = promptID
    }

    /// What the phone understands, sent in its hello.
    public static let feature = "attention"
    /// The phone also gets alerts through the person's iCloud when it's closed: the Mac keeps
    /// looking while no phone is connected.
    public static let cloudFeature = "attention-cloud"
}
