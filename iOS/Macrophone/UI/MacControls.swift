import MacrophoneKit
import SwiftUI

// "Control the Mac entirely from the iPhone" (Oct 19 2026): the pieces the menus and the main
// screen share — Mac Controls (the keyboard's top row, its own button and panel), a Whole Screen
// per display, Wake Your Mac.

/// Mac Controls — volume, brightness, play / pause, next, previous — as its own button (Oct 19
/// 2026, Sameer: "Mac controls should be its own button rather than hidden in a sub menu"): a
/// cell in the window view's header, beside Sound, on every page of the carousel; and on the main
/// screen's Send to panel beside ⋯, as its icon alone (Oct 19 2026, Sameer: "Mac control button can just be the logo"). Only with a Mac that named the feature. A tap opens
/// the Mac's Control Center (`MacControlCenter`).
struct MacControlsButton: View {
    enum Style { case cell, round, menuExtra }
    /// Control Center's own glyph, the one Mac Controls wears everywhere (the window's header, the
    /// vertical bar, the menu bar).
    static let symbol = "switch.2"
    @EnvironmentObject var model: AppModel
    var style: Style

    var body: some View {
        Group {
            switch style {
            case .cell:
                Button { open() } label: {
                    Image(systemName: Self.symbol).font(.subheadline.weight(.semibold)).frame(width: 20)
                }
                .buttonStyle(WatchCellStyle(width: 40, height: WatchLook.header))
            case .round:
                // The same round glass as ⋯ beside it.
                Button { open() } label: {
                    Image(systemName: Self.symbol).font(.subheadline.weight(.bold)).frame(width: 20, height: 20)
                }
                .nativeGlassButton()
                .buttonBorderShape(.circle)
                .controlSize(.small)
            case .menuExtra:
                // Control Center's own glyph, in the menu bar where a Mac keeps it.
                Button { open() } label: { Image(systemName: Self.symbol) }
                    .buttonStyle(MenuExtraStyle())
            }
        }
        .accessibilityLabel("Mac Controls")
        .accessibilityHint("Your Mac's volume, brightness, and play, pause, next and previous.")
        .accessibilityIdentifier("mac-controls")
    }

    private func open() {
        model.sheet = .macControls
    }
}

/// The whole screen, as menu items: one entry with one display (as before), one per display with
/// two or more ("Whole Screen — Studio Display"), a check on the one shown.
struct WholeScreenItems: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    @ObservedObject private var reach = MacReach.shared
    /// Words for a menu where it's an action ("See the Whole Screen"), not a place.
    var verb = false
    var subtitle: String? = nil

    var body: some View {
        if reach.several {
            ForEach(reach.displays) { d in
                Button { model.watchWholeScreen(d) } label: {
                    let shown = watcher.isDesktop && (Displays.key(of: watcher.target) ?? reach.lastDisplay?.id) == d.id
                    Label("Whole Screen — \(Displays.name(for: d, among: reach.displays))",
                          systemImage: shown ? "checkmark" : (d.isMain ? "display" : "display.2"))
                    // Short, per display (the polish pass): the one line that tells them apart.
                    if subtitle != nil { Text(d.isMain ? "With the menu bar, live" : "Everything on it, live") }
                }
                .accessibilityIdentifier("whole-screen-\(d.id)")
            }
        } else {
            Button { model.watchWholeScreen() } label: {
                Label(verb ? "See the Whole Screen" : "Whole Screen", systemImage: watcher.isDesktop && !verb ? "checkmark" : "display")
                if let subtitle { Text(subtitle) }
            }
        }
    }
}

/// The whole screen, one tap from the Send to panel (Oct 19 2026, Sameer: "put the whole screen
/// logo next to the Mac controls button"): the round glass of ⋯ and Mac Controls; with several
/// displays, a menu of them.
struct WholeScreenButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    /// A glyph in the menu bar (the phone's desktop, Nov 1 2026) rather than a round glass button.
    var menuExtra = false
    @ObservedObject private var reach = MacReach.shared

    var body: some View {
        Group {
            if menuExtra {
                control.buttonStyle(MenuExtraStyle())
            } else {
                control
                    .nativeGlassButton()
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
            }
        }
        .accessibilityLabel("Whole Screen")
        .accessibilityHint(reach.several ? "Pick a display to see and use, live." : "See and use your Mac's whole screen, live.")
        .accessibilityIdentifier("whole-screen")
    }

    @ViewBuilder private var control: some View {
        if reach.several {
            Menu {
                WholeScreenItems(watcher: watcher)
            } label: { icon }
        } else {
            Button { model.watchWholeScreen() } label: { icon }
        }
    }

    @ViewBuilder private var icon: some View {
        if menuExtra {
            Image(systemName: reach.looksSeveral ? "display.2" : "display")
                .contentTransition(.symbolEffect(.replace))
        } else {
            Image(systemName: reach.several ? "display.2" : "display").font(.subheadline.weight(.bold)).frame(width: 20, height: 20)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

/// Wake Your Mac, beside the Mac's name while it isn't found: only on a network the Mac was on,
/// with what waking it takes kept from a time it was connected.
struct WakeMacButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var reach = MacReach.shared

    var body: some View {
        if model.wakeInfoHere != nil || reach.waking {
            Button { model.wakeMac() } label: {
                Label(reach.waking ? "Waking…" : "Wake Your Mac", systemImage: "power")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(reach.waking ? Ink.tertiary : Ink.ink)
                    .padding(.horizontal, 2)
                    .frame(minHeight: 37)
            }
            .nativeGlassButton()
            .buttonBorderShape(.capsule)
            .disabled(reach.waking)
            .fixedSize()
            .accessibilityHint("Sends your Mac a wake-up signal over this Wi-Fi. Works only on the same network; a closed laptop on battery may not wake.")
            .accessibilityIdentifier("wake-mac")
            .transition(.opacity)
        }
    }
}
