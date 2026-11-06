import Foundation

// A real keyboard types into the Mac (Nov 5 2026). A Bluetooth keyboard, a Magic Keyboard (or the
// simulator's hardware keyboard) on the iPhone while a window is watched: what it presses goes
// straight to the Mac, the way a Mac's own keyboard would — over the wire the keyboard page
// already uses, nothing new for the Mac to learn:
//
//   - characters (letters, digits, signs, ⇧ and ⌥ included, as iOS's layout gives them) are typed
//     (`watchType`, unicode — so the Mac's own layout never garbles them);
//   - the keys that aren't characters (Esc, Return, Tab, Delete, the arrows, Home/End, Page Up/Down,
//     Forward Delete, F1–F20) are pressed by name (`watchKey`), with ⇧ and ⌥;
//   - ⌘ and ⌃ are held on the Mac while they're held here (`watchKeyState` down / up), so a key
//     pressed meanwhile is a real chord — and ⌘ held with Tab tapped steps the Mac's app switcher,
//     which commits when ⌘ is let go, as on the Mac. ⇧ and ⌥ stay on the phone: they're folded
//     into each key (a held ⇧ on the Mac would go on the typed characters too);
//   - ⌥Tab is the Mac's ⌘Tab (iOS keeps ⌘Tab for itself): ⌘ held on the Mac until ⌥ is let go.
//
// The pure part lives here (`HardwareKeyRouter`): a key's HID usage (what `UIKey.keyCode` is) to
// the Mac's key name (`MacKeys`, the Mac's `KeyCodes`), what a press becomes, which modifiers the
// Mac has been told are down (so every one is let go — on release, on Done, on leaving the app),
// and which presses repeat while held (the Mac never repeats a posted key; the phone does).

/// HID usage page 7 (keyboard) → the Mac's key names.
public enum HardwareKeyNames {
    /// The Mac's name for the key at this usage (letters and digits are their own names; the signs
    /// are `MacKeys.signs`' names; the modifiers are `WatchModifier`'s). Nil for a key the Mac has
    /// no name for (the ISO § key, Print Screen, the international keys…) — typed by its
    /// characters if it has any, else ignored.
    public static func name(usage: Int) -> String? {
        switch usage {
        case 0x04...0x1D: return String(UnicodeScalar(UInt8(0x61 + usage - 0x04)))   // a … z
        case 0x1E...0x26: return String(usage - 0x1E + 1)                              // 1 … 9
        case 0x27: return "0"
        case 0x28: return "return"
        case 0x29: return "escape"
        case 0x2A: return "delete"
        case 0x2B: return "tab"
        case 0x2C: return "space"
        case 0x2D: return "minus"
        case 0x2E: return "equal"
        case 0x2F: return "leftbracket"
        case 0x30: return "rightbracket"
        case 0x31, 0x32: return "backslash"      // the ISO keyboard's # key sits where \ is
        case 0x33: return "semicolon"
        case 0x34: return "quote"
        case 0x35: return "grave"
        case 0x36: return "comma"
        case 0x37: return "period"
        case 0x38: return "slash"
        case 0x39: return "capslock"
        case 0x3A...0x45: return "f\(usage - 0x3A + 1)"                                // F1 … F12
        case 0x49: return "help"                 // Insert: the Mac's Help key sits there
        case 0x4A: return "home"
        case 0x4B: return "pageup"
        case 0x4C: return "forwarddelete"
        case 0x4D: return "end"
        case 0x4E: return "pagedown"
        case 0x4F: return "right"
        case 0x50: return "left"
        case 0x51: return "down"
        case 0x52: return "up"
        // The keypad: its digits and signs as the main row's (⌘1 from the keypad is ⌘1).
        case 0x54: return "slash"
        case 0x56: return "minus"
        case 0x58: return "enter"
        case 0x59...0x61: return String(usage - 0x59 + 1)
        case 0x62: return "0"
        case 0x63: return "period"
        case 0x67: return "equal"
        case 0x68...0x6F: return "f\(usage - 0x68 + 13)"                               // F13 … F20
        case 0x75: return "help"
        case 0xE0, 0xE4: return WatchModifier.control.keyName
        case 0xE1, 0xE5: return WatchModifier.shift.keyName
        case 0xE2, 0xE6: return WatchModifier.option.keyName
        case 0xE3, 0xE7: return WatchModifier.command.keyName
        default: return nil
        }
    }

