import MacrophoneKit
import SwiftUI

// The phone at rest is a little Mac desktop (Nov 1 2026, Sameer: "imagine if apple build a Mac
// controller for the iPhone"): the menu bar across the top, the last dictation as a widget on the
// wallpaper, and the Dock — Send to — just over the Thread and the mic, which stay where they
// always were: the mic is still the reason the app exists.
//
//   [💻 Sameer's MacBook Pro  ⌔         ▭  ⊜  ⏱  ⚙]   menu bar
//   ┌ Terminal · 2 min ago            ✓ ┐
//   │ Fix the login bug where the …     │            widget
//   └ Copy  Send Again          History ┘
//                 (wallpaper)
//   [✈ Send after pasting ●]  [✦ Medium ⌄] [⋯]       the Dock's options
//          ┌ Terminal — claude ┐
//   [■ ■ ■ ■ ■ │ ⎘ ⌶ │ +]                           the Dock
//   ~~~~~~~~~~~~ the Thread ~~~~~~~~~~~~
//                (mic)

/// The phone's menu bar: your Mac's name at the left (a tap opens your Macs, a swipe switches),
/// the menu extras at the right — the whole screen, Control Center, History, Settings.
struct PhoneMenuBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    /// The desktop's empty state has Wake Your Mac (Nov 5 2026): the bar doesn't say it twice.
    var wakeElsewhere = false
    /// What the Mac offered when it was last connected (MainView keeps these, as for the cover's
    /// bar): the extras stay in their places, dimmed, while it connects again — at launch they
    /// popped in a beat after the first frame and pushed History and Settings along (Nov 4 2026).
    @AppStorage("bar.had.wholeScreen") private var hadWholeScreen = false
    @AppStorage("bar.had.controls") private var hadControls = false

    var body: some View {
        MacMenuBar {
            // The name takes what the extras leave and ends in "…" past that, as a Mac's menu
            // bar does — at its full width a long name ("Sameer's MacBook Pro 16-inch") pushed
            // the bar past both sides of the screen, the name cut at the left and Settings gone
            // (Nov 4 2026).
            MacPill(menuBar: true).layoutPriority(1)
            if !wakeElsewhere { WakeMacButton().controlSize(.small) }
        } trailing: {
            // `looksConnected`: back from the background the extras hold as they were while the
            // link comes back (Nov 7 2026); a tap meanwhile waits for it.
            if model.isConnected ? watcher.canWatchDesktop : hadWholeScreen {
                WholeScreenButton(watcher: watcher, menuExtra: true).disabled(!model.looksConnected)
            }
            if model.isConnected ? model.canMacControls : hadControls {
                MacControlsButton(style: .menuExtra).disabled(!model.looksConnected)
            }
            Button { model.sheet = .history } label: { Image(systemName: "clock") }
                .buttonStyle(MenuExtraStyle())
                .accessibilityLabel("History")
                .accessibilityShowsLargeContentViewer { Label("History", systemImage: "clock") }
            Button { model.sheet = .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(MenuExtraStyle())
                .accessibilityLabel("Settings")
                .accessibilityShowsLargeContentViewer { Label("Settings", systemImage: "gearshape") }
        }
        .padding(.horizontal, 6)
    }
}

/// The desktop at rest: the menu bar, the widget, then the Dock and its options in thumb reach.
struct PhoneDesktop: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @ObservedObject var watcher: Watcher
    var compact = false
    var glow: Color = .clear
    /// The vertical bar holds the menu bar's items (the Duo's cover).
    var menuBarHidden = false
    @AppStorage("onboarding.macNudgeDismissed") private var macNudgeDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            if !menuBarHidden { PhoneMenuBar(watcher: watcher) }
            LastDictationWidget(lines: compact ? 2 : 3)
                .padding(.horizontal, Space.margin)
                .padding(.top, compact ? 8 : 14)
            Spacer(minLength: compact ? 10 : 20)
            if model.isPaired {
                DockOptions(settings: settings)
                    .padding(.horizontal, Space.margin)
                SendToDock(current: model.selection.target)
                    .padding(.bottom, compact ? 2 : 6)
            } else {
                QuickControls(settings: settings, compact: compact, glow: glow)
                    .padding(.bottom, compact ? 10 : 18)
            }
        }
    }
}

