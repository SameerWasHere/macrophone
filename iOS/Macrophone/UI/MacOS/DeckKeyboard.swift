import MacrophoneKit
import SwiftUI
import UIKit

// Mac Keys (Nov 7 2026): the Mac's own keyboard, in place of iOS's when he asks for it — the
// keyboard bar's ⌘ swaps it in, ABC swaps iOS's back, as the globe key does. iOS's keyboard is
// the fast one (autocorrect, predictions, slide typing) and comes up first everywhere; this is
// the power layer: ⇧ and the modifiers in a Mac's places, fn with the F-keys and the Mac's own
// moves, esc, ⇥, the inverted-T arrows. Its keys go down on the touch, not the lift, so it's
// never slower than iOS's, and what it types goes straight to the Mac (`MacInput.typed` /
// `press`). It stands as tall as iOS's keys did on that screen, so the window above never moves
// on a swap.

/// The input view that holds it.
final class DeckKeyboardHost: UIInputView {
    private let host: UIHostingController<DeckKeyboard>
    private let input: MacInput

    var surface: KeyboardChoice.Surface {
        didSet { if surface != oldValue { refresh() } }
    }

    /// Its whole height, the screen's foot included (`foot`: what's kept clear of the home
    /// indicator inside it).
    var keysHeight: CGFloat = 260 {
        didSet {
            guard abs(keysHeight - oldValue) > 0.5 else { return }
            frame.size.height = keysHeight
        }
    }

    var foot: CGFloat = 0 {
        didSet { if abs(foot - oldValue) > 0.5 { refresh() } }
    }

    init(input: MacInput, surface: KeyboardChoice.Surface) {
        self.input = input
        self.surface = surface
        host = UIHostingController(rootView: DeckKeyboard(input: input, surface: surface))
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 260), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = []
        host.safeAreaRegions = []
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() { host.rootView = DeckKeyboard(input: input, surface: surface, foot: foot) }
}

/// A Mac keyboard in five rows.
struct DeckKeyboard: View {
    @ObservedObject var input: MacInput
    var surface: KeyboardChoice.Surface
    /// Kept clear at the foot (the home indicator).
    var foot: CGFloat = 0
    /// ⇧ for the next character; tapped twice quickly, held on (caps lock), as iOS's does.
    @State private var shift = false
    @State private var caps = false
    @State private var shiftAt = Date.distantPast

