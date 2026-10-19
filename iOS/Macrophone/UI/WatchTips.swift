import MacrophoneKit
import SwiftUI

// Tips, the first times you watch (Oct 17 2026, Sameer: "there are some hidden features in this
// app (right click, swipe to switch apps). Can we make it so users can discover these features on
// first use?"). One card at a time over the top of the window — never over its newest lines, where
// you type — each shown until you tap Got it, and only once the thing it names works here (a
// right-click with a Mac that takes them, the side swipe with two windows or more, Text with a
// Mac that reads). Six at most (Oct 18 2026): the things with no words of their own on screen —
// a gesture, a bare glyph, a ··· — in the order they're met. The Window menu's Show Tips Again
// brings them back.
//
//   ┌──────────────────────────────────────────────┐
//   │ (hand.tap)  TIP 1 OF 6                   [×] │   a mono kicker, the symbol on a lit disc
//   │ Tap to click, hold to right-click            │   the words in the serif — the app's voice
//   │ A tap is a click there on your Mac. Hold —   │
//   │ or tap with two fingers — for a right-click. │
//   │ ▬ · · ·                              [Next]  │   where you are in them
//   └──────────────────────────────────────────────┘

struct WatchTip: Identifiable, Equatable {
    var id: String
    var symbol: String
    var title: String
    var detail: String

    static let click = WatchTip(id: "click", symbol: "hand.tap",
                                title: "Tap to click, hold to right-click",
                                detail: "A tap is a click there on your Mac. Hold — or tap with two fingers — for a right-click.")
    static let zoom = WatchTip(id: "zoom", symbol: "arrow.up.left.and.arrow.down.right",
                               title: "Pinch to zoom",
                               detail: "Pinch in or out; the window opens where you left it next time. The button by Done shows the whole window.")
    /// With a Mac that reshapes windows: the same tip names the Window menu's Fit to iPhone.
    static let zoomAndFit = WatchTip(id: "zoom", symbol: "arrow.up.left.and.arrow.down.right",
                                     title: "Pinch to zoom, or Fit to iPhone",
                                     detail: "Pinch in or out; the button by Done shows it whole. Fit to iPhone, in the Window menu, reshapes the window to fit here.")
    static let swipe = WatchTip(id: "swipe", symbol: "arrow.left.and.right",
                                title: "Swipe in from the side for your other windows",
                                detail: "Start at the very edge of the screen. Or tap the window's name at the top to pick one.")
    static let scroll = WatchTip(id: "scroll", symbol: "scroll",
                                 title: "Pan or Scroll",
                                 detail: "Pan moves your view. Scroll moves the window on your Mac with one finger — two fingers still pan. Zoomed all the way out, Scroll picks itself.")
    static let keys = WatchTip(id: "keys", symbol: "ellipsis",
                               title: "More keys",
                               detail: "Interrupt, Undo, Send, the arrows and more are behind ··· beside Return.")
    /// With a Mac that takes the pointer: the same first tip names the double-click and the drag.
    static let mouse = WatchTip(id: "click", symbol: "hand.tap",
                                title: "Tap to click, hold to right-click",
                                detail: "Tap twice for a double-click. Tap, then hold and move, to drag. Hold — or tap with two fingers — for a right-click.")
    /// The keyboard and the trackpad beside the mic (Oct 19 2026).
    static let input = WatchTip(id: "input", symbol: "rectangle.and.hand.point.up.left",
                                title: "Swipe beside the mic for a trackpad or keyboard",
                                detail: "Right to left for a trackpad; left to right for a keyboard that types straight into your Mac. Or tap Keyboard, Mic or Trackpad above the mic.")
}

enum WatchTips {
    static let key = "watch.tips.seen"

    static func seen() -> Set<String> {
        Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map(String.init))
    }

    static func markSeen(_ id: String) {
        UserDefaults.standard.set(seen().union([id]).sorted().joined(separator: ","), forKey: key)
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

struct WatchTipCard: View {
    @ObservedObject var watcher: Watcher
    /// How many windows there are to flip between.
    var sessions: Int
    /// The window's height here: a card shows only when it fits over the window with the newest
    /// lines still clear beneath it (the window's question had pushed a card over the answers).
    var room: CGFloat = .greatestFiniteMagnitude
    /// Bumped by Show Tips Again.
    @AppStorage(WatchTips.key) private var seenRaw = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// In the order they're met: the first tap, the picture, the other windows, the switch under
    /// the thumb, the ··· — each only when it works with this Mac.
    private var tips: [WatchTip] {
        var out: [WatchTip] = [watcher.canMouse ? .mouse : watcher.canRightClick ? .click : WatchTip(id: "click", symbol: "hand.tap", title: "Tap to click",
                                                                                                  detail: "A tap is a click there on your Mac.")]
        out.append(watcher.canFitToPhone ? .zoomAndFit : .zoom)
        if sessions > 1 { out.append(.swipe) }
        if watcher.macCanScroll { out.append(.scroll) }
        if watcher.canPressKeys { out.append(.keys) }
        if watcher.input.pages.count > 1 { out.append(.input) }
        return out
    }

    var body: some View {
        let seen = Set(seenRaw.split(separator: ",").map(String.init))
        let open = tips.filter { !seen.contains($0.id) }
        let all = tips
        Group {
            if watcher.phase == .live, room >= 250, let tip = open.first, let at = all.firstIndex(of: tip) {
                card(tip, at: at, of: all.count, left: open.count)
                    .id(tip.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : Motion.settle, value: open.first?.id)
    }

    private func card(_ tip: WatchTip, at: Int, of count: Int, left: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                GlyphPlate(symbol: tip.symbol, tint: Light.cyan, size: 30)
                Kicker("Tip \(at + 1) of \(count)")
                Spacer(minLength: 4)
                Button { dismissAll() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Ink.tertiary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Ink.ink.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Hide tips")
            }
            Text(tip.title)
                .font(.serif(.title3))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(tip.detail)
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { k in
                        Capsule().fill(k == at ? Light.cyan : Ink.lineStrong).frame(width: k == at ? 14 : 4, height: 4)
                    }
                }
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                Button(left > 1 ? "Next" : "Got it") {
                    WatchTips.markSeen(tip.id)
                    seenRaw = UserDefaults.standard.string(forKey: WatchTips.key) ?? ""
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(WatchCellStyle(inset: 16, height: 36))
                .watchGlass(Capsule())
                .accessibilityIdentifier("watch-tip-next")
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .watchGlass(RoundedRectangle(cornerRadius: WatchLook.card, style: .continuous))
        .padding(WatchLook.bezelWidth + 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tip \(at + 1) of \(count): \(tip.title)")
    }

    private func dismissAll() {
        let all = Set(seenRaw.split(separator: ",").map(String.init)).union(tips.map(\.id))
        seenRaw = all.sorted().joined(separator: ",")
    }
}
