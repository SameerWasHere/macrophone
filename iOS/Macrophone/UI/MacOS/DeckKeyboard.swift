import MacrophoneKit
import SwiftUI
import UIKit

// The Duo's own keyboard, upright on the inner screen (Nov 1 2026, Sameer: "Why is it not right
// above or in the keyboard??"). iOS's keyboard keeps an invisible strip over its keys for its
// suggestions, and anything an app hangs on it sits above that strip — on the window's half. So
// upright (the laptop, flat) the hidden field's input view is this: a Mac keyboard drawn to fit
// the deck, Hide among its keys, esc · tab · the arrows · ⌘ ⌥ ⌃ built in. What it types goes
// straight to the Mac (`MacInput.typed` / `press`); no autocorrect, no emoji (the mic is there
// for words).

/// The input view that holds it.
final class DeckKeyboardHost: UIInputView {
    private let host: UIHostingController<DeckKeyboard>
    static let height: CGFloat = 288
    /// The cover is short: the keys a little shorter there.
    static let coverHeight: CGFloat = 248

    init(input: MacInput, height: CGFloat = DeckKeyboardHost.height) {
        host = UIHostingController(rootView: DeckKeyboard(input: input))
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = []
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A Mac keyboard in five rows, sized to the deck.
struct DeckKeyboard: View {
    @ObservedObject var input: MacInput
    /// Shift for the next character (tapped twice: held on, like caps lock).
    @State private var shift = false
    @State private var caps = false

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

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 6
            // The widest row is 13 keys and ⌫ (1.5): the unit fits that across.
            let unit = (geo.size.width - 16 - gap * 13) / 14.5
            let keyHeight = (geo.size.height - 14 - gap * 4) / 5
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    ForEach(Self.rows[0], id: \.self) { character($0, unit) }
                    RepeatingKey(width: unit * 1.5) { delete() } label: { Image(systemName: "delete.left") }
                }
                HStack(spacing: gap) {
                    key("⇥", width: unit * 1.5) { press("tab") }
                    ForEach(Self.rows[1], id: \.self) { character($0, unit) }
                }
                HStack(spacing: gap) {
                    key("esc", width: unit * 1.75) { press("escape") }
                    ForEach(Self.rows[2], id: \.self) { character($0, unit) }
                    key("return", width: unit * 1.75 + gap) { type("\n") }
                }
                HStack(spacing: gap) {
                    shiftKey(width: unit * 2.25 + gap / 2)
                    ForEach(Self.rows[3], id: \.self) { character($0, unit) }
                    shiftKey(width: unit * 2.25 + gap / 2)
                }
                HStack(spacing: gap) {
                    key(width: unit * 1.25, label: Image(systemName: "keyboard.chevron.compact.down"), id: "keyboard-hide", a11y: "Hide Keyboard") { input.hideKeyboard() }
                    modifier(.control, width: unit)
                    modifier(.option, width: unit)
                    modifier(.command, width: unit * 1.25)
                    key(" ", width: max(unit * 3, geo.size.width - 16 - unit * 7.5 - gap * 7), a11y: "Space") { type(" ") }
                    RepeatingKey(width: unit) { arrow("left") } label: { Image(systemName: "arrowtriangle.left.fill") }
                    VStack(spacing: 2) {
                        RepeatingKey(width: unit, height: (keyHeight - 2) / 2) { arrow("up") } label: { Image(systemName: "arrowtriangle.up.fill").imageScale(.small) }
                        RepeatingKey(width: unit, height: (keyHeight - 2) / 2) { arrow("down") } label: { Image(systemName: "arrowtriangle.down.fill").imageScale(.small) }
                    }
                    RepeatingKey(width: unit) { arrow("right") } label: { Image(systemName: "arrowtriangle.right.fill") }
                }
            }
            .frame(maxHeight: .infinity)
            .environment(\.deckKeyHeight, keyHeight)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .background(MagicKeyboard.deck)
    }

    // MARK: Keys

    private func character(_ c: String, _ unit: CGFloat) -> some View {
        let upper = shift || caps
        let shown = upper ? (Self.shifted[c] ?? c.uppercased()) : c
        return key(shown, width: unit) { type(shown) }
    }

    private func key(_ text: String, width: CGFloat, a11y: String? = nil, action: @escaping () -> Void) -> some View {
        key(width: width, label: Text(text), a11y: a11y ?? text, action: action)
    }

    private func key<L: View>(width: CGFloat, label: L, id: String? = nil, a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { label }
            .buttonStyle(DeckKeyStyle(width: width))
            .accessibilityLabel(a11y)
            .accessibilityIdentifier(id ?? "deck-key-\(a11y)")
    }

    private func shiftKey(width: CGFloat) -> some View {
        Button {
            Haptics.tick()
            if caps { caps = false; shift = false } else if shift { caps = true } else { shift = true }
        } label: { Image(systemName: caps ? "capslock.fill" : shift ? "shift.fill" : "shift") }
            .buttonStyle(DeckKeyStyle(width: width, lit: shift || caps))
            .accessibilityLabel(caps ? "Caps Lock, on" : shift ? "Shift, on" : "Shift")
    }

    private func modifier(_ m: WatchModifier, width: CGFloat) -> some View {
        Button { input.toggle(m) } label: { Text(m.glyph) }
            .buttonStyle(DeckKeyStyle(width: width, lit: input.modifiers.contains(m)))
            .accessibilityLabel(m.rawValue.capitalized)
            .accessibilityValue(input.modifiers.contains(m) ? "On for the next key" : "")
    }

    // MARK: Sending

    private func type(_ text: String) {
        Haptics.tick()
        input.typed(WatchTyping(delete: 0, text: text))
        if shift, !caps { shift = false }
    }

    private func delete() { input.typed(WatchTyping(delete: 1, text: "")) }

    private func press(_ name: String) { input.press(WatchKey(name, shift: shift && !caps)); if !caps { shift = false } }

    private func arrow(_ name: String) { press(name) }
}

private struct DeckKeyHeight: EnvironmentKey { static let defaultValue: CGFloat = 50 }
extension EnvironmentValues {
    var deckKeyHeight: CGFloat {
        get { self[DeckKeyHeight.self] }
        set { self[DeckKeyHeight.self] = newValue }
    }
}

/// A Magic Keyboard key on the deck.
private struct DeckKeyStyle: ButtonStyle {
    var width: CGFloat
    var height: CGFloat? = nil
    var lit = false
    @Environment(\.deckKeyHeight) private var keyHeight

    func makeBody(configuration: Configuration) -> some View {
        DeckKeyFace(pressed: configuration.isPressed, lit: lit) { configuration.label }
            .frame(width: width, height: height ?? keyHeight)
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

/// ⌫ and the arrows: again and again while held, as a Mac's do.
private struct RepeatingKey<Label: View>: View {
    var width: CGFloat
    var height: CGFloat? = nil
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.deckKeyHeight) private var keyHeight
    @State private var pressed = false
    @State private var repeater: Task<Void, Never>?

    var body: some View {
        DeckKeyFace(pressed: pressed, label: label)
            .frame(width: width, height: height ?? keyHeight)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    Haptics.tick()
                    action()
                    repeater = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 420_000_000)
                        while !Task.isCancelled { action(); try? await Task.sleep(nanoseconds: 70_000_000) }
                    }
                }
                .onEnded { _ in pressed = false; repeater?.cancel(); repeater = nil })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