    private static let rows: [[String]] = [
        ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="],
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'"],
        ["z", "x", "c", "v", "b", "n", "m", ",", ".", "/"],
    ]
    private static let shifted: [String: String] = [
        "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
    ]
    private static let spoken: [String: String] = [
        "`": "Grave accent", "-": "Hyphen", "=": "Equals", "[": "Left bracket", "]": "Right bracket", "\\": "Backslash",
        ";": "Semicolon", "'": "Apostrophe", ",": "Comma", ".": "Period", "/": "Slash",
    ]

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = geo.size.width > 600 ? 7 : 5
            let side: CGFloat = 6
            // The widest row is 13 keys and ⌫ (1.5): the unit fits that across.
            let unit = (geo.size.width - side * 2 - gap * 13) / 14.5
            let keyHeight = (geo.size.height - 16 - gap * 4) / 5
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    ForEach(Self.rows[0], id: \.self) { character($0, unit) }
                    DeckKey(width: unit * 1.5, a11y: "Delete", id: "deck-key-delete", repeats: true, action: delete) {
                        Image(systemName: "delete.left")
                    }
                }
                HStack(spacing: gap) {
                    pressKey("tab", width: unit * 1.5, a11y: "Tab") { Text("⇥") }
                    ForEach(Self.rows[1], id: \.self) { character($0, unit) }
                }
                HStack(spacing: gap) {
                    pressKey("escape", width: unit * 1.75, a11y: "Escape") { Text("esc").font(.system(size: 15)) }
                    ForEach(Self.rows[2], id: \.self) { character($0, unit) }
                    DeckKey(width: unit * 1.75 + gap, a11y: "Return", id: "deck-key-return", action: { type("\n") }) {
                        Image(systemName: "return")
                    }
                }
                HStack(spacing: gap) {
                    shiftKey(width: unit * 2.25 + gap / 2)
                    ForEach(Self.rows[3], id: \.self) { character($0, unit) }
                    shiftKey(width: unit * 2.25 + gap / 2)
                }
                HStack(spacing: gap) {
                    DeckKey(width: unit * 1.5, a11y: "ABC, the iPhone's keyboard", id: "keyboard-abc", action: {
                        Haptics.pick()
                        KeyboardChoice.shared.set(false, on: surface)
                    }) { Text("ABC").font(.system(size: 15, weight: .medium)) }
                    DeckFn(input: input, width: unit)
                    modifier(.control, width: unit)
                    modifier(.option, width: unit)
                    modifier(.command, width: unit * 1.25)
                    DeckKey(width: unit * 5.75 + gap * 5, a11y: "Space", id: "deck-key-space", repeats: true, action: { type(" ") }) { Color.clear }
                    DeckKey(width: unit, a11y: "Left arrow", id: "deck-key-left", repeats: true, action: { press("left") }) {
                        Image(systemName: "arrowtriangle.left.fill").imageScale(.small)
                    }
                    VStack(spacing: 2) {
                        DeckKey(width: unit, height: (keyHeight - 2) / 2, a11y: "Up arrow", id: "deck-key-up", repeats: true, action: { press("up") }) {
                            Image(systemName: "arrowtriangle.up.fill").imageScale(.small)
                        }
                        DeckKey(width: unit, height: (keyHeight - 2) / 2, a11y: "Down arrow", id: "deck-key-down", repeats: true, action: { press("down") }) {
                            Image(systemName: "arrowtriangle.down.fill").imageScale(.small)
                        }
                    }
                    DeckKey(width: unit, a11y: "Right arrow", id: "deck-key-right", repeats: true, action: { press("right") }) {
                        Image(systemName: "arrowtriangle.right.fill").imageScale(.small)
                    }
                }
            }
            .environment(\.deckKeyHeight, keyHeight)
            .padding(.horizontal, side)
            .padding(.vertical, 8)
        }
        .padding(.bottom, foot)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mac keys")
        .accessibilityIdentifier("deck-keyboard")
    }

    // MARK: Keys

    private func character(_ c: String, _ unit: CGFloat) -> some View {
        let upper = shift || caps
        let shown = upper ? (Self.shifted[c] ?? c.uppercased()) : c
        return DeckKey(width: unit, a11y: Self.spoken[c].map { upper ? "\($0), \(shown)" : $0 } ?? shown, id: "deck-key-\(c)", pop: shown,
                       action: { type(shown) }) { Text(shown) }
    }

    private func pressKey<L: View>(_ name: String, width: CGFloat, a11y: String, @ViewBuilder label: @escaping () -> L) -> some View {
        DeckKey(width: width, a11y: a11y, id: "deck-key-\(name)", action: { press(name) }, label: label)
    }

    private func shiftKey(width: CGFloat) -> some View {
        DeckKey(width: width, lit: shift || caps, a11y: caps ? "Caps Lock" : "Shift", id: "deck-key-shift", action: tapShift) {
            Image(systemName: caps ? "capslock.fill" : shift ? "shift.fill" : "shift")
        }
        .accessibilityValue(caps ? "on" : shift ? "on for the next key" : "off")
    }

    private func tapShift() {
        Haptics.pick()
        let now = Date()
        if caps { caps = false; shift = false }
        else if shift, now.timeIntervalSince(shiftAt) < 0.35 { caps = true }
        else { shift.toggle() }
        shiftAt = now
    }

    private func modifier(_ m: WatchModifier, width: CGFloat) -> some View {
        let on = input.modifiers.contains(m) || (m == .command && input.switching)
        return DeckKey(width: width, lit: on, a11y: m.name, id: "deck-key-\(m.rawValue)", action: { input.toggle(m) }) {
            VStack(spacing: 0) {
                Text(m.glyph).font(.system(size: 15))
                Text(m.rawValue).font(.system(size: 8, weight: .medium)).opacity(width > 34 ? 0.7 : 0)
            }
        }
        .accessibilityValue(on ? "on for the next key" : "off")
    }

    // MARK: Sending

    private func type(_ text: String) {
        Haptics.press()
        KeyboardEcho.shared.typed(WatchTyping(delete: 0, text: text), modifiers: input.modifiers)
        input.typed(WatchTyping(delete: 0, text: text))
        if shift, !caps { shift = false }
    }

    private func delete() {
        Haptics.press()
        KeyboardEcho.shared.typed(WatchTyping(delete: 1, text: ""))
        input.typed(WatchTyping(delete: 1, text: ""))
    }

    /// A named key (`press` plays its own tap), ⇧ folded in while it waits.
    private func press(_ name: String) {
        input.press(WatchKey(name, shift: shift || caps))
        if !caps { shift = false }
    }
}

