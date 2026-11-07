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
//   (and flat, upright)  screen: the picture alone, just under the status bar; nothing over it.
//                        The bottom half is the deck: one mode at a time taking its room — the
//                        trackpad, the mic with the Thread across the half, or the iOS keyboard —
//                        then the modes as a labelled control and the window's header (the name
//                        and menu, Sound, Mac Controls, Pan | Scroll, zoom out, Window, Done) at
//                        its foot; a question's answers a row at its top. Nothing in hand: the
//                        picked app's window live on top (the glance), the cover's own view below.
//                        Flat and upright it is the same layout (the fold is in the same place), so
//                        folding it moves nothing
//   book                 on its side, the hinge up and down — the Mac on the left page, the deck
//   (and flat, on its    on the right: the laptop's modes, one at a time filling the page, the
//   side)                same mode bar at its foot (the right thumb's); nothing in hand: the
//                        glance left, the cover's view right — what the phone opens to. Folded
//                        or flat, one layout
//
// Done on the inner screen is the glance, not a closed window (`Watcher.glance`): the picked
// app's window stays live and big, its controls put away, Show it here to take it in hand again —
// and folding the screen (the laptop, the book) takes it in hand by itself. Nothing sits on the
// fold: every pose splits at the fold's region (`FoldHalves`, the inactive region when flat).
// Turning the screen cross-fades the layouts; folding it moves nothing. Every pose keeps the state — the window, the zoom (kept per app), the carousel's
// page, a dictation under way, a sheet.

/// The Duo's measures.
enum DuoLook {
    /// The mic on a folded deck: a half of the screen to itself, so the disc is a size up from the
    /// phone's 92 (not a cartoon — the glyph and the ring grow with it).
    static let deckMic: CGFloat = 112
    /// The Thread across a folded deck: its slot.
    static let deckThread: CGFloat = 96
    /// The least room over the Thread (the modes are a row of their own at the deck's foot).
    static let deckThreadTop: CGFloat = 8
    /// The mic button with its status line under it, as the carousel stacks them.
    static func micGroup(_ mic: CGFloat) -> CGFloat { 8 + mic * 1.25 + 28 }
    /// The mic and the Thread's slot a deck's mode room holds whole: a size up where it can, the
    /// phone's 92 and a 56 pt Thread where it's short, smaller still only in a sliver.
    static func deckMicFit(_ room: CGFloat) -> (mic: CGFloat, slot: CGFloat) {
        if room >= deckThreadTop + deckThread + micGroup(deckMic) { return (deckMic, deckThread) }
        if room >= deckThreadTop + 56 + micGroup(92) { return (92, 56) }
        let mic: CGFloat = room >= deckThreadTop + 36 + micGroup(80) ? 80 : 64
        return (mic, max(28, min(56, room - deckThreadTop - micGroup(mic))))
    }
    /// A folded half's screen: a hair of bezel, the corner tight to the half's (the book's page;
    /// the laptop's screen has none — `DuoMacHalf.edge`).
    static let halfBezel: CGFloat = 2
    static let halfCorner: CGFloat = 0
    /// How long the overlay header stays after a touch.
    static let headerHold: TimeInterval = 3.5
    /// Open flat and upright (Nov 1 2026, Sameer: "fully open in portrait mode it should have a
    /// different view with an even bigger window. The half view rule should only be of the laptop
    /// mode"): the deck under the window is this tall with a window in hand — the header, the
    /// modes, a question's answers and the phone's mic with its Thread, each whole (Nov 7 2026: at
    /// 300 the mic was cut at the screen's foot) — and taller at rest (the cover's view).
    static let flatDeck: CGFloat = 372
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
    /// Upright, the window under the status bar: the gap over it, and the margins either side —
    /// the deck's own, so the window, the answers and the modes line up.
    static let uprightTop: CGFloat = 6
    static let uprightMargin: CGFloat = 12
    /// Typing (Nov 7 2026, round 3): the breath between the Mac's picture and the keyboard's bar
    /// where the keyboard reaches up into the Mac's room, and the least of the Mac's room at rest
    /// the keyboard may leave — the picture's foot gives way, never its width, its scale or its
    /// top, and never down to a sliver.
    static let keyboardGap: CGFloat = 8
    static let typingMacFloor: CGFloat = 0.5

    /// How far below the screen's top edge a square picture `side` points in from the sides sits
    /// so its top corners are just clear of the screen's rounded corners (on the curve, not past).
    @MainActor static func cornerClear(side: CGFloat) -> CGFloat {
        let r = displayCorner, dx = max(0, r - side)
        return ceil(r - (max(0, r * r - dx * dx)).squareRoot())
    }
}

extension MainView {
    // MARK: On its side: the book, and laid flat (951 × 669 points, the vertical bar trailing)

    /// The inner screen on its side, folded (the book) or flat — one layout (Nov 7 2026): the
    /// fold is in the same place either way, so folding the open screen into the book, or opening
    /// the book flat, moves nothing. (Two layouts cross-faded there: two copies of the window at
    /// two zooms, and the mic flying in from the screen's corner.) The Mac on the left page — the
    /// window in hand, its name a row above it and the answers a row under it, or the glance — and
    /// the right page the cover's: its own view at rest (Nov 1 2026, Sameer: "the view that is on
    /// the out screen should be what I see on the right half on the open duo screen with more
    /// content on the left side"), the deck down it with a window in hand.
    var sideBody: some View {
        GeometryReader { geo in
            let h = posture.halves(for: .book, in: geo.size)
            // The left page meets the screen's rounded corners on three sides: the picture sits in
            // from them, so the curve never cuts the window's title bar or the answers under it.
            let inset = DuoLook.edgeInset
            // Typing: the keyboard rises over the foot of both pages (iOS splits its keys at the
            // hinge), and the book stays a book (Nov 7 2026, round 3): each page keeps its width
            // and the crease between them, and only their heights give way, down to the
            // keyboard's top, in the keyboard's own motion (`keysUp` and `keyboardRoom` change
            // inside it). The Mac's window had taken the whole width over the keyboard — the
            // picture stretched across the crease at twice the zoom each time, and the deck
            // vanished. The deck ends at the keyboard too and stays in the tree: the keyboard's
            // field lives in it. A moment's change, so the Mac's window isn't reshaped for it.
            let typing = typingOver
            let pageWidth = max(0, h.mac.width - inset)
            let restHeight = max(0, geo.size.height - 2 * inset)
            let pageHeight = typing ? max(0, min(restHeight, keyboardTop(in: geo) - inset - DuoLook.keyboardGap)) : restHeight
            let gap = max(0, h.deck.minX - h.mac.maxX)
            let deckHeight = typing ? max(0, min(geo.size.height, keyboardTop(in: geo))) : geo.size.height
            HStack(alignment: .top, spacing: 0) {
                DuoMacHalf(main: self, vertical: true, room: CGSize(width: pageWidth, height: restHeight))
                    .environment(\.fullScreenAvailable, true)
                    .frame(width: pageWidth, height: pageHeight)
                    .padding(.leading, inset)
                    .padding(.top, inset)
                    .frame(height: geo.size.height, alignment: .top)
                Color.clear.frame(width: gap)
                DuoDeck(main: self, vertical: true)
                    .frame(width: max(0, geo.size.width - h.deck.minX), height: deckHeight, alignment: .top)
                    .clipped()
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: h)
        }
        // The keyboard rises over both pages: laid out from its own frame (`keyboardTop`).
        .ignoresSafeArea(.keyboard)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: watcher.isShowing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(posture.pose.spoken)
    }

