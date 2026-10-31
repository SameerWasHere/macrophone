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
        // The keyboard went away while this page was up (hide, a swipe down, the system): the
        // page goes with it — back to the mic (Sameer: "when hitting the close button, the UI
        // should just go back to mic mode", never a keyboard page with no keyboard).
        v.onKeyboardGone = { [weak input] in input?.hideKeyboard(quiet: true) }
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
    /// The keyboard left while the page still wanted it.
    var onKeyboardGone: () -> Void = {}
    var bar: KeyboardBarHost?
    var wantsKeyboard = false
    private var goneCheck: DispatchWorkItem?

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
        Self.all.add(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    /// Let go of the keyboard while the page still wants it (hide, the system, a menu): a
    /// moment later, still without it, the page is told. A menu that hands the keyboard straight
    /// back never counts.
    /// Inside our own `becomeFirstResponder`: UIKit resigns the current first responder first —
    /// this view, when it's asked twice — and that resign is no loss of the keyboard.
    private var becoming = false
    /// A `becomeFirstResponder` already queued (the page's first frames ask twice).
    private var focusQueued = false

    override func becomeFirstResponder() -> Bool {
        becoming = true
        defer { becoming = false }
        let ok = super.becomeFirstResponder()
        if ok { Self.current = self }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r, wantsKeyboard, !becoming {
            goneCheck?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.wantsKeyboard, !self.isFirstResponder, self.window != nil else { return }
                // Another field of this page has the keyboard (the Duo's layouts cross-fading,
                // Oct 25 2026: the arriving layout's field took it from this one's): not gone.
                if let c = Self.current, c !== self, c.isFirstResponder, c.wantsKeyboard { return }
                self.onKeyboardGone()
            }
            goneCheck = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
        return r
    }

    override func deleteBackward() {
        if (text ?? "").isEmpty { onEmptyDelete(); return }
        super.deleteBackward()
    }

    /// Every field alive, and the one that last took the keyboard. Two exist while the Duo's
    /// layouts cross-fade (each layout builds its own carousel; a page's field is in each), and
    /// SwiftUI can keep a faded-out one around at alpha 0 (the third pass found the deck's
    /// not-watching layout lingering so): the keyboard belongs to a field that can be seen,
    /// and a field leaving the window hands it to one that's still there.
    private static let all = NSHashTable<KeyboardTextView>.weakObjects()
    private static weak var current: KeyboardTextView?

    /// Hidden by an ancestor (faded out, hidden): never takes the keyboard.
    private var seen: Bool {
        var v: UIView? = self
        while let u = v { if u.isHidden || u.alpha < 0.01 { return false }; v = u.superview }
        return true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The cover's keyboard spans its whole width: the bar takes one row there.
        if #available(iOS 27.1, *), let w = window {
            let one = w.traitCollection.verticalBarEdge != .unspecified
            if bar?.oneRow != one { bar?.oneRow = one; if isFirstResponder { reloadInputViews() } }
        }
        if window == nil, wantsKeyboard {
            // Gone from the screen while the page still wants the keyboard: a field that's
            // still there (the arriving layout's) takes it.
            for other in Self.all.allObjects where other !== self && other.window != nil && other.wantsKeyboard { other.applyFocus() }
        }
        applyFocus()
    }

    /// Takes the keyboard when the page is up (once it's in a window, and visible), lets it go
    /// when it isn't.
    func applyFocus() {
        guard window != nil else { return }
        if !wantsKeyboard { goneCheck?.cancel() }
        if wantsKeyboard, !isFirstResponder, !focusQueued, seen {
            focusQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusQueued = false
                guard self.wantsKeyboard, self.window != nil, !self.isFirstResponder, self.seen else { return }
                self.becomeFirstResponder()
            }
        } else if !wantsKeyboard, isFirstResponder {
            // Never inside SwiftUI's update (this runs from `updateUIView`): the keyboard's
            // tracking re-renders the same graph and it spins in a cycle — the hide button froze
            // the app on the Duo's cover (Oct 30 2026). Next turn of the run loop, like taking it.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.wantsKeyboard, self.isFirstResponder else { return }
                _ = self.resignFirstResponder()
            }
        }
    }
}

/// The bar above the keys, as a view UIKit can hand to the keyboard: the SwiftUI bar hosted in it.
final class KeyboardBarHost: UIView {
    private let host: UIHostingController<MacKeyboardBar>
    /// Two rows of cells and the room between (`MacKeyboardBar`).
    static let height: CGFloat = MacKeyboardBar.height

