import CoreGraphics
import Foundation

// Real input (Oct 19 2026, Sameer: "for trackpads a keyboard we should make that available in
// window view with the mic as the default … a 3 input method carousel"). Three new messages, each
// gated by a name the Mac puts in its welcome (an unknown message ends an older Mac's session, so
// a phone never sends one unasked):
//
//   "mouse"    `watchMouse`    — the pointer moved (hover), a click with a count and modifiers
//                                (double, triple, ⌘-click), a press / drag / release (select text,
//                                move a window, drag a file), and whether the pointer is shown in
//                                the picture (the trackpad page); all at fractions of the window.
//   "typing"   `watchType`     — what the iPhone's keyboard did: characters deleted, then characters
//                                typed (as unicode, straight into whatever has focus — no clipboard).
//   "keyHold"  `watchKeyState` — a key or a modifier pressed down and held, released later (⌘ held,
//                                Tab, Tab, release: the app switcher); and the Mac's full key map by
//                                name (every letter and sign, F1–F20, Home, End, Help …).
//
// The pure parts live here so both apps and the tests share one rule: how the keyboard's text is
// diffed into deletes and typing, how typing is cut into pieces the Mac can post, which keys are
// held, and how a finger's speed on the trackpad becomes pointer motion.

/// The Mac takes `watchMouse` (named in its welcome).
public enum WatchMouse {
    public static let feature = "mouse"
}

/// A modifier, by name (so a newer phone's list never breaks an older Mac).
public enum WatchModifier: String, Codable, Sendable, CaseIterable, Hashable {
    case command, shift, option, control

    public var glyph: String {
        switch self {
        case .command: return "⌘"
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }

    public var name: String {
        switch self {
        case .command: return "Command"
        case .shift: return "Shift"
        case .option: return "Option"
        case .control: return "Control"
        }
    }

    /// The key that holds it (`watchKeyState`).
    public var keyName: String { rawValue }

    /// The modifiers a key carries, in the order Mac menus write them (⌃⌥⇧⌘).
    public static func of(_ k: WatchKey) -> [WatchModifier] {
        var out: [WatchModifier] = []
        if k.control { out.append(.control) }
        if k.option { out.append(.option) }
        if k.shift { out.append(.shift) }
        if k.command { out.append(.command) }
        return out
    }
}

/// One thing the pointer did, at a fraction of the watched window (0…1, top-left origin).
public struct WatchMouseEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The pointer went here (hover; nothing pressed). While a button is down, a drag.
        case move
        /// A click here: `count` 1, 2 or 3 (the second tap of a double-click is sent as count 2,
        /// the way the Mac counts clicks), with the left or right button and the modifiers held.
        case click
        /// The left button pressed and held here (a drag starts).
        case down
        /// The pointer moved with the button down.
        case drag
        /// The button released here (the drag ends).
        case up
        /// The pointer is being used from the phone's trackpad: show it in the picture and leave it
        /// where it is after a click (no putting it back).
        case show
        /// The trackpad is away: the pointer can be put back after a click, and hidden again.
        case hide
    }

    /// Kept as words: a kind this Mac doesn't know is ignored, never a session's end.
    public var kind: String
    public var x: Double
    public var y: Double
    /// "right" for the right button; nil or "left" otherwise.
    public var button: String?
    /// A click's count (1, 2 or 3).
    public var count: Int?
    /// The modifiers held during it, by name.
    public var modifiers: [String]?

    public init(_ kind: Kind, x: Double, y: Double, right: Bool = false, count: Int = 1, modifiers: [WatchModifier] = []) {
        self.kind = kind.rawValue
        self.x = x
        self.y = y
        self.button = right ? "right" : nil
        self.count = kind == .click ? count : nil
        self.modifiers = modifiers.isEmpty ? nil : modifiers.map(\.rawValue)
    }

    public init(_ kind: Kind, at p: CGPoint, right: Bool = false, count: Int = 1, modifiers: [WatchModifier] = []) {
        self.init(kind, x: Double(p.x), y: Double(p.y), right: right, count: count, modifiers: modifiers)
    }

    public var kindValue: Kind? { Kind(rawValue: kind) }
    public var isRight: Bool { button == "right" }
    public var clickCount: Int { min(3, max(1, count ?? 1)) }
    public var heldModifiers: [WatchModifier] { (modifiers ?? []).compactMap(WatchModifier.init(rawValue:)) }
    public var point: CGPoint { CGPoint(x: x, y: y) }

    /// What the Mac's link accepts: a kind it knows, a spot on the window, a count of 1…3.
    public var isValid: Bool {
        guard kindValue != nil, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return false }
        if let count, !(1...3).contains(count) { return false }
        if let button, button != "left", button != "right" { return false }
        return (modifiers?.count ?? 0) <= 4
    }
}

