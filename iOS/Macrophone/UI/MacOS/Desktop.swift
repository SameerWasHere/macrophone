import MacrophoneKit
import SwiftUI

// The phone at rest is a little Mac desktop (Nov 1 2026, Sameer: "imagine if apple build a Mac
// controller for the iPhone"): the menu bar across the top, the pick's window on the wallpaper
// (Nov 7 2026, `DesktopWindowCard`), and the Dock — Send to — just over the Thread and the mic,
// which stay where they always were: the mic is still the reason the app exists.
//
//   [💻 Sameer's MacBook Pro  ⌔         ▭  ⊜  ⏱  ⚙]   menu bar
//   ┌ ● ● ● ▣ Terminal  claude      [👁 Watch] ┐
//   │       (the window's kept picture)       │      the pick's window
//   └─────────────────────────────────────────┘
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

/// What the next dictation does, under the Dock (Nov 1 2026, Sameer: "the send after pasting
/// toggle and the AI strength toggle … don't quite look like they're placed in the right place"):
/// one bar of glass, centred, hairlines between. Nov 7 2026 ("what should be easy to access vs
/// buried in a menu"): the two things used every dictation in plain sight — Send after pasting as
/// a toggle that says its state ("Paste only" · "Paste & Send", gone where the pick can't send),
/// Cleanup's level, and Attach (a photo, a file, the clipboard), which had been an unlabelled ⋯.
/// One vocabulary whatever the state (Nov 7 2026, round 4): the toggle says "Paste only" or
/// "Paste & Send", Cleanup the wand and its level's word — Off · Light · Medium · Heavy · Custom,
/// never "Cleanup:" and never "Cleanup off" — and Attach its word. Each segment is as wide as its
/// widest word (the toggle and Cleanup lay every word hidden under the visible one), so the bar
/// is one width on a given phone and a change of level or a landing never re-lays it; the room
/// alone decides, in order: Attach gives up its word, then the toggle says "Send".
struct DockOptions: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @State private var pickingPhoto = false
    @State private var pickingFile = false

    var body: some View {
        let target = model.selection.target
        ViewThatFits(in: .horizontal) {
            bar(target, attachWord: true, sendShort: false)
            bar(target, attachWord: false, sendShort: false)
            bar(target, attachWord: false, sendShort: true)
        }
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .macSharePickers(photo: $pickingPhoto, file: $pickingFile, model: model)
        .animation(Motion.snap, value: target.canSend)
    }

    private func bar(_ target: TargetRef, attachWord: Bool, sendShort: Bool) -> some View {
        HStack(spacing: 0) {
            if target.canSend {
                SendToggle(target: target, plain: true, short: sendShort)
                    .transition(.opacity)
                hairline
            }
            CleanupMenu(settings: settings, short: true, plain: true) { model.sheet = .customCleanup }
            if AttachMenu.available(model) {
                hairline
                AttachMenu(style: attachWord ? .labelled : .glyph, pickingPhoto: $pickingPhoto, pickingFile: $pickingFile)
            }
        }
        .frame(height: 40)
        .fixedSize(horizontal: true, vertical: false)
        .modifier(OptionGlass())
    }

    private var hairline: some View {
        Rectangle().fill(Ink.line).frame(width: 0.5, height: 20).accessibilityHidden(true)
    }
}

/// A capsule of glass behind the options' bar.
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
