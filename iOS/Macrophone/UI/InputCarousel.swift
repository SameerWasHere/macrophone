import MacrophoneKit
import SwiftUI

// The three ways in, while a window shows (Oct 19 2026, Sameer: "swiping right to left should
// show the trackpad and swiping left to right should open a full iOS keyboard … a 3 input method
// carousel"). The area under the Thread, where the mic sits, becomes three pages side by side:
//
//        KEYBOARD      ● MIC       TRACKPAD        the row says where you are; a tap goes there
//   ┌──────────────┬──────────────┬──────────────┐
//   │ typing in    │    ( mic )   │  a plate the │   the mic is the default, every time the window
//   │ Claude …     │  status line │  finger moves│   opens; a swipe on the mic page (not on the mic
//   └──────────────┴──────────────┴──────────────┘   itself) slides to the next; the trackpad takes
//                                                    every finger for the pointer, so its way back
// is the row (or a swipe in from its left edge); the keyboard page is a strip above the iOS keyboard,
// whose bar carries Esc, Tab, ⌘ ⌥ ⌃ ⇧, the arrows and the F-keys. A page shows only when the
// connected Mac takes its messages (named in its welcome); a Mac from before has the mic alone,
// and the row doesn't show. The mic page is the same view whatever page is up, so a hold that
// started on the mic is never lost to a page change.

/// The carousel's measures.
enum InputCarouselLook {
    /// The page row's height; the keyboard page's strip (the keyboard itself is below it).
    static let row: CGFloat = 22
    static let keyboardStrip: CGFloat = 44
}

struct InputCarousel<Mic: View>: View {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher
    var compact: Bool
    /// The mic page: the mic button and the status line, built by the mic screen.
    @ViewBuilder var mic: () -> Mic

    /// The finger's offset while a swipe is under way on the mic page.
    @State private var dragX: CGFloat = 0
    @State private var size: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var multi: Bool { input.pages.count > 1 }
    private var index: Int { input.pages.firstIndex(of: input.page) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            if multi {
                InputPageRow(input: input)
                    .frame(height: InputCarouselLook.row)
                    .transition(.opacity)
            }
            ZStack(alignment: .top) {
                ForEach(input.pages) { page in
                    pageView(page)
                        .frame(width: size.width > 0 ? size.width : nil)
                        .offset(x: offset(of: page))
                        .accessibilityHidden(page != input.page)
                        .allowsHitTesting(page == input.page)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: input.page == .keyboard ? InputCarouselLook.keyboardStrip : nil, alignment: .top)
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            // The room beside the mic is the swipe's: without a shape of its own the empty space
            // between the views would take no touch at all.
            .contentShape(Rectangle())
            .simultaneousGesture(swipe, including: multi && input.page == .mic ? .all : .subviews)
        }
        .animation(reduceMotion ? nil : Motion.settle, value: input.page)
        .animation(reduceMotion ? nil : Motion.settle, value: input.pages)
    }

    /// Where a page sits: the current one at 0, the others a width to each side.
    private func offset(of page: MacInput.Page) -> CGFloat {
        guard let i = input.pages.firstIndex(of: page), size.width > 0 else { return page == input.page ? 0 : 10_000 }
        return CGFloat(i - index) * size.width + dragX
    }

    @ViewBuilder private func pageView(_ page: MacInput.Page) -> some View {
        switch page {
        case .mic:
            mic()
        case .trackpad:
            TrackpadPage(input: input, watcher: watcher)
                .frame(height: size.height > 0 ? size.height : nil)
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
                .frame(height: InputCarouselLook.keyboardStrip)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                    if v.translation.width < -40, abs(v.translation.width) > abs(v.translation.height) { input.step(1) }
                })
        }
    }

    /// A swipe on the mic page — not on the mic itself (a hold there is a dictation): the pages
    /// follow the finger, and let go past a quarter of the width (or a flick) they settle on the next.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { v in
                guard !onMic(v.startLocation), abs(v.translation.width) > abs(v.translation.height) else { return }
                var x = v.translation.width
                // No page that way: the finger meets a soft stop.
                if (x > 0 && index == 0) || (x < 0 && index == input.pages.count - 1) { x = x / 4 }
                dragX = x
            }
            .onEnded { v in
                defer { withAnimation(reduceMotion ? nil : Motion.settle) { dragX = 0 } }
                guard !onMic(v.startLocation), abs(v.translation.width) > abs(v.translation.height) else { return }
                let x = v.translation.width, flick = v.predictedEndTranslation.width
                guard abs(x) > size.width / 4 || abs(flick) > size.width / 2 else { return }
                // Right to left: the trackpad (the next page); left to right: the keyboard.
                withAnimation(reduceMotion ? nil : Motion.settle) { input.step(x < 0 ? 1 : -1) }
            }
    }

    /// The mic's own ground, in the middle of the page's top: a touch there is the mic's.
    private func onMic(_ p: CGPoint) -> Bool {
        abs(p.x - size.width / 2) < 70 && p.y < (compact ? 130 : 150)
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

/// The keyboard page: a strip above the iOS keyboard (which the hidden field below brings up)
/// saying where the typing goes; the bar with Esc, Tab, the modifiers, the arrows and the F-keys
/// rides with the keyboard itself (`MacKeyboardField`).
struct KeyboardPage: View {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher

    var body: some View {
        ZStack {
            MacKeyboardField(input: input, watcher: watcher, active: input.page == .keyboard)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Light.cyan)
                Text(line)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 36)
            .watchGlass(Capsule())
            .padding(.horizontal, WatchLook.sideMargin)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line)
        .accessibilityIdentifier("input-keyboard")
    }

    private var line: String {
        if input.switching { return "Switching apps — tap again for the next one" }
        if !input.modifiers.isEmpty {
            let mods = WatchModifier.allCases.filter { input.modifiers.contains($0) }.map(\.glyph).joined()
            return "\(mods) goes on the next key or tap"
        }
        return "Typing in \(watcher.name) on your Mac"
    }
}
