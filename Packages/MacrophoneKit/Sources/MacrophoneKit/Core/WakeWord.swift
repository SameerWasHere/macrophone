import Foundation

// The wake word (Nov 7 2026): say a phrase ("Hey Mac"), talk, and the words land where you're
// typing on the Mac. Moved from SameerOS's "Hey Claude" (Voice/WakeWord.swift there) and made
// general: any phrase, three sensitivities, the vocative form only where it's safe, ending words
// that are lists, and a place by name at the end ("… send to Claude"). Everything here is pure —
// the listener (WakeListener, macOS) feeds it transcripts and times. Tested in `WakeWordTests`.

// MARK: - Sensitivity

public enum WakeSensitivity: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The phrase as written, and its words must settle with good confidence before it wakes.
    case low
    /// The phrase, its common mis-hearings ("Hey Mack", "Hey, Mac"), wakes on the words as they come.
    case normal
    /// Also near spellings, the name alone as an address ("…, Claude,"), and the recognizer's
    /// second guesses.
    case high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }

    public var summary: String {
        switch self {
        case .low: return "Only the phrase said clearly. Fewer false starts; you may need to repeat it."
        case .normal: return "The phrase and its usual mis-hearings."
        case .high: return "Wakes more easily — in a noisy room or with an accent. More false starts."
        }
    }

    /// The least confidence the recognizer may have in the phrase's name once its words settle
    /// (0 = not checked). A wake that settles below it is withdrawn: nothing pastes.
    public var minimumConfidence: Double {
        switch self {
        case .low: return 0.5
        case .normal: return 0.3
        case .high: return 0
        }
    }

    /// Low waits for the settled words (and their confidence) before it wakes at all.
    public var waitsForSettledWords: Bool { self == .low }
}

// MARK: - The phrase

/// A wake phrase: an optional greeting ("hey") and a name ("Mac", "Claude", "Computer").
public struct WakePhrase: Sendable, Hashable {
    public let text: String
    /// The greeting's key ("hey"), nil when the phrase is the name alone ("Computer").
    public let lead: String?
    /// The name's words, as keys.
    public let name: [String]
    /// Extra keys the name is heard as — curated mis-hearings for the presets.
    let variants: Set<String>
    let highVariants: Set<String>
    /// The name said alone as an address ("Claude, check this") counts at Normal. A name that's
    /// an everyday word ("Mac, Windows and Linux…") only counts that way at High.
    let vocative: Bool

    /// The phrases offered first. Custom ones are any two or three words.
    public static let presets = ["Hey Mac", "Hey Claude", "Computer"]
    public static let defaultText = "Hey Mac"

    /// Words that greet: a phrase starting with one has a lead. Each group is how the recognizer
    /// writes it.
    private static let greetingGroups: [[String]] = [
        ["hey", "hi", "hay", "hei", "heh", "he", "hej", "hai"],
        ["hello", "hallo", "hullo", "helo"],
        ["ok", "okay", "okey", "kay"],
        ["yo"],
    ]

    /// Greeting key → every key it's heard as.
    static let greetings: [String: Set<String>] = {
        var map: [String: Set<String>] = [:]
        for group in greetingGroups {
            let keys = Set(group.map(WakeText.key))
            for k in keys { map[k] = keys }
        }
        return map
    }()

    /// Mis-hearings collected over SameerOS's weeks of "Hey Claude" (SFSpeechRecognizer and
    /// SpeechTranscriber) and this Mac's `say` test set. Keys, not spellings.
    static let curated: [String: [String]] = [
        "klaud": ["claud", "clawd", "clod", "clode", "clawed", "klaud", "klod", "claudie", "claudy", "claw", "claude's"],
        "mak": ["mack", "mak", "macc", "mac's", "mach"],
    ]

    /// Hearings that are real words someone might say to a person ("Hey Clyde", "Hey, cloud
    /// storage is full"): SameerOS's old recognizer needed them; SpeechTranscriber hears the name
    /// cleanly and the bench woke on them — High only.
    static let curatedHigh: [String: [String]] = [
        "klaud": ["cloud", "clyde"],
    ]