/// What the iPhone's keyboard did (named "typing" in the Mac's welcome): `delete` characters
/// taken back, then `text` typed. iOS edits a hidden field and the phone sends the difference —
/// so autocorrect's "teh " → "the " arrives as 3 deletes and "he " — never the whole field.
public struct WatchTyping: Codable, Sendable, Equatable {
    public static let feature = "typing"
    /// The most one message types or takes back (a paste of a novel isn't typing).
    public static let maxText = 4000
    public static let maxDelete = 500

    public var delete: Int
    public var text: String

    public init(delete: Int = 0, text: String = "") {
        self.delete = delete
        self.text = text
    }

    public var isEmpty: Bool { delete == 0 && text.isEmpty }
    public var isValid: Bool { delete >= 0 && delete <= Self.maxDelete && text.utf8.count <= Self.maxText }
}

/// The Mac holds keys down (`watchKeyState`) and knows every key by name.
public enum WatchKeyHold {
    public static let feature = "keyHold"
    /// A held key is let go by itself after this long: a modifier stuck down on someone's Mac
    /// (the phone lost its link mid-switch) would turn every click into a ⌘-click.
    public static let longest: TimeInterval = 30
}

// MARK: The keyboard's text, as deletes and typing

public enum TypingDiff {
    /// From what the hidden field held to what it holds now: how many characters to take back from
    /// the end of the old text, and what to type after. Characters are what a person sees as one
    /// (an emoji, a letter with its accent), so a delete on the Mac takes back the same thing.
    public static func diff(old: String, new: String) -> WatchTyping {
        let o = Array(old), n = Array(new)
        var i = 0
        while i < o.count, i < n.count, o[i] == n[i] { i += 1 }
        return WatchTyping(delete: o.count - i, text: String(n[i...]))
    }
}

/// How the Mac posts typed text: as unicode strings a few characters at a time (an event carries
/// about twenty UTF-16 units reliably), with a Return or a Tab pressed as the key itself — most
/// apps take a newline only from the key (a terminal, a chat's Send).
public enum TypingPlan: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case text(String)
        /// "return" or "tab".
        case key(String)
    }

    /// UTF-16 units per unicode event.
    public static let chunk = 20

    public static func steps(for text: String) -> [Step] {
        var out: [Step] = []
        var run = ""
        var units = 0
        func flush() {
            if !run.isEmpty { out.append(.text(run)); run = ""; units = 0 }
        }
        for ch in text {
            switch ch {
            case "\n", "\r", "\r\n": flush(); out.append(.key("return"))
            case "\t": flush(); out.append(.key("tab"))
            default:
                let n = ch.utf16.count
                // A character is never split across two events (a flag, a family, an accent).
                if units + n > chunk { flush() }
                run.append(ch)
                units += n
            }
        }
        flush()
        return out
    }
}

// MARK: Keys held down

/// The keys a phone holds on the Mac, in the order pressed (released in reverse), and the
/// modifier flags they add to every key and click meanwhile.
public struct HeldKeys: Equatable, Sendable {
    public private(set) var names: [String] = []

    public init() {}

    public var isEmpty: Bool { names.isEmpty }
    public func isHeld(_ name: String) -> Bool { names.contains(name) }

    /// Returns false when it was already held (nothing to press again).
    @discardableResult
    public mutating func press(_ name: String) -> Bool {
        guard !names.contains(name) else { return false }
        names.append(name)
        return true
    }

    /// Returns false when it wasn't held.
    @discardableResult
    public mutating func release(_ name: String) -> Bool {
        guard let i = names.firstIndex(of: name) else { return false }
        names.remove(at: i)
        return true
    }

    /// Everything, last pressed first (⌘ then Tab held → Tab up, then ⌘ up).
    public mutating func releaseAll() -> [String] {
        let all = Array(names.reversed())
        names = []
        return all
    }

    /// The modifiers among the held keys.
    public var modifiers: [WatchModifier] { names.compactMap(WatchModifier.init(rawValue:)) }
}

// MARK: The trackpad

/// A finger on the phone's trackpad moves the pointer by how fast it goes, like a laptop's: slow
/// for a precise point, faster across the window in a flick.
public enum TrackpadMotion {
    /// Mac points per phone point at this finger speed (phone points a second).
    public static func gain(speed: Double) -> Double {
        guard speed.isFinite, speed > 0 else { return 1 }
        let slow = 120.0, fast = 1400.0
        let low = 1.0, high = 3.4
        if speed <= slow { return low }
        if speed >= fast { return high }
        return low + (high - low) * (speed - slow) / (fast - slow)
    }

