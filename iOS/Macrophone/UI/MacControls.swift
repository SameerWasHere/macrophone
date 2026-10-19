import MacrophoneKit
import SwiftUI

// "Control the Mac entirely from the iPhone" (Oct 19 2026): the pieces the menus and the main
// screen share — Mac Controls (the keyboard's top row, its own button and panel), a Whole Screen
// per display, Wake Your Mac.

/// Mac Controls — volume, brightness, play / pause, next, previous — as its own button (Oct 19
/// 2026, Sameer: "Mac controls should be its own button rather than hidden in a sub menu"): a
/// cell in the window view's header, beside Sound, on every page of the carousel; and on the main
/// screen's Send to panel beside ⋯, as its icon alone (Oct 19 2026, Sameer: "Mac control button can just be the logo"). Only with a Mac that named the feature. A tap opens
/// `MacControlsPanel`. (It was a submenu in the window's ··· keys menu and Send to's ⋯.)
struct MacControlsButton: View {
    enum Style { case cell, round }
    @EnvironmentObject var model: AppModel
    var style: Style

    var body: some View {
        Group {
            switch style {
            case .cell:
                Button { open() } label: {
                    Image(systemName: "slider.horizontal.3").font(.subheadline.weight(.semibold)).frame(width: 20)
                }
                .buttonStyle(WatchCellStyle(width: 40, height: WatchLook.header))
            case .round:
                // The same round glass as ⋯ beside it.
                Button { open() } label: {
                    Image(systemName: "slider.horizontal.3").font(.subheadline.weight(.bold)).frame(width: 20, height: 20)
                }
                .nativeGlassButton()
                .buttonBorderShape(.circle)
                .controlSize(.small)
            }
        }
        .accessibilityLabel("Mac Controls")
        .accessibilityHint("Your Mac's volume, brightness, and play, pause, next and previous.")
        .accessibilityIdentifier("mac-controls")
    }

    private func open() {
        Haptics.tick()
        model.sheet = .macControls
    }
}

/// The controls themselves, a compact sheet in the app's glass: big cells for volume − / mute /
/// +, brightness − / +, and ⏮ ⏯ ⏭, with the Mac's answer ("Volume 56%", a meter) at the top. A
/// press ticks and the sheet stays for the next; a key the Mac can't press says why.
struct MacControlsPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var reach = MacReach.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The sheet's height before its contents are measured. The sheet then takes exactly the
    /// height they need (Oct 19 2026, Sameer: the top was cut off — a fixed 418 was shorter than
    /// the contents at his text size, so they overflowed past the sheet's top edge).
    static let height: CGFloat = 460
    @State private var measured: CGFloat?

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Kicker("Mac Controls")
                    Text(model.macName)
                        .font(.serif(.title3))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Done") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(WatchCellStyle(inset: 14, height: WatchLook.header))
                    .fixedSize()
                    .watchGlass(Capsule())
                    .accessibilityIdentifier("mac-controls-done")
            }
            readout
            cluster("Volume", MacControl.volume)
            cluster("Brightness", MacControl.brightness)
            cluster("Music and Video", MacControl.media)
            Text(reach.lastControl.map { $0.ok ? "" : $0.detail } ?? "")
                .font(.footnote)
                .foregroundStyle(Light.ochre)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 18)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(reach.lastControl?.ok ?? true)
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = ceil($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(measured ?? Self.height)])
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: reach.lastControl)
    }

    /// The Mac's answer to the last key: the volume as words and a meter, or what it did.
    private var readout: some View {
        let r = reach.lastControl
        let volume = r?.volume
        let muted = r?.muted == true
        return HStack(spacing: 12) {
            Image(systemName: muted ? "speaker.slash.fill" : (volume ?? 0) > 0.6 ? "speaker.wave.3.fill" : (volume ?? 0) > 0.2 ? "speaker.wave.2.fill" : "speaker.wave.1.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(muted ? Light.ochre : Light.cyan)
                .frame(width: 22)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 6) {
                Text(words(r))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                    .contentTransition(.numericText())
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.lineStrong)
                        Capsule().fill(muted ? Light.ochre : Light.cyan)
                            .frame(width: max(0, g.size.width * (muted ? 0 : (volume ?? 0))))
                    }
                }
                .frame(height: 4)
                .opacity(volume == nil ? 0.35 : 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .watchGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words(r))
    }

    private func words(_ r: MacControlResult?) -> String {
        guard let r else { return "Press a volume key to see the level" }
        if r.control.isVolume, let line = MacControlResult.volumeLine(r.volume, muted: r.muted) { return line }
        return r.ok ? r.detail : "\(r.control.title) — couldn't"
    }

    private func cluster(_ title: String, _ controls: [MacControl]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(title)
                .padding(.leading, 4)
            HStack(spacing: 0) {
                ForEach(Array(controls.enumerated()), id: \.element) { i, c in
                    if i > 0 { WatchCellDivider() }
                    Button { model.press(c) } label: {
                        Image(systemName: c.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(WatchCellStyle(height: 56))
                    .accessibilityLabel(c.title)
                    .accessibilityHint("Presses it on your Mac.")
                    .accessibilityIdentifier("mac-control-\(c.rawValue)")
                }
            }
            .watchGlass(Capsule())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
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
