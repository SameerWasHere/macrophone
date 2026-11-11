import Foundation

// MARK: Type as I speak (Nov 10 2026)

/// Type as I speak (Settings › Dictation, off by default): while he talks, the words the
/// recognizer has settled on are typed on the Mac where the dictation is going; when he stops, the
/// cleaned words replace what was typed (only where they differ), and only then is Send pressed.
///
/// The phone sends `LivePiece`s — the keyboard's shape (`WatchTyping`: characters taken back, then
/// text) — numbered per dictation, only to a Mac whose welcome names `feature`. The dictation that
/// ends it is the usual message with `Dictation.livePieces` set to how many pieces went before it.
/// Everything here is pure: the phone's diff (`LiveTypist`), the Mac's rule for when it must stop
/// typing (`LiveFocusRule`) and its plan for the end (`LiveReconcile`).
public enum LiveTyping {
    /// Named in the Mac's welcome: a Mac that doesn't name it never gets a piece.
    public static let feature = "liveTyping"
    /// Words settled before the first piece goes: a spoken app name ("Messages, …") picks another
    /// place, and is heard in the first word or two — nothing is typed until that's decided.
    public static let wordsBeforeTyping = 3
    /// A dictation's pieces, at most (a ten-minute dictation settles a few hundred times).
    public static let maxPieces = 4000
    /// The Mac forgets what it typed for a dictation this long after its last piece.
    public static let sessionLife: TimeInterval = 600
    /// How long the Mac waits for pieces still on their way when the final dictation overtakes them.
    public static let piecesWait: TimeInterval = 1.5
}

/// Phone → Mac: one step of a dictation typed live.
public struct LivePiece: Codable, Sendable, Equatable {
    /// The dictation's id (the final `Dictation` carries the same one).
    public var id: UUID
    /// 1, 2, 3… in the order sent.
    public var seq: Int
    /// Characters (as a person sees them) taken back from the end of what was typed.
    public var delete: Int
    /// Then typed. Never a newline or a tab (the phone sends spaces; the Mac maps any to a space):
    /// a Return typed live would send a chat half-said.
    public var text: String
    /// Where the dictation is going (the Mac brings it forward at the first piece).
    public var target: TargetRef
    /// Take back everything typed for this dictation (the phone's cancel). Nil = a typing step.
    public var cancel: Bool?

    public init(id: UUID, seq: Int, delete: Int = 0, text: String = "", target: TargetRef, cancel: Bool? = nil) {
        self.id = id
        self.seq = seq
        self.delete = delete
        self.text = text
        self.target = target
        self.cancel = cancel
    }

    public var isCancel: Bool { cancel == true }
    public var isValid: Bool {
        seq >= 1 && seq <= LiveTyping.maxPieces && delete >= 0 && delete <= WatchTyping.maxDelete
            && text.utf8.count <= WatchTyping.maxText
    }
}

// MARK: The phone: settled words → pieces

/// What the phone has had typed on the Mac for one dictation, and the next step from the settled
/// words. Pending (dimmer) words never go: only what the recognizer has settled on.
public struct LiveTypist: Equatable, Sendable {
    public let id: UUID
    public let target: TargetRef
    /// What the Mac has been asked to type so far (whitespace folded to single spaces).
    public private(set) var typed = ""
    public private(set) var seq = 0
    /// No more pieces for this dictation (a word's card is up, the place changed by voice, the
    /// link went): what was typed stays typed, and the end reconciles it.
    public private(set) var stoodDown = false
    public private(set) var characters = 0
    public private(set) var deleted = 0

    public init(id: UUID, target: TargetRef) {
        self.id = id
        self.target = target
    }