    /// The usage of the key with this name (the left one of a modifier pair; the main row's digit).
    public static func usage(for name: String) -> Int? {
        (0...0xFF).first { self.name(usage: $0) == name }
    }

    /// The modifier this key is (either side), if it is one.
    public static func modifier(usage: Int) -> WatchModifier? {
        guard (0xE0...0xE7).contains(usage), let n = name(usage: usage) else { return nil }
        return WatchModifier(rawValue: n)
    }

    /// Keys that are never characters: pressed by name, whatever iOS says they type.
    public static let notCharacters: Set<String> = Set(
        ["escape", "return", "enter", "tab", "delete", "forwarddelete", "left", "right", "up", "down",
         "home", "end", "pageup", "pagedown", "help"] + (1...20).map { "f\($0)" })

    /// What a person would see typed: no control characters, no private-use function-key codes
    /// (UIKit's names for the arrows and F-keys live in U+F700…U+F8FF).
    public static func isPrintable(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { u in
            !(u.value < 0x20 || u.value == 0x7F || (0xF700...0xF8FF).contains(u.value))
        }
    }
}

/// What a real keyboard's presses become on the Mac, and which modifiers the Mac holds for it.
public struct HardwareKeyRouter: Equatable, Sendable {
    public enum Out: Equatable, Sendable {
        /// ⌘ or ⌃ pressed down or let go on the Mac (`watchKeyState`).
        case hold(WatchModifier, down: Bool)
        /// A key pressed by name with its modifiers (`watchKey`).
        case key(WatchKey)
        /// Characters typed (`watchType`).
        case type(String)
    }

    /// The modifiers held on the Mac for the keyboard — ⌘ and ⌃ — in the order told.
    public private(set) var heldOnMac: [WatchModifier] = []
    /// Every modifier held on the keyboard now, as its last press said (⇧ and ⌥ go on a click from
    /// the trackpad or the window too: ⇧-click, ⌥-click).
    public private(set) var physical: Set<WatchModifier> = []

    /// The modifiers held on the Mac while held here (a chord's).
    public static let chordModifiers: [WatchModifier] = [.command, .control]

    /// ⌥Tab is stepping the Mac's app switcher: ⌘ is held on the Mac until ⌥ is let go. (iOS keeps
    /// ⌘Tab for itself — on the simulator Tab never reaches the app while ⌘ is down — so ⌥Tab, which
    /// a Mac leaves alone, stands in; a ⌘Tab that does arrive works as itself.)
    public private(set) var switching = false

    public init() {}

    /// A key went down. `characters` is what iOS's layout makes of it with the modifiers held
    /// (`UIKey.characters`); `modifiers` are the ones held as it went down.
    public mutating func press(usage: Int, characters: String, modifiers: Set<WatchModifier>) -> [Out] {
        if let m = HardwareKeyNames.modifier(usage: usage) {
            return reconcile(modifiers.union([m]))
        }
        var out = reconcile(modifiers)
        // ⌥Tab, ⇧⌥Tab: the switcher, one step each, as ⌘Tab and ⇧⌘Tab on the Mac.
        if usage == 0x2B, modifiers.contains(.option), modifiers.isDisjoint(with: Self.chordModifiers) {
            if !switching {
                switching = true
                out.append(.hold(.command, down: true))
            }
            out.append(.key(WatchKey("tab", command: true, shift: modifiers.contains(.shift))))
            return out
        }
        guard let name = HardwareKeyNames.name(usage: usage) else {
            // A key the Mac has no name for: its characters, unless it's part of a chord.
            if modifiers.isDisjoint(with: Self.chordModifiers), HardwareKeyNames.isPrintable(characters) { out.append(.type(characters)) }
            return out
        }
        // Caps Lock stays on the phone: iOS already gives the characters in capitals, and the
        // Mac's own Caps Lock would only be left on for its next real keystroke.
        if name == "capslock" { return out }
        let key = WatchKey(name, command: modifiers.contains(.command), shift: modifiers.contains(.shift),
                           control: modifiers.contains(.control), option: modifiers.contains(.option))
        if key.command || key.control || HardwareKeyNames.notCharacters.contains(name) {
            out.append(.key(key))
        } else if HardwareKeyNames.isPrintable(characters) {
            // ⌥ with a letter types what the Mac would (å, ∫, @ on some layouts): iOS's layout says.
            out.append(.type(characters))
        } else {
            // No characters (a dead key — ⌥E, ⌥U): the key itself, so the Mac composes it.
            out.append(.key(key))
        }
        return out
    }

