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

    var body: some View {
        MacMenuBar {
            MacPill(menuBar: true).fixedSize()
            WakeMacButton().controlSize(.small)
        } trailing: {
            if model.isConnected, watcher.canWatchDesktop {
                WholeScreenButton(watcher: watcher, menuExtra: true)
            }
            if model.canMacControls {
                MacControlsButton(style: .menuExtra)
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

/// What the next dictation does, over the Dock: Send after pasting (a real switch), Cleanup's
/// level, and ⋯ — a photo, a file, the clipboard, a fresh look at the open apps.
struct DockOptions: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @State private var pickingPhoto = false
    @State private var pickingFile = false

    var body: some View {
        let target = model.selection.target
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    sendSwitch(target, words: "Send after pasting").fixedSize()
                    Spacer(minLength: 0)
                    CleanupMenu(settings: settings, short: true) { model.sheet = .customCleanup }.fixedSize()
                }
                HStack(spacing: 8) {
                    sendSwitch(target, words: "Send").fixedSize()
                    Spacer(minLength: 0)
                    CleanupMenu(settings: settings, short: true) { model.sheet = .customCleanup }.fixedSize()
                }
            }
            more
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .macSharePickers(photo: $pickingPhoto, file: $pickingFile, model: model)
    }

    private func sendSwitch(_ target: TargetRef, words: String) -> some View {
        let enabled = target.canSend
        let on = enabled && model.sendSetting(for: target)
        return Toggle(isOn: Binding(get: { on }, set: { new in
            Haptics.tick()
            withAnimation(Motion.snap) { model.setSend(new, for: target) }
            model.explain(Places.sentence(for: target, send: new))
        })) {
            Label(words, systemImage: "paperplane")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(enabled ? Ink.ink : Ink.tertiary)
                .labelStyle(DockOptionLabel())
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Light.cyan)
        .disabled(!enabled)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minHeight: 36)
        .modifier(OptionGlass())
        .accessibilityLabel("Send after pasting. \(Places.sendDetail(target, in: model))")
        .accessibilityIdentifier("send-toggle")
    }

    private var more: some View {
        Menu {
            if model.isConnected {
                Button { model.refreshTargets(); Haptics.tick() } label: { Label("Refresh Open Apps", systemImage: "arrow.clockwise") }
                    .accessibilityIdentifier("refresh-apps")
            }
            MacShareItems(pickingPhoto: $pickingPhoto, pickingFile: $pickingFile)
        } label: {
            Image(systemName: "ellipsis").font(.subheadline.weight(.bold)).frame(width: 20, height: 20)
        }
        .nativeGlassButton()
        .buttonBorderShape(.circle)
        .controlSize(.small)
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
    var glow: Color

    var body: some View {
        DesktopWallpaper(image: wallpaper.image, glow: glow)
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
