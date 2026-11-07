import Combine
import MacrophoneKit
import SwiftUI
import UIKit

/// The three ways in while a window shows (Oct 19 2026, Sameer: "a 3 input method carousel"):
/// the keyboard, the mic (the default, every time), the trackpad. This holds the page, the sticky
/// modifiers (⌘ ⌥ ⌃ ⇧ — one goes on the next key or click), the pointer the trackpad moves (kept
/// here, as a fraction of the window: the phone draws it as an arrow, keeps it in view and tells
/// the Mac the place, so the two never drift apart; it starts where the Mac's own pointer is when
/// the Mac says, else in the middle of what's on screen), and the app switcher's held ⌘. The
/// messages are gated on what the Mac named in its welcome: a page shows only when the Mac takes
/// its messages.
@MainActor
final class MacInput: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case keyboard, mic, trackpad
        var id: String { rawValue }

        var title: String {
            switch self {
            case .keyboard: return "Keyboard"
            case .mic: return "Mic"
            case .trackpad: return "Trackpad"
            }
        }

        var symbol: String {
            switch self {
            case .keyboard: return "keyboard"
            case .mic: return "mic"
            case .trackpad: return "rectangle.and.hand.point.up.left"
            }
        }
    }

    @Published private(set) var page: Page = .mic
    /// The pages this Mac offers, in carousel order: the keyboard, the mic, the trackpad.
    @Published private(set) var pages: [Page] = [.mic]
    /// Modifiers waiting for the next key or click (one-shot).
    @Published private(set) var modifiers: Set<WatchModifier> = []
    /// Where the pointer is, as a fraction of the window.
    @Published private(set) var pointer = TrackpadPointer()
    /// Bumped on every pointer move from the trackpad: the window's view keeps it in sight.
    @Published private(set) var pointerSeq = 0
    /// The pointer shows in the window (the trackpad page is up).
    @Published private(set) var pointerShown = false
    /// ⌘ is held for the app switcher: each tap of Switch App presses Tab again; it lets go a
    /// moment after the last tap (the highlighted app comes forward then, as on the Mac).
    @Published private(set) var switching = false
    /// The trackpad has been used once (its hint can go).
    @AppStorage("watch.trackpad.used") private(set) var trackpadUsed = false
    /// The iOS keyboard is up for the keyboard page (Nov 4 2026, Sameer: "when I am switching to
    /// the keyboard the window jumps up and down too much"). What the keyboard takes the place of —
    /// the carousel's room, the Thread, the window's key row — gives way only when it actually
    /// rises, in its own motion, and comes back as it goes: the window moves once each way
    /// instead of growing, shrinking and growing again.
    @Published private(set) var keysUp = false
    /// How much of the screen the keyboard page's keyboard takes, from the screen's foot (its
    /// keys and the Mac's bar on it); 0 while it's down. The regular iPhone lays the keyboard's
    /// room out from this itself (`MainView.phoneBody`), rather than from the safe area.
    @Published private(set) var keyboardRoom: CGFloat = 0

    init() {
        Self.listeners.append(Weak(self))
        listenForHardwareKeyboard()
    }

    // A real keyboard (Nov 5 2026, HardwareKeyboard.swift): what it holds on the Mac, the key it
    // repeats, and whether it's been said that it types on the Mac.
    var keys = HardwareKeyRouter()
    var keyRepeat: Task<Void, Never>?
    var repeatingUsage: Int?
    var keyboardNoted = false
    var lastKeyPress: Date?
    var keyboardWatch: AnyCancellable?

    // One change for the keyboard's coming and going (Nov 4 2026). The safe area SwiftUI gives
    // the keyboard and `keysUp` arrived in different passes, a sixth of a second apart: rising,
    // the window shrank to a sliver (the keyboard's room taken, the pages' not yet given back)
    // and grew again; going, it grew, shrank under the key row coming back and grew again —
    // and in the middle the page row's words and glyphs came apart. The regular iPhone now
    // ignores the keyboard's safe area on the mic screen and takes `keyboardRoom` instead,
    // changed with `keysUp` in one animation over the keyboard's own time.
    private struct Weak { weak var input: MacInput?; init(_ i: MacInput) { input = i } }
    private static var listeners: [Weak] = []
    private static var listening: [NSObjectProtocol] = []

    static func listenEarly() {
        guard listening.isEmpty else { return }
        // The frame's change is the first word of a keyboard moving (Will Show and Will Hide
        // come after it): up when it ends on the screen, down when it ends below it.
        listening.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: nil) { n in
            let duration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated {
                let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds ?? .zero
                let room = end.height > 0 ? max(0, screen.maxY - end.minY) : 0
                listeners.removeAll { $0.input == nil }
                for l in listeners { l.input?.keyboardMoving(room: room > 1 ? room : 0, duration: duration) }
            }
        })
    }

    private func keyboardMoving(room: CGFloat, duration: Double) {
        let up = room > 0
        // Only the keyboard page's own keyboard (a word being fixed raises one too).
        guard !up || page == .keyboard else { return }
        guard up != keysUp || abs(room - keyboardRoom) > 0.5 else { return }
        withAnimation(duration > 0 ? .spring(duration: duration, bounce: 0) : nil) {
            keysUp = up
            keyboardRoom = room
        }
    }

    var macFeatures: () -> Set<String> = { [] }
    var sendMouse: (WatchMouseEvent) -> Bool = { _ in false }
    var sendType: (WatchTyping) -> Bool = { _ in false }
    var sendKeyState: (WatchKey, Bool) -> Bool = { _, _ in false }
    var sendKey: (WatchKey) -> Bool = { _ in false }
    /// The watch: keeps it awake, says a line over the window, logs.
    weak var watcher: Watcher?
    /// The watched window's size in Mac points, as the phone estimates it (its picture's pixels,
    /// halved — a Retina Mac); the trackpad's motion is in these.
    var windowPoints = CGSize(width: 1400, height: 900)
    private var releaseSwitch: Task<Void, Never>?
    /// The middle of what the window's view shows now, as a fraction of the window (set by the
    /// viewer): where the pointer starts when the trackpad opens, until the Mac says where its
    /// own pointer is.
    var visibleCenter: () -> CGPoint? = { nil }
    /// The trackpad hasn't moved the pointer since its page opened: the Mac's own pointer's place,
    /// when it comes, is where it starts.
    private var untouchedSinceShown = false

    var canMouse: Bool { macFeatures().contains(WatchMouse.feature) }
    var canType: Bool { macFeatures().contains(WatchTyping.feature) }
    var canHoldKeys: Bool { macFeatures().contains(WatchKeyHold.feature) }

    /// What the connected Mac offers: computed when the window opens (and when the link changes).
    func refreshPages() {
        var p: [Page] = []
        if canType { p.append(.keyboard) }
        p.append(.mic)
        if canMouse { p.append(.trackpad) }
        if p != pages { pages = p }
        if !pages.contains(page) { show(.mic, quiet: true) }
    }

    /// The window view opened: the mic, every time — unless it's the Duo's inner screen (Oct 25
    /// 2026), where the deck opens on the page remembered for it (the trackpad the first time,
    /// like a laptop).
    func opened() {
        refreshPages()
        let wanted = pose.isInner ? deckPage(for: pose) : .mic
        if page != wanted { show(wanted, quiet: true) }
        noteHardwareKeyboard()
    }

    // MARK: The Duo's deck (Oct 25 2026)

    /// How the Duo is held (`Posture`): on the inner screen the deck remembers its page.
    private(set) var pose: FoldPose = .closed

    /// The pose changed. The inner screen has two decks — upright (the laptop, and laid flat:
    /// one layout, the fold in the same place) and on its side (the book, and laid flat) — and
    /// folding within one moves nothing, the page included (Nov 7 2026: the laptop's trackpad
    /// laid flat came back as the mic). Turning to the other deck brings its remembered page (the
    /// trackpad the first time); back to the cover, the mic — the page the window view always
    /// opens on there.
    func poseChanged(_ p: FoldPose) {
        let was = pose
        pose = p
        // The window in hand (the glance has its pages put away: no pointer to show there).
        guard watcher?.isShowing == true else { return }
        refreshPages()
        if p.isInner {
            if !was.isInner || Self.deckKey(p) != Self.deckKey(was), !micHeld { show(deckPage(for: p), quiet: true) }
        } else if was.isInner, page == .trackpad {
            show(.mic, quiet: true)
        }
    }

    // MARK: The mic open over a deck (Nov 7 2026)

    /// A dictation is under way: the mic is the page, whatever the deck was on (a laptop's
    /// trackpad showed the words with no mic under them and no way to stop), and no page takes
    /// its place until it ends.
    private(set) var micHeld = false
    /// The deck's page before the mic opened over it: where it goes back to after.
    private var beforeMic: Page?
    /// The page the mic page last took over from, and when (the phone's own view may bring the
    /// mic up a moment before the deck hears the mic open).
    private var micTookOver: (page: Page, at: Date)?

    func micOpen(_ live: Bool) {
        if live {
            guard !micHeld else { return }
            micHeld = true
            if pose.isInner {
                if page != .mic {
                    beforeMic = page
                } else if let t = micTookOver, Date().timeIntervalSince(t.at) < 1 {
                    beforeMic = t.page
                }
                if beforeMic == .keyboard { beforeMic = underKeyboard == .keyboard ? nil : underKeyboard }
            }
            if page != .mic { show(.mic, quiet: true) }
        } else {
            guard micHeld else { return }
            micHeld = false
            let back = beforeMic
            beforeMic = nil
            if let back, back != .mic, page == .mic, pose.isInner, watcher?.isShowing == true, pages.contains(back) {
                show(back, quiet: true)
            }
        }
    }

    /// The deck's page for a folded pose: the one last picked there (the mic or the trackpad —
    /// the keyboard is for the moment it's up, never what a deck opens on), else the trackpad
    /// (the mic when the Mac has no trackpad).
    func deckPage(for p: FoldPose) -> Page {
        // A real keyboard on the desk (Nov 5 2026): the keys are there already, the deck is the
        // trackpad.
        if HardwareKeyboard.shared.connected, pages.contains(.trackpad) { return .trackpad }
        let stored = UserDefaults.standard.string(forKey: Self.deckKey(p)).flatMap(Page.init(rawValue:))
        let wanted = stored ?? .trackpad
        return pages.contains(wanted) ? wanted : .mic
    }

    /// Upright and on its side each keep their own (the laptop's key and the book's, as before).
    private static func deckKey(_ p: FoldPose) -> String { "duo.deck.\(p.foldAcross ? "laptop" : "book")" }

    /// The page the keyboard rose over (a folded deck: what hiding it goes back to).
    private var underKeyboard: Page = .mic

    /// The keyboard put away (its bar's button, a swipe down on it, the system closing it): on a
    /// folded deck, back to the page it rose over — the trackpad on a laptop, as the hands are
    /// already on the deck — and nothing remembered, since he picked no page; everywhere else
    /// the mic, as ever.
    func hideKeyboard(quiet: Bool = false) {
        guard page == .keyboard else { return }
        let back: Page = pose.isInner && pages.contains(underKeyboard) && underKeyboard != .keyboard ? underKeyboard : .mic
        show(back, quiet: true)
        if !quiet { Haptics.pick() }
    }

    /// The window view closed: back to the mic, nothing held or waiting.
    func closed() {
        hardwareReleaseAll()
        if pointerShown { _ = sendMouse(WatchMouseEvent(.hide, at: pointer.point)) }
        pointerShown = false
        endSwitch(now: true)
        modifiers = []
        page = .mic
        pages = [.mic]
        beforeMic = nil
    }

    /// The link came back: the pages may differ (another Mac), and a trackpad page still up gets
    /// its pointer back (the Mac's own cursor was drawn into the stream only while told so).
    func linkChanged(connected: Bool) {
        if connected {
            refreshPages()
            if page == .trackpad, canMouse, !pointerShown {
                pointerShown = true
                _ = sendMouse(WatchMouseEvent(.show, at: pointer.point))
                pointerSeq &+= 1
            }
        } else {
            pointerShown = false
            switching = false
            hardwareForget()
        }
    }

    func show(_ p: Page, quiet: Bool = false) {
        guard pages.contains(p) || p == .mic else { return }
        guard p != page else { return }
        // While the mic is open nothing quietly takes its page (a deck keeping its trackpad, the
        // keyboard going): a tap of his own still does.
        if micHeld, p != .mic, quiet { return }
        watcher?.touch()
        if !quiet { Haptics.pick() }
        let wasTrackpad = page == .trackpad
        if p == .keyboard { underKeyboard = page }
        micTookOver = p == .mic ? (page, Date()) : nil
        page = p
        if p == .trackpad, canMouse {
            // The pointer starts in the middle of what's on screen (the window's centre could be
            // off a zoomed view); the Mac's answer moves it to where its own pointer is.
            if let c = visibleCenter() { pointer.put(c) }
            untouchedSinceShown = true
            pointerShown = true
            _ = sendMouse(WatchMouseEvent(.show, at: pointer.point))
            pointerSeq &+= 1
        } else if wasTrackpad, pointerShown {
            pointerShown = false
            _ = sendMouse(WatchMouseEvent(.hide, at: pointer.point))
        }
        // A modifier waiting is shown lit on the keyboard's bar and nowhere else: leaving the
        // keyboard page lets it go, so no page ever carries one it can't show (the polish pass).
        if p != .keyboard, !modifiers.isEmpty { modifiers = [] }
        // Folded: the deck remembers the page he picked for this pose (the mic or the trackpad).
        if pose.isInner, !quiet, p != .keyboard { UserDefaults.standard.set(p.rawValue, forKey: Self.deckKey(pose)) }
        watcher?.log?.add("watching: input page \(p.rawValue)")
        watcher?.inputPageChanged()
    }

    /// The next page to the left or right of this one (a swipe, VoiceOver's adjust).
    func step(_ delta: Int) {
        guard let i = pages.firstIndex(of: page) else { return }
        let j = i + delta
        guard pages.indices.contains(j) else { return }
        show(pages[j])
    }

    // MARK: Modifiers

    func toggle(_ m: WatchModifier) {
        watcher?.touch()
        Haptics.pick()
        if modifiers.contains(m) { modifiers.remove(m) } else { modifiers.insert(m) }
    }

    /// The modifiers for the next key or click, in menu order — taken, so they're one-shot. ⇧ and
    /// ⌥ held on a real keyboard go too (⇧-click from the trackpad).
    func takeModifiers() -> [WatchModifier] {
        let held = hardwareClickModifiers
        guard !modifiers.isEmpty || !held.isEmpty else { return [] }
        let taken = WatchModifier.allCases.filter { modifiers.contains($0) || held.contains($0) }
        modifiers = []
        return taken
    }

    private func fold(_ k: WatchKey, _ mods: [WatchModifier]) -> WatchKey {
        var key = k
        for m in mods {
            switch m {
            case .command: key.command = true
            case .shift: key.shift = true
            case .option: key.option = true
            case .control: key.control = true
            }
        }
        return key
    }

    // MARK: Keys

    /// A key from the bar or a menu, with the modifiers waiting folded in; the view goes to where
    /// it answers.
    func press(_ k: WatchKey) {
        watcher?.touch()
        let key = fold(k, takeModifiers())
        guard sendKey(key) else { return }
        Haptics.press()
        watcher?.inputSent()
        watcher?.log?.add("watching: key")
    }

    /// ⌘Tab: ⌘ held, Tab pressed; another tap presses Tab again; ⌘ let go a second after the last.
    func switchApp() {
        watcher?.touch()
        guard canHoldKeys else { press(.appSwitcher); return }
        if !switching {
            guard sendKeyState(WatchKey("command"), true) else { return }
            switching = true
            // The keyboard's bar says so too; over the window for the other pages.
            if page != .keyboard { watcher?.say("Switching apps — tap Switch App again for the next one", symbol: "macwindow.on.rectangle") }
        }
        Haptics.press()
        _ = sendKey(WatchKey("tab"))
        watcher?.inputSent()
        releaseSwitch?.cancel()
        releaseSwitch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            self?.endSwitch(now: false)
        }
    }

    /// ⌘ let go (the app the switcher is on comes forward).
    func endSwitch(now: Bool) {
        releaseSwitch?.cancel()
        releaseSwitch = nil
        guard switching else { return }
        switching = false
        _ = sendKeyState(WatchKey("command"), false)
        if !now { watcher?.inputSent() }
    }

    // MARK: Three fingers (Oct 30 2026: the Duo's deck is a laptop's trackpad)

    /// Three fingers swept on the trackpad: what they do on a Mac — up Mission Control, down App
    /// Exposé, left the desktop on the right, right the desktop on the left.
    func threeFingerSwipe(_ d: TrackpadSwipe) {
        let (key, words, symbol): (WatchKey, String, String) = {
            switch d {
            case .up: return (WatchKey("up", control: true), "Mission Control", "rectangle.3.group")
            case .down: return (WatchKey("down", control: true), "App Exposé", "rectangle.stack")
            case .left: return (WatchKey("right", control: true), "Desktop to the right", "arrow.right.square")
            case .right: return (WatchKey("left", control: true), "Desktop to the left", "arrow.left.square")
            }
        }()
        watcher?.touch()
        guard sendKey(key) else { return }
        Haptics.press()
        watcher?.say(words, symbol: symbol)
        watcher?.inputSent()
        watcher?.log?.add("watching: three-finger \(words)")
    }

    /// The trackpad's other moves (Oct 31 2026): a pinch is ⌘+ / ⌘− (what zooms in a browser, a
    /// terminal, an editor — a posted magnify gesture isn't something a Mac takes), three fingers
    /// tapped are Look Up (⌃⌘D, the word under the pointer), four fingers spread show the desktop.
    func trackpadGesture(_ g: TrackpadGesture) {
        let (key, words, symbol): (WatchKey, String, String) = {
            switch g {
            case .zoomIn: return (WatchKey("equal", command: true), "Zoom in", "plus.magnifyingglass")
            case .zoomOut: return (WatchKey("minus", command: true), "Zoom out", "minus.magnifyingglass")
            case .lookUp: return (WatchKey("d", command: true, control: true), "Look Up", "character.book.closed")
            case .showDesktop: return (WatchKey("f11"), "Show Desktop", "menubar.dock.rectangle")
            }
        }()
        watcher?.touch()
        guard sendKey(key) else { return }
        Haptics.press()
        watcher?.say(words, symbol: symbol)
        watcher?.inputSent()
        watcher?.log?.add("watching: trackpad \(words)")
    }

    // MARK: Typing

    /// What the hidden field did. With a modifier waiting, one typed character goes as that
    /// shortcut instead (⌘ then "k" → ⌘K); otherwise the deletes and the characters, as typed.
    func typed(_ t: WatchTyping) {
        guard !t.isEmpty else { return }
        watcher?.touch()
        if !modifiers.isEmpty, t.delete == 0, t.text.count == 1, let c = t.text.first, c.isLetter || c.isNumber || c == " " {
            let name = c == " " ? "space" : String(c).lowercased()
            press(WatchKey(name, shift: c.isUppercase))
            return
        }
        guard sendType(t) else { return }
        watcher?.inputSent(recenter: t.text.contains("\n"))
    }

    // MARK: The trackpad

    /// The Mac said where its own pointer is in the window (with a frame's words): the trackpad
    /// starts from there, so the first move carries on from the real pointer — as long as the
    /// trackpad hasn't moved it yet since its page opened.
    func macCursor(_ p: CGPoint) {
        guard page == .trackpad, pointerShown, untouchedSinceShown else { return }
        guard abs(p.x - pointer.x) > 0.002 || abs(p.y - pointer.y) > 0.002 else { return }
        pointer.put(p)
        pointerSeq &+= 1
    }

    /// A finger moved on the trackpad: the pointer by that much, faster when the finger is.
    func pointerMoved(by delta: CGVector, dt: TimeInterval) {
        trackpadUsed = true
        untouchedSinceShown = false
        watcher?.touch()
        let step = TrackpadMotion.step(delta, dt: dt, speed: Settings.trackpadSpeedNow)
        let before = pointer
        pointer.move(by: step, window: windowPoints)
        pointerSeq &+= 1
        _ = sendMouse(WatchMouseEvent(.move, at: pushed(from: before, by: step), modifiers: Array(modifiers)))
    }

    /// Where to send the pointer: where it is — or, pushed on against an edge it already sits on,
    /// a little past it, so the Mac's cursor presses that edge of the screen as a real trackpad's
    /// does (the hidden Dock, a hot corner — Nov 1 2026, Sameer: "move the mouse all the way to
    /// the bottom, it doesn't reliably bring the Mac dock up").
    private func pushed(from before: TrackpadPointer, by step: CGVector) -> CGPoint {
        var p = pointer.point
        let w = windowPoints
        guard w.width > 0, w.height > 0 else { return p }
        func past(_ d: CGFloat, _ size: CGFloat) -> CGFloat { min(0.05, max(0.004, abs(d) / size)) }
        if before.y >= 0.999, step.dy > 0 { p.y = 1 + past(step.dy, w.height) }
        if before.y <= 0.001, step.dy < 0 { p.y = -past(step.dy, w.height) }
        if before.x >= 0.999, step.dx > 0 { p.x = 1 + past(step.dx, w.width) }
        if before.x <= 0.001, step.dx < 0 { p.x = -past(step.dx, w.width) }
        return p
    }

    /// A tap on the trackpad: a click where the pointer is (count 2 for a double-tap's second tap).
    func tap(count: Int) {
        watcher?.touch()
        Haptics.press()
        _ = sendMouse(WatchMouseEvent(.click, at: pointer.point, count: count, modifiers: takeModifiers()))
        watcher?.inputSent()
        watcher?.log?.add("watching: trackpad click\(count > 1 ? " ×\(count)" : "")")
    }

    /// A two-finger tap on the trackpad: a right-click where the pointer is.
    func rightTap() {
        watcher?.touch()
        Haptics.rightClick()
        _ = sendMouse(WatchMouseEvent(.click, at: pointer.point, right: true, modifiers: takeModifiers()))
        watcher?.inputSent()
        watcher?.log?.add("watching: trackpad right-click")
    }

    /// A drag from the trackpad (tap, tap and hold, then move): the button down where the pointer is.
    func dragBegan() {
        watcher?.touch()
        Haptics.grab()
        _ = sendMouse(WatchMouseEvent(.down, at: pointer.point, modifiers: takeModifiers()))
        watcher?.log?.add("watching: trackpad drag")
    }

    func dragMoved(by delta: CGVector, dt: TimeInterval) {
        untouchedSinceShown = false
        pointer.move(by: TrackpadMotion.step(delta, dt: dt, speed: Settings.trackpadSpeedNow), window: windowPoints)
        pointerSeq &+= 1
        _ = sendMouse(WatchMouseEvent(.drag, at: pointer.point))
    }

    func dragEnded() {
        _ = sendMouse(WatchMouseEvent(.up, at: pointer.point))
        watcher?.inputSent()
    }

    /// A tap on the window itself: the pointer is there now (the trackpad carries on from it).
    func pointerTapped(_ p: CGPoint) {
        untouchedSinceShown = false
        pointer.put(p)
    }

    // MARK: The window's own gestures (the picture)

    /// A tap on the picture, with its count (a second tap within a moment is a double-click's
    /// second click) and the modifiers waiting. False when the Mac predates "mouse" (the caller
    /// sends the old click).
    func windowClick(_ p: CGPoint, count: Int, right: Bool) -> Bool {
        guard canMouse else { return false }
        untouchedSinceShown = false
        pointer.put(p)
        return sendMouse(WatchMouseEvent(.click, at: p, right: right, count: count, modifiers: takeModifiers()))
    }

    /// A drag on the picture (a tap, then a hold that moves): press, drag, release.
    func windowDrag(_ kind: WatchMouseEvent.Kind, at p: CGPoint) {
        guard canMouse else { return }
        untouchedSinceShown = false
        pointer.put(p)
        let mods = kind == .down ? takeModifiers() : []
        _ = sendMouse(WatchMouseEvent(kind, at: p, modifiers: mods))
        if kind == .down { Haptics.grab(); watcher?.log?.add("watching: drag") }
        if kind == .up { watcher?.inputSent() }
    }
}