    // MARK: The laptop (upright: the hinge across — folded, or flat)

    /// The keyboard page is up with a window in hand.
    var keyboardUp: Bool { watcher.isShowing && input.page == .keyboard }
    /// …and its keyboard has risen: what it covers gives way, in the keyboard's own motion
    /// (`MacInput.keysUp` changes on the keyboard's curve). Until then the page keeps its room.
    var typingOver: Bool { keyboardUp && input.keysUp }

    /// The keyboard's top edge in a view laid out ignoring it (its room is from the screen's foot;
    /// the view's foot is the home indicator's line above it). Read from the keyboard's own frame,
    /// never assumed: the iOS keyboard with its predictions is taller than any deck.
    func keyboardTop(in geo: GeometryProxy) -> CGFloat {
        geo.size.height + geo.safeAreaInsets.bottom - input.keyboardRoom
    }

    var laptopBody: some View {
        GeometryReader { geo in
            let h = posture.halves(for: .laptop, in: geo.size)
            // Flat and upright there's no fold to keep to: the window takes all but the deck.
            let flat = posture.pose == .open(landscape: false)
            // The room at rest — the Mac's half, the fold, the deck — which the keyboard never
            // changes. Flat and upright with a window in hand the deck is one height whatever its
            // mode (the tallest's: the header, the modes, a question's answers and the mic with
            // its Thread), so changing mode, a question coming or going, never moves the window.
            let restDeck = flat ? min(geo.size.height * (watcher.isShowing ? 0.45 : 0.52), watcher.isShowing ? DuoLook.flatDeck : DuoLook.flatDeckAtRest) : h.deck.height
            let restGap: CGFloat = flat ? 10 : h.deck.minY - h.mac.maxY
            let restMac = flat ? geo.size.height - restDeck - restGap : h.mac.height
            // The keyboard up (Nov 7 2026, round 3): the top half is the Mac's screen, and a
            // Mac's screen doesn't move for a keyboard — its width, its scale and its top edge
            // stay. The deck ends at the keyboard's top (in the tree still: the keyboard's field
            // lives in it); where the keyboard reaches up past the fold the Mac's frame gives it
            // the room from its foot only, in the keyboard's own motion, never below half of what
            // it had. (It used to take everything above the keyboard: the Whole Screen was
            // re-measured from the shorter room and shrank, re-centred, by a hundred points.) A
            // moment's change: the Mac's window isn't reshaped for it.
            let keysTop = typingOver ? keyboardTop(in: geo) : nil
            let macHeight = keysTop.map { max(min(restMac, $0 - DuoLook.keyboardGap), (restMac * DuoLook.typingMacFloor).rounded()) } ?? restMac
            let gap = keysTop.map { min(restGap, max(0, $0 - macHeight)) } ?? restGap
            let deckHeight = keysTop.map { max(0, $0 - macHeight - gap) } ?? restDeck
            VStack(spacing: 0) {
                // The Mac's screen: the picture as big as the half allows, in from the screen's
                // rounded corners so none of it is cut (Nov 1 2026, Sameer: "the view window
                // should take up the whole top half … as if the duo was a mini Mac").
                if let whole = wholeScreenSize(in: CGSize(width: geo.size.width, height: restMac)) {
                    // The whole screen: all of it, as big as it goes — the half's own shape is
                    // taller than a Mac's display, so the frame takes the picture's shape (no
                    // bars), its foot on the fold, its top corners clear of the screen's. Sized
                    // from the room at rest; the keyboard's band hides its foot (the frame
                    // shortens from the bottom, clipped) rather than shrinking it.
                    DuoMacHalf(main: self, vertical: false, room: whole, edge: true)
                        .frame(width: whole.width, height: whole.height)
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .frame(height: max(0, restMac), alignment: .bottom)
                        .frame(height: max(0, macHeight), alignment: .top)
                        .clipped()
                } else {
                    // In hand from the screen's top edge (the status bar hidden), just clear of
                    // its rounded corners; at rest just under the status bar. The deck's margins
                    // either side: the same top on every path — in hand or the glance, the
                    // keyboard up or the mic open. The keyboard shortens the frame from its foot:
                    // the viewer keeps its zoom and the bottom if it showed.
                    DuoMacHalf(main: self, vertical: false, room: CGSize(width: geo.size.width - 2 * DuoLook.uprightMargin, height: restMac - uprightPictureTop), edge: true)
                        .padding(.horizontal, DuoLook.uprightMargin)
                        .padding(.top, uprightPictureTop)
                        .frame(height: max(0, macHeight), alignment: .top)
                }
                // The fold: nothing sits here.
                Color.clear.frame(height: max(0, gap))
                DuoDeck(main: self, vertical: false)
                    .frame(height: max(0, deckHeight), alignment: .top)
                    // Nothing of it may spill up over the window (typing: it ends at the keys).
                    .clipped()
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: h)
            // A window coming into hand (or going back to the glance) moves the fold's line on a
            // flat screen: the window grows to its new size on the same spring, never jumps.
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: watcher.isShowing)
        }
        // The keyboard rises over the deck; with it up the window takes what's above it
        // (`keyboardTop`), on the keyboard's curve — laid out here, not by the safe area, which
        // came a pass apart from the page and moved the window twice.
        .ignoresSafeArea(.keyboard)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(posture.pose == .laptop ? FoldPose.laptop.spoken : FoldPose.open(landscape: false).spoken)
    }

    /// The whole screen in the laptop's upper half (Nov 1 2026, Sameer: "white bars on the top and
    /// the bottom … maximize that screen size as much as possible … without getting cut off"):
    /// the widest picture of the Mac's display, centred across with its foot on the fold, whose
    /// top corners stay clear of the screen's rounded ones. Nil for a window (it fills the half).
    /// From the room at rest: the keyboard never re-measures it.
    func wholeScreenSize(in room: CGSize) -> CGSize? {
        guard watcher.isShowing, watcher.isDesktop, let size = watcher.videoSize ?? watcher.image?.size,
              size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return nil }
        let aspect = size.width / size.height
        // The side margins are the deck's; the top stays clear of the screen's rounded corners
        // (the status bar is hidden while a window is in hand).
        let w = min(room.width - 2 * DuoLook.uprightMargin, (room.height - uprightPictureTop) * aspect).rounded(.down)
        return CGSize(width: w, height: (w / aspect).rounded(.down))
    }

    // MARK: The pieces

    /// The carousel — the page row, the Thread, the mic · keyboard · trackpad pages — as the phone
    /// builds it. `fill`: the room the pages take whole (the trackpad fills it, the mic sits in
    /// the middle of it); `rowHidden`: an inner deck (the laptop's, the side page's), where the modes are a row of their own
    /// (`DuoModeBar`), the Thread spans the half, the mic is a size up where there's room and the
    /// status line a size up — the Thread and the mic one group in the middle of the mode's room.
    func carousel(fill: CGFloat?, compact: Bool, rowHidden: Bool = false) -> some View {
        let deck = fill != nil
        // A flat inner screen's bottom bar is kept tight (the window has the room): the Thread's
        // slot a step slimmer and the status one line, as a deck's.
        // The laptop's deck: a size up where the mode has the room, the phone's mic and a slimmer
        // Thread where it hasn't (flat upright, a question's answers up) — never cut at the foot.
        let (micSize, slot) = rowHidden ? DuoLook.deckMicFit(fill ?? .infinity) : (CGFloat(92), deck ? 48 : compact ? 48 : 84)
        let micGroup = DuoLook.micGroup(micSize)
        // The Thread and the mic one group in the middle of the mode's room.
        let threadTop: CGFloat = rowHidden ? max(DuoLook.deckThreadTop, ((fill ?? 0) - slot - micGroup) / 2) : 0
        let oneLine = deck || compact
        return InputCarousel(input: input, watcher: watcher, compact: compact, threadHeight: slot + threadTop, fill: fill, rowHidden: rowHidden) {
            VStack(spacing: 0) {
                Color.clear.frame(height: deck ? 8 : compact ? 4 : 30)
                // The one mic sits here while the mic mode is up (`innerMic`) — on a deck its slot
                // is laid over the carousel at this place (below), so it never rides the Thread's
                // slot opening as the mic mode comes (the mic showed at the room's top and slid down).
                if rowHidden {
                    Color.clear.frame(width: micSize * 1.3, height: micSize * 1.25)
                } else {
                    micSlot(size: micSize, inHand: true, visible: input.page == .mic && !input.keysUp)
                }
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
                    Filament(mode: filamentMode, meter: recorder.meter, height: rowHidden ? slot * 1.25 : deck ? 56 : compact ? 56 : 96)
                        .frame(height: slot)
                    DeliveredCheck(visible: showCheck, color: checkColor)
                    timer.frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: slot)
                // A deck's mode changed: the Thread goes with the mic page, at once, so the lit
                // mode and the room agree (its slot folds on the carousel's own spring after).
                .opacity(rowHidden && input.page != .mic ? 0 : 1)
                .animation(rowHidden ? (input.page == .mic ? Motion.pick(Motion.settle, reduce: reduceMotion) : Motion.leave) : nil, value: input.page)
            }
            .frame(height: slot + threadTop)
            .padding(.horizontal, -4)
        }
        .overlay(alignment: .top) {
            // Where the mic page puts the mic once the Thread's slot is open: the deck's mode room
            // has a set height, so this place is set too.
            if rowHidden {
                micSlot(size: micSize, inHand: true, visible: input.page == .mic && !input.keysUp)
                    .padding(.top, threadTop + slot + 8)
            }
        }
        .onChange(of: showLiveWords) { _, live in input.micOpen(live) }
    }
}