    /// Names that are proper names: said alone with a pause they're almost always an address.
    static let properNames: Set<String> = Set(["claude", "siri", "jarvis", "alexa", "friday"].map(WakeText.key))

    /// The greeting and the name run together by the recognizer ("Heymac"), as keys.
    let merged: Set<String>

    public init(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = clean
        let raw = WakeText.words(clean).filter { !WakeText.key($0).isEmpty }
        let words = raw.map(WakeText.key)
        if words.count >= 2, Self.greetings[words[0]] != nil {
            lead = words[0]
            name = Array(words.dropFirst())
            let rawName = raw.dropFirst().joined()
            let group = Self.greetingGroups.first { $0.map(WakeText.key).contains(words[0]) } ?? [raw[0]]
            merged = Set(group.map { WakeText.key($0 + rawName) })
        } else {
            lead = nil
            name = words
            merged = []
        }
        let joined = name.joined()
        variants = Set((Self.curated[joined] ?? []).map(WakeText.key))
        highVariants = Set((Self.curatedHigh[joined] ?? []).map(WakeText.key))
        vocative = Self.properNames.contains(joined)
    }

    var nameKey: String { name.joined() }

    /// Why this phrase won't work, or nil.
    public var problem: String? {
        if name.isEmpty { return "Type a phrase, like “Hey Mac”." }
        if WakeText.words(text).count > 4 { return "Keep it to four words or fewer." }
        if nameKey.count < 3 { return "The name is too short to tell apart from other words." }
        if lead == nil, name.count == 1, WakeText.tooCommonAlone.contains(nameKey) {
            return "“\(text)” is said too often in conversation — add “Hey” in front."
        }
        return nil
    }

    /// A word on how well it will work, or nil.
    public var advice: String? {
        guard problem == nil else { return nil }
        if nameKey.count <= 3 { return "Short names are harder to hear apart — Low sensitivity helps if it wakes by mistake." }
        if lead == nil { return "Say it on its own, then pause — “\(text), …”." }
        return nil
    }

    /// Words worth giving the recognizer as context so it spells the phrase this way.
    public var contextualStrings: [String] {
        var s = [text]
        if let lead, let first = WakeText.words(text).first, WakeText.key(first) == lead {
            s.append(WakeText.words(text).dropFirst().joined(separator: " "))
        }
        return s
    }
}

// MARK: - Text helpers

