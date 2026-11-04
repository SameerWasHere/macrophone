import MacrophoneKit
import SwiftUI
import UIKit

// The iPhone Duo (Oct 25 2026, Sameer: "Everything we built needs to work well on the front
// screen and then we need to come up with an epic inside screen experience … like a little
// MacBook with the window or full screen taking up the full half when partially folded and the
// bottom half being trackpad or keyboard or mic to control it"). The cover screen keeps the
// phone's layout (`MainView.phoneBody`). The inner screen is 669 × 951 with the fold along the
// middle of its long side, so a half is the cover's size (his phone's log, Nov 1 2026: `laptop
// (105°, 669×835)`, `book (174°, 867×635)`): upright the fold runs across, on its side it runs
// down. Four poses, one rule (Nov 1 2026, Sameer: "it's all about consistency … the same toggles
// … The only thing that changes is that there is now more to view"): **the half that was the
// cover goes on being the cover** — the same Send to, switches, Thread and mic, the same buttons
// in the vertical bar where there is one — **and the other half is the more there is to see: the
// Mac.**
//
//   laptop               upright, the hinge across — a little MacBook. The top half IS the Mac's
//   (and flat, upright)  screen: the picture alone, edge to edge, the status bar gone; nothing
//                        over it. The bottom half is the deck: the window's header across its top
//                        (the name and menu, the question's answers, Sound, Mac Controls,
//                        Pan | Scroll, zoom out, Window, Done), then one mode at a time taking
//                        the whole of the rest — the trackpad, the mic with the Thread across the
//                        half, or the iOS keyboard with the Mac's keys on its bar — the three as a
//                        cluster in the corner. Nothing in hand: the picked app's window live on
//                        top (the glance), the cover's own view below. Flat and upright it is the
//                        same layout (the fold is in the same place), so folding it moves nothing
//   book                 on its side, the hinge up and down — the Mac on the left page, the deck
//                        down the right (the keys, the trackpad, Send to and the mic: the right
//                        thumb's); nothing in hand: the glance left, the cover's view right
//   open, on its side    the window tall on the left page; the deck down the right as the book's;
//                        nothing in hand: the glance left, the cover's view right — what the
//                        phone opens to (the cover becomes the right half as it opens)
//
// Done on the inner screen is the glance, not a closed window (`Watcher.glance`): the picked
// app's window stays live and big, its controls put away, Show it here to take it in hand again —
// and folding the screen (the laptop, the book) takes it in hand by itself. Nothing sits on the
// fold: every pose splits at the fold's region (`FoldHalves`, the inactive region when flat). The
// book's split follows the hinge (the deck rises as the angle closes, `Posture.rise`); the poses
// cross-fade. Every pose keeps the state — the window, the zoom (kept per app), the carousel's
// page, a dictation under way, a sheet.

/// The Duo's measures.
enum DuoLook {
    /// The room kept clear each side of the fold's line on a flat inner screen.
    static let foldGap: CGFloat = 14
    /// The mic on a folded deck: a half of the screen to itself, so the disc is a size up from the
    /// phone's 92 (not a cartoon — the glyph and the ring grow with it).
    static let deckMic: CGFloat = 112
    /// The Thread across a folded deck: its slot, and the room kept over it for the pages'
    /// cluster in the corner.
    static let deckThread: CGFloat = 96
    static let deckThreadTop: CGFloat = 46
    /// The rail beside the window when the screen is open on its side and the fold's line isn't
    /// known: the right page's width less the bar (his phone names the line; a frame without
    /// one falls back to this).
    static let rail: CGFloat = 377
    /// A folded half's screen: a hair of bezel, the corner tight to the half's (the book's page;
    /// the laptop's screen has none — `DuoMacHalf.edge`).
    static let halfBezel: CGFloat = 2
    static let halfCorner: CGFloat = 0
    /// How long the overlay header stays after a touch.
    static let headerHold: TimeInterval = 3.5
    /// Open flat and upright (Nov 1 2026, Sameer: "fully open in portrait mode it should have a
    /// different view with an even bigger window. The half view rule should only be of the laptop
    /// mode"): the deck under the window is this tall — less while a window is in hand.
    static let flatDeck: CGFloat = 300
    static let flatDeckAtRest: CGFloat = 430

    /// The screen's own rounded corner, and how far a picture at the screen's edge sits in from
    /// it so the curve never cuts it — r·(1 − 1/√2) — its corner concentric (Nov 1 2026, Sameer:
    /// "part of the Mac window gets cut off by the rounded edges of the duo screen").
    /// The inner screen's corner: 55 pt on every corner (the Duo's device profile, `iPhone
    /// Duo.simdevicetype` — public data; reading it off the screen would be private API).
    @MainActor static var displayCorner: CGFloat { 55 }
    @MainActor static var edgeInset: CGFloat { ceil(displayCorner * (1 - 1 / 2.squareRoot())) }
    /// Square, like the window it shows (the inset alone keeps the screen's curve off it).
    static let edgeCorner: CGFloat = 0
}

extension MainView {
    // MARK: Open, on its side (951 × 669 points, the vertical bar on the trailing side)