    /// Whitespace and line breaks folded to single spaces, ends trimmed: what typing live puts.
    public static func fold(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The next piece for these settled words, or nil when there's nothing new to type (or it
    /// mustn't: too few words yet, stood down, too many pieces).
    public mutating func next(settled: String) -> LivePiece? {
        guard !stoodDown, seq < LiveTyping.maxPieces else { return nil }
        let now = Self.fold(settled)
        if typed.isEmpty, now.split(separator: " ").count < LiveTyping.wordsBeforeTyping { return nil }
        var step = TypingDiff.diff(old: typed, new: now)
        guard !step.isEmpty else { return nil }
        if step.delete > WatchTyping.maxDelete || step.text.utf8.count > WatchTyping.maxText {
            // A recognizer that rewrote everything: stop here and let the end put it right.
            stoodDown = true
            return nil
        }
        // Never take back more than was typed.
        step.delete = min(step.delete, typed.count)
        typed = now
        seq += 1
        characters += step.text.count
        deleted += step.delete
        return LivePiece(id: id, seq: seq, delete: step.delete, text: step.text, target: target)
    }

    /// The piece that takes it all back (seq follows the last).
    public mutating func cancelPiece() -> LivePiece {
        stoodDown = true
        seq += 1
        return LivePiece(id: id, seq: seq, target: target, cancel: true)
    }

    public mutating func standDown() { stoodDown = true }

    /// Something has been typed on the Mac for this dictation.
    public var typedAny: Bool { seq > 0 }
}

// MARK: The Mac: when to stop typing

/// The Mac types live only into the place it brought forward at the first piece, and stops for
/// good the moment anything says that place isn't his to type into any more — it never takes back
/// characters from somewhere it didn't type them.
public enum LiveFocusRule {
    public enum Stop: String, Sendable, Equatable {
        case appChanged = "another app came to the front"
        case windowChanged = "another window came to the front"
        case fieldChanged = "the cursor moved to another field"
        case passwordField = "a password field has the cursor"
        case someoneClicked = "someone clicked on the Mac"
        case someoneTyped = "someone typed on the Mac"
        case locked = "the Mac locked"
    }

    /// What the Mac sees now, against what it saw when it started.
    public struct Look: Equatable, Sendable {
        public var sameApp: Bool
        /// Nil when the window can't be told (no window id).
        public var sameWindow: Bool?
        /// Nil when the field can't be told (a terminal: no focused element).
        public var sameField: Bool?
        public var secure: Bool
        public var locked: Bool
        /// Seconds since a mouse button went down on this Mac (any button).
        public var sinceMouseDown: TimeInterval
        /// Seconds since a key went down (the Mac's own posted keys count here too).
        public var sinceKeyDown: TimeInterval
        /// Seconds since the Mac itself last posted a key for this dictation.
        public var sinceOwnKey: TimeInterval
        /// Seconds since typing live started.
        public var sinceStart: TimeInterval

        public init(sameApp: Bool, sameWindow: Bool?, sameField: Bool?, secure: Bool = false, locked: Bool = false,
                    sinceMouseDown: TimeInterval = .infinity, sinceKeyDown: TimeInterval = .infinity,
                    sinceOwnKey: TimeInterval = .infinity, sinceStart: TimeInterval = 0) {
            self.sameApp = sameApp
            self.sameWindow = sameWindow
            self.sameField = sameField
            self.secure = secure
            self.locked = locked
            self.sinceMouseDown = sinceMouseDown
            self.sinceKeyDown = sinceKeyDown
            self.sinceOwnKey = sinceOwnKey
            self.sinceStart = sinceStart
        }
    }

    /// A key newer than the Mac's own last one by more than this is a person's.
    public static let ownKeySlack: TimeInterval = 0.15

