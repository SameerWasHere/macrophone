import MacrophoneKit
import SwiftUI

// The three ways in, while a window shows (Oct 19 2026, Sameer: "swiping right to left should
// show the trackpad and swiping left to right should open a full iOS keyboard … a 3 input method
// carousel"). The foot of the screen becomes three pages side by side, with the row saying where
// you are ABOVE the Thread (the carousel fixes, Oct 19 2026 — Sameer: "the keyboard, mic, and
// trackpad switcher should be above the wave form in mic mode and swiping where the wave form is
// should still allow switching between views"):
//
//        KEYBOARD      ● MIC       TRACKPAD        the row says where you are; a tap goes there
//   ╌╌╌╌╌╌╌╌╌╌╌╌╌╌ the Thread ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌   on the mic page; it folds away on the others
//   ┌──────────────┬──────────────┬──────────────┐
//   │ (the iOS     │    ( mic )   │  a plate the │   the mic is the default, every time the window
//   │  keyboard)   │  status line │  finger moves│   opens; a swipe on the Thread or beside the mic
//   └──────────────┴──────────────┴──────────────┘   (not on it — a hold there is a dictation)
//                                                    slides to the next; the trackpad takes every
// finger for the pointer and grows into the Thread's room, so its way back is the row (or a swipe
// in from its left edge); the keyboard page is the iOS keyboard with one bar of the Mac's keys
// above it (`MacKeyboardBar`), and hide on that bar comes back to the mic. A page shows only when
// the connected Mac takes its messages (named in its welcome); a Mac from before has the mic
// alone, and the row doesn't show. The mic page is the same view whatever page is up, so a hold
// that started on the mic is never lost to a page change.

/// The carousel's measures.
enum InputCarouselLook {
    /// The page row's height, and the room under it.
    static let row: CGFloat = 22
    static let rowGap: CGFloat = 6
    /// The keyboard page's own height: a breath between the row and the keyboard's bar (the
    /// keys themselves ride on the keyboard).
    static let keyboardBreath: CGFloat = 10
}

struct InputCarousel<Mic: View, Thread: View>: View {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher
    var compact: Bool
    /// The Thread's slot on the mic page (the trackpad takes it on its page).
    var threadHeight: CGFloat
    /// The Duo's deck (Oct 25 2026): the room the whole carousel has — the pages take all of it
    /// (the trackpad whole, the mic in the middle of it). Nil: the pages size themselves.
    var fill: CGFloat? = nil
    /// The page row isn't drawn here (a folded Duo's deck draws the switcher in a corner,
    /// `InputCornerSwitcher`, so the trackpad is the whole half).
    var rowHidden = false
    /// The Duo's cover (Oct 31 2026, Sameer: "there's no way to close the trackpad"): the trackpad
    /// page carries its own row under the plate — the keyboard, back to the mic, close — in the
    /// places the mic page's row has them.
    var trackpadBar = false
    /// The mic is open (the regular iPhone, Nov 4 2026): the page row stays in its place, so
    /// nothing moves, but it's faded and takes no tap — the mic is the only page then.
    var rowDimmed = false
    /// The keyboard's room under the pages, laid out here (the regular iPhone, which ignores the
    /// keyboard's safe area — `MacInput.keyboardRoom`); 0 where the safe area gives it.
    var keyboardRoom: CGFloat = 0
    /// The mic page's height follows its content on the same spring (the Duo's cover, Nov 4
    /// 2026): measured a frame late, the new height used to land in a pass of its own with no
    /// animation — on Done the page grew in one frame, the window above was cut short and the
    /// mic jumped up before the rest of the screen moved.
    var smoothHeight = false
    /// The mic page: the mic button and the status line, built by the mic screen.
    @ViewBuilder var mic: () -> Mic
    /// The Thread's band, between the row and the pages.
    @ViewBuilder var thread: () -> Thread

