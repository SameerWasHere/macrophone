import MacrophoneKit
import SwiftUI
import UIKit

// The keyboard page's machinery (Oct 19 2026): the iPhone's own keyboard, typing live into
// whatever has focus on the Mac. A hidden text view takes what iOS inserts and deletes —
// autocorrect, emoji, accents, other languages, the Return key — and the difference from what it
// held before goes to the Mac as "delete N, type this" (`TypingDiff`), which the Mac types as
// unicode, no clipboard. Above the keys rides one row of what a phone's keyboard lacks: esc, ⇥,
// the arrows (hold to repeat), what was just typed, and Mac Keys — the Mac's own keyboard
// (`DeckKeyboard`) in place of iOS's, swapped as the globe key swaps keyboards (Nov 7 2026: iOS's
// keyboard first on every screen, the Duo's included — it's the fast one).

struct MacKeyboardField: UIViewRepresentable {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher
    /// The keyboard page is up: the field takes the keyboard; else it lets it go.
    var active: Bool
    @ObservedObject private var choice = KeyboardChoice.shared
    /// The screen it types from follows the pose (Mac Keys is remembered per screen).
    @ObservedObject private var posture = Posture.shared

    init(input: MacInput, watcher: Watcher, active: Bool) {
        self.input = input
        self.watcher = watcher
        self.active = active
    }

    func makeUIView(context: Context) -> KeyboardTextView {
        let v = KeyboardTextView()
        v.input = input
        v.delegate = context.coordinator
        v.onEmptyDelete = { [weak input] in
            KeyboardEcho.shared.typed(WatchTyping(delete: 1, text: ""))
            input?.typed(WatchTyping(delete: 1, text: ""))
        }
        // The keyboard went away while this page was up (hide, a swipe down, the system): the
        // page goes with it — back to the mic (Sameer: "when hitting the close button, the UI
        // should just go back to mic mode", never a keyboard page with no keyboard).
        v.onKeyboardGone = { [weak input] in input?.hideKeyboard(quiet: true) }
        v.stillWanted = { [weak input, weak watcher] in input?.page == .keyboard && watcher?.fullScreen == false }
        v.bar = KeyboardBarHost(rootView: MacKeyboardBar(input: input, watcher: watcher))
        v.inputAccessoryView = v.bar
        return v
    }