    var openLandscapeBody: some View {
        GeometryReader { geo in
            // The pages either side of the fold's line (the screen's middle, 84 pt of bar on
            // the right): the window, or the glance, on the left; the right page the cover's.
            let split = posture.foldLine.map { $0.midX } ?? (geo.size.width - DuoLook.rail - DuoLook.foldGap)
            let left = max(0, split - DuoLook.foldGap)
            let right = max(0, geo.size.width - left - 2 * DuoLook.foldGap)
            ZStack {
                if watcher.isShowing {
                    // The window tall on the left page; the deck down the right as the book's.
                    HStack(spacing: 0) {
                        DuoMacArea(main: self, deck: true)
                            .environment(\.fullScreenAvailable, true)
                            .padding(.top, 6)
                            .frame(width: left, height: geo.size.height)
                        Color.clear.frame(width: 2 * DuoLook.foldGap)
                        DuoLaptopDeck(main: self, vertical: true)
                            .frame(width: right, height: geo.size.height)
                    }
                    .transition(.opacity)
                } else {
                    openLandscapeRest(left: left, right: right).transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: watcher.isShowing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FoldPose.open(landscape: true).spoken)
    }

    /// Open on its side, nothing in hand (Nov 1 2026, Sameer: "the view that is on the out screen
    /// should be what I see on the right half on the open duo screen with more content on the left
    /// side"): the right half IS the cover — the same Send to, the same switches, the Thread and
    /// the mic, the same buttons in the vertical bar — and the left half is what the cover had no
    /// room for: the picked app's window, live (the glance; Show it here, or the picked place
    /// tapped again, takes it in hand).
    private func openLandscapeRest(left: CGFloat, right: CGFloat) -> some View {
        HStack(spacing: 0) {
            DuoMacArea(main: self)
                .padding(.top, 6)
                .frame(width: left)
            Color.clear.frame(width: 2 * DuoLook.foldGap)
            phoneBody
                .frame(width: right)
        }
    }

    // MARK: The laptop (upright: the hinge across — folded, or flat)

    /// The keyboard page is up with a window in hand.
    var keyboardUp: Bool { watcher.isShowing && input.page == .keyboard }

    var laptopBody: some View {
        GeometryReader { geo in
            let h = posture.halves(for: .laptop, in: geo.size)
            // Flat and upright there's no fold to keep to: the window takes all but the deck.
            let flat = posture.pose == .open(landscape: false)
            // The keyboard up: it covers the deck, so the window takes everything above it (and
            // its Hide button) and nothing overlaps the picture (Nov 1 2026, Sameer: "the
            // keyboard and the hide button … overlap with the view window"). A moment's change:
            // the Mac's window isn't reshaped for it. The deck stays in the tree at no height —
            // the keyboard's field lives in it.
            let typing = keyboardUp
            let deckHeight = typing ? 0 : flat ? min(geo.size.height * 0.52, watcher.isShowing ? DuoLook.flatDeck : DuoLook.flatDeckAtRest) : h.deck.height
            let gap: CGFloat = typing ? 0 : flat ? 10 : h.deck.minY - h.mac.maxY
            let macHeight = flat ? geo.size.height - deckHeight - gap : h.mac.height
            let inset = DuoLook.edgeInset
            VStack(spacing: 0) {
                // The Mac's screen: the picture as big as the half allows, in from the screen's
                // rounded corners so none of it is cut (Nov 1 2026, Sameer: "the view window
                // should take up the whole top half … as if the duo was a mini Mac").
                if let whole = wholeScreenSize(in: CGSize(width: geo.size.width, height: macHeight)) {
                    // The whole screen: all of it, as big as it goes — the half's own shape is
                    // taller than a Mac's display, so the frame takes the picture's shape (no
                    // bars), its foot on the fold, its top corners clear of the screen's.
                    DuoMacHalf(main: self, vertical: false, room: whole, edge: true)
                        .frame(width: whole.width, height: whole.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .frame(height: max(0, macHeight))
                } else {
                    DuoMacHalf(main: self, vertical: false, room: CGSize(width: geo.size.width - 2 * inset, height: macHeight - inset), edge: true)
                        .padding(.horizontal, inset)
                        .padding(.top, inset)
                        .frame(height: max(0, macHeight))
                }
                // The fold: nothing sits here.
                Color.clear.frame(height: max(0, gap))
                DuoDeck(main: self, vertical: false)
                    .frame(height: max(0, deckHeight))
                    // At no height (typing) nothing of it may spill up over the window.
                    .clipped()
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: h)
        }
        // The keyboard rises over the deck's half; with it up the window sits above it.
        .ignoresSafeArea(keyboardUp ? [] : .keyboard)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(posture.pose == .laptop ? FoldPose.laptop.spoken : FoldPose.open(landscape: false).spoken)
    }

    /// The whole screen in the laptop's upper half (Nov 1 2026, Sameer: "white bars on the top and
    /// the bottom … maximize that screen size as much as possible … without getting cut off"):
    /// the widest picture of the Mac's display, centred across with its foot on the fold, whose
    /// top corners stay clear of the screen's rounded ones. Nil for a window (it fills the half).
    func wholeScreenSize(in room: CGSize) -> CGSize? {
        guard watcher.isShowing, watcher.isDesktop, let size = watcher.videoSize ?? watcher.image?.size,
              size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return nil }
        let aspect = size.width / size.height
        // A hair more than the corner's circle: the display's corner is a continuous curve.
        let r = DuoLook.displayCorner + 2
        func fits(_ w: CGFloat) -> Bool {
            let m = (room.width - w) / 2
            let top = m >= r ? 0 : r - (max(0, r * r - (r - m) * (r - m))).squareRoot()
            return top + w / aspect <= room.height
        }
        var lo: CGFloat = 0, hi = room.width
        if fits(hi) { lo = hi } else { for _ in 0..<24 { let w = (lo + hi) / 2; if fits(w) { lo = w } else { hi = w } } }
        let w = lo.rounded(.down)
        return CGSize(width: w, height: (w / aspect).rounded(.down))
    }

    // MARK: The book (on its side: the hinge up and down)

    var bookBody: some View {
        GeometryReader { geo in
            let h = posture.halves(for: .book, in: geo.size)
            let rise = posture.rise
            HStack(spacing: 0) {
                DuoMacHalf(main: self, vertical: true, room: h.mac.size)
                    .environment(\.fullScreenAvailable, true)
                    .frame(width: max(0, h.mac.width))
                    .scaleEffect(reduceMotion ? 1 : 0.97 + 0.03 * rise, anchor: .leading)
                    .opacity(0.6 + 0.4 * rise)
                Color.clear.frame(width: max(0, h.deck.minX - h.mac.maxX))
                DuoDeck(main: self, vertical: true)
                    .frame(width: max(0, h.deck.width))
                    .offset(x: reduceMotion ? 0 : (1 - rise) * 36)
                    .opacity(0.2 + 0.8 * rise)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: rise)
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: h)
        }
        // The keyboard is the screen's width: with it up both pages sit above it, so nothing of
        // the window is under the keys.
        .ignoresSafeArea(keyboardUp ? [] : .keyboard)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FoldPose.book.spoken)
    }