    /// The pages following a finger. Gesture state: back to 0 whenever the swipe ends — finished
    /// or cancelled (a scroll that takes the touch over never calls onEnded; a plain state stayed
    /// put and left the mic off centre — Oct 19 2026, Sameer: "the mic button shifted").
    @GestureState(resetTransaction: Transaction(animation: Motion.settle)) private var dragX: CGFloat = 0
    @State private var width: CGFloat = 0
    /// The mic page's own height: what the trackpad page starts from.
    @State private var micHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var multi: Bool { input.pages.count > 1 }
    private var index: Int { input.pages.firstIndex(of: input.page) ?? 0 }
    /// The Thread shows on the mic page alone: the trackpad takes its room, the keyboard the foot.
    /// The Thread shows on the mic page alone — and not on a deck too short for it (the Duo
    /// folded with the window's question up: the mic keeps its room, the Thread folds away).
    /// While the keyboard is up (and on its way down) the Thread stays folded, whatever the page.
    private var threadShown: Bool { input.page == .mic && !input.keysUp && !(fill.map { $0 < 175 } ?? false) }
    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.2) : Motion.settle }

    var body: some View {
        VStack(spacing: 0) {
            if multi, !rowHidden {
                InputPageRow(input: input)
                    .frame(height: InputCarouselLook.row)
                    .padding(.bottom, InputCarouselLook.rowGap)
                    .opacity(rowDimmed ? 0.3 : 1)
                    .allowsHitTesting(!rowDimmed)
                    .accessibilityHidden(rowDimmed)
                    .animation(.easeInOut(duration: 0.2), value: rowDimmed)
                    .transition(.opacity)
            }
            // The Thread and the pages are one band: a swipe anywhere on it (off the mic) slides
            // the pages.
            VStack(spacing: 0) {
                // Never clipped: the Thread and its glow run past its slot above and below, as they
                // always have (Oct 19 2026, Sameer: "the glow … is getting cut at the top and
                // bottom"). Folding away it fades as its slot closes, so nothing spills.
                thread()
                    .frame(height: threadShown ? threadHeight : 0)
                    .opacity(threadShown ? 1 : 0)
                    .allowsHitTesting(threadShown)
                // The pages never set the carousel's width — the room offered does (Oct 31 2026:
                // on Sameer's Duo a page measured wider than the screen on the first pass, the
                // carousel took that width and kept it, and the trackpad ran off both sides with
                // the keyboard's button out of sight).
                PagesLayout {
                    ForEach(input.pages) { page in
                        pageView(page)
                            .frame(width: width > 0 ? width : nil)
                            .offset(x: offset(of: page))
                            .accessibilityHidden(page != input.page)
                            .allowsHitTesting(page == input.page)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                // The cover's mic page sits on the foot while its height follows it: a page that
                // grew at once (the mic opening — the larger mic, two lines for the status) hung
                // below the foot, over the home indicator, until the height caught up (Nov 4 2026).
                .frame(height: pagesHeight, alignment: smoothHeight && input.page == .mic ? .bottom : .top)
                // Clipped at the sides only: the pages slide in from there, but the mic's glow
                // runs past the page above and below (Oct 31 2026: "the glow of the orange mic
                // indicator is getting cut off").
                .clipShape(SidesOnly())
            }
            // Without a shape of its own the empty room beside the mic and under the Thread
            // would take no touch at all.
            .contentShape(Rectangle())
            .simultaneousGesture(swipe, including: multi && input.page == .mic && !rowDimmed ? .all : .subviews)
        }
        .animation(motion, value: input.page)
        .animation(motion, value: input.pages)
    }

    /// The pages' height: the mic page's own; the trackpad's that plus the Thread's room (the
    /// screen above never moves); the keyboard's a breath once the keyboard is up (its keys ride
    /// on the keyboard) — until then the trackpad's room, so nothing moves before it rises, and
    /// the breath stays until it has gone again (`MacInput.keysUp`).
    private var pagesHeight: CGFloat? {
        if input.keysUp { return InputCarouselLook.keyboardBreath + keyboardRoom }
        if let fill {
            // The deck: whatever the row and the Thread leave.
            return max(0, fill - (multi && !rowHidden ? InputCarouselLook.row + InputCarouselLook.rowGap : 0) - (threadShown ? threadHeight : 0))
        }
        switch input.page {
        case .mic: return micHeight > 0 ? micHeight : nil
        case .trackpad, .keyboard: return micHeight > 0 ? micHeight + threadHeight : nil
        }
    }

    /// Where a page sits: the current one at 0, the others a width to each side.
    private func offset(of page: MacInput.Page) -> CGFloat {
        guard let i = input.pages.firstIndex(of: page), width > 0 else { return page == input.page ? 0 : 10_000 }
        return CGFloat(i - index) * width + dragX
    }

    @ViewBuilder private func pageView(_ page: MacInput.Page) -> some View {
        switch page {
        case .mic:
            mic()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if smoothHeight, micHeight > 0, !reduceMotion { withAnimation(motion) { micHeight = h } } else { micHeight = h }
                }
                // The deck: the mic in the middle of the room — or, on a folded deck, right under
                // the Thread, the two as one group (the Thread's slot carries the room above).
                .frame(maxHeight: fill != nil ? .infinity : nil, alignment: rowHidden ? .top : .center)
        case .trackpad:
            VStack(spacing: 0) {
                TrackpadPage(input: input, watcher: watcher, big: rowHidden && !trackpadBar,
                             inset: trackpadBar ? 16 : WatchLook.sideMargin)
                    .frame(maxHeight: .infinity)
                if trackpadBar { TrackpadBar(input: input) }
            }
                .frame(height: fill != nil ? pagesHeight : micHeight > 0 ? micHeight + threadHeight : nil)
                // The way back: the row above, or a swipe in from the plate's left edge.
                .overlay(alignment: .leading) {
                    Color.clear
                        .frame(width: 22)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 10).onEnded { v in
                            if v.translation.width > 40, abs(v.translation.width) > abs(v.translation.height) { input.step(-1) }
                        })
                        .accessibilityHidden(true)
                }
        case .keyboard:
            KeyboardPage(input: input, watcher: watcher)
                .frame(height: InputCarouselLook.keyboardBreath)
        }
    }

    /// A swipe on the mic page — on the Thread or beside the mic, never on the mic itself (a hold
    /// there is a dictation): the pages follow the finger, and let go past a quarter of the width
    /// (or a flick) they settle on the next.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .updating($dragX) { v, x, _ in
                // One page (no window showing): nothing to slide to, so nothing moves.
                guard input.pages.count > 1, !onMic(v.startLocation), abs(v.translation.width) > abs(v.translation.height) else { return }
                var dx = v.translation.width
                // No page that way: the finger meets a soft stop.
                if (dx > 0 && index == 0) || (dx < 0 && index == input.pages.count - 1) { dx = dx / 4 }
                x = dx
            }
            .onEnded { v in
                guard input.pages.count > 1, !onMic(v.startLocation), abs(v.translation.width) > abs(v.translation.height) else { return }
                let x = v.translation.width, flick = v.predictedEndTranslation.width
                guard abs(x) > width / 4 || abs(flick) > width / 2 else { return }
                // Right to left: the trackpad (the next page); left to right: the keyboard.
                withAnimation(motion) { input.step(x < 0 ? 1 : -1) }
            }
    }

    /// The mic's own ground, in the middle of the page under the Thread: a touch there is the mic's.
    private func onMic(_ p: CGPoint) -> Bool {
        var top = threadShown ? threadHeight : 0
        // The deck: the mic page sits in the middle of the room (a folded deck's at its top).
        if let pages = pagesHeight, fill != nil, micHeight > 0, !rowHidden { top += max(0, (pages - micHeight) / 2) }
        return abs(p.x - width / 2) < 70 && p.y > top - 6 && p.y < top + (compact ? 130 : 150)
    }
}