    /// One touch move: the finger's delta (phone points) over `dt` seconds, as Mac points.
    public static func step(_ delta: CGVector, dt: TimeInterval) -> CGVector {
        let d = max(dt, 1.0 / 240)
        let speed = (delta.dx * delta.dx + delta.dy * delta.dy).squareRoot() / d
        let g = gain(speed: Double(speed))
        return CGVector(dx: delta.dx * g, dy: delta.dy * g)
    }
}

/// Where the pointer is, as a fraction of the window, kept on the phone (it draws the pointer and
/// keeps it in view; the Mac is told the place, never a delta — so the two never drift apart).
public struct TrackpadPointer: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0.5, y: Double = 0.5) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    public var point: CGPoint { CGPoint(x: x, y: y) }

    /// Moves by Mac points, given the window's size in Mac points; stays inside the window.
    public mutating func move(by d: CGVector, window: CGSize) {
        guard window.width > 0, window.height > 0 else { return }
        x = min(max(x + Double(d.dx / window.width), 0), 1)
        y = min(max(y + Double(d.dy / window.height), 0), 1)
    }

    public mutating func put(_ p: CGPoint) {
        x = min(max(Double(p.x), 0), 1)
        y = min(max(Double(p.y), 0), 1)
    }
}

// MARK: Every key by name

/// The keys beyond letters and digits, by name, with the glyph the phone draws and the words
/// VoiceOver says. The Mac maps each name to its key code (`KeyCodes`); a name it doesn't know, it
/// ignores.
public enum MacKeys {
    /// F1 … F20.
    public static let functionKeys: [WatchKey] = (1...20).map { WatchKey("f\($0)") }

    /// The keys around the letters, by name.
    public static let navigation: [WatchKey] = [WatchKey("home"), WatchKey("end"), WatchKey("pageup"), WatchKey("pagedown"),
                                                WatchKey("forwarddelete"), WatchKey("help")]

    /// A sign's key by name: the Mac finds it on the current layout.
    public static let signs: [(name: String, glyph: String)] = [
        ("minus", "-"), ("equal", "="), ("leftbracket", "["), ("rightbracket", "]"), ("backslash", "\\"), ("semicolon", ";"),
        ("quote", "'"), ("comma", ","), ("period", "."), ("slash", "/"), ("grave", "`"),
    ]

    /// Letters and digits are their own names ("a", "7").
    public static func isLetter(_ name: String) -> Bool { name.count == 1 && name.first!.isLetter }
    public static func isDigit(_ name: String) -> Bool { name.count == 1 && name.first!.isNumber }

    /// The whole keyboard, by name: what a Mac naming "keyHold" knows.
    public static var allNames: [String] {
        ["escape", "tab", "return", "enter", "space", "delete", "forwarddelete", "left", "right", "up", "down",
         "home", "end", "pageup", "pagedown", "help", "capslock", "fn",
         "command", "shift", "option", "control", "rightcommand", "rightshift", "rightoption", "rightcontrol"]
        + "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)
        + functionKeys.map(\.key) + signs.map(\.name)
    }
}

/// One-tap things the Mac does (Oct 19 2026): in the keyboard's bar and the window's More keys.
public extension WatchKey {
    static let spotlight = WatchKey("space", command: true)
    static let missionControl = WatchKey("up", control: true)
    static let showDesktop = WatchKey("f11")
    static let desktopLeft = WatchKey("left", control: true)
    static let desktopRight = WatchKey("right", control: true)
    /// ⌘` — the app's next window.
    static let nextWindow = WatchKey("grave", command: true)
    /// ⌘Tab, held: the app switcher (`MacInput.switchApp` holds ⌘, taps Tab, lets go a moment later).
    static let appSwitcher = WatchKey("tab", command: true)

    /// The Mac section: what each does with the keys under it, in the order you reach for them.
    static let macSection = Section(title: "Your Mac", keys: [.spotlight, .appSwitcher, .nextWindow, .missionControl, .showDesktop, .desktopLeft, .desktopRight])

    /// The More keys menu with a keyboard beside it (Oct 19 2026): nothing a key on the keyboard's
    /// own bar already does by name is repeated here as a bare key; the sections are what you'd
    /// hunt for.
    static let menuSections: [Section] = sections + [macSection]
}