    // MARK: The pieces

    /// The carousel — the page row, the Thread, the mic · keyboard · trackpad pages — as the phone
    /// builds it. `fill`: the room the pages take whole (the trackpad fills it, the mic sits in
    /// the middle of it); `rowHidden`: a folded deck, where the switcher is a cluster in the
    /// corner, the Thread spans the half under it, the mic is a size up and the status line a
    /// size up — the Thread and the mic one group in the middle of the half.
    func carousel(fill: CGFloat?, compact: Bool, rowHidden: Bool = false) -> some View {
        let deck = fill != nil
        // A flat inner screen's bottom bar is kept tight (the window has the room): the Thread's
        // slot a step slimmer and the status one line, as a deck's.
        let slot: CGFloat = rowHidden ? DuoLook.deckThread : deck ? 48 : compact ? 48 : 84
        let micSize = rowHidden ? DuoLook.deckMic : 92
        // A folded deck: the room over the Thread — at least the cluster's row, more on a tall
        // page so the Thread and the mic sit together in the middle.
        let micGroup = 8 + micSize * 1.25 + 28
        let threadTop: CGFloat = rowHidden ? max(DuoLook.deckThreadTop, ((fill ?? 0) - slot - micGroup) / 2) : 0
        let oneLine = deck || compact
        return InputCarousel(input: input, watcher: watcher, compact: compact, threadHeight: slot + threadTop, fill: fill, rowHidden: rowHidden) {
            VStack(spacing: 0) {
                Color.clear.frame(height: deck ? 8 : compact ? 4 : 30)
                MicButton(recording: isRecording,
                          finishing: isFinishing,
                          mode: filamentMode,
                          disabled: micOff,
                          meter: recorder.meter,
                          onDown: pressDown,
                          onUp: pressUp,
                          onAccessibilityToggle: { model.toggleRecording() },
                          size: micSize)
                if oneLine {
                    FixedSlot(alignment: .top) {
                        Text("A").font(rowHidden ? .body : .subheadline).frame(maxWidth: .infinity)
                    } content: {
                        StatusLine(recorder: recorder, holding: holding || look == "holding", font: rowHidden ? .body : .subheadline)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                    .padding(.bottom, deck ? 2 : 6)
                } else {
                    statusSlot
                        .padding(.bottom, compact ? 6 : 18)
                }
            }
        } thread: {
            VStack(spacing: 0) {
                if threadTop > 0 { Color.clear.frame(height: threadTop) }
                ZStack {
                    Filament(mode: filamentMode, meter: recorder.meter, height: rowHidden ? 120 : deck ? 56 : compact ? 56 : 96)
                        .frame(height: slot)
                    DeliveredCheck(visible: showCheck, color: checkColor)
                    timer.frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: slot)
            }
            .frame(height: slot + threadTop)
            .padding(.horizontal, -4)
        }
        .onChange(of: showLiveWords) { _, live in if live, input.page != .mic { input.show(.mic, quiet: true) } }
    }
}

/// Full screen (Nov 3 2026, Sameer: "the window take up the entirety, edge to edge, of the full
/// screen"): the inner screen on its side is the Mac's screen and nothing else — no deck, no bar,
/// no status bar. The window has the screen's shape (`Watcher.setFullScreen`); the whole screen
/// fills it. Taps, drags, pinches and scrolls go to the Mac as in the window view. One glass
/// button in the corner brings the deck back; it fades a few seconds after a touch and a touch
/// brings it back (always there for VoiceOver). A press and hold anywhere brings a see-through
/// trackpad up under the finger (Nov 3 2026, Sameer: "a see through track pad should appear there
/// quickly and stay for a few seconds … dissolve away after like 5 sec of no interaction").
struct DuoFullScreen: View {
    let main: MainView
    @ObservedObject private var watcher: Watcher
    @ObservedObject private var input: MacInput
    /// Where the pad was called up (in this view), while it's up.
    @State private var padAt: CGPoint?
    @State private var padTask: Task<Void, Never>?
    /// When the pad was last used — a box, so a finger moving on it doesn't redraw the view.
    @State private var padClock = PadClock()
    @State private var exitShown = true
    @State private var hideTask: Task<Void, Never>?
    @State private var revealedAt = Date.distantPast
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(main: MainView) {
        self.main = main
        _watcher = ObservedObject(wrappedValue: main.watcher)
        _input = ObservedObject(wrappedValue: main.watcher.input)
    }

    final class PadClock { var last = Date(); var holding = false }
    static let padSize = CGSize(width: 340, height: 220)
    /// How long the pad stays with nothing on it (Sameer: "5 sec … is too long. Make it 3 sec").
    static let padHold: TimeInterval = 3

    private var exitUp: Bool { exitShown || voiceOver || watcher.phase != .live }