enum WakeText {
    private static let wordRegex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}'’]+"#)

    static func words(_ s: String) -> [String] {
        let ns = s as NSString
        return wordRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    struct Token {
        let text: String
        let key: String
        let range: Range<String.Index>
        /// The token is first, or punctuation sits between it and the word before (a pause).
        var pauseBefore: Bool
        /// The token is last, or punctuation follows it (a pause).
        var pauseAfter: Bool
    }

    static func tokens(_ s: String) -> [Token] {
        let ns = s as NSString
        let found = wordRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var out: [Token] = []
        for (i, m) in found.enumerated() {
            guard let r = Range(m.range, in: s) else { continue }
            let word = String(s[r])
            let gapBefore = i == 0 ? "" : ns.substring(with: NSRange(location: NSMaxRange(found[i - 1].range), length: m.range.location - NSMaxRange(found[i - 1].range)))
            let after = i + 1 < found.count ? found[i + 1].range.location : ns.length
            let gapAfter = ns.substring(with: NSRange(location: NSMaxRange(m.range), length: after - NSMaxRange(m.range)))
            out.append(Token(text: word, key: key(word), range: r,
                             pauseBefore: i == 0 || hasPause(gapBefore),
                             pauseAfter: i + 1 == found.count || hasPause(gapAfter)))
        }
        return out
    }

    static func hasPause(_ gap: String) -> Bool {
        gap.contains { ",.!?;:—–-…".contains($0) }
    }

    /// A spelling key: sounds that are spelled several ways spelled one way. "Mack" and "Mac" are
    /// both "mak"; "Clawd", "Claud" and "Claude" are "klaud"; "Max" ("maks") and "Mike" ("mik")
    /// stay apart.
    static func key(_ word: String) -> String {
        var w = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if w.hasSuffix("'s") { w = String(w.dropLast(2)) }
        w = w.filter { $0.isLetter || $0.isNumber }
        guard w.count > 1 else { return w }
        w = w.replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "ck", with: "k")
            .replacingOccurrences(of: "q", with: "k")
            .replacingOccurrences(of: "x", with: "ks")
            .replacingOccurrences(of: "z", with: "s")
            .replacingOccurrences(of: "aw", with: "au")
        var chars = Array(w)
        for i in chars.indices where chars[i] == "c" {
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            chars[i] = "eiy".contains(next) ? "s" : "k"
        }
        var out: [Character] = []
        for c in chars where out.last != c { out.append(c) }
        if out.count > 3, out.last == "e" { out.removeLast() }
        if out.count > 2, out.last == "y" { out[out.count - 1] = "i" }
        return String(out)
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Everyday words a near spelling must never be taken for (High's fuzzy match), and single
    /// names too common to be a phrase on their own.
    static let common: Set<String> = Set([
        "max", "man", "men", "map", "mat", "mad", "mike", "make", "mark", "match", "mic", "back", "black", "sack",
        "the", "and", "you", "that", "this", "with", "have", "what", "when", "then", "there", "they", "them",
        "computer", "phone", "mac", "apple", "music", "light", "lights", "cloud", "clothes", "close", "clock",
        "hello", "okay", "yeah", "right", "sure", "please", "thanks", "stop", "start", "send", "type", "note",
    ].map(key))

    /// Names too everyday to be a phrase without a greeting in front.
    static let tooCommonAlone: Set<String> = Set([
        "mac", "max", "man", "apple", "phone", "music", "light", "lights", "hello", "okay", "yeah", "stop", "start",
        "send", "type", "note", "notes", "mail", "message", "messages", "claude", "home", "work",
    ].map(key))
}

// MARK: - Matching

/// Where the phrase was heard in a transcript, and what was said after it.
public struct WakeHit: Equatable, Sendable {
    /// Characters from the start of the transcript to the end of the phrase (and the pause after).
    public let end: Int
    /// The name's characters (for the recognizer's confidence in it).
    public let nameRange: Range<Int>
    /// How many words come before the command (the phrase's included).
    public let wordsBefore: Int
    /// What was said after the phrase, first letter up.
    public let command: String
}

public struct WakeMatcher: Sendable {
    public let phrase: WakePhrase
    public let sensitivity: WakeSensitivity

    public init(phrase: WakePhrase, sensitivity: WakeSensitivity) {
        self.phrase = phrase
        self.sensitivity = sensitivity
    }

    private var leadKeys: Set<String> {
        guard let lead = phrase.lead else { return [] }
        switch sensitivity {
        case .low: return [lead]
        case .normal: return WakePhrase.greetings[lead] ?? [lead]
        // "a Claude" is how a fast "hey Claude" is often written.
        case .high: return (WakePhrase.greetings[lead] ?? [lead]).union(["a", "eh", "hm"].map(WakeText.key))
        }
    }

    private var allowsVocative: Bool {
        if phrase.lead == nil { return true }
        switch sensitivity {
        case .low: return false
        case .normal: return phrase.vocative
        // Not for an everyday name even at High: "Mac, Windows and Linux…" (the bench woke on it).
        case .high: return !WakeText.common.contains(phrase.nameKey)
        }
    }

    /// Does one token match the name word at `index` of the name?
    private func wordMatches(_ token: String, _ nameWord: String, whole: Bool) -> Bool {
        if token == nameWord { return true }
        guard sensitivity != .low else { return false }
        if whole, phrase.variants.contains(token) { return true }
        if whole, sensitivity == .high, phrase.highVariants.contains(token) { return true }
        if sensitivity == .high, nameWord.count >= 5, !WakeText.common.contains(token),
           WakeText.distance(token, nameWord) <= 1 { return true }
        return false
    }

    /// The name at tokens[i...]: the index after it, or nil.
    private func nameEnd(_ t: [WakeText.Token], at i: Int) -> Int? {
        let n = phrase.name
        guard i < t.count else { return nil }
        // One token for the whole name ("Macrophone", "Mack", "Claudie").
        if wordMatches(t[i].key, phrase.nameKey, whole: true) { return i + 1 }
        // Word for word.
        if n.count > 1, i + n.count <= t.count,
           (0..<n.count).allSatisfy({ wordMatches(t[i + $0].key, n[$0], whole: false) }) { return i + n.count }
        // Split by the recognizer ("Macro phone"): up to three tokens joined.
        var joined = ""
        for j in i..<min(t.count, i + 3) {
            joined += t[j].key
            if j > i, joined == phrase.nameKey { return j + 1 }
            if joined.count >= phrase.nameKey.count { break }
        }
        return nil
    }

    /// Every place the phrase is heard, in order.
    public func matches(in text: String) -> [WakeHit] {
        let t = WakeText.tokens(text)
        guard !t.isEmpty, !phrase.name.isEmpty else { return [] }
        let leads = leadKeys
        var hits: [WakeHit] = []
        var i = 0
        while i < t.count {
            var found: (start: Int, nameStart: Int, end: Int)?
            if phrase.lead != nil, leads.contains(t[i].key), let e = nameEnd(t, at: i + 1) {
                found = (i, i + 1, e)
            } else if phrase.lead != nil, sensitivity != .low,
                      phrase.merged.contains(t[i].key) {
                // Run together: "Heymac".
                found = (i, i, i + 1)
            } else if allowsVocative, t[i].pauseBefore || isGreeting(t, i - 1), let e = nameEnd(t, at: i), t[e - 1].pauseAfter {
                found = (i, i, e)
            }
            if let f = found {
                hits.append(hit(text, t, nameStart: f.nameStart, end: f.end))
                i = f.end
            } else {
                i += 1
            }
        }
        return hits
    }

    private func isGreeting(_ t: [WakeText.Token], _ i: Int) -> Bool {
        guard i >= 0, i < t.count else { return false }
        return WakePhrase.greetings.keys.contains(t[i].key)
    }

    private func hit(_ text: String, _ t: [WakeText.Token], nameStart: Int, end: Int) -> WakeHit {
        let nameLow = text.distance(from: text.startIndex, to: t[nameStart].range.lowerBound)
        let nameHigh = text.distance(from: text.startIndex, to: t[end - 1].range.upperBound)
        // The command starts after the phrase and any pause marks.
        var idx = t[end - 1].range.upperBound
        let skip = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.!?;:-–—…"))
        while idx < text.endIndex, text[idx].unicodeScalars.allSatisfy({ skip.contains($0) }) { idx = text.index(after: idx) }
        let rest = String(text[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let command = rest.isEmpty ? "" : rest.prefix(1).uppercased() + rest.dropFirst()
        return WakeHit(end: text.distance(from: text.startIndex, to: idx), nameRange: nameLow..<nameHigh,
                       wordsBefore: end, command: command)
    }

    /// The command anchored where the phrase first was: the recognizer revises its words as you
    /// speak, so the hit nearest `wordsBefore` wins; if the phrase is revised away, the same
    /// number of leading words is dropped instead (SameerOS's rule).
    public func command(in text: String, anchoredAt wordsBefore: Int) -> (command: String, hit: WakeHit?) {
        let all = matches(in: text)
        if let m = all.min(by: { abs($0.wordsBefore - wordsBefore) < abs($1.wordsBefore - wordsBefore) }),
           abs(m.wordsBefore - wordsBefore) <= 2 {
            return (m.command, m)
        }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > wordsBefore else { return ("", nil) }
        let rest = words.dropFirst(wordsBefore).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:-–— "))
        return (rest.prefix(1).uppercased() + rest.dropFirst(), nil)
    }
}

// MARK: - Ending words and places

/// What ends a capture and what it does. Editable lists; a phrase belongs to one list.
public struct WakeEndingWords: Codable, Equatable, Sendable {
    /// Paste, then press Return.
    public var send: [String]
    /// Paste only (the same as saying nothing).
    public var paste: [String]
    /// Drop it: nothing pastes.
    public var cancel: [String]

    public init(send: [String] = WakeEndingWords.defaultSend, paste: [String] = WakeEndingWords.defaultPaste,
                cancel: [String] = WakeEndingWords.defaultCancel) {
        self.send = send
        self.paste = paste
        self.cancel = cancel
    }

    public static let defaultSend = ["send it", "send that"]
    public static let defaultPaste = ["type it", "paste it"]
    public static let defaultCancel = ["never mind", "cancel", "cancel that", "scratch that"]
    public static let `default` = WakeEndingWords()

    /// Words the recognizer should expect.
    public var all: [String] { send + paste + cancel }

    /// One list's words, cleaned: lowercased, trimmed, no repeats, never empty (the defaults
    /// come back), and taken out of the other lists so a phrase can't do two things.
    public mutating func set(_ list: WakeAction, _ words: [String]) {
        var cleaned: [String] = []
        for w in words.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() })
        where !w.isEmpty && !cleaned.contains(w) { cleaned.append(w) }
        switch list {
        case .send: send = cleaned.isEmpty ? Self.defaultSend : cleaned
        case .paste: paste = cleaned.isEmpty ? Self.defaultPaste : cleaned
        case .cancel: cancel = cleaned.isEmpty ? Self.defaultCancel : cleaned
        }
        let taken = Set(cleaned)
        if list != .send { send = send.filter { !taken.contains($0) }; if send.isEmpty { send = Self.defaultSend.filter { !taken.contains($0) } } }
        if list != .paste { paste = paste.filter { !taken.contains($0) }; if paste.isEmpty { paste = Self.defaultPaste.filter { !taken.contains($0) } } }
        if list != .cancel { cancel = cancel.filter { !taken.contains($0) }; if cancel.isEmpty { cancel = Self.defaultCancel.filter { !taken.contains($0) } } }
    }
}

public enum WakeAction: String, Codable, Sendable, Equatable {
    case paste, send, cancel
}

/// What a capture comes to: the words to land, what to do, and where (a place said by name).
public struct WakeOutcome: Equatable, Sendable {
    public var text: String
    public var action: WakeAction
    /// An app named at the end ("… send to Claude" → "Claude"), not yet looked up.
    public var place: String?
    /// The ending words heard, as said (for the log's counts and the pill).
    public var ending: String?

    public init(text: String, action: WakeAction, place: String? = nil, ending: String? = nil) {
        self.text = text
        self.action = action
        self.place = place
        self.ending = ending
    }
}

public enum WakeEndings {
    /// Reads the end of a capture: cancel words, a place by name ("send it to Claude", "paste
    /// in Notes"), send words, paste words — each stripped from the words that land.
    public static func parse(_ command: String, words: WakeEndingWords) -> WakeOutcome {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = strip(endingPhrase: words.cancel, from: text) {
            return WakeOutcome(text: c.text, action: .cancel, ending: c.tail)
        }
        if let p = place(in: text) { return p }
        if let s = strip(endingPhrase: words.send, from: text) {
            return WakeOutcome(text: s.text, action: .send, ending: s.tail)
        }
        if let s = strip(endingPhrase: words.paste, from: text) {
            return WakeOutcome(text: s.text, action: .paste, ending: s.tail)
        }
        return WakeOutcome(text: text, action: .paste)
    }

    /// Whether the words end in something that ends a capture (for arming the quick finish).
    public static func endsWithEnding(_ command: String, words: WakeEndingWords) -> Bool {
        let o = parse(command, words: words)
        return o.ending != nil || o.place != nil
    }

    private static let wordRegex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}'’]+"#)
    private static let trailing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-–—"))

    /// If `text` ends with one of `phrases` (whole words, any case, punctuation ignored), the text
    /// without it. A one-word phrase ("cancel") counts only on its own or after a pause mark —
    /// "we shouldn't cancel" stays words; "…, cancel." doesn't. "Nevermind" matches "never mind".
    /// (SameerOS's `strip(endingPhrase:)`, with the one-word rule added.)
    public static func strip(endingPhrase phrases: [String], from text: String) -> (text: String, phrase: String, tail: String)? {
        let ns = text as NSString
        let matches = wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let words = matches.map { ns.substring(with: $0.range).lowercased().replacingOccurrences(of: "’", with: "'") }
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            let phraseWords = phrase.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
            guard !phraseWords.isEmpty else { continue }
            let variants = phraseWords.count > 1 ? [phraseWords, [phraseWords.joined()]] : [phraseWords]
            for variant in variants where variant.count <= words.count && Array(words.suffix(variant.count)) == variant {
                let first = matches.count - variant.count
                if variant.count == 1, first > 0 {
                    let gap = ns.substring(with: NSRange(location: NSMaxRange(matches[first - 1].range),
                                                         length: matches[first].range.location - NSMaxRange(matches[first - 1].range)))
                    guard WakeText.hasPause(gap) else { continue }
                }
                let cut = matches[first].range.location
                let rest = ns.substring(to: cut).trimmingCharacters(in: trailing)
                return (rest, phrase, ns.substring(from: cut))
            }
        }
        return nil
    }

    // With how the recognizer writes them: "paste it in" comes out "pasted in", "send it to" "sent to".
    private static let verbs: [String: WakeAction] = ["send": .send, "sent": .send, "paste": .paste, "pasted": .paste, "paced": .paste,
                                                      "type": .paste, "typed": .paste, "put": .paste, "drop": .paste]
    private static let objects: Set<String> = ["it", "that", "this", "them"]
    private static let preps: Set<String> = ["to", "in", "into", "on", "onto"]

    /// "… send it to Claude" → send to "Claude"; "… paste in Notes" / "type that into Notes" →
    /// paste into "Notes". The name is one to three words at the very end.
    public static func place(in text: String) -> WakeOutcome? {
        let ns = text as NSString
        let m = wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let w = m.map { ns.substring(with: $0.range).lowercased() }
        guard w.count >= 3 else { return nil }
        // The verb, from the end back, within the last seven words.
        for v in stride(from: w.count - 3, through: max(0, w.count - 7), by: -1) {
            guard let action = verbs[w[v]] else { continue }
            var p = v + 1
            if p < w.count, objects.contains(w[p]) { p += 1 }
            if p < w.count, w[p] == "over" { p += 1 }
            guard p < w.count, preps.contains(w[p]) else { continue }
            p += 1
            if p < w.count - 1, w[p] == "the" { p += 1 }
            let nameStart = p
            let nameCount = w.count - nameStart
            guard (1...3).contains(nameCount) else { continue }
            // A one-word ending verb sentence ("I'll send it to you") isn't a place: "you", "me",
            // "him"… are people.
            let people: Set<String> = ["you", "me", "him", "her", "them", "us", "everyone", "everybody", "someone"]
            if nameCount == 1, people.contains(w[nameStart]) { continue }
            let nameRange = NSRange(location: m[nameStart].range.location, length: NSMaxRange(m[w.count - 1].range) - m[nameStart].range.location)
            let place = ns.substring(with: nameRange)
            let before = ns.substring(to: m[v].range.location).trimmingCharacters(in: trailing)
            let tail = ns.substring(from: m[v].range.location)
            return WakeOutcome(text: before, action: action, place: place, ending: tail)
        }
        return nil
    }
}

