import MacrophoneKit
import SwiftUI

// "Control the Mac entirely from the iPhone" (Oct 19 2026): the pieces the menus and the main
// screen share — Mac Controls (the keyboard's top row), a Whole Screen per display, Wake Your Mac.

/// Mac Controls: volume, brightness, play / pause, next, previous — a submenu in the window view's
/// keys menu and in Send to's ⋯. A press keeps the menu open (volume is pressed several times);
/// each gives a tick, and the Mac's answer ("Volume 40%") shows in the status line.
struct MacControlsMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.canMacControls {
            Section {
                Menu {
                    row("Volume", MacControl.volume)
                    row("Brightness", MacControl.brightness)
                    row("Music and Video", MacControl.media)
                    Text("Brightness keys change only a built-in or Apple display.")
                } label: {
                    Label("Mac Controls", systemImage: "slider.horizontal.3")
                    Text("Volume, brightness, play and pause")
                }
                .accessibilityIdentifier("mac-controls")
            }
        }
    }

    private func row(_ title: String, _ controls: [MacControl]) -> some View {
        Section(title) {
            ControlGroup {
                ForEach(controls) { c in
                    Button { model.press(c) } label: { Label(c.title, systemImage: c.symbol) }
                        .menuActionDismissBehavior(.disabled)
                        .accessibilityLabel(c.title)
                        .accessibilityIdentifier("mac-control-\(c.rawValue)")
                }
            }
            .controlGroupStyle(.compactMenu)
        }
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
                    if let subtitle { Text(d.isMain ? "\(subtitle) · with the menu bar" : subtitle) }
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