/// A clip at the sides alone: tall enough above and below for any glow.
private struct SidesOnly: Shape {
    func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: 0, dy: -160)) }
}

/// The pages side by side in one place: each offered the room's width, the room's width whatever
/// a page would like (a ZStack takes its widest child's).
private struct PagesLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w, height: proposal.height)).height }.max() ?? 0
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews {
            s.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                    proposal: ProposedViewSize(width: bounds.width, height: proposal.height))
        }
    }
}

/// The cover's trackpad row (Oct 31 2026): the keyboard on the left, close on the right — where
/// the mic page's row has the keyboard and the trackpad, so the thumb that opened the trackpad
/// closes it in the same place. (A mic in the middle only went back to the mic page, as close
/// does — Sameer: "useless"; the middle says what two fingers do.)
struct TrackpadBar: View {
    @ObservedObject var input: MacInput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if input.pages.contains(.keyboard) {
                    button("keyboard", "Keyboard", "trackpad-bar-keyboard") { go(.keyboard) }
                } else { Color.clear }
            }
            .frame(maxWidth: .infinity)
            Text("Two fingers scroll")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 96)
                .accessibilityHidden(true)
            button("xmark", "Close the trackpad", "trackpad-bar-close") { go(.mic) }
                .frame(maxWidth: .infinity)
        }
        .frame(height: 56)
        .padding(.bottom, 4)
    }

    /// On the pages' spring, the whole screen at once: the window above grows back as the
    /// trackpad goes, instead of jumping to its new size under the plate (Nov 4 2026).
    private func go(_ p: MacInput.Page) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.settle) { input.show(p) }
    }

    private func button(_ symbol: String, _ label: String, _ id: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.tick(); action() } label: {
            Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 30, height: 30)
        }
        .circleGlassButton()
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// A folded Duo's deck (Oct 25 2026): the three pages as one small cluster of glass cells in the
/// deck's corner — the keyboard, the mic, the trackpad — so the trackpad can be the whole half.
/// The same one adjustable element for VoiceOver as the row.
struct InputCornerSwitcher: View {
    @ObservedObject var input: MacInput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(input.pages.enumerated()), id: \.element.id) { i, page in
                if i > 0 { WatchCellDivider() }
                let on = page == input.page
                Button { input.show(page) } label: {
                    Image(systemName: page.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? Light.cyan : Ink.secondary)
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        .watchGlass(Capsule())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: input.page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input")
        .accessibilityValue(input.page.title)
        .accessibilityHint("Swipe up or down for \(input.pages.map { $0.title.lowercased() }.joined(separator: ", ")).")
        .accessibilityAdjustableAction { direction in
            input.step(direction == .increment ? 1 : -1)
        }
        .accessibilityIdentifier("input-pages")
    }
}