// MARK: Built ahead, shown by a fade (Nov 4 2026)

/// One of `keptPair`'s two, hidden or not.
struct KeptHidden: ViewModifier {
    var hidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.threadPaused) private var paused
    /// The size it had when last on screen: hidden, it keeps it. Laid out again in a room that
    /// changed meanwhile (the deck shorter with a window in hand, the status bar gone), the cover's
    /// view kept the scroll position that room gave it — its top bar came back cut in half — and
    /// fading out it re-laid itself into the deck (Send to dropped before the window moved).
    @State private var size: CGSize?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { if !hidden { size = $0 } }
            .frame(width: hidden ? size?.width : nil, height: hidden ? size?.height : nil, alignment: .top)
            // (Never more than the room, whatever it keeps: the one on screen stays where it is.)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .animation(hidden ? Motion.leave : Motion.pick(Motion.settle, reduce: reduceMotion)) { $0.opacity(hidden ? 0 : 1) }
            .allowsHitTesting(!hidden)
            .accessibilityGone(hidden)
            .environment(\.threadPaused, hidden || paused)
    }
}

extension EnvironmentValues {
    /// The inner screen's layout lies under full screen: built, hidden, its windows without viewers.
    @Entry var innerAsleep = false
}

// MARK: The inner screen's one mic (Nov 4 2026)

// The inner screen's layouts each have a mic in a different place — the cover's view (92 pt, under
// the Thread), the laptop's mic mode (112), the column beside a window (72) — and as one layout gave
// way to another the two mics faded through each other for a moment. Now each layout keeps only a
// slot (`micSlot`) and one mic, drawn over the whole inner screen (`innerMic`), goes to the slot
// of the layout on screen: it glides there and takes its size, and is never two. Being one view it
// also keeps a hold across a layout change.

/// Where a layout wants the mic: its frame, its size, whose it is and whether it shows.
struct MicSlot {
    var anchor: Anchor<CGRect>
    var size: CGFloat
    /// The layout it belongs to (`MainView.micOwner`): a layout on its way out still reports its
    /// slot for the length of its fade, and is ignored.
    var owner: String
    var visible: Bool
}

struct MicSlotKey: PreferenceKey {
    static let defaultValue: [MicSlot] = []
    static func reduce(value: inout [MicSlot], nextValue: () -> [MicSlot]) { value += nextValue() }
}

extension MainView {
    /// The size the one mic is drawn at, scaled to each slot (down, so it stays crisp).
    static let innerMicBase: CGFloat = DuoLook.deckMic

    /// Whose slot the mic goes to: the pose's layout (upright or on its side — folded or flat
    /// it's one layout), in hand or at rest.
    func micOwner(inHand: Bool) -> String {
        "\(posture.pose.foldAcross ? "upright" : "side")/\(inHand ? "hand" : "rest")"
    }

    /// A layout's place for the mic: the mic button's own frame, empty.
    func micSlot(size: CGFloat, inHand: Bool, visible: Bool = true) -> some View {
        let owner = micOwner(inHand: inHand)
        return Color.clear
            .frame(width: size * 1.3, height: size * 1.25)
            .anchorPreference(key: MicSlotKey.self, value: .bounds) { [MicSlot(anchor: $0, size: size, owner: owner, visible: visible)] }
            .accessibilityHidden(true)
    }

    /// The cover's view and the deck, both built, the one not on screen hidden (Nov 4 2026): Show
    /// it here and Done only fade between them — building the deck (its keyboard field, the
    /// trackpad, the keys) and the cover's view again each time held the main thread for a tenth
    /// of a second or more before anything moved. What leaves goes at once, what arrives fades in
    /// on the spring carrying the change (as `.handoff`); the hidden one takes no touch, says
    /// nothing to VoiceOver and its Thread stands still.
    func keptPair<Rest: View, Hand: View>(inHand: Bool, rest: Rest, hand: Hand) -> some View {
        // Both from the top: one that wants more room than there is (the laptop's modes, hidden
        // with a question up) must never push the other off centre — the cover's view lost its
        // top bar above the deck's edge that way.
        ZStack(alignment: .top) {
            rest.modifier(KeptHidden(hidden: inHand))
            hand.modifier(KeptHidden(hidden: !inHand))
        }
    }

    /// The one mic, over the inner screen's layouts, at the slot of the one on screen.
    func innerMic(_ slots: [MicSlot]) -> some View { InnerMic(main: self, slots: slots) }
}