/// What the next dictation does, under the Dock (Nov 1 2026, Sameer: "the send after pasting
/// toggle and the AI strength toggle … don't quite look like they're placed in the right place"):
/// one bar of glass, centred — Send after pasting (a real switch) · Cleanup's level · ⋯ (a photo,
/// a file, the clipboard, a fresh look at the open apps) — hairlines between, the words shortened
/// only when the full ones don't fit.
struct DockOptions: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @State private var pickingPhoto = false
    @State private var pickingFile = false
    /// The switch's paper plane flies up when it's turned on and when a dictation is sent.
    @State private var flights = 0

    var body: some View {
        let target = model.selection.target
        ViewThatFits(in: .horizontal) {
            bar(target, send: "Send after pasting", short: false)
            bar(target, send: "Send after pasting", short: true)
            bar(target, send: "Send", short: true)
        }
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .macSharePickers(photo: $pickingPhoto, file: $pickingFile, model: model)
        .onChange(of: model.landedChip?.sent == true) { _, sent in if sent { flights += 1 } }
    }

    private func bar(_ target: TargetRef, send: String, short: Bool) -> some View {
        HStack(spacing: 0) {
            sendSwitch(target, words: send)
            hairline
            CleanupMenu(settings: settings, short: short, plain: true) { model.sheet = .customCleanup }
            hairline
            more
        }
        .frame(height: 40)
        .fixedSize(horizontal: true, vertical: false)
        .modifier(OptionGlass())
    }

    private var hairline: some View {
        Rectangle().fill(Ink.line).frame(width: 0.5, height: 20).accessibilityHidden(true)
    }

    private func sendSwitch(_ target: TargetRef, words: String) -> some View {
        let enabled = target.canSend
        let on = enabled && model.sendSetting(for: target)
        return Toggle(isOn: Binding(get: { on }, set: { new in
            Haptics.pick()
            if new { flights += 1 }
            withAnimation(Motion.snap) { model.setSend(new, for: target) }
            model.explain(Places.sentence(for: target, send: new))
        })) {
            Label {
                Text(words)
            } icon: {
                Image(systemName: "paperplane").symbolEffect(.bounce.up.byLayer, value: flights)
            }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(enabled ? Ink.ink : Ink.tertiary)
                .labelStyle(DockOptionLabel())
                .fixedSize()
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Light.cyan)
        .disabled(!enabled)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .accessibilityLabel("Send after pasting. \(Places.sendDetail(target, in: model))")
        .accessibilityIdentifier("send-toggle")
    }

    private var more: some View {
        Menu {
            if model.isConnected {
                Button { model.refreshTargets(); Haptics.press() } label: { Label("Refresh Open Apps", systemImage: "arrow.clockwise") }
                    .accessibilityIdentifier("refresh-apps")
            }
            MacShareItems(pickingPhoto: $pickingPhoto, pickingFile: $pickingFile)
        } label: {
            Image(systemName: "ellipsis").font(.subheadline.weight(.bold)).foregroundStyle(Ink.ink)
                .frame(width: 44, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityHint("Send a photo or file into \(Places.appName(model.selection.target, in: model)), or move the clipboard.")
        .accessibilityIdentifier("send-to-more")
    }
}

/// The glyph in the accent, the words in ink.
private struct DockOptionLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.footnote.weight(.semibold)).foregroundStyle(Light.cyan)
            configuration.title
        }
    }
}

/// A capsule of glass behind a control that isn't a button (the switch).
private struct OptionGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(reduceTransparency ? AnyShapeStyle(Ink.raised) : AnyShapeStyle(.regularMaterial)))
                .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 0.5))
        }
    }
}

/// The wallpaper behind the whole app: the Mac's own when it sent one (it follows the active Mac),
/// the state's light washing in from the foot.
struct DesktopBackground: View {
    @ObservedObject var wallpaper: WallpaperStore
    @ObservedObject var settings: Settings
    var glow: Color

    var body: some View {
        DesktopWallpaper(image: settings.macWallpaper ? wallpaper.image : nil, strength: settings.wallpaperStrength, glow: glow)
    }
}

/// The screen's edge in Apple Intelligence's colours while the mic listens, breathing with the
/// voice (read off the meter 30 times a second — only while the mic is open).
struct ListeningEdge: View {
    var active: Bool
    let meter: LevelMeter
    @State private var level: Double = 0

    var body: some View {
        EdgeGlow(active: active, level: level)
            .task(id: active) {
                guard active else { level = 0; return }
                while !Task.isCancelled {
                    let raw = Double(meter.level)
                    level += (min(1, max(0, raw)) - level) * 0.35
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }
    }
}
