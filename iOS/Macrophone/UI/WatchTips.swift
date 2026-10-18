import MacrophoneKit
import SwiftUI

// Tips, the first times you watch (Oct 17 2026, Sameer: "there are some hidden features in this
// app (right click, swipe to switch apps). Can we make it so users can discover these features on
// first use?"). One card at a time over the top of the window — never over its newest lines, where
// you type — each shown until you tap Got it, and only once the thing it names works here (a
// right-click with a Mac that takes them, the side swipe with two windows or more). The Window
// menu's Show Tips Again brings them back.
//
//   ┌──────────────────────────────────────────────┐
//   │ [hand.tap]  Hold to right-click          [×] │
//   │ Tap is a click on your Mac. Hold — or tap    │
//   │ with two fingers — for a right-click.        │
//   │                                 [Got it] 1/4 │
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
    static let swipe = WatchTip(id: "swipe", symbol: "arrow.left.and.right",
                                title: "Swipe in from the side for your other windows",
                                detail: "Start at the very edge of the screen. Or tap the window's name at the top to pick one.")
    static let scroll = WatchTip(id: "scroll", symbol: "scroll",
                                 title: "Pan or Scroll",
                                 detail: "Pan moves your view. Scroll moves the window on your Mac with one finger — two fingers still pan.")
    static let keys = WatchTip(id: "keys", symbol: "ellipsis",
                               title: "More keys",
                               detail: "Control-C, Tab, Command-Return and more are behind ··· beside Return.")
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
    /// Bumped by Show Tips Again.
    @AppStorage(WatchTips.key) private var seenRaw = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tips: [WatchTip] {
        var out: [WatchTip] = [watcher.canRightClick ? .click : WatchTip(id: "click", symbol: "hand.tap", title: "Tap to click",
                                                                       detail: "A tap is a click there on your Mac.")]
        out.append(.zoom)
        if sessions > 1 { out.append(.swipe) }
        if watcher.macCanScroll { out.append(.scroll) }
        if watcher.canPressKeys { out.append(.keys) }
        return out
    }

    var body: some View {
        let seen = Set(seenRaw.split(separator: ",").map(String.init))
        let open = tips.filter { !seen.contains($0.id) }
        Group {
            if watcher.phase == .live, let tip = open.first {
                card(tip, left: open.count)
                    .id(tip.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : Motion.settle, value: open.first?.id)
    }

    private func card(_ tip: WatchTip, left: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: tip.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Light.cyan)
                    .frame(width: 22)
                Text(tip.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { dismissAll() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Ink.tertiary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide tips")
            }
            Text(tip.detail)
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 32)
            HStack {
                if left > 1 {
                    Text("\(left - 1) more").font(.caption).foregroundStyle(Ink.tertiary)
                }
                Spacer()
                Button(left > 1 ? "Next" : "Got it") {
                    Haptics.tick()
                    WatchTips.markSeen(tip.id)
                    seenRaw = UserDefaults.standard.string(forKey: WatchTips.key) ?? ""
                }
                .font(.footnote.weight(.semibold))
                .nativeGlassButton()
                .controlSize(.small)
                .accessibilityIdentifier("watch-tip-next")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Ink.line, lineWidth: 0.5))
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tip: \(tip.title)")
    }

    private func dismissAll() {
        Haptics.tick()
        let all = Set(seenRaw.split(separator: ",").map(String.init)).union(tips.map(\.id))
        seenRaw = all.sorted().joined(separator: ",")
    }
}
