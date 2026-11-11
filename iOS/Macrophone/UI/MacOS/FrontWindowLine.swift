import MacrophoneKit
import SwiftUI

// What's in front on your Mac, as one quiet line (Nov 7 2026): under the desktop card on the
// regular iPhone and the Duo's cover, under the Duo glance's bar on the inner screen. Shown only
// while the Mac's front window isn't the pick; a tap watches it — a look, Send to stays put
// (Model/FrontWindowHere.swift). Its room is kept while the Mac tells the phone what's in front,
// so the card never moves as the line comes and goes.
//
//      ▣  Now on your Mac  Terminal — codex ~/api        👁

enum FrontWindowLook {
    static let height: CGFloat = 36
    /// Between the card (or the glance's bar) and the line.
    static let gap: CGFloat = 8
    /// The line's room, gap included: what a layout keeps for it.
    static var room: CGFloat { height + gap }
}

extension AppModel {
    /// The Mac tells this phone what's in front (its welcome named it, or it already said; while
    /// it connects, what it did last time — `bar.had.front`, as the bar keeps its buttons): the
    /// line's room is kept, shown or not, so nothing moves when the Mac connects.
    var macTellsFront: Bool {
        guard looksConnected else { return false }
        if isConnected { return client.macSendsFrontWindow || macFront != nil }
        return UserDefaults.standard.bool(forKey: "bar.had.front")
    }
}

struct FrontWindowLine: View {
    @EnvironmentObject var model: AppModel
    var window: FrontWindow
    /// The widest it may be (the card's width).
    var width: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var icon: Data? {
        model.liveTargets.first { $0.bundleID == window.bundleID && $0.icon != nil }?.icon
            ?? model.macApps.first { $0.bundleID == window.bundleID }?.icon
    }

    private var kicker: some View {
        Text("Now on your Mac")
            .font(.caption)
            .foregroundStyle(Ink.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var name: some View {
        Text(window.line)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Ink.ink)
            .oneLine()
    }

    var body: some View {
        Button { model.watchFront(window) } label: {
            HStack(spacing: 8) {
                DockTile(target: window.target, icon: icon, size: 22)
                // The kicker goes before the window's name is cut: the name is what's tapped for.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { kicker; name.fixedSize() }
                    HStack(spacing: 8) { kicker; name.frame(minWidth: 120, alignment: .leading) }
                    name
                }
                Image(systemName: "eye")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Light.cyan)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: FrontWindowLook.height)
            .background {
                if #available(iOS 26.0, *), !reduceTransparency {
                    Color.clear.glassEffect(.regular.interactive(), in: Capsule())
                } else {
                    Capsule().fill(.regularMaterial).overlay(Capsule().strokeBorder(Ink.line, lineWidth: 0.5))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Hugs its words, up to the card's width (a long title is cut at its end).
        .frame(maxWidth: width)
        .disabled(!model.isConnected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now on your Mac: \(window.line)")
        .accessibilityHint("Watch it live and control it from here. Send to stays as it is.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("front-window-line")
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}