/// An app a place by name can be (an open app on the Mac, a window).
public struct WakePlaceCandidate: Sendable, Hashable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum WakePlaces {
    private static func norm(_ s: String) -> String {
        var words = WakeText.words(s).map { $0.lowercased() }
        while let last = words.last, ["app", "window", "application"].contains(last), words.count > 1 { words.removeLast() }
        if words.first == "the", words.count > 1 { words.removeFirst() }
        return words.joined()
    }

    /// The open app a spoken name means: the same name, the same sound ("Clawd" → Claude), the
    /// first word of a longer name ("Chrome" → Google Chrome, "Visual Studio" → Visual Studio
    /// Code), or one letter off for a longer name. Candidates come newest first; a tie goes to
    /// the newest. Nil when nothing is close.
    public static func match(_ spoken: String, in candidates: [WakePlaceCandidate]) -> WakePlaceCandidate? {
        let s = norm(spoken)
        guard s.count >= 2 else { return nil }
        let sKey = WakeText.key(s)
        var best: (score: Int, c: WakePlaceCandidate)?
        for c in candidates {
            let n = norm(c.name)
            guard !n.isEmpty else { continue }
            let nWords = WakeText.words(c.name).map { WakeText.key($0) }
            var score = 0
            if n == s { score = 100 }
            else if WakeText.key(n) == sKey { score = 90 }
            else if n.hasPrefix(s), s.count >= 4 { score = 70 }
            else if nWords.contains(sKey), sKey.count >= 4 { score = 65 }
            else if s.count >= 5, WakeText.distance(WakeText.key(n), sKey) <= (s.count >= 8 ? 2 : 1) { score = 60 }
            else if n.count >= 4, s.hasPrefix(n) { score = 50 }   // "Notes app thing" → Notes
            if score > (best?.score ?? 0) { best = (score, c) }
        }
        return best?.c
    }
}

