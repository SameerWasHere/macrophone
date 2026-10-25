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

    /// The window view opened: the mic, every time — unless the Duo is folded into the laptop
    /// or the book (Oct 25 2026), where the deck opens on the page remembered for that pose (the
    /// trackpad the first time, like a laptop).
    func opened() {
        refreshPages()
        let wanted = pose.isFolded ? deckPage(for: pose) : .mic
        if page != wanted { show(wanted, quiet: true) }
    }

    // MARK: The Duo's deck (Oct 25 2026)

    /// How the Duo is held (`Posture`): folded, the deck remembers its page per pose.
    private(set) var pose: FoldPose = .closed

    /// The pose changed: a folded pose brings its remembered page up (the trackpad the first
    /// time); back to a flat or closed screen, the mic — the page the window view always opens on.
    func poseChanged(_ p: FoldPose) {
        let was = pose
        pose = p
        guard watcher?.isOpen == true else { return }
        refreshPages()
        if p.isFolded, !was.isFolded || p != was {
            show(deckPage(for: p), quiet: true)
        } else if !p.isFolded, was.isFolded, page == .trackpad {
            show(.mic, quiet: true)
        }
    }

    /// The deck's page for a folded pose: the one last picked there, else the trackpad (the mic
    /// when the Mac has no trackpad).
    func deckPage(for p: FoldPose) -> Page {
        let stored = UserDefaults.standard.string(forKey: Self.deckKey(p)).flatMap(Page.init(rawValue:))
        let wanted = stored ?? .trackpad
        return pages.contains(wanted) ? wanted : .mic
    }

    private static func deckKey(_ p: FoldPose) -> String { "duo.deck.\(p.name)" }

    /// The window view closed: back to the mic, nothing held or waiting.
    func closed() {
        if pointerShown { _ = sendMouse(WatchMouseEvent(.hide, at: pointer.point)) }
        pointerShown = false
        endSwitch(now: true)
        modifiers = []
        page = .mic
        pages = [.mic]
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
        }
    }

    func show(_ p: Page, quiet: Bool = false) {
        guard pages.contains(p) || p == .mic else { return }
        guard p != page else { return }
        watcher?.touch()
        if !quiet { Haptics.tick() }
        let wasTrackpad = page == .trackpad
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
        // Folded: the deck remembers the page he picked for this pose.
        if pose.isFolded, !quiet { UserDefaults.standard.set(p.rawValue, forKey: Self.deckKey(pose)) }
        watcher?.log?.add("watching: input page \(p.rawValue)")
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
        Haptics.tick()
        if modifiers.contains(m) { modifiers.remove(m) } else { modifiers.insert(m) }
    }

    /// The modifiers for the next key or click, in menu order — taken, so they're one-shot.
    func takeModifiers() -> [WatchModifier] {
        guard !modifiers.isEmpty else { return [] }
        let taken = WatchModifier.allCases.filter { modifiers.contains($0) }
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
        Haptics.tick()
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
        Haptics.tick()
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
        pointer.move(by: TrackpadMotion.step(delta, dt: dt), window: windowPoints)
        pointerSeq &+= 1
        _ = sendMouse(WatchMouseEvent(.move, at: pointer.point, modifiers: Array(modifiers)))
    }

    /// A tap on the trackpad: a click where the pointer is (count 2 for a double-tap's second tap).
    func tap(count: Int) {
        watcher?.touch()
        Haptics.tick()
        _ = sendMouse(WatchMouseEvent(.click, at: pointer.point, count: count, modifiers: takeModifiers()))
        watcher?.inputSent()
        watcher?.log?.add("watching: trackpad click\(count > 1 ? " ×\(count)" : "")")
    }

    /// A two-finger tap on the trackpad: a right-click where the pointer is.
    func rightTap() {
        watcher?.touch()
        Haptics.success()
        _ = sendMouse(WatchMouseEvent(.click, at: pointer.point, right: true, modifiers: takeModifiers()))
        watcher?.inputSent()
        watcher?.log?.add("watching: trackpad right-click")
    }

    /// A drag from the trackpad (tap, tap and hold, then move): the button down where the pointer is.
    func dragBegan() {
        watcher?.touch()
        Haptics.soft()
        _ = sendMouse(WatchMouseEvent(.down, at: pointer.point, modifiers: takeModifiers()))
        watcher?.log?.add("watching: trackpad drag")
    }

    func dragMoved(by delta: CGVector, dt: TimeInterval) {
        untouchedSinceShown = false
        pointer.move(by: TrackpadMotion.step(delta, dt: dt), window: windowPoints)
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
        if kind == .down { Haptics.soft(); watcher?.log?.add("watching: drag") }
        if kind == .up { watcher?.inputSent() }
    }
}
