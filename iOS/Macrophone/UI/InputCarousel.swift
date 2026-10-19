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
    private var threadShown: Bool { input.page == .mic }
    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.2) : Motion.settle }

    var body: some View {
        VStack(spacing: 0) {
            if multi {
                InputPageRow(input: input)
                    .frame(height: InputCarouselLook.row)
                    .padding(.bottom, InputCarouselLook.rowGap)
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
                ZStack(alignment: .top) {
                    ForEach(input.pages) { page in
                        pageView(page)
                            .frame(width: width > 0 ? width : nil)
                            .offset(x: offset(of: page))
                            .accessibilityHidden(page != input.page)
                            .allowsHitTesting(page == input.page)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: pagesHeight, alignment: .top)
                .clipped()
            }
            // Without a shape of its own the empty room beside the mic and under the Thread
            // would take no touch at all.
            .contentShape(Rectangle())
            .simultaneousGesture(swipe, including: multi && input.page == .mic ? .all : .subviews)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .animation(motion, value: input.page)
        .animation(motion, value: input.pages)
    }

    /// The pages' height: the mic page's own; the trackpad's that plus the Thread's room (the
    /// screen above never moves); the keyboard's a breath (its keys ride on the keyboard).
    private var pagesHeight: CGFloat? {
        switch input.page {
        case .mic: return micHeight > 0 ? micHeight : nil
        case .trackpad: return micHeight > 0 ? micHeight + threadHeight : nil
        case .keyboard: return InputCarouselLook.keyboardBreath
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { micHeight = $0 }
        case .trackpad:
            TrackpadPage(input: input, watcher: watcher)
                .frame(height: micHeight > 0 ? micHeight + threadHeight : nil)
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
        let top = threadShown ? threadHeight : 0
        return abs(p.x - width / 2) < 70 && p.y > top - 6 && p.y < top + (compact ? 130 : 150)
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
                            Text(page.title.uppercased())
                                .font(.mono(.caption2, weight: .semibold))
                                .tracking(1.1)
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: input.page)
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
        MacKeyboardField(input: input, watcher: watcher, active: input.page == .keyboard)
            .frame(width: 1, height: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Keyboard, typing in \(watcher.name) on your Mac")
            .accessibilityIdentifier("input-keyboard")
    }
}