private struct DeckKeyHeight: EnvironmentKey { static let defaultValue: CGFloat = 50 }
extension EnvironmentValues {
    var deckKeyHeight: CGFloat {
        get { self[DeckKeyHeight.self] }
        set { self[DeckKeyHeight.self] = newValue }
    }
}

/// A Magic Keyboard key that goes down on the touch, as a real key does — iOS's keys wait for the
/// lift, and a keyboard that waited for both would read as slow. A character shows big over the
/// finger while it's down; ⌫, the arrows and space repeat while held (the first press felt, the
/// repeats quiet).
private struct DeckKey<Label: View>: View {
    var width: CGFloat
    var height: CGFloat? = nil
    var lit = false
    var a11y: String
    var id: String
    var pop: String? = nil
    var repeats = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.deckKeyHeight) private var keyHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false
    @State private var repeater: Task<Void, Never>?

    var body: some View {
        let h = height ?? keyHeight
        DeckKeyFace(pressed: pressed && pop == nil, lit: lit, label: label)
            .frame(width: width, height: h)
            .overlay(alignment: .bottom) {
                if pressed, let pop {
                    // The key grown over the finger, iOS's way: the letter is never under the thumb.
                    Text(pop)
                        .font(.system(size: 30))
                        .foregroundStyle(MagicKeyboard.legend)
                        .frame(width: max(width * 1.5, 44), height: h * 1.1)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MagicKeyboard.key)
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2))
                        .offset(y: -h - 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .zIndex(pressed ? 1 : 0)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    action()
                    guard repeats else { return }
                    repeater = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 420_000_000)
                        while !Task.isCancelled { Haptics.quietly(action); try? await Task.sleep(nanoseconds: 70_000_000) }
                    }
                }
                .onEnded { _ in stop() })
            .onDisappear { stop() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11y)
            .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
            .accessibilityIdentifier(id)
    }

    private func stop() {
        pressed = false
        repeater?.cancel()
        repeater = nil
    }
}

private struct DeckKeyFace<Label: View>: View {
    var pressed: Bool
    var lit = false
    @ViewBuilder var label: () -> Label

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        label()
            .font(.system(size: 19, weight: .regular))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(lit ? Ink.onTint : MagicKeyboard.legend)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(lit ? Light.cyan : pressed ? MagicKeyboard.keyDown : MagicKeyboard.key))
            .shadow(color: MagicKeyboard.keyShadow, radius: 0, y: pressed ? 0 : 1)
            .offset(y: pressed ? 1 : 0)
            .contentShape(shape)
    }
}

/// fn: F1–F20, Home, End, the pages, and the Mac's own moves (Spotlight, Switch App, Mission
/// Control) — the window's ··· menu's list, in its order.
private struct DeckFn: View {
    @ObservedObject var input: MacInput
    var width: CGFloat
    @Environment(\.deckKeyHeight) private var keyHeight

    var body: some View {
        Menu {
            Section(WatchKey.macSection.title) {
                ForEach(WatchKey.macSection.keys) { k in
                    Button { if k == .appSwitcher { input.switchApp() } else { input.press(k) } } label: { Text(k.title); Text(k.glyph) }
                        .accessibilityLabel("\(k.title), \(k.name)")
                }
            }
            Section("Function keys") {
                ForEach(0..<4, id: \.self) { row in
                    ControlGroup {
                        ForEach(MacKeys.functionKeys[(row * 5)..<min(row * 5 + 5, MacKeys.functionKeys.count)]) { k in
                            Button(k.glyph) { input.press(k) }.accessibilityLabel(k.name)
                        }
                    }
                    .controlGroupStyle(.compactMenu)
                }
            }
            Section("More keys") {
                ForEach(MacKeys.navigation) { k in
                    Button { input.press(k) } label: { Text(k.name); Text(k.glyph) }
                        .accessibilityLabel(k.name)
                }
            }
        } label: {
            DeckKeyFace(pressed: false) {
                Text("fn").font(.system(size: 15, weight: .medium))
            }
            .frame(width: width, height: keyHeight)
        }
        .accessibilityLabel("Function keys and more")
        .accessibilityHint("F1 to F20, Home, End, Page Up and Down, and your Mac's own moves: Spotlight, Switch App, Mission Control.")
        .accessibilityIdentifier("deck-key-fn")
    }
}