    var body: some View {
        GeometryReader { geo in
            WatchWindow(watcher: watcher, interactive: true, bezelWidth: 0, corner: 0, fill: true, onHold: summonPad,
                        // The finger that held is already a trackpad finger: no lifting first.
                        onHoldMoved: { [padClock] d, dt in padClock.last = Date(); input.pointerMoved(by: d, dt: dt) },
                        onHoldEnded: { [padClock] in padClock.last = Date(); padClock.holding = false })
                .overlay(alignment: .bottom) { MacPermissionBanner(watcher: watcher) }
                .overlay(alignment: .bottom) {
                    if main.showLiveWords {
                        DuoLiveWords(main: main, room: geo.size)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if exitUp {
                        exitButton
                            .padding(.leading, DuoLook.edgeInset)
                            .padding(.top, DuoLook.edgeInset)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.3), value: exitUp)
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in reveal() })
                .overlay {
                    if let at = padAt { pad(at: at, in: geo.size) }
                }
                // The mic, small, wherever he left it (never faded: it's the app's point).
                .overlay { FloatingMic(main: main, room: geo.size) }
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            reveal()
            #if DEBUG
            // MACROPHONE_FULLSCREEN_PAD=x,y: the hold's pad at that point, 2 s in (for a screenshot).
            if let v = DebugHooks.env["MACROPHONE_FULLSCREEN_PAD"]?.split(separator: ",").compactMap({ Double($0) }), v.count == 2 {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    _ = summonPad(at: CGPoint(x: v[0], y: v[1]))
                    padClock.holding = false
                }
            }
            #endif
        }
        .onDisappear { hideTask?.cancel(); hideTask = nil; padTask?.cancel(); padTask = nil }
        // The page left the trackpad (the mic opened): the pad goes with it.
        .onChange(of: input.page) { _, p in if p != .trackpad, padAt != nil { dismissPad() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Mac, full screen")
    }

    // MARK: The trackpad on a hold

    /// A hold on the picture: the pad comes up centred under the finger (kept on screen) and the
    /// pointer shows — instead of a right-click (two fingers still right-click).
    private func summonPad(at p: CGPoint) -> Bool {
        guard input.pages.contains(.trackpad), !main.showLiveWords else { return false }
        Haptics.soft()
        padClock.last = Date()
        padClock.holding = true
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.2, dampingFraction: 0.85)) { padAt = p }
        input.show(.trackpad, quiet: true)
        armPad()
        return true
    }

    /// Dissolves the pad once nothing has touched it for `padHold` seconds.
    private func armPad() {
        padTask?.cancel()
        padTask = Task { @MainActor in
            while !Task.isCancelled {
                // A finger still down on it, even at rest, is using it.
                if padClock.holding { padClock.last = Date() }
                let left = Self.padHold - Date().timeIntervalSince(padClock.last)
                if left <= 0 { dismissPad(); return }
                try? await Task.sleep(nanoseconds: UInt64(left * 1e9) + 50_000_000)
            }
        }
    }

    private func dismissPad() {
        padTask?.cancel()
        padTask = nil
        withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.6)) { padAt = nil }
        if input.page == .trackpad { input.show(.mic, quiet: true) }
    }

    private func pad(at p: CGPoint, in room: CGSize) -> some View {
        let size = Self.padSize
        let inset = DuoLook.edgeInset
        let x = min(max(p.x, inset + size.width / 2), max(inset + size.width / 2, room.width - inset - size.width / 2))
        let y = min(max(p.y, inset + size.height / 2), max(inset + size.height / 2, room.height - inset - size.height / 2))
        let shape = RoundedRectangle(cornerRadius: WatchLook.bezel, style: .continuous)
        return TrackpadSurface(input: input, watcher: watcher, onUse: { [padClock] in padClock.last = Date() })
            // See-through: the window shows under a light frost and a hairline edge.
            .background(.ultraThinMaterial.opacity(0.5), in: shape)
            .background(Color.white.opacity(0.06), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.4), lineWidth: 1).allowsHitTesting(false))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .frame(width: size.width, height: size.height)
            .position(x: x, y: y)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.92)), removal: .opacity))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trackpad")
            .accessibilityHint("Moves the pointer on your Mac. It goes away after a few seconds unused.")
            .accessibilityIdentifier("fullscreen-trackpad")
    }

    private var exitButton: some View {
        Button {
            Haptics.tick()
            watcher.setFullScreen(false)
        } label: {
            Image(systemName: "arrow.down.forward.and.arrow.up.backward.rectangle")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(WatchCellStyle(width: 46, height: WatchLook.header))
        .watchGlass(Capsule())
        .accessibilityLabel("Exit Full Screen")
        .accessibilityIdentifier("watch-fullscreen-exit")
    }

    private func reveal() {
        let now = Date()
        guard !exitShown || now.timeIntervalSince(revealedAt) > 0.5 else { return }
        revealedAt = now
        hideTask?.cancel()
        if !exitShown { exitShown = true }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(DuoLook.headerHold * 1e9))
            guard !Task.isCancelled else { return }
            exitShown = false
        }
    }
}

/// The mic in full screen (Nov 3 2026, Sameer: "make it small and give me a little lip on it so I
/// could drag and move anywhere"): the same mic button, small, with a grab tab on its top edge.
/// The disc keeps its tap and hold (a dictation); only the lip moves it, so a hold is never taken
/// for a drag. It stays where it's left (a fraction of the screen, `duo.fullscreen.mic`), kept clear
/// of the screen's rounded corners.
struct FloatingMic: View {
    let main: MainView
    var room: CGSize
    @AppStorage("duo.fullscreen.mic.x") private var fx = 0.93
    @AppStorage("duo.fullscreen.mic.y") private var fy = 0.84
    @State private var drag: CGSize = .zero
    @State private var dragging = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static let size: CGFloat = 52
    /// The lip above the disc, and how far it overlaps it.
    static let lip = CGSize(width: 34, height: 16)

