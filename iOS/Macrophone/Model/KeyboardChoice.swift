import Combine
import Foundation
import MacrophoneKit

// Which keyboard the keyboard page brings up (Nov 7 2026, Sameer: "the keyboard you built is nice
// and complete. But it's much slower to type on than the default iOS keyboard, so maybe we should
// give users the iOS keyboard and give them the ability to toggle to the more detailed Mac
// keyboard"). iOS's keyboard is the default on every screen — autocorrect, predictions, slide
// typing, accents; the Mac's keys (`DeckKeyboard`) are one tap away on its bar, remembered per
// surface: the regular iPhone, the Duo's cover and its inner screen are held differently.

@MainActor
final class KeyboardChoice: ObservableObject {
    static let shared = KeyboardChoice()

    enum Surface: String, CaseIterable {
        case phone, cover, inner
        var key: String { "keyboard.macKeys.\(rawValue)" }
    }

    @Published private(set) var macKeys: [Surface: Bool]

    private init() {
        var m: [Surface: Bool] = [:]
        for s in Surface.allCases { m[s] = UserDefaults.standard.bool(forKey: s.key) }
        #if DEBUG
        // MACROPHONE_MAC_KEYS=1|0: Mac Keys on (or off) on every screen for this run, not stored.
        if let v = ProcessInfo.processInfo.environment["MACROPHONE_MAC_KEYS"] { for s in Surface.allCases { m[s] = v == "1" } }
        #endif
        macKeys = m
    }

    func macKeys(on s: Surface) -> Bool { macKeys[s] ?? false }

    func set(_ on: Bool, on s: Surface) {
        guard macKeys(on: s) != on else { return }
        macKeys[s] = on
        UserDefaults.standard.set(on, forKey: s.key)
    }

    func toggle(on s: Surface) {
        Haptics.pick()
        set(!macKeys(on: s), on: s)
    }
}

/// What was just typed, for the keyboard's bar: the field it goes through is hidden, so without
/// it nothing on screen says what reached the Mac. The tail of a line, kept here only — never
/// logged, never stored (the apps collect nothing).
@MainActor
final class KeyboardEcho: ObservableObject {
    static let shared = KeyboardEcho()

    /// The last words typed, newest at the end; newlines shown as ⏎.
    @Published private(set) var text = ""
    /// A keystroke in the last moment: the bar shows the words, else where they go.
    @Published private(set) var fresh = false
    private var fade: DispatchWorkItem?
    private static let keep = 120
    static let hold: TimeInterval = 1.5

    /// The field's difference, or a key of the Mac's keyboard, as it goes to the Mac. With a
    /// modifier waiting a single character is a shortcut: it's shown as one (⌘K).
    func typed(_ t: WatchTyping, modifiers: Set<WatchModifier> = []) {
        guard !t.isEmpty else { return }
        // The same rule as `MacInput.typed`: a letter, a digit or a space goes as the shortcut.
        if !modifiers.isEmpty, t.delete == 0, t.text.count == 1, let c = t.text.first, c.isLetter || c.isNumber || c == " " {
            chord(WatchModifier.allCases.filter { modifiers.contains($0) }.map(\.glyph).joined() + t.text.uppercased())
            return
        }
        var s = text
        if t.delete > 0 { s.removeLast(min(t.delete, s.count)) }
        s += t.text.replacingOccurrences(of: "\n", with: " ⏎ ")
        if s.count > Self.keep { s = String(s.suffix(Self.keep)) }
        text = s
        bump()
    }

    /// A key pressed (esc, an arrow, a shortcut): its glyph, so the bar answers every key.
    func chord(_ glyphs: String) {
        var s = text
        if !s.isEmpty, !s.hasSuffix(" ") { s += " " }
        s += glyphs + " "
        if s.count > Self.keep { s = String(s.suffix(Self.keep)) }
        text = s
        bump()
    }

    func clear() {
        fade?.cancel()
        text = ""
        fresh = false
    }

    private func bump() {
        if !fresh { fresh = true }
        fade?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fresh = false }
        fade = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: item)
    }
}