    func updateUIView(_ v: KeyboardTextView, context: Context) {
        context.coordinator.input = input
        v.bar?.rootView = MacKeyboardBar(input: input, watcher: watcher, surface: v.surface)
        v.applyKeys()
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
            KeyboardEcho.shared.typed(diff, modifiers: input.modifiers)
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
    /// The Mac's keyboard, made the first time Mac Keys is asked for.
    var deckKeyboard: DeckKeyboardHost?
    /// Which screen this field types from (Mac Keys is remembered per screen).
    var surface: KeyboardChoice.Surface = .phone
    /// On the Duo's cover (its vertical bar).
    var onCover: Bool {
        if #available(iOS 27.1, *), let w = window { return w.traitCollection.verticalBarEdge != .unspecified }
        return false
    }
    var wantsKeyboard = false
    /// Asked again the moment the keyboard would be taken (Nov 8 2026, round 2): `wantsKeyboard`
    /// is what the last SwiftUI update said; the page can have moved on since, and in full screen
    /// there is no keyboard page at all — the reviewer's Duo brought this field's keyboard up over
    /// the full-screen picture from the mic mode.
    var stillWanted: () -> Bool = { true }
    /// No shortcuts groups beside the predictions (upright on the inner screen).
    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            _ = (savedLeading, savedTrailing)  // kept before they're cleared
            inputAssistantItem.leadingBarButtonGroups = compact ? [] : savedLeading
            inputAssistantItem.trailingBarButtonGroups = compact ? [] : savedTrailing
        }
    }
    private lazy var savedLeading = inputAssistantItem.leadingBarButtonGroups
    private lazy var savedTrailing = inputAssistantItem.trailingBarButtonGroups
    private var goneCheck: DispatchWorkItem?
    private var reloadQueued = false

    /// How tall iOS's keys stood last on each screen held each way (the bar left out, the
    /// screen's foot in): the Mac's keys take the same, so the window above never moves on a swap.
    private var measureKey: String {
        let s = window?.bounds.size ?? .zero
        // The folded laptop's frame holds the hinge's band too: kept apart from flat upright's
        // (`v2`: before Nov 7 2026 the two shared one key, and the laptop's 495 pt was taken for
        // flat upright's 350).
        let shape = s.width > s.height ? "wide" : Posture.shared.pose == .laptop ? "laptop" : "tall"
        return "keyboard.iosKeys.v2.\(surface.rawValue).\(shape)"
    }

    /// The keyboard's whole height last seen on flat upright, its keys and the bar on them (the
    /// flat deck makes room for it at rest, so the Mac's window never moves for it).
    static var flatUprightKeyboard: CGFloat {
        let keys = UserDefaults.standard.double(forKey: "keyboard.iosKeys.v2.inner.tall")
        return (keys > 150 ? keys : 350) + KeyboardBarHost.height
    }

    var macKeysHeight: CGFloat {
        let foot = window?.safeAreaInsets.bottom ?? 0
        let fallback: CGFloat = (surface == .phone ? 292 : surface == .cover ? 248 : 288) + foot
        let known = UserDefaults.standard.double(forKey: measureKey)
        var h = max(known > 0 ? known : fallback, 216 + foot)
        // Upright on the inner screen iOS's keyboard frame reaches over the fold (its keys keep
        // off the hinge, the frame doesn't): the Mac's keys and the bar stay on the deck's half.
        if surface == .inner, let w = window, w.bounds.height > w.bounds.width {
            h = min(h, w.bounds.height / 2 - KeyboardBarHost.height)
        }
        return h
    }

    /// The keyboard this screen wants, put in place: iOS's, or the Mac's when Mac Keys is on here;
    /// the bar on either. From the representable's update, the field arriving in a window (the
    /// cover is known only then) and a pose change.
    func applyKeys() {
        guard let input else { return }
        let pose = Posture.shared.pose
        // The pose first: on its side the inner screen has a vertical bar too.
        let s: KeyboardChoice.Surface = pose.isInner ? .inner : onCover ? .cover : .phone
        surface = s
        if let bar, bar.rootView.surface != s { var r = bar.rootView; r.surface = s; bar.rootView = r }
        let mac = KeyboardChoice.shared.macKeys(on: s)
        if mac, deckKeyboard == nil { deckKeyboard = DeckKeyboardHost(input: input, surface: s) }
        deckKeyboard?.surface = s
        deckKeyboard?.keysHeight = macKeysHeight
        deckKeyboard?.foot = window?.safeAreaInsets.bottom ?? 0
        let keys: UIView? = mac ? deckKeyboard : nil
        var reload = false
        // The bar is the keyboard's accessory on every screen. (On the folded laptop iOS starts the
        // keyboard's frame at the top of the hinge's band, 20 pt above the fold, its keys ~50 pt
        // lower — and the keyboard's window takes every touch in that band, so a bar drawn there
        // by the layout can't be tapped. On the accessory it sits just above the band.)
        if inputAccessoryView !== bar { inputAccessoryView = bar; reload = true }
        if inputView !== keys { inputView = keys; reload = true }
        // Upright on the inner screen the deck is short: no shortcuts groups beside the predictions.
        // The predictions stay (Nov 7 2026, Sameer's newest word wins over the Nov 1 "suppress the
        // Siri part": they're the speed).
        let upright = pose == .laptop || pose == .open(landscape: false)
        if compact != upright { compact = upright; reload = true }
        // Never inside SwiftUI's update: the keyboard's frame moving re-renders this same graph.
        if reload, isFirstResponder { reloadSoon() }
    }

    /// The keyboard swapped or re-dressed on the next turn of the run loop, as the globe key does:
    /// the field keeps the keyboard throughout.
    func reloadSoon() {
        guard !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadQueued = false
            if self.isFirstResponder { self.reloadInputViews() }
        }
    }

    @objc private func keyboardShown(_ n: Notification) {
        #if DEBUG
        // MACROPHONE_KBD_DUMP=1: where the keyboard's frame starts, whether the bar is on it, and
        // where the system keyboard's keys start (its placeholder) — the laptop's hinge band.
        if isFirstResponder, DebugHooks.env["MACROPHONE_KBD_DUMP"] == "1" {
            let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            var keysTop = CGFloat.nan
            func find(_ v: UIView) {
                if String(describing: type(of: v)).contains("KeyboardPlaceholder") { keysTop = v.convert(v.bounds, to: nil).minY }
                v.subviews.forEach(find)
            }
            window?.windowScene?.windows.forEach(find)
            NSLog("KBD frame top %.1f (%.1f tall), the bar %@, keys from %.1f", end.minY, end.height,
                  inputAccessoryView === bar ? "on it" : "drawn by the layout", keysTop)
        }
        #endif
        guard isFirstResponder, inputView == nil,
              let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let keys = end.height - (inputAccessoryView === bar ? (bar?.bounds.height ?? 0) : 0)
        guard keys > 150, abs(keys - UserDefaults.standard.double(forKey: measureKey)) > 0.5 else { return }
        UserDefaults.standard.set(Double(keys), forKey: measureKey)
        if let d = deckKeyboard, abs(d.keysHeight - macKeysHeight) > 0.5 { d.keysHeight = macKeysHeight }
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        keyboardAppearance = .default
        // A developer's keyboard: no curly quotes or dashes into a terminal, no capital at the
        // start of a command; autocorrect stays (it's the phone's, and it's what the diff is for).
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        autocorrectionType = .default
        spellCheckingType = .default
        returnKeyType = .default
        // Writing Tools would rewrite the hidden field, and the rewrite would go to the Mac as typing.
        if #available(iOS 18.0, *) { writingToolsBehavior = .none }
        accessibilityElementsHidden = true
        Self.all.add(self)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardShown(_:)), name: UIResponder.keyboardDidShowNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Let go of the keyboard while the page still wants it (hide, the system, a menu): a
    /// moment later, still without it, the page is told. A menu that hands the keyboard straight
    /// back never counts.
    /// Inside our own `becomeFirstResponder`: UIKit resigns the current first responder first —
    /// this view, when it's asked twice — and that resign is no loss of the keyboard.
    private var becoming = false
    /// A `becomeFirstResponder` already queued (the page's first frames ask twice).
    private var focusQueued = false

    /// Only while the page wants it (Nov 8 2026, round 3): UIKit restores a text view's keyboard
    /// by itself — the window's last text input, when the responder that took over lets go — and
    /// did so a tenth of a second into full screen on the Duo once the keyboard mode had been
    /// used (the log read "wants false, page mic, full screen true"): the keyboard rose over the
    /// deck with the Mac bar on it, the full-screen ground arrived under it, then it went.
    override var canBecomeFirstResponder: Bool { wantsKeyboard && stillWanted() && super.canBecomeFirstResponder }

    override func becomeFirstResponder() -> Bool {
        guard wantsKeyboard, stillWanted() else {
            #if DEBUG
            AppModel.shared.log.add("keyboard field: refused the keyboard (page \(String(describing: MainActor.assumeIsolated { AppModel.shared.watcher.input.page })), full screen \(MainActor.assumeIsolated { AppModel.shared.watcher.fullScreen }))")
            #endif
            return false
        }
        #if DEBUG
        AppModel.shared.log.add("keyboard field: taking the keyboard (wants \(wantsKeyboard), seen \(seen), page \(String(describing: MainActor.assumeIsolated { AppModel.shared.watcher.input.page })), full screen \(MainActor.assumeIsolated { AppModel.shared.watcher.fullScreen }))")
        #endif
        becoming = true
        defer { becoming = false }
        let ok = super.becomeFirstResponder()
        if ok { Self.current = self }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        // A real keyboard's ⌘ or ⌃ held on the Mac goes with it.
        if r, !becoming { input?.hardwareReleaseAll() }
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

    // A real keyboard while the keyboard page is up (Nov 5 2026): its characters, Return, Tab and
    // Delete go through this field like the phone's own keys (autocorrect's diff stays in step);
    // its chords, Esc and the arrows go to the Mac as keys — never to this hidden field's caret or
    // its Copy and Undo.
    weak var input: MacInput?
    /// Presses passed on to the field, so their ends go the same way.
    private var passed: Set<Int> = []

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses {
            guard let key = p.key, input?.hardwarePress(key, field: true) == true else {
                rest.insert(p)
                if let k = p.key { passed.insert(k.keyCode.rawValue) }
                continue
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = hardwareEnded(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = hardwareEnded(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    private func hardwareEnded(_ presses: Set<UIPress>) -> Set<UIPress> {
        var rest = Set<UIPress>()
        for p in presses {
            guard let key = p.key else { rest.insert(p); continue }
            input?.hardwareRelease(key)
            if passed.remove(key.keyCode.rawValue) != nil { rest.insert(p) }
        }
        return rest
    }

    /// Every field alive, and the one that last took the keyboard. Two exist while the Duo's
    /// layouts cross-fade (each layout builds its own carousel; a page's field is in each), and
    /// SwiftUI can keep a faded-out one around at alpha 0 (the third pass found the deck's
    /// not-watching layout lingering so): the keyboard belongs to a field that can be seen,
    /// and a field leaving the window hands it to one that's still there.
    private static let all = NSHashTable<KeyboardTextView>.weakObjects()
    private static weak var current: KeyboardTextView?

    #if DEBUG
    /// The hooks' typing, as the keyboard's own keys would put it in (autocorrect's diff, the bar's words).
    static func debugType(_ text: String) -> Bool {
        guard let c = current, c.isFirstResponder else { return false }
        c.insertText(text)
        return true
    }
    #endif

    /// Hidden by an ancestor (faded out, hidden): never takes the keyboard.
    private var seen: Bool {
        var v: UIView? = self
        while let u = v { if u.isHidden || u.alpha < 0.01 { return false }; v = u.superview }
        return true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyKeys() }
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
        if wantsKeyboard, !isFirstResponder, !focusQueued, seen, stillWanted() {
            focusQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusQueued = false
                guard self.wantsKeyboard, self.window != nil, !self.isFirstResponder, self.seen, self.stillWanted() else { return }
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
    static let height: CGFloat = MacKeyboardBar.height

    var rootView: MacKeyboardBar {
        get { host.rootView }
        set { host.rootView = newValue }
    }

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

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }
}

/// The keys a phone's keyboard lacks — one row on every screen (Nov 7 2026; it was two, 94 pt,
/// and the Duo had none):
///
///   [ esc | ⇥ ]  [ ← | ↑ | ↓ | → ]   …llo there            [ ⌘ | ⌨︎ ]
///
/// In the middle, what was just typed (the field it goes through is hidden), fading back to where
/// it goes; a modifier waiting or the app switcher held says so there instead. ⌘ is Mac Keys: the
/// Mac's own keyboard in place of iOS's. That one has esc, ⇥ and the arrows itself, so with it up
/// the row keeps only the words, Mac Keys and hide. A swipe right to left on the row's open room
/// comes back to the mic, as hide does.
struct MacKeyboardBar: View {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher
    var surface: KeyboardChoice.Surface = .phone
    @ObservedObject private var choice = KeyboardChoice.shared
    @ObservedObject private var echo = KeyboardEcho.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A key's height: a whole touch target.
    static let cell: CGFloat = 44
    static let height: CGFloat = cell + 4 * 2

    private var macKeys: Bool { choice.macKeys(on: surface) }

    var body: some View {
        HStack(spacing: 6) {
            if !macKeys {
                HStack(spacing: 0) {
                    MacKeyboardCell(input: input, watcher: watcher, key: WatchKey("escape"), label: Text("esc"), width: 40)
                    WatchCellDivider()
                    MacKeyboardCell(input: input, watcher: watcher, key: WatchKey("tab"), label: Text("⇥"), width: 34)
                }
                .watchGlass(Capsule())
                .transition(.opacity)
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
                .transition(.opacity)
            }
            echoLine
            HStack(spacing: 0) {
                macKeysToggle
                WatchCellDivider()
                Button { input.hideKeyboard() } label: {
                    Image(systemName: "keyboard.chevron.compact.down").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(WatchCellStyle(width: 40, height: Self.cell, tint: Ink.secondary))
                .accessibilityLabel("Hide the keyboard")
                .accessibilityHint(input.pose.isFolded ? "Back to the deck." : "Back to the mic.")
                .accessibilityIdentifier("keyboard-hide")
            }
            .watchGlass(Capsule())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: Self.height)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: macKeys)
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

    /// What was just typed; a moment after the last key, where it goes.
    private var echoLine: some View {
        let waiting = input.switching || !input.modifiers.isEmpty
        let showing = !waiting && echo.fresh && !echo.text.isEmpty
        let words = showing ? echo.text : status
        return Group {
            if showing {
                // The newest letters at the right edge; the oldest go first.
                Text(words).truncationMode(.head)
            } else {
                // Where it goes, shortened to the app's name where the row is narrow.
                ViewThatFits(in: .horizontal) {
                    Text(words)
                    Text(waiting ? words : watcher.name).truncationMode(.tail)
                }
            }
        }
            .font(.footnote.weight(waiting ? .semibold : .regular))
            .foregroundStyle(waiting ? Light.cyan : showing ? Ink.secondary : Ink.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .animation(.easeOut(duration: 0.25), value: showing)
            .animation(.easeOut(duration: 0.15), value: waiting)
            .accessibilityLabel(showing ? "Typed: \(words)" : words)
            .accessibilityIdentifier("keyboard-echo")
    }

    private var status: String {
        if input.switching { return "Tap for next app" }
        if !input.modifiers.isEmpty {
            let mods = WatchModifier.allCases.filter { input.modifiers.contains($0) }.map(\.glyph).joined()
            return "\(mods) next key"
        }
        return "Typing in \(watcher.name)"
    }

    /// The layer switch, as the system keyboard's "123" / "ABC" key: "Mac" brings the Mac's
    /// keyboard, "ABC" iOS's. A plain word, never lit — it switches layers, it isn't an on/off
    /// light (Nov 7 2026: drawn as ⌘ it read as the sticky ⌘ key, which it had been in that place).
    private var macKeysToggle: some View {
        Button { choice.toggle(on: surface) } label: {
            Text(macKeys ? "ABC" : "Mac")
                .font(.subheadline.weight(.semibold))
                .contentTransition(.identity)
        }
        .buttonStyle(WatchCellStyle(width: 44, height: Self.cell))
        .accessibilityLabel("Mac Keys")
        .accessibilityValue(macKeys ? "on" : "off")
        .accessibilityHint(macKeys ? "Back to the iPhone's keyboard." : "The Mac's keyboard: ⌘ ⌥ ⌃, fn and the function keys.")
        .accessibilityIdentifier("keyboard-mac-keys")
    }

    private func repeatKey(_ k: WatchKey, symbol: String) -> some View {
        RepeatKey(label: Image(systemName: symbol), name: k.name, watcherName: watcher.name, width: 34, height: Self.cell) { input.press(k) }
            .accessibilityIdentifier("keyboard-\(k.key)")
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
            .buttonStyle(WatchCellStyle(width: width, height: MacKeyboardBar.cell))
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
    var height: CGFloat = WatchLook.control
    var press: () -> Void
    @State private var holding = false
    @State private var timer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Ink.ink)
            .frame(width: width, height: height)
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
                        // Felt once, on the first press: the repeats go quietly.
                        timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in Haptics.quietly(press) }
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