    var body: some View {
        let centre = place(CGPoint(x: fx * room.width + drag.width, y: fy * room.height + drag.height))
        // The lip just above the disc's ring, a few points clear of it (the lip's frame carries
        // 8 pt of touch room under it; the button's runs a little past the ring).
        VStack(spacing: -7) {
            lip.zIndex(1)
            main.micButton(size: Self.size)
        }
        .scaleEffect(dragging ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
        .position(centre)
    }

    private var lip: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 0.5))
            .overlay(Capsule().fill(Ink.secondary).frame(width: 14, height: 3))
            .frame(width: Self.lip.width, height: Self.lip.height)
            .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.18), radius: 3, y: 1)
            // A thumb's worth of target round the little tab.
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { v in
                    if !dragging { dragging = true; Haptics.soft() }
                    drag = v.translation
                }
                .onEnded { v in
                    let p = place(CGPoint(x: fx * room.width + v.translation.width, y: fy * room.height + v.translation.height))
                    if room.width > 0, room.height > 0 { fx = p.x / room.width; fy = p.y / room.height }
                    drag = .zero
                    dragging = false
                    Haptics.tick()
                })
            .accessibilityHidden(true)
    }

    /// The centre kept so the whole of it is on screen and out of the rounded corners.
    private func place(_ p: CGPoint) -> CGPoint {
        let inset = DuoLook.edgeInset
        let halfW = Self.size * 0.8, top = Self.size / 2 + Self.lip.height + 8, bottom = Self.size * 0.8
        return CGPoint(x: min(max(p.x, inset + halfW), room.width - inset - halfW),
                       y: min(max(p.y, inset + top), room.height - inset - bottom))
    }
}

/// The Mac on a flat inner screen: the window view as the phone has it (its header, the window,
/// the keys or the answers in a row), or — Done, or nothing watched — the glance.
struct DuoMacArea: View {
    let main: MainView
    /// The laptop deck is under or beside it (the keys are there).
    var deck = false
    @ObservedObject private var watcher: Watcher

    init(main: MainView, deck: Bool = false) {
        self.main = main
        self.deck = deck
        _watcher = ObservedObject(wrappedValue: main.watcher)
    }