    /// Nil = keep typing; else why it must stop.
    public static func check(_ l: Look) -> Stop? {
        if l.locked { return .locked }
        if !l.sameApp { return .appChanged }
        if l.sameWindow == false { return .windowChanged }
        if l.sameField == false { return .fieldChanged }
        if l.secure { return .passwordField }
        // A click since it started may have moved the caret, even in the same field.
        if l.sinceMouseDown < l.sinceStart { return .someoneClicked }
        // A key newer than its own, since it started: a person typing here too.
        let ownOrStart = min(l.sinceOwnKey, l.sinceStart)
        if l.sinceKeyDown + ownKeySlack < ownOrStart { return .someoneTyped }
        return nil
    }
}

// MARK: The Mac: putting it right at the end

/// What the Mac does when the final (cleaned) words arrive for a dictation it typed live.
///
/// Chosen: read the field when it can be read and replace exactly the characters it typed (an
/// Accessibility selection of that range, then the cleaned words pasted over it); where it can't
/// be read (a terminal, some web views) take back the differing end with Delete, but only when
/// nothing has touched the place since it typed there. Select-and-replace is exact and fast
/// however long the dictation; Delete is what a terminal's line editor understands (it has no
/// selection) and stays inside what was typed.
public enum LiveReconcile {
    /// The field as it reads now: its text and where the cursor is (UTF-16, as Accessibility counts).
    public struct Field: Equatable, Sendable {
        public var value: String
        /// The caret's place (a selection's start); the selection's length.
        public var caret: Int
        public var selection: Int
        public init(value: String, caret: Int, selection: Int = 0) {
            self.value = value
            self.caret = caret
            self.selection = selection
        }
    }

    public enum Plan: Equatable, Sendable {
        /// What's there is already the final text.
        case nothing
        /// Select this UTF-16 range of the field (all inside what was typed) and put `text` over
        /// it (empty: just delete it).
        case replace(location: Int, length: Int, text: String)
        /// Press Delete this many times (characters as a person sees them), then put `text`.
        case backspace(delete: Int, text: String)
        /// What was typed can't be found or safely taken back: leave it, and put the final words in
        /// the usual way (a paste) — the caller says so.
        case deliverNormally
    }

    /// - typed: what the Mac typed for this dictation (its own count, piece by piece).
    /// - final: the dictation's final words, as they'd be pasted.
    /// - field: the field read now, nil when it can't be read.
    /// - untouched: the focus rule held from the first piece to now.
    public static func plan(typed: String, final: String, field: Field?, untouched: Bool) -> Plan {
        if typed.isEmpty { return .deliverNormally }
        // Already the final words: wherever they are now, putting them in again would double them.
        if typed == final { return .nothing }
        if let f = field, let start = rangeOfTyped(typed, in: f) {
            let (keep, rest) = prefixSplit(typed, final)
            let keepUnits = keep.utf16.count
            let length = typed.utf16.count - keepUnits
            if length == 0 && rest.isEmpty { return .nothing }
            return .replace(location: start + keepUnits, length: length, text: rest)
        }
        // Can't see it (or it reads otherwise — a field that reformats as you type): Delete, only
        // if nothing has been near it.
        guard untouched else { return .deliverNormally }
        if field != nil {
            // Readable, and what's before the caret isn't what was typed: something we don't
            // understand happened there. Never press Delete into it.
            return .deliverNormally
        }
        let step = TypingDiff.diff(old: typed, new: final)
        return .backspace(delete: step.delete, text: step.text)
    }

    /// Where the typed text starts in the field, when it ends exactly at the caret (with no
    /// selection) — the only place the Mac's typing can have left it.
    public static func rangeOfTyped(_ typed: String, in f: Field) -> Int? {
        guard f.selection == 0 else { return nil }
        let units = Array(f.value.utf16)
        let t = Array(typed.utf16)
        guard f.caret >= t.count, f.caret <= units.count else { return nil }
        let start = f.caret - t.count
        guard Array(units[start..<f.caret]) == t else { return nil }
        return start
    }

    /// The characters `a` and `b` start with in common, and what follows in `b`.
    static func prefixSplit(_ a: String, _ b: String) -> (String, String) {
        let x = Array(a), y = Array(b)
        var i = 0
        while i < x.count, i < y.count, x[i] == y[i] { i += 1 }
        return (String(x[..<i]), String(y[i...]))
    }
}

// MARK: Counts for the log (never words)

/// "live: 14 pieces, 212 characters typed, 3 taken back, 41 corrected at the end".
public struct LiveCounts: Equatable, Sendable {
    public var pieces = 0
    public var typed = 0
    public var deleted = 0
    public init() {}
    public var line: String { "\(pieces) piece\(pieces == 1 ? "" : "s"), \(typed) characters typed, \(deleted) taken back" }
}