// MARK: - The capture

/// How a capture after the phrase ends: on a pause (end of speech), on ending words, Esc, or a
/// key. Pure; the listener feeds it the words (the command so far) and whether a voice is
/// heard, with times, and ticks it.
public struct WakeCapture: Sendable {
    public struct Config: Sendable, Equatable {
        /// This much quiet after the last word lands it (tunable on the Dictation page).
        public var endSilence: TimeInterval = 2.0
        /// After ending words ("send it"), this much quiet.
        public var endingDelay: TimeInterval = 0.8
        /// Ending words said alone ("never mind").
        public var endingAloneDelay: TimeInterval = 0.5
        /// No new words this long counts as quiet even if the room never is (a fan, a TV).
        public var noWordsExtra: TimeInterval = 1.5
        /// The phrase alone and then nothing: given up after this.
        public var bareTimeout: TimeInterval = 6
        /// A capture never runs longer.
        public var maxDuration: TimeInterval = 180
        public init(endSilence: TimeInterval = 2.0) { self.endSilence = endSilence }
    }

    public enum Decision: Equatable, Sendable {
        /// Land it (the outcome may still say cancel — ending words).
        case finish(WakeOutcome)
        /// Nothing was said after the phrase.
        case nothingSaid
    }

    public let config: Config
    public let words: WakeEndingWords
    public private(set) var command = ""
    public private(set) var startedAt: TimeInterval
    private var lastChange: TimeInterval
    private var lastVoice: TimeInterval
    /// The desk key is held: only its release ends it.
    public var held = false