/// The inner screen's one mic (`MainView.innerMic`).
///
/// It only ever shows in a slot that has settled (Nov 7 2026). A slot's frame is measured
/// mid-change — the keyboard's room collapsing in two passes, a layout handing over, the screen
/// turning — and the mic used to turn up at the first frame it was given and glide from there: on
/// the Mac window's text, over the Dock, over the glance, cut off in a corner. Now a frame counts
/// once it has held still for two display frames with nothing on its way (no pose change in the
/// last `poseQuiet`, the keyboard not coming or going, its own room not moving); from hidden the
/// mic fades in there; it glides only from a settled slot it showed in to another of the same
/// layout in the same pose; a pose change, or the window coming into hand or going back, hides it
/// until the new slot settles. A finger on it keeps it where it is, shown — a hold is never lost.
struct InnerMic: View {
    let main: MainView
    let slots: [MicSlot]

    /// Where it's drawn, at what size, in which pose — set only from a settled slot.
    @State private var placed: CGRect = .zero
    @State private var placedSize: CGFloat = 92
    @State private var placedPose: FoldPose?
    /// Whose slot it was placed in (`MainView.micOwner`): in hand or at rest.
    @State private var placedOwner: String?
    @State private var shown = false
    @State private var clock = SettleClock()
    @State private var settleTask: Task<Void, Never>?

    static let poseQuiet: TimeInterval = 0.45
    static let keyboardQuiet: TimeInterval = 0.35
    /// How long a shown mic moves in step with its slot after its room was re-laid (a spring's length).
    static let follow: TimeInterval = 0.9
    /// The longest it waits for a bar at the foot that's due, and the room that says it's there
    /// (the home indicator's 34 and the bar's 48 on the simulator; the threshold sits between).
    static let barWait: TimeInterval = 1.5
    static let roomQuiet: TimeInterval = 0.3
    static let footBarRoom: CGFloat = 60
    /// A few display frames: a spring's frames come further apart than two when the main thread
    /// is busy (a window coming into hand), and the mic took a frame mid-spring for its place.
    static let still: TimeInterval = 0.1

    /// What the slot says now and when anything last moved — a box, so the settling task reads
    /// the newest without the view redrawing for it.
    final class SettleClock {
        var target: Target?
        var rectChanged = Date.distantPast
        var quietUntil = Date.distantPast
        /// Until when a shown mic moves with its slot frame by frame: its room is being re-laid
        /// under it (a bar arriving late), and the layout it sits in springs to its new place.
        var followUntil = Date.distantPast
        /// Its room as last measured, and until when it waits for a bar at the foot that's due.
        var room: RoomKey?
        var barWaitUntil = Date.distantPast
    }

    /// The mic's own room: where it is on the screen and what it keeps clear of.
    struct RoomKey: Equatable {
        var frame: CGRect
        var insets: EdgeInsets
    }

    struct Target: Equatable {
        var rect: CGRect
        var size: CGFloat
        var pose: FoldPose
        var owner: String
        var visible: Bool
    }

    private var fingerDown: Bool { main.holding || main.stopOnRelease }

    var body: some View {
        GeometryReader { geo in
            let want = main.micOwner(inHand: main.watcher.isShowing)
            let slot = slots.last { $0.owner == want }
            let pose = main.posture.pose
            let r = slot.map { geo[$0.anchor] } ?? .zero
            // A slot laid out off the screen (a layout measured mid-turn) is no place for it.
            let onScreen = r.width > 1 && r.height > 1 && r.minX > -8 && r.minY > -8
            let target = Target(rect: r, size: slot?.size ?? 92, pose: pose, owner: want,
                                visible: (slot?.visible ?? false) && onScreen)
            // Never in a pose or a layout it wasn't placed in, not for a frame (unless a finger is
            // on it): the window coming into hand re-lays the screen in the very next passes.
            let visible = shown && ((placedPose == pose && placedOwner == want) || fingerDown)
            main.micCore(size: MainView.innerMicBase)
                .scaleEffect(placedSize / MainView.innerMicBase)
                .frame(width: placedSize * 1.3, height: placedSize * 1.25)
                // At rest the cover's view has the slot under its mic (`LandedSlot`); in hand
                // the deck has none, so the pill floats over the mic there.
                .landedPill(on: want.hasSuffix("/hand"), size: placedSize, namespace: main.micSpace)
                .opacity(visible ? 1 : 0)
                .animation(nil, value: pose)
                .position(x: placed.midX, y: placed.midY)
                .allowsHitTesting(visible)
                .accessibilityHidden(!visible)
                .onChange(of: target, initial: true) { old, new in heard(new, was: old) }
                .onChange(of: main.posture.settleSeq) { _, _ in poseMoved() }
                .onChange(of: main.input.keysUp) { _, _ in quiet(for: Self.keyboardQuiet) }
                // In hand or back at rest: the status bar, the bars and the kept layers re-lay the
                // screen over the next few passes (the system's, not ours) — gone at once, back
                // once that has settled. Gliding from the old slot, it rose or fell 50–100 pt
                // after Done and Show it here (Nov 7 2026, on his Duo: "the mic button seems to
                // shift up and then come down to its appropriate place after about a second").
                .onChange(of: main.watcher.isShowing) { _, _ in
                    quiet(for: Self.poseQuiet)
                    clock.barWaitUntil = Date().addingTimeInterval(Self.barWait)
                    // (At once: a fade began under a main thread busy building the window's
                    // half and drew its first frame after the room had moved — 82 pt up, opaque.)
                    if !fingerDown { hide(animated: false) }
                    settle()
                }
                // Its own room re-laid (a bar arriving late, the status bar's room given back):
                // whatever the slot says isn't settled yet.
                // Shown, it moves with the layout around it, in step — never after it, as a glide.
                .onChange(of: RoomKey(frame: geo.frame(in: .global), insets: geo.safeAreaInsets), initial: true) { _, room in
                    clock.room = room
                    clock.rectChanged = Date()
                    // (The layout follows its room a pass or two later — the fold's halves are
                    // measured and published after it — and only then springs: give it that.)
                    quiet(for: Self.roomQuiet)
                    if shown { clock.followUntil = Date().addingTimeInterval(Self.follow) }
                    if !shown { settle() }
                }
                .onAppear { clock.barWaitUntil = Date().addingTimeInterval(Self.barWait) }
                .onDisappear { settleTask?.cancel(); settleTask = nil }
        }
    }

    private func quiet(for seconds: TimeInterval) {
        clock.quietUntil = max(clock.quietUntil, Date().addingTimeInterval(seconds))
    }

    private func poseMoved() {
        quiet(for: Self.poseQuiet)
        clock.barWaitUntil = Date().addingTimeInterval(Self.barWait)
        if !fingerDown { hide(animated: false) }
        settle()
    }