    var body: some View {
        ZStack {
            if watcher.isShowing {
                WatchPanel(watcher: watcher, compact: false, duo: true, deck: deck)
                    .overlay(alignment: .bottom) {
                        // The words you're saying over the picture's foot, as on a folded half.
                        if deck, main.showLiveWords {
                            GeometryReader { g in
                                DuoLiveWords(main: main, room: g.size)
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .transition(.opacity)
            } else {
                DuoGlance(watcher: watcher, fill: false)
                    .padding(.horizontal, WatchLook.sideMargin)
                    .padding(.vertical, 4)
                    .transition(.opacity)
            }
        }
    }
}

/// The Mac's half of a folded screen — a MacBook's screen: the picture edge to edge, filling the
/// half; a slim header laid over its top like a menu bar that fades after a few seconds and
/// comes back on a touch (never fades for VoiceOver); the question's answers floating over its
/// foot; the words you're saying over the picture while the mic is open. Or the glance.
struct DuoMacHalf: View {
    let main: MainView
    /// The book's page: narrow and tall, so the header takes two rows.
    var vertical: Bool
    /// The half's size (what the words over the picture may take).
    var room: CGSize
    /// The laptop's screen (Nov 1 2026): no bezel, no corner — the picture is the half.
    var edge = false
    @ObservedObject private var watcher: Watcher
    @State private var headerShown = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(main: MainView, vertical: Bool, room: CGSize, edge: Bool = false) {
        self.main = main
        self.vertical = vertical
        self.room = room
        self.edge = edge
        _watcher = ObservedObject(wrappedValue: main.watcher)
    }

    private var bezel: CGFloat { edge ? 0 : DuoLook.halfBezel }
    private var corner: CGFloat { edge ? DuoLook.edgeCorner : DuoLook.halfCorner }

    /// What floats over the picture's foot (the answers): the picture's newest lines stay above it.
    @State private var floatingHeight: CGFloat = 0

    var body: some View {
        let live = watcher.phase == .live
        ZStack {
            if watcher.isShowing {
                if !vertical {
                    // The laptop (Oct 31 2026, Sameer: "the view window fully filling one half …
                    // the hot keys to all be the bottom half … so that nothing blocks the view
                    // window"): the picture is the whole half and nothing lies over it — the
                    // header, the answers and the words you're saying are on the deck.
                    screen(footInset: 0, floating: false, header: false)
                        .transition(.opacity)
                } else if let short = shortPicture {
                    // A window that can't fill the half (the fourth pass — the Mac can't reshape
                    // it, or hasn't yet: the whole screen, a window on the book's tall page):
                    // the picture at the top at the scale that fills the width, and the room
                    // under it holds what floated over it — the answers with Esc · Keys and
                    // Pan | Scroll (or the keys), the words you're saying. No black above or below.
                    VStack(spacing: 10) {
                        // The header has room of its own here, above the picture, as on the open
                        // screen (never over its first lines).
                        WatchHeaderBar(watcher: watcher, twoRows: vertical, dragSwitch: true) { t, _ in watcher.say(t.title, symbol: "arrow.left.and.right") }
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                        screen(footInset: 0, floating: false, header: false)
                            .frame(height: short)
                        if main.showLiveWords {
                            DuoLiveWords(main: main, room: room, below: true)
                                .transition(.opacity)
                        } else {
                            // The answers alone (the deck beside it has the keys).
                            WatchActions(watcher: watcher, floating: true)
                                .padding(.horizontal, 12)
                                .opacity(live ? 1 : 0)
                                .allowsHitTesting(live)
                                .accessibilityHidden(!live)
                        }
                        Spacer(minLength: 0)
                    }
                    .transition(.opacity)
                } else {
                    screen(footInset: live && !main.showLiveWords ? floatingHeight : 0, floating: true)
                        .transition(.opacity)
                }
            } else if let short = shortPicture {
                DuoGlance(watcher: watcher, fill: true, pictureHeight: short, edge: edge)
                    .transition(.opacity)
            } else {
                DuoGlance(watcher: watcher, fill: true, edge: edge)
                    .transition(.opacity)
            }
        }
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: shortPicture != nil)
        .onAppear { reveal() }
        .onDisappear { hideTask?.cancel(); hideTask = nil }
        .onChange(of: watcher.isShowing) { _, _ in reveal() }
        .onChange(of: watcher.answers?.id) { _, _ in reveal() }
        .onChange(of: watcher.phase) { _, _ in reveal() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Mac")
    }

    /// The screen: the picture edge to edge with the overlay header over its top and — `floating`
    /// — the answers or the words you're saying over its foot (the picture's foot scrolls up above
    /// the answers: `footInset`).
    private func screen(footInset: CGFloat, floating: Bool, header: Bool = true) -> some View {
        let live = watcher.phase == .live
        return WatchWindow(watcher: watcher, interactive: true, bezelWidth: bezel, corner: corner, fill: true, footInset: footInset)
            .overlay(alignment: .bottom) { MacPermissionBanner(watcher: watcher) }
            .overlay(alignment: .bottom) {
                if floating {
                    if main.showLiveWords {
                        DuoLiveWords(main: main, room: room)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        WatchActions(watcher: watcher, floating: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { floatingHeight = watcher.answers == nil ? 0 : $0 }
                            .opacity(live ? 1 : 0)
                            .allowsHitTesting(live)
                            .accessibilityHidden(!live)
                    }
                }
            }
            .overlay(alignment: .top) {
                // Down, it's gone (not merely faded): nothing of it for a finger or
                // VoiceOver to find over the screen.
                if header, headerUp {
                    DuoOverlayHeader(watcher: watcher, twoRows: vertical)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.3), value: headerUp)
            // A touch anywhere on the screen brings the header back (the window's own
            // gestures go on as before).
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in reveal() })
    }

    /// The picture's height when it can't fill the half — a window shaped nothing like it (one
    /// the Mac can't reshape, or hasn't yet; the whole screen) on the book's tall page: the
    /// width-fit scale times the fill's cap, the bezel round it. Nil when it fills the half (the
    /// cap doesn't bite), or when what's left under it would be too little to use.
    private var shortPicture: CGFloat? {
        // The laptop's screen is the picture, whatever its shape (it fills, scrolling).
        guard !edge, watcher.hasPicture, let size = watcher.videoSize ?? watcher.image?.size, size.width > 0, size.height > 0 else { return nil }
        let width = room.width - 2 * DuoLook.halfBezel
        let h = width * ViewerScrollView.fillCap * size.height / size.width + 2 * DuoLook.halfBezel
        // The header's rows above it, the answers and the keys under it.
        return h < room.height - (vertical ? 250 : 200) ? (h / 2).rounded() * 2 : nil
    }

    /// The header shows: lately touched, or always for VoiceOver (and held for a screenshot).
    private var headerUp: Bool {
        #if DEBUG
        if DebugHooks.duoHeaderHeld { return true }
        #endif
        return headerShown || voiceOver || watcher.phase != .live
    }

    @State private var revealedAt = Date.distantPast

    private func reveal() {
        // A finger moving over the picture arrives at every frame: the hold is re-armed at most
        // twice a second (each re-arm is a task), and the header stays up while it moves.
        let now = Date()
        guard !headerShown || now.timeIntervalSince(revealedAt) > 0.5 else { return }
        revealedAt = now
        hideTask?.cancel()
        if !headerShown { headerShown = true }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(DuoLook.headerHold * 1e9))
            guard !Task.isCancelled else { return }
            headerShown = false
        }
    }
}

/// The menu bar over a folded half's picture: the window's header on a dark gradient that
/// fades into the picture, so the top of the screen is still the screen.
struct DuoOverlayHeader: View {
    @ObservedObject var watcher: Watcher
    var twoRows: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        WatchHeaderBar(watcher: watcher, twoRows: twoRows, dragSwitch: true) { t, _ in watcher.say(t.title, symbol: "arrow.left.and.right") }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 16)
            // The bar is a bar: a tap between its controls stays on it (it never clicks through
            // to the Mac's title bar under it).
            .contentShape(Rectangle())
            .onTapGesture {}
            .background {
                LinearGradient(colors: [Ink.ground.opacity(reduceTransparency ? 0.96 : 0.82), Ink.ground.opacity(reduceTransparency ? 0.96 : 0.5), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: DuoLook.halfCorner, style: .continuous))
            .padding(DuoLook.halfBezel)
    }
}

/// The words you're saying, over the picture (a folded half): where they're going and the words
/// themselves on a card of glass over the foot of the screen, up to half the half.
struct DuoLiveWords: View {
    let main: MainView
    var room: CGSize
    /// Under a picture that doesn't fill the half, not over it: the card takes the room it has.
    var below = false