    public init(config: Config, words: WakeEndingWords, command: String = "", at t: TimeInterval) {
        self.config = config
        self.words = words
        self.command = command
        startedAt = t
        lastChange = t
        lastVoice = t
    }

    private static func wordList(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    /// The command so far (settled + still being decided).
    public mutating func heard(_ text: String, at t: TimeInterval) {
        // Only real word changes count as talking (the recognizer re-sends words with new
        // punctuation).
        if Self.wordList(text) != Self.wordList(command) { lastChange = t }
        command = text
    }

    /// A voice in the mic (above the room) right now.
    public mutating func voice(at t: TimeInterval) {
        lastVoice = max(lastVoice, t)
    }

    /// Whether the end is near (ending words heard): the listener ticks faster.
    public var armed: Bool { !command.isEmpty && WakeEndings.endsWithEnding(command, words: words) }

    public func decide(at t: TimeInterval) -> Decision? {
        if t - startedAt >= config.maxDuration {
            return command.isEmpty ? .nothingSaid : .finish(WakeEndings.parse(command, words: words))
        }
        if held { return nil }
        let wordsQuiet = t - lastChange
        let silent = t - max(lastChange, lastVoice)
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return wordsQuiet >= config.bareTimeout ? .nothingSaid : nil
        }
        let outcome = WakeEndings.parse(command, words: words)
        if outcome.ending != nil || outcome.place != nil {
            let alone = outcome.text.isEmpty
            let delay = alone ? config.endingAloneDelay : config.endingDelay
            if silent >= delay || wordsQuiet >= delay + config.noWordsExtra { return .finish(outcome) }
            return nil
        }
        if silent >= config.endSilence || wordsQuiet >= config.endSilence + config.noWordsExtra { return .finish(outcome) }
        return nil
    }
}