    private func heard(_ new: Target, was old: Target) {
        if new.rect != old.rect || clock.target == nil { clock.rectChanged = Date() }
        if new.pose != old.pose { quiet(for: Self.poseQuiet); if !fingerDown { hide(animated: false) } }
        clock.target = new
        guard new.visible else {
            settleTask?.cancel(); settleTask = nil
            if !fingerDown { hide(animated: true) }
            return
        }
        // A finger on it: it stays in hand and follows its slot, as before.
        if fingerDown, shown {
            withAnimation(Motion.pick(Motion.settle, reduce: main.reduceMotion)) { place(new) }
            return
        }
        if shown, new.rect == placed, new.size == placedSize, new.pose == placedPose, new.owner == placedOwner { return }
        // Its room re-laid a moment ago: the slot is riding the layout's own spring — in step.
        if shown, new.pose == placedPose, new.owner == placedOwner, Date() < clock.followUntil {
            var t = Transaction(animation: nil); t.disablesAnimations = true
            withTransaction(t) { place(new) }
            return
        }
        settle()
    }

    private func hide(animated: Bool) {
        guard shown else { return }
        if animated { withAnimation(.easeOut(duration: 0.1)) { shown = false } } else {
            var t = Transaction(animation: nil); t.disablesAnimations = true
            withTransaction(t) { shown = false }
        }
    }

    private func place(_ t: Target) {
        placed = t.rect
        placedSize = t.size
        placedPose = t.pose
        placedOwner = t.owner
    }

    /// Waits for the slot to hold still with nothing on its way, then shows the mic there.
    private func settle() {
        settleTask?.cancel()
        let began = Date()
        settleTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let t = clock.target, t.visible else { return }
                let now = Date()
                // The keyboard page's keyboard still up after the page left it: on its way down
                // (for a moment at most — a keyboard that stays isn't one going).
                if main.input.keysUp, main.input.page != .keyboard, now.timeIntervalSince(began) < 0.6 { quiet(for: 0.05) }
                // Upright at rest the system puts the bar's lower group at the foot — after a turn,
                // most of a second late (the stack still laying out the vertical bar it had); the
                // mic's slot then rises by the bar's height while all above it stays (Nov 7 2026,
                // his Duo: "the mic button seems to shift … then come down to its appropriate
                // place"). Due and not there yet: not settled (for `barWait` at most — if it never
                // comes, the mic still shows).
                if main.uprightFootBar, (clock.room?.insets.bottom ?? 0) < Self.footBarRoom, now < clock.barWaitUntil { quiet(for: 0.05) }
                let ready = max(clock.rectChanged.addingTimeInterval(Self.still), clock.quietUntil)
                if ready > now {
                    try? await Task.sleep(nanoseconds: UInt64(ready.timeIntervalSince(now) * 1e9) + 2_000_000)
                    continue
                }
                commit(t)
                return
            }
        }
    }

    private func commit(_ t: Target) {
        settleTask = nil
        if shown, placedPose == t.pose, placedOwner == t.owner, placed.width > 1 {
            withAnimation(Motion.pick(Motion.settle, reduce: main.reduceMotion)) { place(t) }
            return
        }
        var still = Transaction(animation: nil); still.disablesAnimations = true
        withTransaction(still) { shown = false; place(t) }
        // Placed first, then faded in there (a frame later, so the move is never part of the fade).
        Task { @MainActor in
            guard clock.target == t else { return }
            withAnimation(main.reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.15)) { shown = true }
        }
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
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in reveal() })
                .overlay {
                    if let at = padAt { pad(at: at, in: geo.size) }
                }
                // The mic, small, wherever he left it (never faded: it's the app's point) — and the
                // way out beside it (Nov 4 2026). In the screen's top-left corner the button sat
                // over the Mac window's own close, minimise and zoom buttons, which every Mac window
                // has right there (and a touch there brought it up under the finger as the tap went
                // through to them). Beside the mic it's where he put the mic — somewhere he doesn't
                // need on the Mac — and under his thumb, on the side towards the screen's middle.
                .overlay {
                    FloatingMic(main: main, room: geo.size, exitShown: exitUp) { exitButton }
                        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.3), value: exitUp)
                }
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
        Haptics.grab()
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
            watcher.setFullScreen(false)
        } label: {
            Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(WatchCellStyle(width: FloatingMic<EmptyView>.exitSize, height: FloatingMic<EmptyView>.exitSize))
        .watchGlass(Circle())
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
struct FloatingMic<Exit: View>: View {
    let main: MainView
    var room: CGSize
    /// The way out of full screen beside the disc (it fades with the screen's other controls).
    var exitShown = false
    @ViewBuilder var exit: () -> Exit
    // First at the right edge, halfway down (Nov 7 2026): bottom-right sat on a chat's Send button.
    @AppStorage("duo.fullscreen.mic.x") private var fx = 1.0
    @AppStorage("duo.fullscreen.mic.y") private var fy = 0.5
    @State private var drag: CGSize = .zero
    @State private var dragging = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static var size: CGFloat { 52 }
    /// The lip above the disc, and how far it overlaps it.
    static var lip: CGSize { CGSize(width: 34, height: 16) }
    /// The exit button beside the disc.
    static var exitSize: CGFloat { 40 }

    var body: some View {
        let centre = place(CGPoint(x: home.x + drag.width, y: home.y + drag.height))
        // The exit on the side towards the screen's middle (there's always room there), level
        // with the disc (the lip's frame is above it: 32 pt, less the 7 they overlap).
        let towardsLeft = centre.x > room.width / 2
        let disc = CGPoint(x: centre.x, y: centre.y + (32 - 7) / 2)
        let gap = Self.size * 0.65 + 6 + Self.exitSize / 2
        ZStack {
            // The lip just above the disc's ring, a few points clear of it (the lip's frame carries
            // 8 pt of touch room under it; the button's runs a little past the ring).
            VStack(spacing: -7) {
                lip.zIndex(1)
                main.micButton(size: Self.size)
            }
            .scaleEffect(dragging ? 1.06 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
            .position(centre)
            // Undo, while the Mac can take the paste back: just above the lip, with the mic
            // wherever he left it — the exit sits beside the disc, so the two never meet.
            if !dragging {
                UndoChip()
                    .position(x: centre.x, y: max(centre.y - 37 - 8 - 14, 22))
            }
            if exitShown, !dragging {
                exit()
                    .position(x: disc.x + (towardsLeft ? -gap : gap), y: disc.y)
                    .transition(.opacity)
            }
        }
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
                    if !dragging { dragging = true; Haptics.grab() }
                    drag = v.translation
                }
                .onEnded { v in
                    let p = place(CGPoint(x: home.x + v.translation.width, y: home.y + v.translation.height))
                    if room.width > 0, room.height > 0 { fx = p.x / room.width; fy = p.y / room.height }
                    drag = .zero
                    dragging = false
                    Haptics.arrived()
                })
            .accessibilityHidden(true)
    }

    /// Where it rests (kept on screen: a drag moves it from there at once, even from the edge).
    private var home: CGPoint { place(CGPoint(x: fx * room.width, y: fy * room.height)) }

    /// The centre kept so the whole of it is on screen and out of the rounded corners.
    private func place(_ p: CGPoint) -> CGPoint {
        let inset = DuoLook.edgeInset
        let halfW = Self.size * 0.8, top = Self.size / 2 + Self.lip.height + 8, bottom = Self.size * 0.8
        return CGPoint(x: min(max(p.x, inset + halfW), room.width - inset - halfW),
                       y: min(max(p.y, inset + top), room.height - inset - bottom))
    }
}