    var body: some View {
        VStack(spacing: 0) {
            DestinationLine(words: main.recorder.words)
                .padding(.horizontal, 18)
                .padding(.top, 14)
            LiveWords(words: main.recorder.words, listening: main.isRecording)
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .frame(maxWidth: 640)
        .frame(height: below ? nil : max(120, min(room.height * 0.62, 320)))
        .frame(maxHeight: below ? 360 : nil)
        .watchGlass(RoundedRectangle(cornerRadius: WatchLook.card, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }
}

/// The deck of a folded screen (and of the open screen upright): with a window in hand, the
/// laptop's modes — the trackpad the whole half, the keyboard rising over it with the Mac's keys
/// on its bar, or the mic with the Thread across the half — or, down the book's page, the keys,
/// the trackpad and the mic all at once. Nothing in hand: the cover's own view, whole (Nov 1
/// 2026: the half that was the cover goes on being the cover). `vertical`: the book's page.
struct DuoDeck: View {
    let main: MainView
    var vertical: Bool
    @ObservedObject private var watcher: Watcher
    @ObservedObject private var input: MacInput

    init(main: MainView, vertical: Bool) {
        self.main = main
        self.vertical = vertical
        _watcher = ObservedObject(wrappedValue: main.watcher)
        _input = ObservedObject(wrappedValue: main.watcher.input)
    }

    var body: some View {
        ZStack {
            if watcher.isShowing, vertical {
                // The book's page: the trackpad, the keys and the mic, all at once.
                DuoLaptopDeck(main: main, vertical: true).transition(.opacity)
            } else if watcher.isShowing {
                laptopModes.transition(.opacity)
            } else {
                // The cover's view, as it is on the cover: Send to, the switches, the Thread,
                // the mic (its buttons in the vertical bar where the screen has one, else its
                // own top bar).
                main.phoneBody.transition(.opacity)
            }
        }
        .animation(Motion.pick(Motion.settle, reduce: main.reduceMotion), value: watcher.isShowing)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(watcher.isShowing ? "The deck: trackpad, keyboard and mic" : "Send to and the mic")
    }

    /// The laptop's deck while a window shows (Nov 1 2026, Sameer: "the trackpad is really small …
    /// I should still be able to select mic mode, keyboard mode to trackpad mode and have each of
    /// those modes take up the full half"): the window's header across the top (its question's
    /// answers in its middle, so nothing lies over the picture), then one mode at a time, the
    /// whole of the rest — the trackpad edge to edge, the mic with the Thread across the half,
    /// or the iOS keyboard with the Mac's keys on its bar — the three as a cluster of glass
    /// cells in the deck's top-right corner (`InputCornerSwitcher`; the mic page keeps the room
    /// over its Thread for it). The deck remembers its mode (the trackpad the first time). While
    /// you talk, the words sit over the Thread; the mic under them never moves (a hold on it is
    /// never lost).
    private var laptopModes: some View {
        let live = watcher.phase == .live
        return VStack(spacing: 4) {
            // The question's answers on a row of their own under the header, only while one is
            // up: the header has the name, the clusters and Done across the half's 669 points,
            // and the answers squeezed between them showed one digit of the first.
            if live, !main.showLiveWords, watcher.answers != nil {
                WatchActions(watcher: watcher, floating: true, oneLine: true)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }
            GeometryReader { g in
                main.carousel(fill: g.size.height, compact: true, rowHidden: true)
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
                    .overlay(alignment: .top) {
                        if main.showLiveWords {
                            DuoLiveWords(main: main, room: g.size, below: true)
                                .frame(height: max(96, g.size.height - DuoLook.deckMic * 1.25 - 52))
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    // The modes, in the corner: over the trackpad's plate or the room above the
                    // Thread; the keyboard rises over it (hide comes back here).
                    .overlay(alignment: .topTrailing) {
                        if input.pages.count > 1 {
                            InputCornerSwitcher(input: input)
                                .padding(.top, 8)
                                .padding(.trailing, 12)
                        }
                    }
            }
            // The window's controls at the deck's foot (Nov 1 2026, Sameer: "move all of the Mac
            // controls and … window selection tools to the bottom so that they don't interfere"):
            // the keyboard rises over them, and nothing sits between the window and the deck.
            WatchHeaderBar(watcher: watcher, dragSwitch: true) { t, _ in
                watcher.say(t.title, symbol: "arrow.left.and.right")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .padding(.top, 6)
        .animation(Motion.pick(Motion.settle, reduce: main.reduceMotion), value: watcher.answers?.id)
    }
}

/// The glance (Oct 25 2026): the picked app's window, live and big, with its controls put away —
/// a bar over its foot names it and one tap takes it in hand (Show it here). Nothing watched yet:
/// the picked app on a plate of the window's bezel and the same tap; or what's missing — a Mac
/// to pair, a Mac to connect.
struct DuoGlance: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    /// A folded half: the picture fills it, edge to edge.
    var fill: Bool
    /// A picture that can't fill the half (the book's tall page): this tall, at the top, with
    /// the bar under it rather than over its foot.
    var pictureHeight: CGFloat? = nil
    /// The laptop's screen: no bezel, no corner.
    var edge = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var bezelWidth: CGFloat { edge ? 0 : fill ? DuoLook.halfBezel : WatchLook.bezelWidth }
    private var corner: CGFloat { edge ? DuoLook.edgeCorner : fill ? DuoLook.halfCorner : WatchLook.bezel }

    var body: some View {
        let target = model.selection.target
        ZStack {
            if watcher.isOpen, watcher.hasPicture {
                // Live, the pictures still coming: the same screen, without its controls.
                let window = WatchWindow(watcher: watcher, interactive: false, bezelWidth: bezelWidth, corner: corner, fill: fill)
                if let pictureHeight {
                    VStack(spacing: 0) {
                        window.frame(height: pictureHeight)
                        liveBar(under: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(watcher.name)'s window on your Mac, live")
                } else if !fill, let size = watcher.videoSize ?? watcher.image?.size, size.width > 0, size.height > 0 {
                    // The open screen: the window at its own shape (no band of empty bezel above
                    // or below it), the bar under it when there's room, else over its foot.
                    GeometryReader { geo in
                        let b = bezelWidth, aspect = size.width / size.height
                        let wide = (geo.size.width - 2 * b) / aspect + 2 * b
                        let barRoom: CGFloat = 76
                        Group {
                            if wide + barRoom <= geo.size.height {
                                VStack(spacing: 0) {
                                    window.frame(height: wide)
                                    liveBar(under: true)
                                }
                            } else {
                                let h = min(wide, geo.size.height)
                                window
                                    .overlay(alignment: .bottom) { liveBar(under: false) }
                                    .frame(width: wide > geo.size.height ? (h - 2 * b) * aspect + 2 * b : geo.size.width, height: h)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(watcher.name)'s window on your Mac, live")
                } else {
                    window
                        .overlay(alignment: .bottom) { liveBar(under: false) }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(watcher.name)'s window on your Mac, live")
                }
            } else {
                plate
                VStack(spacing: 14) {
                    if !model.isPaired {
                        GlyphPlate(symbol: "macbook.and.iphone", tint: Light.cyan, size: 56)
                        Text("Pair your Mac").font(.serif(.title2)).foregroundStyle(Ink.ink)
                        Text("Your Mac's windows show here, live, once Macrophone on your Mac is paired.")
                            .font(.footnote).foregroundStyle(Ink.secondary)
                        Button { model.sheet = .pairing } label: { Label("Pair a Mac", systemImage: "qrcode.viewfinder").fontWeight(.semibold) }
                            .duoProminentButton()
                            .accessibilityIdentifier("duo-pair")
                    } else if !model.isConnected {
                        GlyphPlate(symbol: "wifi.exclamationmark", tint: Ink.secondary, size: 56)
                        Text("Looking for \(model.macName)").font(.serif(.title2)).foregroundStyle(Ink.ink)
                        Text("Its window shows here the moment it's connected.")
                            .font(.footnote).foregroundStyle(Ink.secondary)
                    } else {
                        icon(target, size: 64)
                        Text(Places.appName(target, in: model)).font(.serif(.title2)).foregroundStyle(Ink.ink)
                        Text(target == .clipboard || target == .frontApp ? "Your Mac's whole screen, live."
                             : model.isNotOpen(target) ? "Not open on your Mac — pick another place, or open it from Send to."
                             : "Its window on your Mac, live — and your words go there.")
                            .font(.footnote).foregroundStyle(model.isNotOpen(target) ? Light.ochre : Ink.secondary)
                        if !model.isNotOpen(target) { showButton }
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .frame(maxWidth: 360)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Mac")
    }

    /// The empty screen: a plate of the window's bezel.
    private var plate: some View {
        let bezel = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return bezel.fill(Ink.sunk)
            .overlay(bezel.strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
            .padding(bezelWidth)
            .background { bezel.fill(Ink.raised).shadow(color: .black.opacity(reduceTransparency ? 0 : 0.5), radius: 16, y: 10) }
            .overlay(SpecularEdge(shape: bezel))
    }

    /// Over the live picture's foot (or under a short picture): the app, that it's live (or
    /// paused), and Show it here — on one line, or the button on its own line when the page is
    /// narrow (the book's).
    private func liveBar(under: Bool) -> some View {
        let target = model.selection.target
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                icon(target, size: 30)
                liveWords
                Spacer(minLength: 8)
                showButton.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) { icon(target, size: 30); liveWords; Spacer(minLength: 0) }
                showButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, under ? 12 : 22)
        .padding(.bottom, 12)
        .background {
            if !under {
                LinearGradient(colors: [.clear, Ink.ground.opacity(reduceTransparency ? 0.96 : 0.55), Ink.ground.opacity(reduceTransparency ? 0.96 : 0.86)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .padding(bezelWidth)
    }

    private var liveWords: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(watcher.name).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink).lineLimit(1)
            Text(watcher.phase.isPaused ? "Paused · Show it here to go on" : "Live on your Mac")
                .font(.caption).foregroundStyle(watcher.phase.isPaused ? Light.ochre : Ink.secondary).lineLimit(1)
        }
    }

    private var showButton: some View {
        let target = model.selection.target
        return Button { model.showWindowForPose() } label: { Label("Show it here", systemImage: "eye").fontWeight(.semibold) }
            .duoProminentButton()
            .disabled(target == .clipboard || target == .frontApp ? !model.watcher.canWatchDesktop : false)
            .accessibilityHint("Takes the window in hand: tap to click, the trackpad, the keyboard and the mic.")
            .accessibilityIdentifier("duo-show")
    }

    @ViewBuilder private func icon(_ target: TargetRef, size: CGFloat) -> some View {
        if let icon = model.liveTarget(for: target)?.icon, let img = UIImage(data: icon) {
            Image(uiImage: img).resizable().frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .accessibilityHidden(true)
        } else {
            GlyphPlate(symbol: target == .clipboard || target == .frontApp ? "macwindow.on.rectangle" : "app", tint: Light.cyan, size: size * 0.875)
        }
    }
}

private extension View {
    @ViewBuilder func duoProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Light.cyan).foregroundStyle(Ink.onTint)
        } else {
            buttonStyle(.borderedProminent).tint(Light.cyan).foregroundStyle(Ink.onTint)
        }
    }
}

/// Where the inner screen turns (Oct 25 2026): every way on the Duo's inner screen; the cover,
/// and every other iPhone, stays upright as before (`UISupportedInterfaceOrientations` lists
/// them all; this narrows it). The hinge decides first: UIKit asks while the phone is opening,
/// with the window still on the cover, and "upright only" then kept the app upright and boxed on
/// the open screen (Nov 1 2026).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if Posture.shared.hingeOpen { return .all }
        guard let screen = window?.windowScene?.screen ?? window?.screen else { return .portrait }
        let b = screen.bounds.size
        return min(b.width, b.height) >= FoldPose.innerShortSide ? .all : .portrait
    }
}