    var rootView: MacKeyboardBar {
        get { host.rootView }
        set { var r = newValue; r.oneRow = oneRow; host.rootView = r }
    }

    /// The bar in one row (the Duo's cover): its height follows.
    var oneRow = false {
        didSet {
            guard oneRow != oldValue else { return }
            host.rootView.oneRow = oneRow
            frame.size.height = barHeight
            invalidateIntrinsicContentSize()
        }
    }

    private var barHeight: CGFloat { oneRow ? MacKeyboardBar.oneRowHeight : Self.height }

    init(rootView: MacKeyboardBar) {
        host = UIHostingController(rootView: rootView)
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height))
        autoresizingMask = .flexibleWidth
        backgroundColor = .clear
        // The bar sits flush on the keys: a safe area here (the cover's vertical bar, the
        // screen's foot) only pushed its cells up off the keyboard.
        host.safeAreaRegions = []
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

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: barHeight) }
}

/// The keys a phone's keyboard lacks — one bar on the keyboard itself, two rows, fitting every
/// iPhone without scrolling (the carousel fixes, Oct 19 2026 — before, the arrows rode the
/// carousel's page and the modifiers the keyboard's bar, two strips laid out by two systems
/// that overlapped once the keyboard rose):
///
///   [ esc | ⇥ ]  [ ← | ↑ | ↓ | → ]         Typing in Claude      ← the first row
///   [ ⌘ | ⌥ | ⌃ | ⇧ ]                        [ fn | ⌨︎ ]           ← the second
///
/// Clusters of the watch's glass, so it reads as one instrument with the window's keys. A swipe
/// right to left on the bar's open room comes back to the mic, as the row above and hide do.
struct MacKeyboardBar: View {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher

    /// Two rows of cells, the room between and around.
    static let height: CGFloat = WatchLook.control * 2 + 6 * 3
    /// One row: the iPhone Duo's cover, whose keyboard spans the whole 466 pt (Oct 30 2026 —
    /// the two rows left the window a sliver).
    static let oneRowHeight: CGFloat = WatchLook.control + 6 * 2
    var oneRow = false

    private var cell: CGFloat { oneRow ? 32 : 38 }