/// The window in hand and the glance each give up their viewer only once they've faded out (a
/// viewer gone at once left an empty plate fading where the picture had been); the one arriving
/// has its viewer at once.
struct DormantAfterFade: ViewModifier {
    var inHand: Bool
    @Binding var panel: Bool
    @Binding var glance: Bool
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: inHand) { _, on in
                task?.cancel()
                if on { panel = false } else { glance = false }
                task = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    if on { glance = true } else { panel = true }
                }
            }
    }
}

/// The Mac's half of a folded screen — a MacBook's screen: the picture filling the half, nothing
/// laid over it (on the book's page the name is a row above it and the answers a row under it);
/// the words you're saying over the picture while the mic is open. Or the glance.
struct DuoMacHalf: View {
    let main: MainView
    /// The book's page: narrow and tall, so the header takes two rows.
    var vertical: Bool
    /// The half's size (what the words over the picture may take).
    var room: CGSize
    /// The laptop's screen (Nov 1 2026): no bezel, no corner — the picture is the half.
    var edge = false
    @ObservedObject private var watcher: Watcher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(main: MainView, vertical: Bool, room: CGSize, edge: Bool = false) {
        self.main = main
        self.vertical = vertical
        self.room = room
        self.edge = edge
        _watcher = ObservedObject(wrappedValue: main.watcher)
        _handDormant = State(initialValue: !main.watcher.isShowing)
        _glanceDormant = State(initialValue: main.watcher.isShowing)
    }

    private var bezel: CGFloat { edge ? 0 : DuoLook.halfBezel }
    private var corner: CGFloat { edge ? DuoLook.edgeCorner : DuoLook.halfCorner }

    var body: some View {
        // The window in hand and the glance, both built, one hidden (Nov 4 2026): Show it here
        // and Done only fade between them; only the one on screen has a viewer.
        let inHand = watcher.isShowing
        ZStack {
            handScreen
                // The tests read the window's place off this (it must never move).
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("duo-window")
                .modifier(KeptHidden(hidden: !inHand))
            glanceScreen.modifier(KeptHidden(hidden: inHand))
        }
        .modifier(DormantAfterFade(inHand: inHand, panel: $handDormant, glance: $glanceDormant))
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: shortPicture != nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Mac")
    }

    @State private var handDormant: Bool
    @State private var glanceDormant: Bool
    @Environment(\.innerAsleep) private var asleep