/// Where you are among the pages, and a tap to any: the current one lit, a short bar under it.
/// One adjustable element for VoiceOver (swipe up or down to change the page).
struct InputPageRow: View {
    @ObservedObject var input: MacInput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 22) {
            ForEach(input.pages) { page in
                let on = page == input.page
                Button { input.show(page) } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: page.symbol).font(.system(size: 9, weight: .bold))
                            Text(page.title.capitalized)
                                .font(.caption.weight(.semibold))
                                .contentTransition(.identity)
                        }
                        .foregroundStyle(on ? Light.cyan : Ink.tertiary)
                        Capsule().fill(on ? Light.cyan : .clear).frame(width: 14, height: 3)
                    }
                    .frame(minWidth: 44, minHeight: InputCarouselLook.row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // The lit page changes at once, as a segmented control's does. Animated (it was a quick
        // ease of its own), each word's colour cross-fade was drawn apart from its glyph and
        // underline — leaving the keyboard, while the row rode down with it, the words, the glyphs
        // and the bar came apart and met again (Nov 4 2026).
        .animation(nil, value: input.page)
        // One picture: as the room under the window changed with the keyboard, the words moved
        // on one timing and their glyphs and the bar on another, the row coming apart for a
        // quarter of a second.
        .drawingGroup()
        // A kicker row of a fixed height: it keeps a kicker's size at accessibility sizes (the
        // words had grown past the row and the screen's width).
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input")
        .accessibilityValue(input.page.title)
        .accessibilityHint("Swipe up or down for \(input.pages.map { $0.title.lowercased() }.joined(separator: ", ")).")
        .accessibilityAdjustableAction { direction in
            input.step(direction == .increment ? 1 : -1)
        }
        .accessibilityIdentifier("input-pages")
    }
}

/// The keyboard page: the hidden field that brings the iOS keyboard up, with the Mac's keys on
/// the keyboard's own bar (`MacKeyboardBar`) — nothing of its own on the page but a breath.
struct KeyboardPage: View {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher

    var body: some View {
        #if DEBUG
        let standIn = DebugHooks.fakeKeyboard != nil
        #else
        let standIn = false
        #endif
        MacKeyboardField(input: input, watcher: watcher, active: input.page == .keyboard && !standIn)
            .frame(width: 1, height: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Keyboard, typing in \(watcher.name) on your Mac")
            .accessibilityIdentifier("input-keyboard")
    }
}