    var body: some View {
        Group {
            if oneRow {
                HStack(spacing: 6) {
                    escTab
                    arrows
                    Spacer(minLength: 0)
                    mods
                    fnHide
                }
            } else {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        escTab
                        arrows
                        // Where the typing goes, when there's room for it (the kicker at the top says
                        // the window too); a modifier waiting or the app switcher held says so instead.
                        ViewThatFits(in: .horizontal) {
                            status.fixedSize()
                            Color.clear.frame(width: 0, height: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityHidden(true)
                    }
                    HStack(spacing: 8) {
                        mods
                        Spacer(minLength: 0)
                        fnHide
                    }
                }
            }
        }
        .padding(.horizontal, WatchLook.sideMargin)
        .padding(.vertical, 6)
        .frame(height: oneRow ? Self.oneRowHeight : Self.height)
        // The way back on the open room (a key keeps its own press).
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                    if v.translation.width < -40, abs(v.translation.width) > abs(v.translation.height) { input.hideKeyboard() }
                })
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keys for \(watcher.name) on your Mac")
        .accessibilityIdentifier("keyboard-bar")
    }

    private var escTab: some View {
        HStack(spacing: 0) {
            MacKeyboardCell(input: input, watcher: watcher, key: WatchKey("escape"), label: Text("esc"), width: oneRow ? 36 : 44)
            WatchCellDivider()
            MacKeyboardCell(input: input, watcher: watcher, key: WatchKey("tab"), label: Text("⇥"), width: oneRow ? 30 : 36)
        }
        .watchGlass(Capsule())
    }

    private var arrows: some View {
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

    private var mods: some View {
        HStack(spacing: 0) {
            ForEach(WatchModifier.allCases, id: \.self) { m in
                if m != .command { WatchCellDivider() }
                modifier(m)
            }
        }
        .watchGlass(Capsule())
    }

    private var fnHide: some View {
        HStack(spacing: 0) {
            moreKeys
            WatchCellDivider()
            Button { input.hideKeyboard() } label: {
                Image(systemName: "keyboard.chevron.compact.down").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(WatchCellStyle(width: oneRow ? 34 : 40, tint: Ink.secondary))
            .accessibilityLabel("Hide the keyboard")
            .accessibilityHint(input.pose.isFolded ? "Back to the deck." : "Back to the mic.")
            .accessibilityIdentifier("keyboard-hide")
        }
        .watchGlass(Capsule())
    }

    private var status: some View {
        Text(line)
            .font(.footnote.weight(.medium))
            .foregroundStyle(input.switching || !input.modifiers.isEmpty ? Light.cyan : Ink.tertiary)
            .lineLimit(1)
            .padding(.trailing, 4)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.15), value: line)
    }

    /// Short, so it fits beside the clusters on a 402pt phone (134pt is what's left there).
    private var line: String {
        if input.switching { return "Tap for next app" }
        if !input.modifiers.isEmpty {
            let mods = WatchModifier.allCases.filter { input.modifiers.contains($0) }.map(\.glyph).joined()
            return "\(mods) next key"
        }
        return "Typing in \(watcher.name)"
    }

    private func repeatKey(_ k: WatchKey, symbol: String) -> some View {
        RepeatKey(label: Image(systemName: symbol), name: k.name, watcherName: watcher.name, width: cell) { input.press(k) }
            .accessibilityIdentifier("keyboard-\(k.key)")
    }

    /// ⌘ ⌥ ⌃ ⇧: on, the next key or tap goes with it.
    private func modifier(_ m: WatchModifier) -> some View {
        let on = input.modifiers.contains(m) || (m == .command && input.switching)
        return Button { input.toggle(m) } label: {
            Text(m.glyph)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: cell, height: WatchLook.control - 6)
                .background(Capsule().fill(on ? Light.cyan : .clear).padding(.horizontal, 2))
                .foregroundStyle(on ? Ink.ground : Ink.ink)
        }
        .buttonStyle(.plain)
        .frame(width: cell, height: WatchLook.control)
        .contentShape(Rectangle())
        .accessibilityLabel(m.name)
        .accessibilityValue(on ? "on" : "off")
        .accessibilityHint("Goes on the next key you type or the next tap on the window.")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("keyboard-\(m.rawValue)")
    }

    /// F1–F20, the keys past the arrows, and the Mac's own moves — the same list, in the same
    /// order, as the window's ··· menu shows while the keyboard is away (`WatchKey.macSection`).
    private var moreKeys: some View {
        Menu {
            Section(WatchKey.macSection.title) {
                ForEach(WatchKey.macSection.keys) { k in
                    Button {
                        // The app switcher holds ⌘ (the Mac names "keyHold"); every other key is a press.
                        if k == .appSwitcher { input.switchApp() } else { input.press(k) }
                    } label: { Text(k.title); Text(k.glyph) }
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
        .buttonStyle(WatchCellStyle(width: oneRow ? 32 : 40, tint: Ink.secondary))
        .accessibilityLabel("Function keys and more")
        .accessibilityHint("F1 to F20, Home, End, Page Up and Down, and your Mac's own moves: Spotlight, Switch App, Mission Control.")
        .accessibilityIdentifier("keyboard-fn")
    }
}

/// One key as a cell: pressed in the watched window, with the modifiers waiting folded in.
struct MacKeyboardCell: View {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher
    var key: WatchKey
    var label: Text
    var width: CGFloat = 40

    var body: some View {
        Button { input.press(key) } label: { label.font(.subheadline.weight(.semibold)) }
            .buttonStyle(WatchCellStyle(width: width))
            .accessibilityLabel(key.name)
            .accessibilityHint("Presses \(key.name) in \(watcher.name) on your Mac.")
            .accessibilityIdentifier("keyboard-\(key.key)")
    }
}

/// A key that repeats while held (the arrows): one press on touch-down, then, held past 0.4 s,
/// one every 70 ms until the finger lifts.
struct RepeatKey<L: View>: View {
    var label: L
    var name: String
    var watcherName: String
    var width: CGFloat = 38
    var press: () -> Void
    @State private var holding = false
    @State private var timer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Ink.ink)
            .frame(width: width, height: WatchLook.control)
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
            // The page can slide away under a held finger: the repeat never outlives the key.
            .onDisappear {
                holding = false
                timer?.invalidate()
                timer = nil
            }
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityHint("Presses \(name) in \(watcherName) on your Mac.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { press() }
    }
}