    /// The window in hand.
    @ViewBuilder private var handScreen: some View {
        if !vertical {
            // The laptop (Oct 31 2026, Sameer: "the view window fully filling one half … the hot
            // keys to all be the bottom half … so that nothing blocks the view window"): the
            // picture is the whole half and nothing lies over it — the header, the answers and the
            // words you're saying are on the deck.
            screen(footInset: 0, floating: false)
        } else if let short = shortPicture {
            // A window that can't fill the half (the fourth pass — the Mac can't reshape it, or
            // hasn't yet: the whole screen, a window on the book's tall page): the picture at the
            // top at the scale that fills the width, and the room under it holds what floated over
            // it — the answers with Esc · Keys and Pan | Scroll (or the keys), the words you're
            // saying. No black above or below.
            VStack(spacing: 10) {
                // The header has room of its own here, above the picture, as on the open screen
                // (never over its first lines).
                WatchHeaderBar(watcher: watcher, twoRows: vertical, dragSwitch: true) { t, _ in watcher.say(t.title, symbol: "arrow.left.and.right") }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                screen(footInset: 0, floating: false)
                    .frame(height: short)
                if main.showLiveWords {
                    DuoLiveWords(main: main, room: room, below: true)
                        .transition(.opacity)
                } else {
                    // The answers alone (the deck beside it has the keys).
                    WatchActions(watcher: watcher, floating: true)
                        .padding(.horizontal, 12)
                        .watchLive(watcher.phase)
                }
                Spacer(minLength: 0)
            }
        } else {
            // The book's page (Nov 6 2026, Sameer: "I don't like having anything ever overlaid
            // over the window"): the name on a row of its own above the picture and the answers
            // on one under it; the picture takes what's between (auto-fit gives it that shape).
            VStack(spacing: 8) {
                WatchHeaderBar(watcher: watcher, twoRows: vertical, dragSwitch: true) { t, _ in watcher.say(t.title, symbol: "arrow.left.and.right") }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                screen(footInset: 0, floating: true)
                if watcher.answers != nil, !main.showLiveWords {
                    // One row while typing: the keyboard has the rest.
                    WatchActions(watcher: watcher, floating: true, oneLine: main.typingOver)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .watchLive(watcher.phase)
                        .transition(.opacity)
                }
            }
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: watcher.answers?.id)
        }
    }

    /// The glance.
    private var glanceScreen: some View {
        DuoGlance(watcher: watcher, fill: true, edge: edge, dormant: glanceDormant || asleep)
    }

    /// The screen: the picture edge to edge, nothing over it but — `floating`, only while the mic
    /// is open — the words you're saying.
    private func screen(footInset: CGFloat, floating: Bool) -> some View {
        WatchWindow(watcher: watcher, interactive: true, bezelWidth: bezel, corner: corner, fill: true, footInset: footInset, dormant: handDormant || asleep)
            .overlay(alignment: .bottom) { MacPermissionBanner(watcher: watcher) }
            .overlay(alignment: .bottom) {
                if floating, main.showLiveWords {
                    DuoLiveWords(main: main, room: room)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
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

/// The inner screen's deck, on every pose (Nov 7 2026, round 3 — one control vocabulary): with a
/// window in hand, one mode at a time filling the deck — the trackpad edge to edge, the mic with
/// the Thread across it, or the iOS keyboard — picked by `DuoModeBar` at its foot. The laptop (and
/// flat upright) adds the window's header under the modes and a question's answers over them; the
/// side page (the book, flat on its side) has neither — its name is a row over the picture, its
/// answers a row under it and its controls in the vertical bar. Nothing in hand: the cover's own
/// view, whole (Nov 1 2026: the half that was the cover goes on being the cover). `vertical`: the
/// side page.
struct DuoDeck: View {
    let main: MainView
    var vertical: Bool
    @ObservedObject private var watcher: Watcher
    @ObservedObject private var input: MacInput
    @EnvironmentObject private var model: AppModel

    init(main: MainView, vertical: Bool) {
        self.main = main
        self.vertical = vertical
        _watcher = ObservedObject(wrappedValue: main.watcher)
        _input = ObservedObject(wrappedValue: main.watcher.input)
    }

    var body: some View {
        // Both stay built (`keptPair`): Show it here and Done only fade between them.
        main.keptPair(inHand: watcher.isShowing, rest: main.phoneBody, hand: modes)
        .animation(Motion.pick(Motion.settle, reduce: main.reduceMotion), value: watcher.isShowing)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(watcher.isShowing ? "The deck: trackpad, keyboard and mic" : "Send to and the mic")
    }

    /// The keyboard page is asked for or still up: what it covers gives way at once.
    private var keyboardAsked: Bool { input.page == .keyboard || input.keysUp }

    /// The laptop's answers row: a question up, and never while the keyboard is asked for or up —
    /// whenever it shows the keyboard is down, so its chips (Esc first) never change under the
    /// finger, and the keyboard's bar never slides up through them (Nov 7 2026).
    private var answersShown: Bool {
        !vertical && watcher.phase.holdsLayout && !main.showLiveWords && watcher.answers != nil && !keyboardAsked
    }

    /// The deck in hand (Nov 1 2026, Sameer: "the trackpad is really small … I should still be
    /// able to select mic mode, keyboard mode to trackpad mode and have each of those modes take
    /// up the full half"; Nov 7 2026: the same on the side page, where a column of everything at
    /// once had made a 90° fold change the whole control model). The deck's height never changes
    /// with its mode or a question, so the window never moves. While you talk, the words sit over
    /// the Thread and the mic under them, lit to stop; the modes stay in their place, dimmed.
    private var modes: some View {
        VStack(spacing: 6) {
            // (Held, dimmed, while the link comes back: the deck under them never moves for a blip.)
            if answersShown {
                WatchActions(watcher: watcher, floating: true, oneLine: true)
                    .padding(.horizontal, 12)
                    .watchLive(watcher.phase)
                    .transition(.asymmetric(insertion: .opacity.animation(Motion.pick(Motion.settle, reduce: main.reduceMotion)),
                                            removal: .opacity.animation(Motion.leave)))
            }
            GeometryReader { g in room(g.size) }
            modeRow
                .padding(.horizontal, 12)
            if !vertical {
                // The window's controls at the deck's foot (Nov 1 2026, Sameer: "move all of the Mac
                // controls and … window selection tools to the bottom so that they don't
                // interfere"): the keyboard rises over them, and nothing sits between the window and
                // the deck.
                WatchHeaderBar(watcher: watcher, dragSwitch: true) { t, _ in
                    watcher.say(t.title, symbol: "arrow.left.and.right")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
        // The side page lines up with the window's page beside it (in from the screen's corners).
        .padding(.top, vertical ? DuoLook.edgeInset : 6)
        .padding(.bottom, vertical ? DuoLook.edgeInset : 0)
        .animation(Motion.pick(Motion.settle, reduce: main.reduceMotion), value: watcher.answers?.id)
        .animation(Motion.pick(Motion.settle, reduce: main.reduceMotion), value: main.showLiveWords)
        .animation(Motion.pick(Motion.settle, reduce: main.reduceMotion), value: answersShown)
    }

    /// The mode's room. The carousel stays in it whatever the mode (it holds the keyboard's field);
    /// with the keyboard up on the side page nothing of it shows, and only the modes stay, over the
    /// keyboard — Trackpad or Mic one tap away.
    private func room(_ size: CGSize) -> some View {
        let mic = DuoLook.deckMicFit(size.height).mic
        return main.carousel(fill: size.height, compact: true, rowHidden: true)
            .frame(width: size.width, height: size.height, alignment: .top)
            .overlay {
                // Keyboard lit, the keyboard not up yet: the room is already the keyboard's.
                if input.page == .keyboard, !input.keysUp {
                    VStack(spacing: 8) {
                        Image(systemName: MacInput.Page.keyboard.symbol).font(.system(size: 28, weight: .regular))
                        Text(MacInput.Page.keyboard.title).font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Ink.tertiary)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08)),
                                            removal: .opacity.animation(Motion.leave)))
                }
            }
            .overlay(alignment: .top) {
                if main.showLiveWords {
                    DuoLiveWords(main: main, room: size, below: true)
                        .frame(height: max(72, size.height - DuoLook.micGroup(mic) - 4))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }

    /// The modes in the middle of their row, Open an App at its end (the way to an app that isn't
    /// open, with a window in hand: the window's name menu lists only the open ones).
    private var modeRow: some View {
        HStack(spacing: 8) {
            // Its twin's width on the other side, so the modes sit in the row's middle.
            Color.clear.frame(width: 44, height: 1)
            Spacer(minLength: 0)
            if input.pages.count > 1 {
                DuoModeBar(input: input)
                    .opacity(main.showLiveWords ? 0.4 : 1)
                    .allowsHitTesting(!main.showLiveWords)
            }
            Spacer(minLength: 0)
            Button { model.sheet = .openApp } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(WatchCellStyle(width: 44, height: 44))
            .watchGlass(Circle())
            .disabled(!model.isConnected || main.showLiveWords)
            .accessibilityLabel("Open an App")
            .accessibilityHint("Opens an app on your Mac.")
            .accessibilityIdentifier("deck-open-app")
        }
        .frame(height: DuoModeBar.height)
    }
}

/// The glance (Oct 25 2026): the picked app's window, live and big, with its controls put away —
/// a bar under it names it and one tap takes it in hand (Show it here). Nothing over the picture
/// (Nov 6 2026), and the moment the Mac connects looks exactly like the live glance it becomes —
/// the window's last picture in the same frame, the bar in the same place, only its words and
/// whether Show it here can be pressed yet differ (Nov 7 2026: the bar dropped and the button
/// jumped as it went live). Nothing watched yet: the picked app on a plate of the window's bezel
/// and the same tap; or what's missing — a Mac to pair, a Mac to connect.
struct DuoGlance: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    /// A folded half: the picture fills it, edge to edge.
    var fill: Bool
    /// The laptop's screen: no bezel, no corner.
    var edge = false
    /// Built but hidden behind the window in hand (`DuoMacHalf`): its window has no viewer.
    var dormant = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// The pick's window as it last looked (Nov 3 2026): on the plate while the Mac connects.
    @State private var kept: UIImage?

    private var bezelWidth: CGFloat { edge ? 0 : fill ? DuoLook.halfBezel : WatchLook.bezelWidth }
    private var corner: CGFloat { edge ? DuoLook.edgeCorner : fill ? DuoLook.halfCorner : WatchLook.bezel }

    /// Where the glance's window would come from: the pick, or the whole screen for the Clipboard
    /// and Where I'm typing (as `openWindowForPose` opens them).
    private var keptKey: String? {
        let pick = model.selection.target
        let place: TargetRef = { if case .app = pick { return pick } else { return model.reach.wholeScreenTarget } }()
        return WindowSnapshots.key(mac: model.pairedMac?.id, target: place)
    }

    var body: some View {
        let target = model.selection.target
        ZStack {
            // Opening, its last picture already there (the live one dissolves in over it).
            if watcher.isOpen, watcher.hasPicture || watcher.lastPicture != nil {
                // Live, the pictures still coming: the same screen, without its controls.
                pictured(watcher.videoSize ?? watcher.image?.size ?? watcher.lastPicture?.size, connecting: false) {
                    WatchWindow(watcher: watcher, interactive: false, bezelWidth: bezelWidth, corner: corner, fill: true, dormant: dormant)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(watcher.name)'s window on your Mac, live")
            } else if model.isPaired, !model.isConnected, model.settling || model.reconnecting, let kept = kept ?? WindowSnapshots.cached(keptKey), kept.size.width > 0, kept.size.height > 0 {
                // The moment it connects at launch: the window as it last looked, laid out as the
                // live glance lays it, so the live one takes its place without a jump — and no alarm.
                pictured(kept.size, connecting: true) { keptScreen(kept) }
                    .transition(.opacity)
            } else if model.isPaired, !model.isConnected, model.settling || model.reconnecting || !model.isUnreachable {
                // The moment it connects (at launch, or looking for it again), nothing kept yet:
                // the pick, and no alarm — only a Mac that wasn't found is news.
                plate
                VStack(spacing: 10) {
                    icon(target, size: 64)
                    Text(Places.appName(target, in: model)).font(.serif(.title2)).foregroundStyle(Ink.ink)
                    HStack(spacing: 8) {
                        ProgressView().tint(Ink.secondary)
                        Text(model.reconnecting ? "Reconnecting to \(model.macName)…" : "Connecting to \(model.macName)").font(.footnote).foregroundStyle(Ink.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .watchGlass(Capsule())
                }
                .transition(.opacity)
            } else if !model.isPaired || !model.isConnected || model.isNotOpen(target) {
                // Nothing to show, and why — as Apple's own empty states (Nov 5 2026).
                plate
                emptyState(target)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: 420)
                    .transition(.opacity)
            } else {
                plate
                VStack(spacing: 14) {
                    icon(target, size: 64)
                    Text(Places.appName(target, in: model)).font(.serif(.title2)).foregroundStyle(Ink.ink)
                    Text(target == .clipboard || target == .frontApp ? "Your Mac's whole screen, live."
                         : "Its window on your Mac, live — and your words go there.")
                        .font(.footnote).foregroundStyle(Ink.secondary)
                    showButton
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .frame(maxWidth: 360)
            }
        }
        .task(id: keptKey) { kept = WindowSnapshots.load(keptKey) }
        .animation(.easeInOut(duration: 0.25), value: model.settling)
        .animation(.easeInOut(duration: 0.25), value: model.reconnecting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Mac")
    }

    /// No Mac paired, the Mac not found, or the pick not open on it: the symbol, the title, one
    /// sentence and the button that fixes it.
    @ViewBuilder private func emptyState(_ target: TargetRef) -> some View {
        if !model.isPaired {
            EmptyState(symbol: "macbook.and.iphone", title: "Pair your Mac",
                       message: "Its windows show up here, live, once it's paired.") {
                Button { model.sheet = .pairing } label: { Label("Pair a Mac", systemImage: "qrcode.viewfinder") }
                    .emptyStateButton()
                    .accessibilityIdentifier("duo-pair")
            }
        } else if !model.isConnected, model.localNetworkDenied {
            EmptyState(symbol: "network.slash", title: "Local Network is off",
                       message: "Turn it on in Settings so Macrophone can find \(model.macName) on this Wi-Fi.") {
                Button("Open Settings") { openAppSettings() }.emptyStateButton()
            }
        } else if !model.isConnected {
            EmptyState(symbol: "laptopcomputer.slash", title: "Can't find \(model.macName)",
                       message: "Make sure it's awake with Macrophone open — its windows show up here when it is.") {
                WakeMacAction()
            }
        } else if case let .app(bundleID, _, _) = target {
            // The pick isn't open on the Mac: open it from here.
            let name = Places.appName(target, in: model)
            ContentUnavailableView {
                Label { Text("\(name) isn't open") } icon: { icon(target, size: 64) }
            } description: {
                Text("Open it on your Mac to see its window here.")
            } actions: {
                Button("Open \(name)") { model.openOnMac(MacApp(bundleID: bundleID, name: name)) }
                    .emptyStateButton()
                    .accessibilityIdentifier("duo-open-app")
            }
        }
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

    /// The bar under the picture: one height whatever it says, so nothing above or below it moves.
    static let barHeight: CGFloat = 64

    /// The picture at its own shape, as large as the room over the bar allows (the room's own
    /// shape before a picture is known), at the top, and the bar under it as wide as it.
    private func pictured<Screen: View>(_ aspect: CGSize?, connecting: Bool, @ViewBuilder screen: () -> Screen) -> some View {
        let screen = screen()
        return GeometryReader { geo in
            let room = CGSize(width: geo.size.width, height: max(0, geo.size.height - Self.barHeight))
            let frame = Self.fit(aspect, bezel: bezelWidth, in: room)
            VStack(spacing: 0) {
                screen.frame(width: frame.width, height: frame.height)
                glanceBar(connecting: connecting)
                    .frame(width: max(frame.width, min(geo.size.width, 320)), height: Self.barHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    /// A picture of `aspect` (plus its bezel) fitted into `room`; the room itself when unknown.
    static func fit(_ aspect: CGSize?, bezel: CGFloat, in room: CGSize) -> CGSize {
        guard let a = aspect, a.width > 0, a.height > 0, room.width > 2 * bezel, room.height > 2 * bezel else { return room }
        let ratio = a.width / a.height
        var w = room.width
        var h = (w - 2 * bezel) / ratio + 2 * bezel
        if h > room.height { h = room.height; w = (h - 2 * bezel) * ratio + 2 * bezel }
        return CGSize(width: w.rounded(.down), height: h.rounded(.down))
    }

    /// The app, that it's live (or paused, or still connecting), and Show it here on one line.
    private func glanceBar(connecting: Bool) -> some View {
        let target = model.selection.target
        return HStack(spacing: 12) {
            icon(target, size: 32)
            Group { if connecting { connectingWords } else { liveWords } }
                .frame(maxWidth: .infinity, alignment: .leading)
            showButton.fixedSize().disabled(connecting)
        }
        .padding(.horizontal, 14)
    }

    private var connectingWords: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Places.appName(model.selection.target, in: model)).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink).lineLimit(1)
            Text(model.reconnecting ? "Reconnecting to \(model.macName)…" : "Connecting to \(model.macName)…").font(.caption).foregroundStyle(Ink.secondary).lineLimit(1)
        }
    }

    /// The kept picture in the live window's own frame — its bezel and corner — a little dimmed.
    private func keptScreen(_ image: UIImage) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            .opacity(0.6)
            .background(Ink.sunk)
            .clipShape(shape)
            .padding(bezelWidth)
            .background(Ink.raised, in: shape)
            .accessibilityHidden(true)
    }

    private var liveWords: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(watcher.name).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink).lineLimit(1)
            Group {
                switch watcher.phase {
                case .paused: Text("Paused · Show it here to go on").foregroundStyle(Light.ochre)
                // The link dropped: the picture holds, and says so calmly (Nov 5 2026).
                case .reconnecting: Text("Reconnecting to \(model.macName)…").foregroundStyle(Ink.secondary)
                case .offline: Text("\(model.macName) isn't connected").foregroundStyle(Light.ochre)
                default: Text("Live on your Mac").foregroundStyle(Ink.secondary)
                }
            }
            .font(.caption).lineLimit(1)
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
            let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            Image(uiImage: img).resizable().frame(width: size, height: size)
                .clipShape(shape)
                // A hairline rim: a dark icon (Terminal) on a dark ground still has its edge.
                .overlay(shape.strokeBorder(Ink.line, lineWidth: 0.5))
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
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if Posture.shared.hingeOpen { return .all }
        guard let screen = window?.windowScene?.screen ?? window?.screen else { return .portrait }
        let b = screen.bounds.size
        return min(b.width, b.height) >= FoldPose.innerShortSide ? .all : .portrait
    }
}