    /// A key went up; `modifiers` are the ones still held after it.
    public mutating func release(usage: Int, modifiers: Set<WatchModifier>) -> [Out] {
        guard let m = HardwareKeyNames.modifier(usage: usage) else { return [] }
        return reconcile(modifiers.subtracting([m]))
    }

    /// Everything let go (Done, the app left, another field took the keyboard): last held first.
    public mutating func releaseAll() -> [Out] {
        physical = []
        var out = heldOnMac.reversed().map { Out.hold($0, down: false) }
        if switching, !heldOnMac.contains(.command) { out.append(.hold(.command, down: false)) }
        switching = false
        heldOnMac = []
        return out
    }

    /// The link went: the Mac lets go of a session's held keys itself; nothing to send.
    public mutating func forget() {
        heldOnMac = []
        physical = []
        switching = false
    }

    /// The Mac's ⌘ / ⌃ brought in line with what's held here — a release iOS swallowed (⌘H,
    /// ⌘Space) or a press before the keyboard reached the app is put right on the next key. ⌥ let
    /// go ends the switcher's ⌘ (the app it's on comes forward).
    private mutating func reconcile(_ held: Set<WatchModifier>) -> [Out] {
        physical = held
        var out: [Out] = []
        if switching, !held.contains(.option) {
            switching = false
            if !heldOnMac.contains(.command) { out.append(.hold(.command, down: false)) }
        }
        for m in heldOnMac.reversed() where !held.contains(m) {
            heldOnMac.removeAll { $0 == m }
            // The switcher still holds ⌘ on the Mac: it lets go with ⌥.
            if m == .command, switching { continue }
            out.append(.hold(m, down: false))
        }
        for m in Self.chordModifiers where held.contains(m) && !heldOnMac.contains(m) {
            heldOnMac.append(m)
            if m == .command, switching { continue }
            out.append(.hold(m, down: true))
        }
        return out
    }

    /// Whether this press runs on while the key is held (after `repeatDelay`, every
    /// `repeatInterval`): characters, Delete, the arrows, Page Up/Down — never a ⌘ or ⌃ chord (a
    /// held ⌘W over a slow link would close window after window), never Esc, Return or Tab.
    public static func repeats(_ out: Out) -> Bool {
        switch out {
        case .hold: return false
        case .type: return true
        case .key(let k):
            return !k.command && !k.control && ["delete", "forwarddelete", "left", "right", "up", "down", "pageup", "pagedown", "space"].contains(k.key)
        }
    }

    /// A Mac's own key repeat at its usual settings.
    public static let repeatDelay: TimeInterval = 0.4
    public static let repeatInterval: TimeInterval = 0.045

    /// What a text field on the phone types itself (the keyboard page's hidden field, while it has
    /// the keyboard): characters, Return, Tab and Delete go through it — so autocorrect's diff
    /// stays in step with the Mac — and everything else (chords, Esc, the arrows) goes as keys.
    public static func textFieldTakes(_ out: Out) -> Bool {
        switch out {
        case .hold: return false
        case .type: return true
        case .key(let k):
            return !k.command && !k.control && ["return", "enter", "tab", "delete"].contains(k.key)
        }
    }
}
