import MacrophoneKit
import SwiftUI
import UIKit

// The keyboard page's machinery (Oct 19 2026): the iPhone's own keyboard, typing live into
// whatever has focus on the Mac. A hidden text view takes what iOS inserts and deletes —
// autocorrect, emoji, accents, other languages, the Return key — and the difference from what it
// held before goes to the Mac as "delete N, type this" (`TypingDiff`), which the Mac types as
// unicode, no clipboard. Above the keys rides a bar of what a phone's keyboard lacks: Esc, Tab,
// the sticky modifiers (⌘ ⌥ ⌃ ⇧ — on, the next key or tap goes with it), the arrows (hold to
// repeat), the F-keys and the Mac's own moves (Spotlight, the app switcher, Mission Control…).

struct MacKeyboardField: UIViewRepresentable {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher
    /// The keyboard page is up: the field takes the keyboard; else it lets it go.
    var active: Bool

    func makeUIView(context: Context) -> KeyboardTextView {
        let v = KeyboardTextView()
        v.delegate = context.coordinator
        v.onEmptyDelete = { [weak input] in input?.typed(WatchTyping(delete: 1, text: "")) }
        v.bar = KeyboardBarHost(rootView: MacKeyboardBar(input: input, watcher: watcher))
        v.inputAccessoryView = v.bar
        return v
    }

    func updateUIView(_ v: KeyboardTextView, context: Context) {
        context.coordinator.input = input
        v.bar?.rootView = MacKeyboardBar(input: input, watcher: watcher)
        v.wantsKeyboard = active
        v.applyFocus()
    }

    func makeCoordinator() -> Coordinator { Coordinator(input: input) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var input: MacInput
        /// What the field held after the last difference was sent.
        private var last = ""
        init(input: MacInput) { self.input = input }

        func textViewDidChange(_ tv: UITextView) {
            // Mid-composition (Japanese, Chinese, a held accent key): nothing is settled yet.
            guard tv.markedTextRange == nil else { return }
            let now = tv.text ?? ""
            let diff = TypingDiff.diff(old: last, new: now)
            guard !diff.isEmpty else { return }
            if !input.modifiers.isEmpty, diff.delete == 0, diff.text.count == 1 {
                // A shortcut, not a character: the field goes back to what it held.
                input.typed(diff)
                tv.text = last
                return
            }
            input.typed(diff)
            last = now
            // The field never grows past a short tail (enough for autocorrect to see the last words).
            if last.count > 300 {
                last = String(last.suffix(80))
                tv.text = last
            }
        }
    }
}

/// The hidden field: a text view that also reports a delete when it's already empty (iOS tells a
/// delegate nothing then), with the Mac's bar as its accessory.
final class KeyboardTextView: UITextView {
    var onEmptyDelete: () -> Void = {}
    var bar: KeyboardBarHost?
    var wantsKeyboard = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        keyboardAppearance = .dark
        // A developer's keyboard: no curly quotes or dashes into a terminal, no capital at the
        // start of a command; autocorrect stays (it's the phone's, and it's what the diff is for).
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        autocorrectionType = .default
        spellCheckingType = .default
        returnKeyType = .default
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    override func deleteBackward() {
        if (text ?? "").isEmpty { onEmptyDelete(); return }
        super.deleteBackward()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyFocus()
    }

    /// Takes the keyboard when the page is up (once it's in a window), lets it go when it isn't.
    func applyFocus() {
        guard window != nil else { return }
        if wantsKeyboard, !isFirstResponder {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsKeyboard, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        } else if !wantsKeyboard, isFirstResponder {
            resignFirstResponder()
        }
    }
}

/// The bar above the keys, as a view UIKit can hand to the keyboard: the SwiftUI bar hosted in it.
final class KeyboardBarHost: UIView {
    private let host: UIHostingController<MacKeyboardBar>
    static let height: CGFloat = 50

    var rootView: MacKeyboardBar {
        get { host.rootView }
        set { host.rootView = newValue }
    }

    init(rootView: MacKeyboardBar) {
        host = UIHostingController(rootView: rootView)
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height))
        autoresizingMask = .flexibleWidth
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }
}

/// Esc · ⇥ | ⌘ ⌥ ⌃ ⇧ | ← ↑ ↓ → | F-keys and the Mac's moves | hide — clusters of the watch's glass,
/// scrolling sideways when the phone is narrow.
struct MacKeyboardBar: View {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher

    var body: some View {
        // fn and hide stay put at the trailing end; the keys scroll beside them on a narrow phone.
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        cell(WatchKey("escape"), label: Text("esc"), width: 44)
                        WatchCellDivider()
                        cell(WatchKey("tab"), label: Text("⇥"), width: 36)
                    }
                    .watchGlass(Capsule())
                    HStack(spacing: 0) {
                        ForEach(WatchModifier.allCases, id: \.self) { m in
                            if m != .command { WatchCellDivider() }
                            modifier(m)
                        }
                    }
                    .watchGlass(Capsule())
                    HStack(spacing: 0) {
                        repeatKey(WatchKey("left"), symbol: "arrow.left")
                        WatchCellDivider()
                        repeatKey(WatchKey("up"), symbol: "arrow.up")
                        WatchCellDivider()
                        repeatKey(WatchKey("down"), symbol: "arrow.down")
                        WatchCellDivider()
                        repeatKey(WatchKey("right"), symbol: "arrow.right")
                    }
                    .watchGlass(Capsule())
                }
                .padding(.leading, WatchLook.sideMargin)
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 0) {
                moreKeys
                WatchCellDivider()
                Button { input.show(.mic) } label: {
                    Image(systemName: "keyboard.chevron.compact.down").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(WatchCellStyle(width: 40, tint: Ink.secondary))
                .accessibilityLabel("Hide the keyboard")
                .accessibilityHint("Back to the mic.")
                .accessibilityIdentifier("keyboard-hide")
            }
            .watchGlass(Capsule())
            .padding(.trailing, WatchLook.sideMargin)
            .padding(.vertical, 6)
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityIdentifier("keyboard-bar")
    }

    private func cell(_ k: WatchKey, label: Text, width: CGFloat = 40) -> some View {
        Button { input.press(k) } label: { label.font(.subheadline.weight(.semibold)) }
            .buttonStyle(WatchCellStyle(width: width))
            .accessibilityLabel(k.name)
            .accessibilityHint("Presses \(k.name) in \(watcher.name) on your Mac.")
            .accessibilityIdentifier("keyboard-\(k.key)")
    }

    /// ⌘ ⌥ ⌃ ⇧: on, the next key or tap goes with it.
    private func modifier(_ m: WatchModifier) -> some View {
        let on = input.modifiers.contains(m) || (m == .command && input.switching)
        return Button { input.toggle(m) } label: {
            Text(m.glyph)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: WatchLook.control - 6)
                .background(Capsule().fill(on ? Light.cyan : .clear).padding(.horizontal, 2))
                .foregroundStyle(on ? Ink.ground : Ink.ink)
        }
        .buttonStyle(.plain)
        .frame(width: 38, height: WatchLook.control)
        .contentShape(Rectangle())
        .accessibilityLabel(m.name)
        .accessibilityValue(on ? "on" : "off")
        .accessibilityHint("Goes on the next key you type or the next tap on the window.")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("keyboard-\(m.rawValue)")
    }

    /// An arrow: one press, or held, repeats.
    private func repeatKey(_ k: WatchKey, symbol: String) -> some View {
        RepeatKey(label: Image(systemName: symbol), name: k.name, watcherName: watcher.name) { input.press(k) }
            .accessibilityIdentifier("keyboard-\(k.key)")
    }

    /// F1–F20, the keys past the arrows, and the Mac's own moves.
    private var moreKeys: some View {
        Menu {
            Section("Your Mac") {
                Button { input.switchApp() } label: { Text("Switch App"); Text(WatchKey.appSwitcher.glyph) }
                    .accessibilityLabel("Switch App, Command-Tab held")
                ForEach([WatchKey.spotlight, .nextWindow, .missionControl, .showDesktop, .desktopLeft, .desktopRight]) { k in
                    Button { input.press(k) } label: { Text(k.title); Text(k.glyph) }
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
            Text("fn")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(WatchCellStyle(width: 40, tint: Ink.secondary))
        .accessibilityLabel("Function keys and more")
        .accessibilityHint("F1 to F20, Home, End, Page Up and Down, and your Mac's own moves: Spotlight, Switch App, Mission Control.")
        .accessibilityIdentifier("keyboard-fn")
    }
}

/// A key that repeats while held (the arrows): one press on touch-down, then, held past 0.4 s,
/// one every 70 ms until the finger lifts.
struct RepeatKey<L: View>: View {
    var label: L
    var name: String
    var watcherName: String
    var press: () -> Void
    @State private var holding = false
    @State private var timer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Ink.ink)
            .frame(width: 38, height: WatchLook.control)
            .background(Capsule().fill(WatchLook.press).opacity(holding ? 1 : 0).padding(3))
            .contentShape(Rectangle())
            .scaleEffect(holding && !reduceMotion ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: holding)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding else { return }
                    holding = true
                    press()
                    timer?.invalidate()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                        timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in press() }
                    }
                }
                .onEnded { _ in
                    holding = false
                    timer?.invalidate()
                    timer = nil
                })
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityHint("Presses \(name) in \(watcherName) on your Mac.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { press() }
    }
}
