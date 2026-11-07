import MacrophoneKit
import SwiftUI
import UIKit

// Watching (Oct 14 2026) — the picked app's window on the Mac, in the area above the Thread:
//
//   ● CLAUDE ⌄ ▬····            [⤡ | ▭] [Done]   the name is a menu of the Mac's windows; the
//   ╔══════════════════════════════════════════╗   dots say where you are; zoom out and the
//   ║  the window, pinned to its newest output ║   Window menu share one piece of glass
//   ║  (centred on the column you type in)     ║   tap = a click there on the Mac; one finger
//   ╚═══════════════════════════════ [Newest] ═╝   looks around (Pan) or scrolls (Scroll)
//   [ Esc | ↑ | ↓ | ⏎ | ··· ]     (Pan | Scroll)   one cluster of keys under the thumb
//
// The look (Oct 18 2026, Sameer: "less generic … quality design and refinement, still Liquid
// Glass"): the window is a screen set in a bezel — a recessed edge, a specular rim, and a glow in
// the state's colour (cyan while it's live) — and every control is a cell in a cluster of one
// piece of glass, 44pt tall, so the row reads as an instrument, not a row of buttons.
//
// The mic, the Thread and the status line don't move. Holding the mic shrinks the window to a
// strip at the top, so the question stays in view while the words take the rest.

/// The watch's own measures, kept here (Theme.swift holds the app's).
enum WatchLook {
    /// The bezel's corner, and the screen's inside it (concentric: the bezel's less its width).
    static let bezel: CGFloat = 20
    static let bezelWidth: CGFloat = 3
    static var screen: CGFloat { bezel - bezelWidth }
    /// Every cell, key, switch and header control.
    /// Trimmed from 44 (Oct 18 2026, Sameer: "make some of the buttons around the window a bit
    /// smaller so we can further increase the square window") — still a comfortable press.
    static let control: CGFloat = 38
    /// The window runs nearer the screen's edges than the page's margin.
    static let sideMargin: CGFloat = 10
    /// The header's controls (name, zoom out, Window, Done): a step under the keys, so the window
    /// gets the room (Sameer, Oct 18 2026).
    static let header: CGFloat = 32
    /// The tip card and the notes over the window.
    static let card: CGFloat = 16
    /// A cell's pressed wash, and the hairline between cells.
    static let press = Ink.ink.opacity(0.14)
}

struct WatchPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    var compact = false
    /// The iPhone Duo's open inner screen (Oct 25 2026): the answers go across in a row, and a
    /// first-run tip keeps to the window's top corner, off its middle.
    var duo = false
    /// The Duo's cover screen (Oct 30 2026): floating answers and keys-only actions like the
    /// inner screen, but tips stay as overlays (the cover has no room for an extra row).
    var cover = false
    /// The window alone, nothing over it (the cover with the keyboard up: every point counts).
    var bare = false
    /// The Duo's inner screen with the laptop deck under it: the keys are the deck's, so no key
    /// row; Pan | Scroll joins the header.
    var deck = false
    /// Built but hidden (the Duo's inner screen, while it glances): its window has no viewer.
    var dormant = false
    /// The window just switched to, named for a moment ("Terminal — codex ~/api").
    @State private var switchedTo: String?
    @State private var switchedTask: Task<Void, Never>?
    /// The window slides in from the side it came from (a swipe's direction, or the menu's).
    @State private var slide: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let floats = duo || cover
        VStack(spacing: compact ? 6 : 8) {
            // Nothing lies over the window (Nov 6 2026, Sameer: "I don't like having anything ever
            // overlaid over the window because it blocks UI elements"): the name is a row above it
            // everywhere — on the cover too, where it had floated over the window's corner — and
            // the answers and the tips are rows under it.
            if !bare { WatchHeaderBar(watcher: watcher, dragSwitch: deck, onSwitched: announce) }
            WatchWindow(watcher: watcher, interactive: true, dormant: dormant)
                .frame(maxHeight: .infinity)
                // The Mac can't take taps or keys yet (Accessibility off): say so, and how.
                .overlay(alignment: .bottom) { MacPermissionBanner(watcher: watcher) }
                .offset(x: slide)
            // The first times: what a tap, a hold, a pinch and the side swipe do — a strip under
            // the window, never a card over it.
            if !bare, !dormant {
                WatchTipCard(watcher: watcher, sessions: sessions.count, inline: true)
            }
            // The Duo (inner screen or cover): the question's answers on a row of their own under
            // the window, the key row under them (on the cover the key row steps aside while a
            // question is up: the answers carry Esc, and Pan | Scroll is in the vertical bar).
            if floats, watcher.answers != nil {
                WatchActions(watcher: watcher, floating: true, oneLine: cover)
                    .watchLive(watcher.phase)
                    .transition(.opacity)
            }
            if !deck, !(cover && watcher.answers != nil) {
                WatchActions(watcher: watcher, keysOnly: floats, dragElsewhere: cover)
                    .watchLive(watcher.phase)
            }
        }
        .animation(reduceMotion ? nil : Motion.settle, value: watcher.answers?.id)
        .padding(.horizontal, WatchLook.sideMargin)
        .padding(.top, 4)
        .padding(.bottom, compact ? 6 : 8)
        // Swipe in from a side edge (in the margin beside the window, under a thumb) for the
        // previous or next window; the menu on the name is the visible way to the same thing.
        .overlay(alignment: .leading) { edge(step: -1) }
        .overlay(alignment: .trailing) { edge(step: 1) }
        .overlay(alignment: .top) {
            if let switchedTo {
                WatchNote(symbol: "arrow.left.and.right", words: switchedTo)
                    .padding(.top, 66)
                    .padding(.horizontal, 32)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .accessibilityAction(named: "Next window") { go(1) }
        .accessibilityAction(named: "Previous window") { go(-1) }
        // The window is a picture; its chrome (the kicker, Done, the keys) stays a moderate size so
        // the whole panel always fits above the Thread — at accessibility sizes it overflowed both ends.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Sessions — the windows to flip between

    private var sessions: [LiveTarget] { model.watchSessions }

    private func go(_ step: Int) {
        if let t = model.watchStep(step) { announce(t, from: step) }
    }

    /// Names the window for a moment, and slides it in from the side it came from.
    private func announce(_ t: LiveTarget, from step: Int) {
        switchedTask?.cancel()
        if !reduceMotion {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { slide = CGFloat(step) * 36 }
            withAnimation(Motion.settle) { slide = 0 }
        }
        withAnimation(.easeOut(duration: 0.15)) { switchedTo = t.title }
        UIAccessibility.post(notification: .announcement, argument: t.title)
        switchedTask = Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { switchedTo = nil }
        }
    }

    /// A strip in the margin beside the window: a swipe in from it flips to the next window.
    private func edge(step: Int) -> some View {
        Color.clear
            .frame(width: 14)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 12).onEnded { v in
                let dx = v.translation.width
                guard abs(dx) > 40, abs(dx) > abs(v.translation.height) else { return }
                // From the right edge, a swipe to the left is the next; from the left, to the right, the previous.
                if (step > 0 && dx < 0) || (step < 0 && dx > 0) { go(step) }
            })
            .accessibilityHidden(true)
    }
}

/// The window view's header — the name as a menu of the Mac's windows (with the page dots), Sound
/// and Mac Controls, zoom out and the Window menu, Done — as one row; on the Duo's book page
/// (Oct 25 2026, `twoRows`) the name and Done on one row and the clusters under them. The panel
/// draws it over the window; a folded Duo draws it at the top of the deck, the window filling
/// the other half.
extension EnvironmentValues {
    /// The iPhone Duo (Nov 1 2026, Sameer: "the same toggles in the side bar … when I open it"):
    /// a screen with a vertical bar keeps Done, Sound, Mac Controls, Pan | Scroll, zoom out and
    /// Window there, on the cover and the inner screen alike — the window's own header shows its
    /// name alone.
    @Entry var controlsInVerticalBar = false
    /// The Duo's inner screen on its side (Nov 3 2026): Full Screen sits beside the window's name.
    @Entry var fullScreenAvailable = false
}

struct WatchHeaderBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    var twoRows = false
    /// Pan | Scroll among the clusters (a folded Duo's overlay header: its deck has no key row).
    var dragSwitch = false
    /// The window's name alone: the Duo cover's buttons are in its vertical bar.
    var nameOnly = false
    /// What sits between the name and the clusters on the one row (the laptop's deck: the
    /// question's answers, so they never take a row of their own from the trackpad).
    var middle: AnyView? = nil
    /// A window picked from the menu, and the side it came from (1 next, -1 previous).
    var onSwitched: (LiveTarget, Int) -> Void = { _, _ in }

    /// The screen's vertical bar holds Done and the window's buttons (the Duo, cover or inner).
    @Environment(\.controlsInVerticalBar) private var inBar
    @Environment(\.fullScreenAvailable) private var fullScreenAvailable

    var body: some View {
        if nameOnly || inBar {
            HStack(spacing: 10) {
                nameDotsIfRoom
                fullScreenButton
                if let middle, !nameOnly {
                    middle.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(minHeight: WatchLook.header)
        } else if twoRows {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    nameDotsIfRoom
                    fullScreenButton
                    Spacer(minLength: 8)
                    done
                }
                HStack(spacing: 10) {
                    clusters()
                    Spacer(minLength: 0)
                }
            }
        } else if let middle {
            HStack(spacing: narrow ? 6 : 10) {
                name()
                fullScreenButton
                middle.frame(maxWidth: .infinity, alignment: .leading)
                clusters()
                done
            }
            .frame(minHeight: WatchLook.header)
            .onGeometryChange(for: Bool.self) { $0.size.width < 380 } action: { narrow = $0 }
        } else {
            // Title first, as a Mac's window and an iOS bar put it (Nov 7 2026, Sameer: the app
            // read "C…" beside four pieces of glass): the row that fits, giving way in order —
            // the page dots, then "Paused ·" before the name, then zoom out (into the Window
            // menu). The app's own name always reads whole; only a row narrower than any phone
            // lets it shrink.
            ViewThatFits(in: .horizontal) {
                row(.full)
                row(.noDots)
                row(.nameAlone)
                row(.zoomInMenu)
                row(.squeezed)
            }
            .frame(minHeight: WatchLook.header)
            .onGeometryChange(for: Bool.self) { $0.size.width < 380 } action: { narrow = $0 }
        }
    }

    /// How much the one row keeps, from all of it to the least.
    private enum Fit { case full, noDots, nameAlone, zoomInMenu, squeezed }

    private func row(_ fit: Fit) -> some View {
        // 8 between the pieces of glass (10 had a Pro's row 3 pt short of keeping zoom out).
        HStack(spacing: narrow ? 6 : 8) {
            name(dots: fit == .full, words: fit == .full || fit == .noDots)
                .fixedSize(horizontal: fit != .squeezed, vertical: false)
            fullScreenButton
            Spacer(minLength: narrow ? 2 : 4)
            clusters(zoomInMenu: fit == .zoomInMenu || fit == .squeezed)
            done
        }
    }

    /// A small phone's row (an SE, 355 pt): the gaps and Done's padding a little tighter, so the
    /// app's name reads whole — it was "Te…" for Terminal there (Nov 4 2026).
    @State private var narrow = false

    private var sessions: [LiveTarget] { model.watchSessions }

    private var current: Int? {
        guard let t = watcher.target else { return nil }
        return sessions.firstIndex { t.matches($0) }
    }

    private func show(_ t: LiveTarget) {
        let was = current
        if model.watchSession(t) {
            let now = sessions.firstIndex { $0.id == t.id }
            onSwitched(t, (was.map { w in (now ?? w) >= w } ?? true) ? 1 : -1)
        }
    }

    /// Every window on the Mac's screen that isn't already one of the places above (Finder, a
    /// dialog, a pop-up — anything).
    private var otherWindows: [LiveTarget] {
        model.everyWindow.filter { w in
            // A listed window is in the list already; an app listed as a whole stands for its
            // window only when that's its one window (its dialogs and panels stay here).
            let alone = model.everyWindow.filter { $0.bundleID == w.bundleID }.count == 1
            return !sessions.contains { $0.bundleID == w.bundleID && ($0.windowKey == w.windowKey || ($0.windowKey == nil && alone)) }
        }
    }

    private func sessionMenu(words: Bool) -> some View {
        Menu {
            // The whole screen first: for a pop-up that isn't in any one window.
            if watcher.canWatchDesktop {
                Section {
                    // One per display when the Mac has two or more (Oct 19 2026).
                    WholeScreenItems(watcher: watcher, subtitle: "Everything on your Mac, live")
                }
            }
            if !otherWindows.isEmpty {
                Section("Every Window") {
                    ForEach(otherWindows) { t in
                        Button { watcher.open(t.ref) } label: {
                            if watcher.target?.matches(t) ?? false { Label(t.title, systemImage: "checkmark") } else { Text(t.title) }
                        }
                    }
                }
            }
            ForEach(sessions) { t in
                Button { show(t) } label: {
                    if watcher.target?.matches(t) ?? false { Label(t.title, systemImage: "checkmark") }
                    else if model.needs(t) != nil { Label(t.title, systemImage: "circlebadge.fill") }
                    else { Text(t.title) }
                    if model.needs(t) != nil, !(watcher.target?.matches(t) ?? false) { Text("Answered you") }
                }
            }
        } label: {
            HStack(spacing: 6) {
                WatchKicker(watcher: watcher, nameOnly: !words)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Ink.tertiary)
            }
            .frame(minHeight: WatchLook.header)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Window: \(watcher.name)")
        .accessibilityHint("Shows another window from your Mac — and sends there. You can also swipe in from the side.")
        .accessibilityIdentifier("watch-sessions")
    }

    /// The window's name (a menu of the Mac's windows when there are others), the bell when it's
    /// on watch for changes, and the page dots. `words`: "Paused · Claude" rather than "Claude".
    @ViewBuilder private func name(dots: Bool = true, words: Bool = true) -> some View {
        HStack(spacing: 8) {
            if sessions.count > 1 || watcher.canWatchDesktop || !model.everyWindow.isEmpty {
                sessionMenu(words: words)
            } else {
                WatchKicker(watcher: watcher, nameOnly: !words)
            }
            if alertOn, !inBar { WatchAlertBadge() }
            if dots, sessions.count > 1, sessions.count <= 8, let i = current {
                WatchPageDots(count: sessions.count, current: i)
            }
        }
        .layoutPriority(1)
        .animation(Motion.snap, value: alertOn)
    }

    /// The name with the page dots when they fit beside it, else without (the controls are in the
    /// vertical bar or on a row of their own).
    private var nameDotsIfRoom: some View {
        ViewThatFits(in: .horizontal) {
            name().fixedSize(horizontal: true, vertical: false)
            name(dots: false)
        }
        .layoutPriority(1)
    }

    /// This window is on watch for changes (the Window menu's Alert Me). The vertical bar, where
    /// there is one, shows its own bell.
    private var alertOn: Bool {
        guard let t = watcher.target else { return false }
        return model.alertWatch(for: t) != nil
    }

    /// The clusters by Done. `zoomInMenu`: zoom out is the Window menu's first item instead of a
    /// cell of its own (a row too narrow for the name otherwise).
    @ViewBuilder private func clusters(zoomInMenu: Bool = false) -> some View {
        // The Mac's sound here, and its volume, brightness and media keys (Oct 19 2026,
        // Sameer: "Mac controls should be its own button rather than hidden in a sub menu"
        // — one tap from any window, on every page): one piece of glass.
        // While the link comes back they hold their places, dimmed (the header never re-lays).
        let sound = model.macAudio.macCanPlay || watcher.heldFeature(MacSound.feature)
        let controls = model.canMacControls || watcher.heldFeature(MacControl.feature)
        if sound || controls {
            HStack(spacing: 0) {
                WatchSoundButton(player: model.macAudio, held: sound)
                if sound, controls { WatchCellDivider() }
                if controls { MacControlsButton(style: .cell).disabled(!model.canMacControls) }
            }
            .watchGlass(Capsule())
        }
        // Alert Me is the Window menu's first item, and the gold bell by the name says it's on
        // (Nov 7 2026: a bell of its own here cost the name its room — "C…").
        if dragSwitch, watcher.phase.holdsLayout {
            WatchDragSwitch(watcher: watcher, style: .glyphs).fixedSize().disabled(watcher.phase != .live)
        }
        if watcher.macCanFit, watcher.target != .clipboard {
            // The whole screen has no window to size, minimize or close: zoom out stays its cell.
            let folded = zoomInMenu && !watcher.isDesktop
            HStack(spacing: 0) {
                if !folded { WatchWholeButton(watcher: watcher) }
                if !watcher.isDesktop {
                    if !folded { WatchCellDivider() }
                    WatchWindowMenu(watcher: watcher, zoomItem: folded)
                }
            }
            .watchGlass(Capsule())
        }
    }

    /// Full Screen: the window takes the whole inner screen, edge to edge (`DuoFullScreen`).
    @ViewBuilder private var fullScreenButton: some View {
        if fullScreenAvailable {
            Button {
                watcher.setFullScreen(true)
            } label: {
                Image(systemName: "arrow.up.backward.and.arrow.down.forward.rectangle")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(WatchCellStyle(width: 42, height: WatchLook.header))
            .watchGlass(Capsule())
            .fixedSize()
            .accessibilityLabel("Full Screen")
            .accessibilityHint("Shows \(watcher.name) on the whole screen.")
            .accessibilityIdentifier("watch-fullscreen")
        }
    }

    private var done: some View {
        Button("Done") {
            watcher.done()
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(WatchCellStyle(inset: narrow ? 11 : 14, height: WatchLook.header))
        .fixedSize()
        .watchGlass(Capsule())
        .accessibilityHint(watcher.glanceOnDone ? "Puts the controls away; the window stays in view." : "Stops showing the window and brings back Send to and Cleanup.")
        .accessibilityIdentifier("watch-done")
    }
}

/// Where you are among the Mac's windows: the one shown is a short bar in the window's light,
/// the others points — and the bar glides when you flip.
struct WatchPageDots: View {
    var count: Int
    var current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { k in
                Capsule()
                    .fill(k == current ? Light.cyan : Ink.lineStrong)
                    .frame(width: k == current ? 14 : 4, height: 4)
            }
        }
        .animation(reduceMotion ? nil : Motion.settle, value: current)
        .accessibilityHidden(true)
    }
}

/// Zoom out (Oct 17 2026, Sameer: "a quick tap ... so that we can see the whole window"): the whole
/// window on screen, and the same button goes back to the column you type in. A cell beside the
/// Window menu, in one piece of glass.
struct WatchWholeButton: View {
    @ObservedObject var watcher: Watcher

    var body: some View {
        Button { watcher.toggleWholeWindow() } label: {
            Image(systemName: watcher.wholeWindow ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(.subheadline.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(WatchCellStyle(width: 42, height: WatchLook.header, tint: watcher.wholeWindow ? Light.cyan : Ink.ink))
        .disabled(watcher.phase != .live)
        .accessibilityLabel(watcher.wholeWindow ? "Zoom back in" : "Show the whole window")
        .accessibilityHint(watcher.wholeWindow ? "Back to the part of the window you type in." : "Fits all of \(watcher.name)'s window on screen.")
        .accessibilityIdentifier("watch-whole")
    }
}

/// The Window menu (Oct 17 2026): everything about the window itself, by how often it's wanted —
/// Fit to iPhone and the text size (how it fits here), sizes laid out on the Mac's screen, minimize
/// and close (asked first), a photo, a file or the clipboard into its chat, and the tips. Picked
/// from a list, since dragging a window's edge on a phone is fiddly (Sill's window controls, the
/// same idea). Tinted while a text size narrows the window.
struct WatchWindowMenu: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    /// A toolbar item (the Duo cover's vertical bar): the system draws it, not a glass cell.
    var bar = false
    /// Zoom out lives here (a header too narrow for its own cell beside the window's name).
    var zoomItem = false
    @State private var confirmClose = false
    @State private var pickingPhoto = false
    @State private var pickingFile = false

    var body: some View {
        Menu {
            // Alerts first: the reason to walk away from a window is knowing when it needs you.
            if let t = watcher.target {
                Section { AlertWatchButton(ref: t) }
            }
            if zoomItem {
                Section {
                    Button { watcher.toggleWholeWindow() } label: {
                        Label(watcher.wholeWindow ? "Zoom Back In" : "Show the Whole Window",
                              systemImage: watcher.wholeWindow ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    }
                    .accessibilityIdentifier("watch-whole")
                }
            }
            if watcher.canFitToPhone {
                Section {
                    Button { watcher.fitToPhone() } label: {
                        Label("Fit to iPhone", systemImage: "iphone.gen3")
                        Text("The whole window, filling this view")
                    }
                }
            }
            // A header over a picker doesn't draw in a menu (iOS 26), so each row says what it is:
            // "Normal text", "Larger text", "Largest text".
            Picker("Text size on this iPhone", selection: Binding(get: { watcher.fit }, set: { watcher.setFit($0) })) {
                ForEach(WatchFit.allCases, id: \.self) { f in Text("\(f.title) text").tag(f) }
            }
            .pickerStyle(.inline)
            if watcher.canWindowCommands {
                Section("Size on your Mac") {
                    ForEach([WatchWindowCommand.fill, .leftHalf, .rightHalf, .middle, .restore], id: \.self) { c in
                        Button { watcher.window(c) } label: { Label(c.title, systemImage: c.symbol) }
                    }
                }
                Section {
                    Button { watcher.window(.minimize) } label: { Label(WatchWindowCommand.minimize.title, systemImage: WatchWindowCommand.minimize.symbol) }
                    Button(role: .destructive) { confirmClose = true } label: {
                        Label(WatchWindowCommand.close.title, systemImage: WatchWindowCommand.close.symbol)
                    }
                }
            }
            // A photo, a file or the clipboard into this window's chat — the same items as the ⋯ by
            // Send to, here because the controls panel is away while a window shows.
            MacShareItems(pickingPhoto: $pickingPhoto, pickingFile: $pickingFile)
            Section {
                Button { WatchTips.reset() } label: { Label("Show Tips Again", systemImage: "lightbulb") }
            }
        } label: {
            if bar {
                Label("Window", systemImage: "macwindow")
            } else {
                Image(systemName: "macwindow")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .modifier(WatchCellUnlessBar(bar: bar, width: 42, tint: watcher.fit == .normal ? Ink.ink : Light.cyan))
        .disabled(watcher.phase != .live)
        .accessibilityLabel("Window")
        .accessibilityHint("Fit to iPhone and the text size here; the window's size, minimize and close on your Mac; a photo, a file or the clipboard into its chat; the tips again.")
        .accessibilityIdentifier("watch-window")
        .macSharePickers(photo: $pickingPhoto, file: $pickingFile, model: model)
        .confirmationDialog("Close \(watcher.name)'s window on your Mac?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close Window", role: .destructive) { watcher.window(.close) }
        } message: {
            Text("If it has unsaved work, your Mac asks first.")
        }
    }
}

/// A header cell's look, except in a toolbar, where the system draws the item.
struct WatchCellUnlessBar: ViewModifier {
    var bar: Bool
    var width: CGFloat
    var tint: Color = Ink.ink

    func body(content: Content) -> some View {
        if bar { content } else { content.buttonStyle(WatchCellStyle(width: width, height: WatchLook.header, tint: tint)) }
    }
}

/// The gold bell beside the window's name while it's on watch for changes: a word, not a control
/// (the Window menu's first item turns it on and off).
struct WatchAlertBadge: View {
    var body: some View {
        Image(systemName: "bell.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Light.gold)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .accessibilityLabel("Alerts on")
            .accessibilityHint("You'll get a notification when this window changes. Turn it off in the Window menu.")
            .accessibilityIdentifier("watch-alert-on")
    }
}

/// "● CLAUDE" (the dot breathing cyan says live), "PAUSED · CLAUDE", "MAC NOT CONNECTED".
struct WatchKicker: View {
    @ObservedObject var watcher: Watcher
    /// The app's name without "Paused ·" or "Opening" (a header with no room for them).
    var nameOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            // Breathes while live, driven by Core Animation: it costs the app nothing per frame
            // (a SwiftUI repeat animation re-rendered the view sixty times a second).
            LiveDot(color: UIColor(color), breathing: watcher.phase == .live && !reduceMotion)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 4)
                .accessibilityHidden(true)
            // Whole words or fewer of them, never cut: "PAUSED · CLAUDE", then "CLAUDE".
            ViewThatFits(in: .horizontal) {
                label(nameOnly && watcher.phase != .offline ? watcher.name : words)
                label(watcher.name)
                label(watcher.name, fits: false).minimumScaleFactor(0.6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("watch-kicker")
        // "Opening …" only once opening has taken a moment, as the window's own note: a window
        // that comes up at once never flashes it (Nov 4 2026 — the name read "Opening Claude",
        // then the two words cross-faded at two widths into "Claude", a beat after it opened).
        .task(id: watcher.phase == .starting) {
            slow = false
            guard watcher.phase == .starting else { return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            slow = true
        }
    }

    @State private var slow = false

    /// `fits`: measured at its full width (a rung of the ladder); the last rung may shrink instead.
    private func label(_ text: String, fits: Bool = true) -> some View {
        // The app's bold name, as a Mac's menu bar starts with the app in front.
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(watcher.phase == .live ? Ink.ink : Ink.tertiary)
            .lineLimit(1)
            .fixedSize(horizontal: fits, vertical: false)
    }

    /// Live: the name alone — the lit dot is the word. Anything else says what's up.
    private var words: String {
        let n = watcher.name
        switch watcher.phase {
        case .starting: return slow ? "Opening \(n)" : n
        case .live: return n
        case .paused(.mac): return "Stopped · \(n)"
        case .paused: return "Paused · \(n)"
        case .needsPermission, .unavailable: return n
        // The link dropped: the capsule over the picture says so; the name stays put.
        case .reconnecting: return n
        case .offline: return "Mac not connected"
        }
    }

    private var spoken: String {
        switch watcher.phase {
        case .live: return "Live · \(watcher.name)"
        case .reconnecting: return "Reconnecting · \(watcher.name)"
        default: return words
        }
    }

    private var color: Color {
        switch watcher.phase {
        case .live: return Light.cyan
        case .starting, .reconnecting: return Ink.tertiary
        case .paused: return Ink.tertiary
        case .needsPermission, .unavailable, .offline: return Light.ochre
        }
    }
}

/// The window itself — a screen set in a bezel, with what's going on laid over it when it isn't live.
struct WatchWindow: View {
    @ObservedObject var watcher: Watcher
    /// The pointer and the modifiers (Oct 19 2026): the viewer draws the pointer and keeps it in view.
    @ObservedObject private var input: MacInput
    var interactive: Bool
    /// The bezel's width and corner: the phone's (3pt, 20), or a folded Duo's half, where the
    /// screen runs almost to the edges (Oct 25 2026).
    var bezelWidth: CGFloat = WatchLook.bezelWidth
    var corner: CGFloat = WatchLook.bezel
    /// The picture fills the view (aspect-fill, scrolling) rather than letterboxing — a folded
    /// Duo's half. The zoom-out button still shows it whole.
    var fill = false
    /// Something floats over the screen's foot (the Duo's answers): the picture's newest lines —
    /// the question — stay above it, so what's answered is never under its answers.
    var footInset: CGFloat = 0
    /// A press and hold taken for something else (full screen's trackpad): true when it was.
    var onHold: ((CGPoint) -> Bool)? = nil
    /// The finger that held moving on, and lifting.
    var onHoldMoved: (CGVector, TimeInterval) -> Void = { _, _ in }
    var onHoldEnded: () -> Void = {}
    /// Built but not on screen (the Duo's inner screen keeps the glance and the window in hand
    /// both built, one hidden — Nov 4 2026): no viewer, so it never takes the video from the one
    /// on screen, nor measures for the window's shape.
    var dormant = false

    init(watcher: Watcher, interactive: Bool, bezelWidth: CGFloat = WatchLook.bezelWidth, corner: CGFloat = WatchLook.bezel, fill: Bool = false, footInset: CGFloat = 0,
         dormant: Bool = false,
         onHold: ((CGPoint) -> Bool)? = nil, onHoldMoved: @escaping (CGVector, TimeInterval) -> Void = { _, _ in }, onHoldEnded: @escaping () -> Void = {}) {
        self.watcher = watcher
        self.dormant = dormant
        self.onHold = onHold
        self.onHoldMoved = onHoldMoved
        self.onHoldEnded = onHoldEnded
        self.interactive = interactive && !dormant
        self.bezelWidth = bezelWidth
        // A Mac's window is square-cornered, so the picture is too, everywhere: a rounded corner
        // only ever cut its corners off (Nov 1 2026, Sameer: "windows are always going to be sharp
        // cornered").
        self.corner = 0
        self.fill = fill
        self.footInset = footInset
        _input = ObservedObject(wrappedValue: watcher.input)
    }
    /// Built and hidden at rest (the phone's kept panel, Nov 7 2026): the viewer stays, holding the
    /// pick's kept picture, so an open builds no viewer — but it takes no touch and tells the
    /// watcher nothing (not its size either: the panel is laid out without its header meanwhile).
    @Environment(\.watchWindowHidden) private var hidden
    @Environment(\.watchRestPicture) private var restPicture
    private var live: Bool { interactive && !hidden }
    /// A moment of words after the Pan | Scroll switch flips or Aa changes: what happens now.
    @State private var dragNote: String?
    @State private var dragNoteTask: Task<Void, Never>?
    /// "Opening …" shows only once a switch has taken a moment: a quick one never flashes it.
    @State private var opening = false
    /// The link has been gone a moment (`WatchReconnect.quietFor`): the held picture's shade shows.
    @State private var heldShown = false
    /// The pointer's sprite and the viewer that places it (the trackpad's pointer, drawn above
    /// everything over the picture).
    @StateObject private var pointer = PointerLink()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let screen = RoundedRectangle(cornerRadius: max(0, corner - bezelWidth), style: .continuous)
        let bezel = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let high = contrast == .increased
        ZStack {
            Ink.sunk
            // Opening: what this window looked like last time, until its first frame (Nov 3
            // 2026). (Nov 4 2026) It's the same viewer as the live picture, handed the kept one
            // until then: drawn as its own picture, whole and dimmed, it was smaller and paler
            // than the live one, so a window showed three looks in a row — an empty plate, a
            // ghost, then the real thing at another scale, the two double-exposed as one faded
            // into the other (and a second viewer, laid out apart from the first as the window
            // grew into its room, never lined up with it). Now the window opens at its own zoom
            // and spot with what it last showed, and only what changed on the Mac changes. It
            // stays under the video for a beat after the first frame: the video layer draws a
            // moment after it's handed the frame, and the plate never shows bare.
            let kept = watcher.hasPicture ? nil : watcher.lastPicture ?? (hidden ? restPicture : nil)
            if watcher.hasPicture || kept != nil, !dormant {
                WindowViewer(image: kept ?? watcher.image ?? watcher.lastPicture, video: watcher.videoSize != nil ? watcher.video : nil, videoSize: watcher.videoSize ?? .zero,
                             focus: watcher.focus, recenter: watcher.recenter, generation: watcher.windowSeq, kept: kept != nil,
                             interactive: live && watcher.phase == .live,
                             drag: watcher.drag, phased: watcher.macCanScroll, fill: fill, footInset: footInset,
                             viewKey: interactive ? watcher.viewKey : nil,
                             pointer: live && input.pointerShown ? input.pointer.point : nil, pointerSeq: input.pointerSeq,
                             canDrag: live && watcher.canMouse, keyboardUp: input.page == .keyboard || input.keysUp,
                             answersUp: watcher.answers != nil,
                             onLog: interactive ? { [weak watcher] in watcher?.log?.add($0) } : nil,
                             onTouch: { watcher.touch() },
                             onTap: { watcher.click($0, count: $1) }, onRightClick: { watcher.rightClick($0) },
                             onHold: live ? onHold : nil,
                             onHoldMoved: onHoldMoved, onHoldEnded: onHoldEnded,
                             onDrag: { watcher.windowDrag($0, at: $1) }, whole: watcher.wholeWindow,
                             onScroll: { watcher.scroll(at: $0, by: $1) },
                             onScrollPhase: { watcher.scrollPhase($0, at: $1) },
                             onAdjusted: { moved in if live { watcher.setMovedAway(moved) } },
                             onWhole: { whole in if live { watcher.wholeShown(whole) } },
                             pointerSprite: live ? pointer.sprite : nil,
                             onReady: { v in
                                 guard live else { return }
                                 pointer.viewer = v
                                 // Where the trackpad's pointer starts: the middle of what shows.
                                 input.visibleCenter = { [weak v] in v?.visibleCenter }
                             })
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { watcher.viewerMeasured($0, fill: fill, interactive: live) }
                    .accessibilityLabel("\(watcher.name)'s window on your Mac")
                    .accessibilityHint(interactive ? (watcher.drag == .pan
                        ? "Tap to click there on your Mac; hold, or tap with two fingers, to right-click. Drag to look around the window; pinch to zoom. Switch to Scroll to scroll the window on your Mac."
                        : "Tap to click there on your Mac; hold, or tap with two fingers, to right-click. Swipe to scroll the window on your Mac; two fingers move the picture.")
                        + (watcher.canMouse ? " Tap twice for a double-click; tap, then hold and move, to drag." : "") : "")
                    .accessibilityAddTraits(.isImage)
            }
            // A switch: the last window's picture stays, dimmed, until the new one's first frame.
            if watcher.stale {
                Ink.ground.opacity(0.5).transition(.opacity).allowsHitTesting(false).accessibilityHidden(true)
            }
            // The link dropped: the last frame holds, a shade darker, one calm word over it — only
            // once it's been gone a moment (a hiccup shows nothing).
            if watcher.phase == .reconnecting, heldShown {
                Ink.ground.opacity(0.32).transition(.opacity).allowsHitTesting(false).accessibilityHidden(true)
                if interactive {
                    ReconnectingCapsule()
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            // The whole screen on the Duo's inner screen is the Mac's screen and nothing else
            // (Nov 1 2026, Sameer: "I don't want any overlays over it"): no Newest, no app chip.
            let bare = fill && watcher.isDesktop
            if interactive && watcher.movedAway && watcher.phase == .live && !bare {
                Button { watcher.showNewest() } label: {
                    Label("Newest", systemImage: "arrow.down.to.line").font(.footnote.weight(.semibold))
                }
                .buttonStyle(WatchCellStyle(inset: 14, height: 36))
                .watchGlass(Capsule())
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .accessibilityHint("Back to the newest output, at the bottom of the window.")
                .accessibilityIdentifier("watch-newest")
            }
            // The whole screen: the app in front, a tap from its own window (tap a window on the
            // screen to bring it forward, then here).
            if interactive, !bare, watcher.isDesktop, watcher.phase == .live, let front = watcher.front {
                WatchFrontChip(front: front)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity)
                    .id(front.bundleID)
            }
            if let dragNote, interactive && watcher.phase == .live {
                WatchNote(symbol: watcher.noteSymbol, words: dragNote)
                    .padding(.top, 10)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            // The trackpad's pointer, above the picture and everything laid over it.
            if interactive {
                PointerOverlay(sprite: pointer.sprite)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if interactive { overlay }
        }
        .clipShape(screen)
        // The screen sits a hair below the bezel: a dark line at its edge is the recess.
        .overlay(screen.strokeBorder(Color.black.opacity(high ? 0 : 0.55), lineWidth: 1))
        .padding(bezelWidth)
        .background {
            // The bezel, and the light under it in the state's colour (a still layer of its own, so
            // the pictures changing above it cost the shadow nothing).
            bezel.fill(Ink.raised)
                .shadow(color: glow.opacity(reduceTransparency ? 0 : glowStrength), radius: 28, y: 6)
                .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.5), radius: 16, y: 10)
        }
        // The rim, lit from above as every plate in the app is.
        .overlay(SpecularEdge(shape: bezel))
        // The window comes alive: one pass of light round its rim as the first picture lands.
        .overlay {
            if interactive && !reduceMotion {
                bezel.strokeBorder(Light.cyan, lineWidth: 1.5)
                    .keyframeAnimator(initialValue: 0.0, trigger: watcher.cameAlive) { ring, a in ring.opacity(a) } keyframes: { _ in
                        CubicKeyframe(0.9, duration: 0.18)
                        CubicKeyframe(0, duration: 0.9)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // A key, an answer or a Window command on its way: the rim answers the moment it's sent,
        // so the input never feels lost while the Mac's next frame is on its way (a click has
        // its ring at the finger instead).
        .overlay {
            if interactive && !reduceMotion {
                bezel.strokeBorder(Light.cyan, lineWidth: 1.5)
                    .keyframeAnimator(initialValue: 0.0, trigger: watcher.inputSeq) { ring, a in ring.opacity(a) } keyframes: { _ in
                        CubicKeyframe(0.7, duration: 0.07)
                        CubicKeyframe(0, duration: 0.33)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: watcher.cameAlive) { _, _ in if interactive { Haptics.arrived() } }
        .onChange(of: watcher.noteSeq) { _, _ in
            guard interactive else { return }
            let words = watcher.noteWords
            UIAccessibility.post(notification: .announcement, argument: words)
            dragNoteTask?.cancel()
            withAnimation(.easeOut(duration: 0.15)) { dragNote = words }
            dragNoteTask = Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.3)) { dragNote = nil }
            }
        }
        .task(id: watcher.phase == .starting && (!watcher.hasPicture || watcher.stale)) {
            opening = false
            guard watcher.phase == .starting, !watcher.hasPicture || watcher.stale else { return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { opening = true }
        }
        .task(id: watcher.phase == .reconnecting) {
            guard watcher.phase == .reconnecting else { heldShown = false; return }
            // A hiccup shows nothing; neither does a return from the background while the link
            // is on its way back (`Watcher.capsuleWait`, Nov 7 2026).
            try? await Task.sleep(nanoseconds: UInt64(watcher.capsuleWait * 1_000_000_000))
            guard !Task.isCancelled, watcher.phase == .reconnecting else { return }
            withAnimation(.easeOut(duration: 0.3)) { heldShown = true }
            if interactive { UIAccessibility.post(notification: .announcement, argument: "Reconnecting to your Mac") }
        }
        .animation(.easeInOut(duration: 0.25), value: watcher.phase)
        .animation(.easeInOut(duration: 0.2), value: watcher.movedAway)
        .animation(.easeInOut(duration: 0.2), value: watcher.stale)
        .animation(.easeInOut(duration: 0.25), value: watcher.hasPicture)
    }

    /// The light under the bezel: the window's state, in the kicker's colour.
    private var glow: Color {
        switch watcher.phase {
        case .live: return Light.cyan
        case .needsPermission, .unavailable, .offline: return Light.ochre
        case .starting, .paused, .reconnecting: return Light.cyan
        }
    }

    private var glowStrength: Double {
        switch watcher.phase {
        case .live: return interactive ? 0.22 : 0.14
        case .needsPermission, .unavailable, .offline: return 0.16
        case .starting, .paused, .reconnecting: return 0.06
        }
    }

    @ViewBuilder private var overlay: some View {
        switch watcher.phase {
        case .live:
            EmptyView()
        case .starting:
            if !watcher.hasPicture || watcher.stale, opening {
                Note(symbol: nil, title: "Opening \(watcher.name)'s window", detail: nil) { ProgressView().tint(Ink.secondary) }
                    .transition(.opacity)
            }
        case .reconnecting:
            // Drawn with the picture's shade (`heldShown`), for the glance too.
            EmptyView()
        case .paused(.leftScreen):
            // The app left the screen: the picture as it was (the app switcher's snapshot, and the
            // moment it's back) — it picks up again by itself.
            EmptyView()
        case .paused(let reason):
            Dimmed {
                Note(symbol: reason == .mac ? "stop.circle" : "pause.circle",
                     title: reason == .mac ? "Stopped from your Mac" : "Paused to save battery",
                     detail: reason == .mac ? "Macrophone's menu on your Mac stopped the pictures. Resume asks for them again." : nil) {
                    Button { watcher.resume() } label: { Label("Resume", systemImage: "play.fill").fontWeight(.semibold) }
                        .watchProminentButton()
                        .accessibilityIdentifier("watch-resume")
                }
            }
        case .offline:
            Dimmed {
                Note(symbol: "wifi.exclamationmark", title: "Your Mac isn't connected",
                     detail: "Macrophone keeps trying — the window comes back the moment it's connected.") { EmptyView() }
            }
        case .needsPermission:
            Dimmed {
                Note(symbol: "rectangle.dashed.badge.record", title: "Your Mac needs to allow Screen Recording",
                     detail: MacPermissionsState.shared.canShowOnMac()
                        ? "Open Macrophone on your Mac — it shows where to turn it on. It only ever shows the app you pick."
                        : "Turn on Macrophone in Privacy & Security › Screen Recording on your Mac. It only ever shows the app you pick.") {
                    // A Mac that can brings Macrophone's permissions forward (a live check as it's
                    // switched on); an older one opens the setting itself.
                    Button {
                        if !MacPermissionsState.shared.openOnMac() { watcher.perform(.openScreenRecordingSettings) }
                    } label: {
                        Text(MacPermissionsState.shared.canShowOnMac() ? "Open Macrophone on my Mac" : "Open the setting on my Mac").fontWeight(.semibold)
                    }
                    .watchProminentButton()
                    .accessibilityIdentifier("watch-open-permission")
                }
            }
        case let .unavailable(why, canReveal):
            Dimmed {
                Note(symbol: "macwindow", title: why, detail: nil) {
                    if canReveal {
                        Button { watcher.perform(.reveal) } label: { Text("Show it on my Mac").fontWeight(.semibold) }
                            .watchProminentButton()
                    }
                }
            }
        }
    }

    /// Over the held picture while the link comes back: a spinner and one word, on a capsule of
    /// glass in the middle of the window (FaceTime's frozen frame, in the app's look).
    private struct ReconnectingCapsule: View {
        var body: some View {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Ink.secondary)
                Text("Reconnecting…").font(.footnote.weight(.semibold)).foregroundStyle(Ink.ink)
            }
            .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 9)
            .watchGlass(Capsule())
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reconnecting to your Mac")
            .accessibilityIdentifier("watch-reconnecting")
        }
    }

    /// The last picture, darkened, under a note — or the plain plate when there's no picture.
    private struct Dimmed<Content: View>: View {
        @ViewBuilder var content: Content
        var body: some View {
            ZStack {
                Ink.ground.opacity(0.78)
                content
            }
        }
    }

    /// What's going on, over the picture, on a card of glass so it reads over any window: a
    /// symbol on a disc, a line, a word or two more, and what to do about it.
    private struct Note<Action: View>: View {
        var symbol: String?
        var title: String
        var detail: String?
        @ViewBuilder var action: Action
        var body: some View {
            VStack(spacing: 12) {
                if let symbol {
                    GlyphPlate(symbol: symbol, tint: Ink.secondary, size: 44)
                }
                VStack(spacing: 6) {
                    Text(title).font(.headline).foregroundStyle(Ink.ink)
                    if let detail {
                        Text(detail).font(.footnote).foregroundStyle(Ink.secondary)
                    }
                }
                action.padding(.top, 2)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: 320)
            .watchGlass(RoundedRectangle(cornerRadius: WatchLook.card, style: .continuous))
            .padding(.horizontal, 20)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
    }
}

/// A sentence over the window for a moment — what just changed, or the window just switched to.
struct WatchNote: View {
    var symbol: String
    var words: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(Light.cyan)
            Text(words)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Ink.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 8)
        .watchGlass(Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: The cluster — one piece of glass, cells inside it

/// A control's glass: Liquid Glass on iOS 26+, else thin material over the raised ink with a
/// hairline. Reduce Transparency: a solid plate; Increase Contrast: a firm edge.
private struct WatchGlassPlate<S: InsettableShape>: ViewModifier {
    var shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let high = contrast == .increased
        if #available(iOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(.regular, in: shape)
                .overlay { if high { shape.strokeBorder(Ink.ink.opacity(0.45), lineWidth: 1) } }
        } else {
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(Ink.raised.opacity(reduceTransparency ? 0.95 : 0.55)))
                }
                .overlay(shape.strokeBorder(high ? Ink.ink.opacity(0.45) : Ink.lineStrong, lineWidth: 1))
        }
    }
}

extension View {
    /// The watch's glass, in a shape (a capsule for a cluster, a rounded rect for a card).
    func watchGlass<S: InsettableShape>(_ shape: S) -> some View { modifier(WatchGlassPlate(shape: shape)) }
}

/// A cell in a cluster: 44pt tall, its label in the tint, a wash while pressed. `width` fixes it;
/// `inset` pads a word; neither, and it shares the cluster's width with its neighbours.
struct WatchCellStyle: ButtonStyle {
    var width: CGFloat? = nil
    var inset: CGFloat = 0
    var height: CGFloat = WatchLook.control
    var tint: Color = Ink.ink
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, inset)
            .frame(width: width)
            .frame(maxWidth: width == nil && inset == 0 ? .infinity : nil, minHeight: height)
            .background(Capsule().fill(WatchLook.press).opacity(configuration.isPressed ? 1 : 0).padding(3))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The hairline between two cells.
struct WatchCellDivider: View {
    var body: some View {
        Rectangle().fill(Ink.lineStrong).frame(width: 1, height: 16).accessibilityHidden(true)
    }
}

/// Pan | Scroll — what one finger does on the window. Pan (the default) moves around the picture;
/// Scroll scrolls the window on the Mac, right where the finger is (and two fingers move the
/// picture). It ends the key row on the right, where the thumb rests, so a watched window works
/// with one hand.
struct WatchDragSwitch: View {
    /// How much of each option shows: the word (the usual), the glyph when the row is too narrow
    /// for the words, or both (the full form, kept for a wide row that asks for it). The key row
    /// and the answers' row pick the same form, so the switch never changes shape between them.
    enum Style { case full, words, glyphs }
    @ObservedObject var watcher: Watcher
    var style: Style = .words
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            option(.pan, "Pan", symbol: "hand.draw")
            option(.scroll, "Scroll", symbol: "arrow.up.and.down")
        }
        .padding(3)
        .watchGlass(Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What one finger does")
    }

    private func option(_ d: Watcher.Drag, _ title: String, symbol: String) -> some View {
        let on = watcher.drag == d
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) { watcher.setDrag(d) }
        } label: {
            Group {
                switch style {
                case .full: Label(title, systemImage: symbol)
                case .words: Text(title)
                case .glyphs: Image(systemName: symbol).accessibilityLabel(title)
                }
            }
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(on ? Ink.onTint : Ink.secondary)
                .padding(.horizontal, style == .glyphs ? 13 : 12)
                .frame(minHeight: WatchLook.control - 6)
                .background {
                    if on {
                        Capsule().fill(Light.cyan)
                            // Lit along its top, as the keys' glass is (the gradient masked by
                            // the hairline, so the GPU draws it — `SpecularEdge`).
                            .overlay(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .bottom).mask(Capsule().strokeBorder(lineWidth: 1)))
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(d == .pan ? "One finger moves around the picture." : "One finger scrolls the window on your Mac.")
        .accessibilityIdentifier("watch-drag-\(d.rawValue)")
    }
}

/// While the mic is open: the bottom of the window, small, so the question stays in view; its
/// top dissolves — the window goes on above it.
struct WatchStrip: View {
    @ObservedObject var watcher: Watcher
    var compact = false

    var body: some View {
        WatchWindow(watcher: watcher, interactive: false)
            .frame(height: compact ? 72 : 104)
            .edgeFade(top: compact ? 20 : 28, bottom: 0)
            .opacity(watcher.hasPicture ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// Esc · ↑ · ↓ · Return — the same four keys in every app (Sameer, Oct 14 2026: "basic things
/// that allow the user to navigate very quickly or confirm things very quickly") — and Pan | Scroll,
/// all on one row under the thumb (Oct 16 2026). The keys are cells of one cluster. While the
/// window asks a question, its answers take the keys' place ("the buttons should replace the
/// default up, down, return, esc buttons").
///
/// The answers (Nov 7 2026): one component everywhere, never taller than two rows and never cut
/// mid-word. Each is a chip — its number and its words to a word's end, about 24 letters, the
/// rest a long press away (and all of it to VoiceOver). A phone's room is one row that scrolls
/// sideways, Esc first, the far end fading while there's more; a wide room (the Duo's pages, the
/// laptop's deck, 560 pt or more) wraps them onto two rows, then scrolls. On a phone the row is as
/// tall as the key row it replaces, so a question coming or going never moves the window.
struct WatchActions: View {
    @ObservedObject var watcher: Watcher
    /// Which input page is up: with the keyboard, its own bar carries Esc, the arrows and Return,
    /// so this row steps aside and the window keeps the room (the polish pass, Oct 19 2026).
    @ObservedObject private var input: MacInput
    /// Kept for its callers: the room's own width decides how the answers lay out now.
    var wide = false
    /// The Duo (a folded half, the inner screen, the cover): the answers alone, on a row of their
    /// own — Esc first, nothing else (the keys are elsewhere). Nothing to answer: nothing shows.
    var floating = false
    /// The keys alone (Esc · ↑ · ↓ · Return · ··· and Pan | Scroll), whatever the window asks —
    /// its answers are a row of their own (the Duo).
    var keysOnly = false
    /// Kept for its callers: every phone-width room is one row now, and a wide one two.
    var oneLine = false
    /// Pan | Scroll lives elsewhere (the Duo cover's vertical bar): the keys alone, centred.
    var dragElsewhere = false
    /// The row's width, measured: 560 pt or more is a wide room.
    @State private var room: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(watcher: Watcher, wide: Bool = false, floating: Bool = false, keysOnly: Bool = false, oneLine: Bool = false, dragElsewhere: Bool = false) {
        self.dragElsewhere = dragElsewhere
        self.watcher = watcher
        self.wide = wide
        self.floating = floating
        self.keysOnly = keysOnly
        self.oneLine = oneLine
        _input = ObservedObject(wrappedValue: watcher.input)
    }

    /// The keyboard has risen (not just been asked for): the key row gives way with it.
    private var keyboardUp: Bool { input.keysUp }

    /// A room this wide takes the answers on two rows.
    static let wideRoom: CGFloat = 560

    var body: some View {
        Group {
            if let p = watcher.answers, !keysOnly {
                answers(p)
                    .transition(.opacity)
            } else if !keyboardUp, !floating {
                keys.transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: watcher.answers?.id)
        // The keyboard's own motion (`MacInput.keysUp` changes inside it), not a spring of its own.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// The question's answers: the one the arrows are on — what Return would pick — stands out
    /// in the window's light; a tap on any of them answers. Esc leads (with the keyboard up it's
    /// on the keyboard's bar); on a phone "Keys" ends the row (the arrows and Return instead of
    /// these) and Pan | Scroll stays where the key row had it.
    private func answers(_ p: WatchPrompt) -> some View {
        HStack(spacing: 8) {
            WatchChipScroller(rows: room >= Self.wideRoom ? 2 : 1) {
                if !keyboardUp {
                    key(.escape, label: Text("Esc"), name: "Escape", inset: 16)
                        .watchGlass(Capsule())
                        .fixedSize()
                }
                ForEach(Array(p.choices.enumerated()), id: \.offset) { i, c in
                    answer(p, i, c)
                }
                if !floating {
                    Button { watcher.showKeys() } label: {
                        Label("Keys", systemImage: "keyboard").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(WatchCellStyle(inset: 16))
                    .watchGlass(Capsule())
                    .fixedSize()
                    .accessibilityHint("Shows Esc, the arrows and Return instead of these answers.")
                    .accessibilityIdentifier("watch-keys")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(p.question ?? "\(watcher.name) is asking")
            .accessibilityIdentifier("watch-answers")
            if !floating, !dragElsewhere, !keyboardUp {
                WatchDragSwitch(watcher: watcher, style: .words).fixedSize()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
    }

    private func answer(_ p: WatchPrompt, _ i: Int, _ c: WatchPrompt.Choice) -> some View {
        let lit = p.highlighted == i
        let short = Self.chipWords(c.label)
        return Button { watcher.choose(i) } label: {
            HStack(spacing: 8) {
                if let mark = c.number.map(String.init) ?? c.key {
                    Text(mark)
                        .font(.mono(.caption, weight: .semibold))
                        .foregroundStyle(lit ? Ink.onTint.opacity(0.8) : Ink.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(lit ? Ink.onTint.opacity(0.14) : Ink.ink.opacity(0.08)))
                }
                Text(short)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(lit ? Ink.onTint : Ink.ink)
                    .lineLimit(1)
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .frame(minHeight: WatchLook.control)
            .contentShape(WatchAnswerStyle.shape)
        }
        .buttonStyle(WatchAnswerStyle(lit: lit))
        .fixedSize()
        // The whole answer, a long press away (a chip shows its first words).
        .contextMenu {
            Button { watcher.choose(i) } label: { Label("Answer", systemImage: "return") }
        } preview: {
            Text(c.label)
                .font(.body.weight(.semibold))
                .foregroundStyle(Ink.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, alignment: .leading)
                .padding(16)
        }
        .accessibilityLabel(c.label)
        .accessibilityHint(lit ? "What Return picks now. Answers \(watcher.name) on your Mac." : "Answers \(watcher.name) on your Mac.")
        .accessibilityIdentifier("watch-answer-\(i)")
    }

    /// An answer's words for its chip: whole words up to about `limit` letters, then "…" — never
    /// a word cut in two, never a dangling comma ("Yes, and don't ask again this session" →
    /// "Yes, and don't ask again…").
    static func chipWords(_ s: String, limit: Int = 24) -> String {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit + 1 else { return text }
        var out = ""
        for word in text.split(separator: " ") {
            let next = out.isEmpty ? String(word) : out + " " + word
            if next.count > limit { break }
            out = next
        }
        // One word longer than the chip: its first letters.
        if out.isEmpty { out = String(text.prefix(limit)) }
        while let last = out.last, ",;:.-–—".contains(last) { out.removeLast() }
        return out + "…"
    }

    /// The row at the widest it fits: Pan | Scroll as words, else as glyphs (Oct 18 2026 — with
    /// glyphs and words the row was 381pt, so on every phone it overflowed the margins by a few
    /// points each side and widened the whole panel with it).
    private var keys: some View {
        ViewThatFits(in: .horizontal) {
            keyRow(.words)
            keyRow(.glyphs)
        }
    }

    private func keyRow(_ style: WatchDragSwitch.Style) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                key(.escape, label: Text("Esc"), name: "Escape")
                WatchCellDivider()
                key(.arrowUp, label: Image(systemName: "arrow.up"), name: "Up arrow")
                WatchCellDivider()
                key(.arrowDown, label: Image(systemName: "arrow.down"), name: "Down arrow")
                WatchCellDivider()
                key(.returnKey, label: Image(systemName: "return"), name: "Return")
                if watcher.canPressKeys {
                    WatchCellDivider()
                    moreKeys
                }
            }
            .watchGlass(Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Keys")
            if !dragElsewhere {
                WatchDragSwitch(watcher: watcher, style: style)
                    .fixedSize()
            }
        }
        .frame(maxWidth: dragElsewhere ? .infinity : nil)
    }

    /// More keys, from a menu (a Mac that can): what each does, with its keys under it, by section;
    /// the digits as one row at the foot.
    private var moreKeys: some View {
        Menu {
            // (Mac Controls — volume, brightness, media — is the header's own button since the
            // carousel fixes, Oct 19 2026; it was a submenu here.)
            ForEach(watcher.input.canHoldKeys ? WatchKey.menuSections : WatchKey.sections) { section in
                Section(section.title) {
                    ForEach(section.keys) { k in
                        Button {
                            // The app switcher holds ⌘ (the Mac names "keyHold"); every other key is a press.
                            if k == .appSwitcher { watcher.input.switchApp() } else { watcher.press(k) }
                        } label: {
                            Text(k.title)
                            Text(k.glyph)
                        }
                        .accessibilityLabel("\(k.title), \(k.name)")
                    }
                }
            }
            Section("Numbers") {
                ControlGroup {
                    ForEach(WatchKey.digits) { k in
                        Button(k.glyph) { watcher.press(k) }.accessibilityLabel(k.key)
                    }
                }
                .controlGroupStyle(.compactMenu)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(WatchCellStyle(tint: Ink.secondary))
        .accessibilityLabel("More keys")
        .accessibilityHint("Interrupt, Tab, Send, Undo, the arrows and more, pressed in \(watcher.name) on your Mac.")
        .accessibilityIdentifier("watch-more-keys")
    }

    private func key<L: View>(_ a: WatchAction, label: L, name: String, inset: CGFloat = 0) -> some View {
        Button { watcher.perform(a) } label: {
            label
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(WatchCellStyle(inset: inset))
        .accessibilityLabel(name)
        .accessibilityHint("Presses \(name) in \(watcher.name) on your Mac.")
        .accessibilityIdentifier("watch-\(a.rawValue)")
    }
}

/// An answer: glass, or — for the one Return would pick — filled with the window's light.
private struct WatchAnswerStyle: ButtonStyle {
    var lit: Bool
    /// A capsule at one line; a two-line answer keeps the same corner instead of a bulging end.
    static let shape = RoundedRectangle(cornerRadius: WatchLook.control / 2, style: .continuous)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        let shape = Self.shape
        Group {
            if lit {
                configuration.label
                    .background {
                        shape.fill(Light.cyan)
                            .overlay(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .bottom).mask(shape.strokeBorder(lineWidth: 1)))
                            .shadow(color: Light.cyan.opacity(reduceTransparency ? 0 : 0.3), radius: 12, y: 4)
                    }
            } else {
                configuration.label
                    .background(shape.fill(WatchLook.press).opacity(configuration.isPressed ? 1 : 0))
                    .watchGlass(shape)
            }
        }
        .opacity(configuration.isPressed ? 0.85 : 1)
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Chips in a row that scrolls sideways — on `rows` rows when there's room to wrap first — with
/// the side that hides more fading out, so the row reads as one that scrolls. Cut at its own
/// sides only: the glass's shadows still spill above and below.
struct WatchChipScroller<Content: View>: View {
    var rows = 1
    @ViewBuilder var content: Content
    @State private var width: CGFloat = 0
    @State private var more = WatchScrollMore()
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            WatchChipRows(rows: rows, room: width) { content }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                    contentWidth = w
                    if #unavailable(iOS 18.0) { more = WatchScrollMore(before: false, after: w > width + 1) }
                }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .modifier(ScrollEdges(more: $more))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            width = w
            if #unavailable(iOS 18.0) { more = WatchScrollMore(before: false, after: contentWidth > w + 1) }
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [more.before ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 20)
                Color.black
                LinearGradient(colors: [.black, more.after ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 36)
            }
            .padding(.vertical, -24)
        }
    }
}

/// Which sides of a sideways scroll hide more (iOS 18+: from the scroll's own geometry; iOS 17
/// sets it from the widths alone).
struct WatchScrollMore: Equatable { var before = false, after = false }

private struct ScrollEdges: ViewModifier {
    @Binding var more: WatchScrollMore

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: WatchScrollMore.self) { g in
                let x = g.contentOffset.x + g.contentInsets.leading
                return .init(before: x > 1, after: x + g.containerSize.width < g.contentSize.width - 1)
            } action: { _, m in
                withAnimation(.easeOut(duration: 0.18)) { more = m }
            }
        } else {
            content
        }
    }
}

/// Lays chips left to right, wrapping onto at most `rows` rows of `room`; when they need more than
/// that, the rows grow wider than the room (the scroll view around them scrolls) — never a third.
struct WatchChipRows: Layout {
    var rows = 1
    var room: CGFloat
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    private func lines(_ widths: [CGFloat], in width: CGFloat) -> [[Int]] {
        var out: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, w) in widths.enumerated() {
            if !out[out.count - 1].isEmpty, x + spacing + w > width {
                out.append([i]); x = w
            } else {
                x += (out[out.count - 1].isEmpty ? 0 : spacing) + w
                out[out.count - 1].append(i)
            }
        }
        return out
    }

    private func arrange(_ sizes: [CGSize]) -> [[Int]] {
        let widths = sizes.map(\.width)
        guard rows > 1, room > 0, !widths.isEmpty else { return [Array(widths.indices)] }
        var width = max(room, widths.max() ?? 0)
        var l = lines(widths, in: width)
        while l.count > rows { width += 12; l = lines(widths, in: width) }
        return l
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let l = arrange(sizes)
        let w = l.map { line in line.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(max(0, line.count - 1)) }.max() ?? 0
        let h = l.map { line in line.map { sizes[$0].height }.max() ?? 0 }.reduce(0, +) + rowSpacing * CGFloat(max(0, l.count - 1))
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in arrange(sizes) {
            let h = line.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for i in line {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - sizes[i].height) / 2), proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += h + rowSpacing
        }
    }
}

private extension View {
    @ViewBuilder func watchProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Light.cyan).foregroundStyle(Ink.onTint)
        } else {
            buttonStyle(.borderedProminent).tint(Light.cyan).foregroundStyle(Ink.onTint)
        }
    }
}

// MARK: The zoomable picture

/// The window's picture in a zooming scroll view: it opens on the column you type in, at the
/// bottom (the newest output), and stays there as pictures arrive — until you zoom or drag, then
/// it stays where you put it (Newest brings it back). A tap is a click there on the Mac, with a
/// ring where it landed. One finger moves the picture (Pan, the default) or scrolls the Mac's
/// window right there (Scroll — Sameer, Oct 14 2026: "swipe gestures could trigger small scrolls
/// … where the swipe occurs"); in Scroll, two fingers move the picture; a pinch zooms it.
///
/// A swipe is a trackpad gesture on the Mac (Oct 17 2026): its deltas go once a display frame,
/// bracketed by where the finger is (landed, lifted), and a flick coasts — the phone steps the
/// momentum on a display link and sends it, so the Mac's window keeps moving after the finger
/// lifts, as under a trackpad. A Mac from before gets the deltas alone, and one flick delta.
///
/// The window is a picture (`image`) or video (`video`, the Watcher's one `VideoCanvas`, which
/// this viewer hosts over the picture while video flows — taken over from whichever viewer had it,
/// the strip or the window, which keeps a snapshot for its fade-out).
struct WindowViewer: UIViewRepresentable {
    var image: UIImage?
    var video: VideoCanvas?
    var videoSize: CGSize
    var focus: CGRect?
    var recenter: Int
    /// Which window this is (bumped on a switch): a new one starts its view fresh.
    var generation: Int = 0
    /// The picture is the window's kept one (`Watcher.lastPicture`), until its first frame.
    var kept = false
    var interactive: Bool
    var drag: Watcher.Drag
    /// The Mac takes a swipe's phases (it named "scroll").
    var phased: Bool
    /// The picture fills the view (a folded Duo's half): it opens at the scale that covers the
    /// view, scrolling, instead of letterboxed; the whole window is still a zoom-out away.
    var fill = false
    /// Something floats over the view's foot: the picture's newest lines stay above it.
    var footInset: CGFloat = 0
    /// Where this viewer remembers the zoom you left it at (the window's, per app); nil: the strip.
    var viewKey: String? = nil
    /// The pointer the trackpad moves (a fraction of the window), drawn over the picture; nil = none.
    var pointer: CGPoint? = nil
    /// Bumped with each move: the view keeps the pointer in sight.
    var pointerSeq = 0
    /// The Mac takes drags (a tap, then a hold that moves).
    var canDrag = false
    /// The keyboard page is up: the view's height changing keeps the zoom.
    var keyboardUp = false
    /// The window's question has answers showing: their row coming or going keeps the zoom too.
    var answersUp = false
    /// A line for the diagnostics log (the window in hand only).
    var onLog: ((String) -> Void)? = nil
    var onTouch: () -> Void
    /// A tap, with its count (2 = a double-click's second click, 3 a triple's).
    var onTap: (CGPoint, Int) -> Void
    /// A press and hold or a two-finger tap; returns whether the Mac takes right-clicks.
    var onRightClick: (CGPoint) -> Bool = { _ in false }
    /// A press and hold taken for something else (full screen's trackpad), at a point in the
    /// view; true when it was — no right-click then.
    var onHold: ((CGPoint) -> Bool)? = nil
    /// The finger that held goes on moving (the pad it brought up follows it), and lifts.
    var onHoldMoved: (CGVector, TimeInterval) -> Void = { _, _ in }
    var onHoldEnded: () -> Void = {}
    /// A drag: the button pressed, moved, released — at fractions of the window.
    var onDrag: (WatchMouseEvent.Kind, CGPoint) -> Void = { _, _ in }
    /// The whole window on screen (the zoom-out button).
    var whole = false
    var onScroll: (CGPoint, CGVector) -> Void
    var onScrollPhase: (WatchScrollPhase, CGPoint) -> Void
    var onAdjusted: (Bool) -> Void
    /// The whole window is on screen (fully zoomed out), or no longer is.
    var onWhole: (Bool) -> Void = { _ in }
    /// The pointer's sprite, placed by this view (the window's stack draws it above everything).
    var pointerSprite: PointerSpriteView? = nil
    /// The view, once made and on every update: the window hands it what needs it.
    var onReady: (ViewerScrollView) -> Void = { _ in }

    func makeUIView(context: Context) -> ViewerScrollView {
        let v = ViewerScrollView()
        wire(v)
        return v
    }

    func updateUIView(_ v: ViewerScrollView, context: Context) {
        wire(v)
        v.viewKey = viewKey
        v.canDrag = canDrag
        v.keyboardUp = keyboardUp
        v.answersUp = answersUp
        v.onLog = onLog
        v.fill = fill
        v.footInset = footInset
        v.kept = kept
        v.update(image: image, video: video, videoSize: videoSize, focus: focus, recenter: recenter, generation: generation, interactive: interactive, drag: drag, phased: phased)
        v.showWhole(whole)
        v.setPointer(pointer, seq: pointerSeq)
    }

    private func wire(_ v: ViewerScrollView) {
        v.onTouch = onTouch
        v.onTap = onTap
        v.onRightClick = onRightClick
        v.onHold = onHold
        v.onHoldMoved = onHoldMoved
        v.onHoldEnded = onHoldEnded
        v.onDrag = onDrag
        v.onScroll = onScroll
        v.onScrollPhase = onScrollPhase
        v.onAdjusted = onAdjusted
        v.onWholeShown = onWhole
        v.pointerHost = pointerSprite
        onReady(v)
    }
}

final class ViewerScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// What zooms: the picture, with the video canvas over it while video flows.
    private let canvas = UIView()
    /// Fires the moment a finger lands (a press with no wait, beside every other gesture): a
    /// mark under the finger says the touch is registered before the tap, the hold or the drag
    /// has decided what it is.
    private var touchDown: UILongPressGestureRecognizer!
    private var pressMark: CALayer?
    private var pressMarkTask: Task<Void, Never>?
    private let imageView = UIImageView()
    private var imageSize: CGSize = .zero
    /// What's up is the window's kept picture: the first frame lands in its place, framed the
    /// same, with no dissolve (one only showed the video at its raw size for a few frames).
    var kept = false
    private var keptShown = false
    private var focus: CGRect?
    /// The person zoomed or dragged: leave the view where they put it.
    private var adjusted = false { didSet { if adjusted != oldValue { onAdjusted(adjusted) } } }
    private var lastRecenter: Int?
    private var lastGeneration = 0
    /// A picture has been up: the next size change dissolves instead of jumping.
    private var hadPicture = false
    private var lastBounds: CGSize = .zero
    /// The keyboard page is up (Nov 4 2026, Sameer: "I don't want the window to auto zoom when
    /// I open the keyboard"): the view getting shorter as it rises, and taller as it goes, keeps
    /// the zoom and the spot — the newest lines stay in view if they were.
    var keyboardUp = false {
        didSet {
            guard keyboardUp != oldValue, !keyboardUp else { return }
            // The keyboard's way down settles within a second; after that a height change is
            // the view's own again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.keyboardUp == false { self?.heightBeforeKeyboard = nil }
            }
        }
    }
    /// The view's height before the keyboard came, while it's up or on its way down.
    private var heightBeforeKeyboard: CGFloat?
    /// A question's answers came or went (Nov 7 2026): their row is there only while it asks, so
    /// for a moment after, a change of the view's height alone keeps the zoom and the spot as
    /// the keyboard's does — the picture never re-fits to another zoom in one jump.
    var answersUp = false {
        didSet {
            // Only for a view already showing the window: one just made takes its own start.
            guard answersUp != oldValue, imageSize != .zero, lastBounds != .zero else { return }
            holdZoomUntil = CACurrentMediaTime() + 0.8
            let zoom = zoomScale, height = lastBounds.height, came = answersUp
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
                guard let self, abs(self.bounds.height - height) >= 1, self.imageSize != .zero else { return }
                self.onLog?(String(format: "viewer: the answers %@ — zoom %.3f before, %.3f after (view %d → %d pt)",
                                   came ? "came" : "went", zoom, self.zoomScale, Int(height), Int(self.bounds.height)))
            }
        }
    }
    private var holdZoomUntil: CFTimeInterval = 0
    var onLog: ((String) -> Void)?
    var onTouch: () -> Void = {}
    var onTap: (CGPoint, Int) -> Void = { _, _ in }
    var onRightClick: (CGPoint) -> Bool = { _ in false }
    var onHold: ((CGPoint) -> Bool)?
    var onHoldMoved: (CGVector, TimeInterval) -> Void = { _, _ in }
    var onHoldEnded: () -> Void = {}
    /// A hold taken by `onHold`: the same finger goes on as a trackpad finger until it lifts.
    private var holdTaken = false
    private var holdLast: (point: CGPoint, time: TimeInterval) = (.zero, 0)
    var onDrag: (WatchMouseEvent.Kind, CGPoint) -> Void = { _, _ in }
    /// The Mac takes drags: a hold right after a tap presses the button and moves with the finger.
    var canDrag = false
    /// A drag is under way (the hold that began it is still down).
    private var dragUnderWay = false
    /// The last tap, for a double-click's count: when and where.
    private var lastTapAt = Date.distantPast
    private var lastTapPoint = CGPoint.zero
    private var lastTapCount = 0
    /// The pointer the trackpad moves: its sprite lives in the window's stack above everything
    /// (so the Newest button or a note never covers it); this view places it.
    weak var pointerHost: PointerSpriteView?
    private var pointerSpot: CGPoint?
    private var pointerSeq = 0
    private var holder: UILongPressGestureRecognizer!
    private var twoTapper: UITapGestureRecognizer!
    /// When a hold last right-clicked: the lift that ends it isn't also a click.
    private var heldAt = Date.distantPast
    /// Showing the whole window (the zoom-out button), as last set.
    private var wholeShown = false
    var onScroll: (CGPoint, CGVector) -> Void = { _, _ in }
    var onScrollPhase: (WatchScrollPhase, CGPoint) -> Void = { _, _ in }
    var onAdjusted: (Bool) -> Void = { _ in }
    /// Where the zoom you leave it at is kept, so the window opens there next time.
    var viewKey: String?
    /// The picture covers the view (a folded Duo's half, Oct 25 2026): the start scale fills it
    /// rather than fitting it, and the zoom's top end is at least that.
    var fill = false { didSet { if fill != oldValue, imageSize != .zero, bounds.width > 0 { configureZoom(); reset(animated: false) } } }
    /// Something floats over the view's foot (the Duo's answers, Oct 25 2026): the picture's foot
    /// — the newest output, the question — stays above it. The view's visible height is the
    /// bounds less this; a picture that fits whole fits above it; the bottom is above it.
    var footInset: CGFloat = 0 {
        didSet {
            guard footInset != oldValue, imageSize != .zero, bounds.width > 0 else { return }
            let atBottom = contentOffset.y + contentInset.top >= max(0, imageSize.height * zoomScale - (bounds.height - oldValue)) - 24
            configureZoom()
            if zoomScale < minimumZoomScale { setZoomScale(minimumZoomScale, animated: false) }
            if !adjusted || atBottom {
                reset(animated: true, toBottom: true)
            } else {
                centerIfSmall()
                keepPointerInView(CGPoint(x: (contentOffset.x + bounds.width / 2) / zoomScale, y: (contentOffset.y + visibleHeight / 2) / zoomScale))
            }
        }
    }
    /// The height the picture has above whatever floats over the foot.
    private var visibleHeight: CGFloat { max(1, bounds.height - footInset) }
    private var tapper: UITapGestureRecognizer!
    private var swiper: UIPanGestureRecognizer!
    /// The swipe so far, not yet sent (sent once a display frame), and where it started.
    private var pendingScroll = CGVector.zero
    private var scrollAnchor = CGPoint.zero
    /// The Mac takes the swipe's phases: a gesture, then a coast.
    private var phased = false
    /// Ticks once a display frame while a finger swipes or a flick coasts: the deltas since the
    /// last tick go out as one (sixty a second at most, whatever the display's rate).
    private var scrollLink: CADisplayLink?
    private var momentum: ScrollMomentum?
    private var lastTick: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        // A pan coasts as a photo does (the fast rate stopped short, like a page).
        decelerationRate = .normal
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleToFill
        imageView.layer.minificationFilter = .trilinear
        canvas.addSubview(imageView)
        addSubview(canvas)
        tapper = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tapper)
        // Right-click, as remote-desktop apps do it: a press and hold, or a two-finger tap.
        holder = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        holder.minimumPressDuration = 0.45
        // A hold may move on: a drag follows the finger (a right-click's hold ignores the moves).
        holder.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(holder)
        twoTapper = UITapGestureRecognizer(target: self, action: #selector(twoTapped(_:)))
        twoTapper.numberOfTouchesRequired = 2
        addGestureRecognizer(twoTapper)
        swiper = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        swiper.maximumNumberOfTouches = 1
        addGestureRecognizer(swiper)
        touchDown = UILongPressGestureRecognizer(target: self, action: #selector(fingerDown(_:)))
        touchDown.minimumPressDuration = 0
        touchDown.allowableMovement = .greatestFiniteMagnitude
        touchDown.cancelsTouchesInView = false
        touchDown.delaysTouchesBegan = false
        touchDown.delaysTouchesEnded = false
        touchDown.delegate = self
        addGestureRecognizer(touchDown)
        apply(drag: .pan)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The touch-down mark lives beside every other gesture; it decides nothing.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { g === touchDown }

    /// A small mark the moment a finger lands on the picture (a press with no wait — the view's
    /// own touches never arrive for a tap inside a scroll view); it lifts with the finger (a tap's
    /// ring grows from it) and fades as soon as the finger moves on to pan, scroll or zoom.
    @objc private func fingerDown(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            guard g.numberOfTouches == 1, spot(g) != nil else { return }
            showPressMark(at: g.location(in: self))
        case .changed:
            if let m = pressMark, abs(m.position.x - g.location(in: self).x) + abs(m.position.y - g.location(in: self).y) > 8 { hidePressMark() }
        default:
            hidePressMark()
        }
    }

    private func showPressMark(at p: CGPoint) {
        pressMark?.removeFromSuperlayer()
        // Whatever the touch becomes, the mark never outlives a long hold.
        pressMarkTask?.cancel()
        pressMarkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.hidePressMark()
        }
        let r: CGFloat = 9
        let m = CALayer()
        m.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        m.cornerRadius = r
        m.position = p
        m.backgroundColor = UIColor(Light.cyan).withAlphaComponent(0.22).cgColor
        m.borderColor = UIColor(Light.cyan).withAlphaComponent(0.7).cgColor
        m.borderWidth = 1
        layer.addSublayer(m)
        if !UIAccessibility.isReduceMotionEnabled {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.5
            grow.toValue = 1
            grow.duration = 0.1
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            m.add(grow, forKey: "in")
        }
        pressMark = m
    }

    private func hidePressMark() {
        pressMarkTask?.cancel()
        pressMarkTask = nil
        guard let m = pressMark else { return }
        pressMark = nil
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.15
        m.opacity = 0
        m.add(fade, forKey: "out")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { m.removeFromSuperlayer() }
    }

    /// Pan: one finger moves the picture (the scroll view's own drag). Scroll: one finger scrolls the
    /// Mac's window, and the picture moves with two.
    private func apply(drag: Watcher.Drag) {
        panGestureRecognizer.minimumNumberOfTouches = drag == .pan ? 1 : 2
        swiper.isEnabled = drag == .scroll && isScrollEnabled
    }

    func update(image: UIImage?, video: VideoCanvas?, videoSize: CGSize, focus: CGRect?, recenter: Int, generation: Int, interactive: Bool, drag: Watcher.Drag, phased: Bool) {
        isScrollEnabled = interactive
        pinchGestureRecognizer?.isEnabled = interactive
        tapper.isEnabled = interactive
        holder.isEnabled = interactive
        twoTapper.isEnabled = interactive
        touchDown.isEnabled = interactive
        self.phased = phased
        apply(drag: drag)
        if generation != lastGeneration {
            // Another window: its view starts fresh with its first frame (the picture of the one
            // before stays in place, dimmed by the panel, until then).
            lastGeneration = generation
            imageSize = .zero
            adjusted = false
            lastRecenter = nil
            wholeShown = false
            lastWhole = nil
        }
        let focusChanged = focus != self.focus && !adjusted
        self.focus = focus
        imageView.image = image
        adopt(video)
        let size = video != nil ? videoSize : image?.size ?? .zero
        defer { if size != .zero { keptShown = kept } }
        guard size != .zero else { return }
        if size != imageSize, hadPicture, bounds.width > 0, WatchReconnect.sameShape(imageSize, size) {
            // The same window at another resolution (back from a dropped link at home, or away:
            // 2,560 ↔ 1,600 px — Nov 5 2026): the view stays where it was, the picture drawn as
            // large as before, only sharper or softer — never back to the start.
            let zoom = WatchReconnect.carriedZoom(zoomScale, from: imageSize, to: size), offset = contentOffset
            imageSize = size
            zoomScale = 1
            canvas.frame = CGRect(origin: .zero, size: size)
            imageView.frame = canvas.bounds
            video?.frame = canvas.bounds
            contentSize = size
            configureZoom()
            minimumZoomScale = min(minimumZoomScale, zoom)
            maximumZoomScale = max(maximumZoomScale, zoom)
            setZoomScale(zoom, animated: false)
            centerIfSmall()
            contentOffset = offset
            reportWhole()
        } else if size != imageSize {
            // A new size (first picture, another window, or the window was resized): start over —
            // under a short dissolve when a picture was already up, so the view never jumps.
            let dissolve = hadPicture && !keptShown && !UIAccessibility.isReduceMotionEnabled
            imageSize = size
            let apply = {
                self.zoomScale = 1
                self.canvas.frame = CGRect(origin: .zero, size: size)
                self.imageView.frame = self.canvas.bounds
                video?.frame = self.canvas.bounds
                self.contentSize = size
                self.configureZoom()
                self.reset(animated: false)
            }
            if dissolve { UIView.transition(with: self, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction], animations: apply) }
            else { apply() }
            hadPicture = true
        } else if lastRecenter != nil, recenter != lastRecenter {
            // A key, an answer or a dictation: its result shows at the bottom. Your zoom stays.
            reset(animated: true, toBottom: true)
        } else if focusChanged {
            // Where you type, learned a moment after the first frame: the view glides there
            // rather than jumping (Nov 4 2026, "every detail considered").
            reset(animated: hadPicture && !UIAccessibility.isReduceMotionEnabled)
        }
        lastRecenter = recenter
    }

    /// Hosts the video canvas over the picture, or lets it go. Taken from another viewer (the
    /// window's, when the strip opens; the strip's, when it closes), that one keeps a snapshot
    /// in its place for its fade-out. Nothing per frame: the canvas draws itself.
    private func adopt(_ video: VideoCanvas?) {
        canvas.subviews.filter { $0.tag == Self.snapshotTag }.forEach { $0.removeFromSuperview() }
        wantedVideo = video
        guard let video else { return }
        // The newest viewer that wants the video: a viewer on its way out hands the canvas here.
        if window != nil { Self.newest = self }
        guard video.superview !== canvas else { return }
        if let old = video.superview, let snap = video.snapshotView(afterScreenUpdates: false) {
            snap.frame = video.frame
            snap.tag = Self.snapshotTag
            old.addSubview(snap)
        }
        video.removeFromSuperview()
        video.frame = canvas.bounds
        canvas.addSubview(video)
    }

    private static let snapshotTag = 7001

    /// The canvas this viewer shows when video flows, and the viewer most recently given it. Two
    /// viewers overlap while one cross-fades into the other (the Duo's glance, Oct 25 2026): the
    /// one leaving the screen could take the canvas with it, leaving the new one black until the
    /// next update — so a viewer leaving the window hands the canvas to the newest one that wants it.
    private var wantedVideo: VideoCanvas?
    private static weak var newest: ViewerScrollView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let v = wantedVideo else { return }
        Self.newest = self
        if v.superview !== canvas { adopt(v) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBounds, imageSize != .zero, bounds.width > 0 else { return }
        let old = lastBounds
        lastBounds = bounds.size
        let forAnswers = CACurrentMediaTime() < holdZoomUntil
        if old != .zero, abs(old.width - bounds.width) < 1, keyboardUp || heightBeforeKeyboard != nil || forAnswers {
            if keyboardUp, heightBeforeKeyboard == nil { heightBeforeKeyboard = old.height }
            keepZoom(oldHeight: old.height)
            return
        }
        heightBeforeKeyboard = nil
        configureZoom()
        reset(animated: false)
    }

    /// The height changed for the keyboard: the same zoom, the bottom kept if it showed, else
    /// the same spot.
    private func keepZoom(oldHeight: CGFloat) {
        let s = zoomScale, h = imageSize.height * s
        let top = contentOffset.y + contentInset.top
        let wasBottom = top >= max(0, h - max(1, oldHeight - footInset)) - 24
        let before = contentOffset.y
        configureZoom()
        minimumZoomScale = min(minimumZoomScale, s)
        maximumZoomScale = max(maximumZoomScale, s)
        centerIfSmall()
        let bottom = max(0, h - visibleHeight)
        let y = wasBottom ? bottom : min(max(top, 0), bottom)
        contentOffset = CGPoint(x: contentOffset.x, y: y - contentInset.top)
        followResize(from: before, keepBottom: wasBottom)
        reportWhole()
    }

    /// The view's height changing inside the keyboard's own animation (Nov 4 2026): UIKit moves
    /// its size on the keyboard's spring, but the spot it shows was set at once — the newest
    /// lines jumped up and the empty plate showed under them until the size caught up. The spot
    /// rides the same spring, so the foot of the picture stays on the view's foot all the way.
    private func followResize(from oldY: CGFloat, keepBottom: Bool) {
        guard let size = layer.animation(forKey: "bounds.size") as? CABasicAnimation, size.isAdditive,
              let grow = (size.fromValue as? NSValue)?.cgSizeValue,
              let follow = size.copy() as? CABasicAnimation else { return }
        let dy = keepBottom ? -grow.height : oldY - contentOffset.y
        guard abs(dy) > 0.5 else { return }
        follow.keyPath = "bounds.origin"
        follow.fromValue = NSValue(cgPoint: CGPoint(x: 0, y: dy))
        follow.toValue = NSValue(cgPoint: .zero)
        layer.add(follow, forKey: "keep.origin")
    }

    /// The scale that shows the column you type in across the width (or the whole window, if
    /// it's narrow), never smaller than the whole window's width.
    private var startScale: CGFloat {
        Self.startScale(image: imageSize, width: bounds.width, visibleHeight: visibleHeight, focus: focus, fill: fill, maxZoom: maximumZoomScale)
    }

    static func startScale(image: CGSize, width: CGFloat, visibleHeight: CGFloat, focus: CGRect?, fill: Bool, maxZoom: CGFloat) -> CGFloat {
        guard image.width > 0, image.height > 0, width > 0 else { return 1 }
        let fitWidth = width / image.width
        let fillHeight = visibleHeight / image.height
        // A folded Duo's half: the picture covers it, the window's foot (the newest output) in
        // view — a window shaped nothing like the half (one the Mac can't reshape, on the book's
        // tall page) stops at the usual 1.8× rather than zooming onto a sliver.
        if fill { return min(max(fitWidth, fillHeight), fitWidth * ViewerScrollView.fillCap, maxZoom) }
        // A window shaped like this view (Fit to iPhone gives it the view's own shape, square or
        // not): all of it, never zoomed onto a part.
        let shapeRatio = (image.width / image.height) / (width / visibleHeight)
        if abs(shapeRatio - 1) < 0.15 { return min(fitWidth, fillHeight) }
        // A window taller than it's wide (Aa's Larger and Largest make it about the phone's shape)
        // already fits the phone across: its whole width, never zoomed onto a bar inside it.
        if image.height > image.width * 1.1 { return fitWidth }
        if let f = focus, f.width > 0.12 {
            return min(max(fitWidth, width / (f.width * image.width * 1.08)), maxZoom)
        }
        return max(fitWidth, min(fillHeight, fitWidth * 1.8))
    }

    /// Whether a picture of this size opens with all of it on screen in a view of this size — the
    /// viewer's own rule (its zoom range, the view he left this app's window at, else the start
    /// scale), asked before the first frame so Pan | Scroll is picked once (Nov 7 2026).
    static func opensWhole(image: CGSize, view: CGSize, focus: CGRect?, fill: Bool, viewKey: String?) -> Bool {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else { return false }
        let fitAll = min(view.width / image.width, view.height / image.height)
        var maxZoom = max(1.0, fitAll * 2)
        if fill { maxZoom = max(maxZoom, view.width / image.width, view.height / image.height) }
        let fitWidth = view.width / image.width
        let s: CGFloat
        if let viewKey, let data = UserDefaults.standard.data(forKey: viewKey),
           let v = try? JSONDecoder().decode(SavedView.self, from: data),
           abs(v.aspect - image.height / image.width) / (image.height / image.width) < 0.08 {
            s = min(max(v.zoom * fitWidth, fitAll), maxZoom)
        } else {
            s = startScale(image: image, width: view.width, visibleHeight: view.height, focus: focus, fill: fill, maxZoom: maxZoom)
        }
        return s <= fitAll * 1.03
    }

    /// Filling a view with a picture shaped nothing like it stops here (a multiple of fitting the
    /// width): past it the view would be a sliver of the window.
    static let fillCap: CGFloat = 1.8

    private func configureZoom() {
        guard imageSize.width > 0, bounds.width > 0 else { return }
        let fitAll = min(bounds.width / imageSize.width, visibleHeight / imageSize.height)
        minimumZoomScale = fitAll
        // In to one point per pixel of the Mac's picture (three screen pixels to one of the
        // Mac's): Retina text reads large there, and past it a pinch only blurred.
        maximumZoomScale = max(1.0, fitAll * 2)
        // Filling the view is always within reach.
        if fill { maximumZoomScale = max(maximumZoomScale, bounds.width / imageSize.width, visibleHeight / imageSize.height) }
    }

    /// Back to the start: where you last left this app's window (your zoom, your spot across it,
    /// and the bottom if you were there), else the column, at the bottom. `toBottom` keeps your
    /// zoom and goes to the newest (after a key, an answer or a dictation).
    private func reset(animated: Bool, toBottom: Bool = false) {
        guard imageSize != .zero, bounds.width > 0 else { return }
        let saved = savedView
        adjusted = saved != nil && !(saved!.bottom || toBottom)
        let s = saved.map { min(max($0.zoom * fitWidth, minimumZoomScale), maximumZoomScale) } ?? startScale
        // Filling the view past the window's width (one the Mac can't reshape to this view): it
        // starts at its top-left corner, so its title bar — close, minimize, zoom — is in view
        // (Nov 7 2026: centred, the red light was off the screen's edge, and the book lost the
        // whole title bar). He pans from there.
        let fromCorner = saved == nil && fill && s > fitWidth * 1.01
        let apply = {
            self.setZoomScale(s, animated: false)
            self.centerIfSmall()
            let w = self.imageSize.width * s, h = self.imageSize.height * s
            let cx = (saved?.x ?? self.focus.map { $0.midX } ?? 0.5) * w
            let x = fromCorner ? 0 : min(max(cx - self.bounds.width / 2, 0), max(0, w - self.bounds.width))
            let bottom = max(0, h - self.visibleHeight)
            let y = fromCorner && !toBottom ? 0 : saved.flatMap { $0.bottom || toBottom ? nil : min(max($0.y * h - self.visibleHeight / 2, 0), bottom) } ?? bottom
            self.contentOffset = CGPoint(x: x - self.contentInset.left, y: y - self.contentInset.top)
        }
        if animated { UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: apply) }
        else { apply() }
        reportWhole()
    }

    private var fitWidth: CGFloat { imageSize.width > 0 ? bounds.width / imageSize.width : 1 }

    /// The view you left: zoom as a multiple of fitting the width, the middle of what showed as
    /// fractions of the window, whether you were at the bottom, and the window's shape then (a
    /// window reshaped since, by Aa or a size, starts fresh).
    fileprivate struct SavedView: Codable { var zoom, x, y, aspect: CGFloat; var bottom: Bool }

    private var savedView: SavedView? {
        guard let viewKey, let data = UserDefaults.standard.data(forKey: viewKey),
              let v = try? JSONDecoder().decode(SavedView.self, from: data), imageSize.width > 0 else { return nil }
        let aspect = imageSize.height / imageSize.width
        return abs(v.aspect - aspect) / aspect < 0.08 ? v : nil
    }

    private func keepView() {
        guard let viewKey, !wholeShown, imageSize.width > 0, zoomScale > 0, bounds.width > 0 else { return }
        let w = imageSize.width * zoomScale, h = imageSize.height * zoomScale
        let mid = CGPoint(x: contentOffset.x + contentInset.left + bounds.width / 2,
                          y: contentOffset.y + contentInset.top + visibleHeight / 2)
        let bottom = contentOffset.y + contentInset.top >= max(0, h - visibleHeight) - 24
        let v = SavedView(zoom: zoomScale / fitWidth, x: min(max(mid.x / w, 0), 1), y: min(max(mid.y / h, 0), 1),
                          aspect: imageSize.height / imageSize.width, bottom: bottom)
        if let data = try? JSONEncoder().encode(v) { UserDefaults.standard.set(data, forKey: viewKey) }
    }

    /// A picture smaller than the view sits in the middle of it (of the room above the foot).
    private func centerIfSmall() {
        let w = imageSize.width * zoomScale, h = imageSize.height * zoomScale
        let dx = max(0, (bounds.width - w) / 2), dy = max(0, (visibleHeight - h) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy + footInset, right: dx)
    }

    /// The whole window, fitted, or back to the start (the column you type in).
    func showWhole(_ on: Bool) {
        guard on != wholeShown, imageSize != .zero, bounds.width > 0 else { return }
        wholeShown = on
        guard on else { reset(animated: true); return }
        adjusted = true
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.setZoomScale(self.minimumZoomScale, animated: false)
            self.centerIfSmall()
            self.contentOffset = CGPoint(x: -self.contentInset.left, y: -self.contentInset.top)
        }
        reportWhole()
    }

    /// Fully zoomed out (Oct 18 2026, Sameer: "when user is fully zoomed out then the mode should
    /// automatically switch to scroll mode"): said once each time it changes.
    var onWholeShown: (Bool) -> Void = { _ in }
    private var lastWhole: Bool?

    private func reportWhole() {
        guard imageSize != .zero, bounds.width > 0, minimumZoomScale > 0 else { return }
        let whole = zoomScale <= minimumZoomScale * 1.03
        guard whole != lastWhole else { return }
        lastWhole = whole
        onWholeShown(whole)
    }

    /// Where on the window a gesture is, as fractions of it; nil off the picture.
    private func spot(_ g: UIGestureRecognizer) -> CGPoint? {
        guard imageSize.width > 0 else { return nil }
        let p = g.location(in: canvas)
        let n = CGPoint(x: p.x / imageSize.width, y: p.y / imageSize.height)
        return (0...1).contains(n.x) && (0...1).contains(n.y) ? n : nil
    }

    /// A hold: a right-click — or, right after a tap (within 0.5 s, near it), a drag: the button
    /// pressed where the finger is, moved with it, released when it lifts.
    @objc private func held(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            guard let n = spot(g) else { return }
            let p = g.location(in: self)
            if canDrag, Date().timeIntervalSince(lastTapAt) < 0.5, abs(p.x - lastTapPoint.x) + abs(p.y - lastTapPoint.y) < 30 {
                dragUnderWay = true
                hidePressMark()
                onDrag(.down, n)
                return
            }
            // Full screen: a hold brings the trackpad up there instead (Nov 3 2026).
            if let onHold, onHold(CGPoint(x: p.x - contentOffset.x, y: p.y - contentOffset.y)) {
                hidePressMark()
                holdTaken = true
                holdLast = (g.location(in: window), ProcessInfo.processInfo.systemUptime)
                return
            }
            heldAt = Date()
            if onRightClick(n) { ring(at: p, right: true) }
        case .changed:
            if holdTaken {
                // In the window's space: the picture doesn't scroll under a trackpad finger.
                let at = g.location(in: window), now = ProcessInfo.processInfo.systemUptime
                onHoldMoved(CGVector(dx: at.x - holdLast.point.x, dy: at.y - holdLast.point.y), now - holdLast.time)
                holdLast = (at, now)
                return
            }
            guard dragUnderWay else { return }
            onDrag(.drag, clampedSpot(g))
        case .ended, .cancelled, .failed:
            if holdTaken { holdTaken = false; onHoldEnded(); return }
            guard dragUnderWay else { return }
            dragUnderWay = false
            onDrag(.up, clampedSpot(g))
            ring(at: g.location(in: self))
        default: break
        }
    }

    /// Where a gesture is, as fractions of the window, held inside it (a drag may leave the picture).
    private func clampedSpot(_ g: UIGestureRecognizer) -> CGPoint {
        guard imageSize.width > 0 else { return .zero }
        let p = g.location(in: canvas)
        return CGPoint(x: min(max(p.x / imageSize.width, 0), 1), y: min(max(p.y / imageSize.height, 0), 1))
    }

    // MARK: The pointer (the trackpad's)

    /// The pointer, as a fraction of the window: the arrow drawn over it; a move (a new `seq`)
    /// keeps it in sight, scrolling the view as little as needed. Nil takes the arrow away.
    func setPointer(_ p: CGPoint?, seq: Int) {
        pointerSpot = p
        guard let p, imageSize.width > 0 else {
            pointerHost?.hide()
            return
        }
        if seq != pointerSeq {
            pointerSeq = seq
            keepPointerInView(CGPoint(x: p.x * imageSize.width, y: p.y * imageSize.height))
        }
        placePointer()
    }

    /// The arrow where the pointer is, in the sprite's coordinates — again on every scroll and zoom.
    private func placePointer() {
        guard let host = pointerHost, let p = pointerSpot, imageSize.width > 0 else { return }
        host.place(canvas.convert(CGPoint(x: p.x * imageSize.width, y: p.y * imageSize.height), to: host))
    }

    /// The middle of what's on screen, as a fraction of the window (where the trackpad's pointer
    /// starts); nil before a picture.
    var visibleCenter: CGPoint? {
        guard imageSize.width > 0, zoomScale > 0, bounds.width > 0 else { return nil }
        let w = imageSize.width * zoomScale, h = imageSize.height * zoomScale
        let cx = contentOffset.x + bounds.width / 2, cy = contentOffset.y + visibleHeight / 2
        return CGPoint(x: min(max(cx / w, 0), 1), y: min(max(cy / h, 0), 1))
    }

    /// Zoomed in, the pointer stays on screen: when it nears an edge the view moves with it, as
    /// far as it moved (the content's coordinates: the visible rect starts at the content offset;
    /// a picture smaller than the view sits inside the insets and never moves).
    private func keepPointerInView(_ canvasPoint: CGPoint) {
        guard zoomScale > 0, bounds.width > 0 else { return }
        let p = CGPoint(x: canvasPoint.x * zoomScale, y: canvasPoint.y * zoomScale)
        let margin: CGFloat = 36
        var offset = contentOffset
        let visible = CGRect(origin: contentOffset, size: CGSize(width: bounds.width, height: visibleHeight))
        // Only a pointer near an edge moves the view: a pointer well inside it — where the
        // trackpad starts it — moved nothing, but the clamp below nudged a view resting a hair
        // past its bounds and that counted as looking away, so Newest showed the moment the
        // trackpad came up (Nov 4 2026).
        let nearEdge = p.x < visible.minX + margin || p.x > visible.maxX - margin
            || p.y < visible.minY + margin || p.y > visible.maxY - margin
        if p.x < visible.minX + margin { offset.x = p.x - margin }
        if p.x > visible.maxX - margin { offset.x = p.x + margin - bounds.width }
        if p.y < visible.minY + margin { offset.y = p.y - margin }
        if p.y > visible.maxY - margin { offset.y = p.y + margin - visibleHeight }
        let minX = -contentInset.left, minY = -contentInset.top
        let maxX = max(minX, contentSize.width - bounds.width + contentInset.right)
        let maxY = max(minY, contentSize.height - bounds.height + contentInset.bottom)
        offset.x = min(max(offset.x, minX), maxX)
        offset.y = min(max(offset.y, minY), maxY)
        guard offset != contentOffset else { return }
        if nearEdge, abs(offset.x - contentOffset.x) >= 1 || abs(offset.y - contentOffset.y) >= 1 { adjusted = true }
        setContentOffset(offset, animated: false)
    }

    @objc private func twoTapped(_ g: UITapGestureRecognizer) {
        guard let n = spot(g) else { return }
        if onRightClick(n) { ring(at: g.location(in: self), right: true) }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard Date().timeIntervalSince(heldAt) > 0.3, !dragUnderWay else { return }
        guard imageSize.width > 0 else { return }
        let p = g.location(in: canvas)
        let n = CGPoint(x: p.x / imageSize.width, y: p.y / imageSize.height)
        guard (0...1).contains(n.x), (0...1).contains(n.y) else { return }
        // The ring grows out of the touch-down mark, at once.
        pressMarkTask?.cancel()
        pressMark?.removeFromSuperlayer()
        pressMark = nil
        let here = g.location(in: self)
        // A tap right after another, near it, is the next click of a double (then a triple):
        // sent as its count, the way the Mac counts them — the first tap went at once, so a
        // single click never waits to see whether a second comes.
        let again = Date().timeIntervalSince(lastTapAt) < 0.35 && abs(here.x - lastTapPoint.x) + abs(here.y - lastTapPoint.y) < 30
        let count = again ? min(lastTapCount + 1, 3) : 1
        lastTapAt = Date()
        lastTapPoint = here
        lastTapCount = count
        ring(at: here, right: count > 1)
        onTap(n, count)
    }

    @objc private func swiped(_ g: UIPanGestureRecognizer) {
        guard imageSize.width > 0, zoomScale > 0 else { return }
        let shown = CGSize(width: imageSize.width * zoomScale, height: imageSize.height * zoomScale)
        switch g.state {
        case .began:
            onTouch()
            // A new swipe while the last flick still coasts ends the coast first, so the Mac sees
            // its end before this gesture's beginning.
            endMomentum()
            let p = g.location(in: canvas)
            scrollAnchor = CGPoint(x: min(max(p.x / imageSize.width, 0), 1), y: min(max(p.y / imageSize.height, 0), 1))
            pendingScroll = .zero
            g.setTranslation(.zero, in: self)
            if phased { onScrollPhase(.began, scrollAnchor) }
            startLink()
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            // As fractions of the window, so the Mac moves its content as far as the finger did.
            pendingScroll.dx += t.x / shown.width
            pendingScroll.dy += t.y / shown.height
        case .ended:
            flushScroll()
            let v = g.velocity(in: self)
            if phased {
                onScrollPhase(.ended, scrollAnchor)
                // A flick coasts, a delta per frame from the lift-off speed, until it fades.
                if let m = ScrollMomentum(velocity: CGVector(dx: v.x, dy: v.y)) {
                    momentum = m
                    onScrollPhase(.momentumBegan, scrollAnchor)
                    step(dt: 1 / ScrollMomentum.tickRate)
                } else {
                    stopLink()
                }
            } else {
                // A Mac from before: a flick carries on a little, in one delta.
                pendingScroll.dy += min(max(v.y * 0.12, -900), 900) / shown.height
                flushScroll()
                stopLink()
            }
        default:
            flushScroll()
            if phased { onScrollPhase(.ended, scrollAnchor) }
            stopLink()
        }
    }

    private func startLink() {
        guard scrollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(ScrollMomentum.tickRate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        scrollLink = link
        lastTick = CACurrentMediaTime()
    }

    private func stopLink() {
        scrollLink?.invalidate()
        scrollLink = nil
        momentum = nil
    }

    /// Once a display frame: the finger's deltas since the last, or the coast's next step.
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = now - lastTick
        lastTick = now
        if momentum != nil { step(dt: dt) } else { flushScroll() }
    }

    /// One step of the coast, in the picture's points as the finger's deltas are — nothing left
    /// to move ends it.
    private func step(dt: CFTimeInterval) {
        guard var m = momentum, let s = m.step(dt: dt) else { endMomentum(); return }
        momentum = m
        let shown = CGSize(width: imageSize.width * zoomScale, height: imageSize.height * zoomScale)
        guard shown.width > 0, shown.height > 0 else { endMomentum(); return }
        onScroll(scrollAnchor, CGVector(dx: s.dx / shown.width, dy: s.dy / shown.height))
    }

    private func endMomentum() {
        let coasting = momentum != nil
        stopLink()
        if coasting { onScrollPhase(.momentumEnded, scrollAnchor) }
    }

    private func flushScroll() {
        guard abs(pendingScroll.dx) + abs(pendingScroll.dy) > 0.0005 else { return }
        onScroll(scrollAnchor, pendingScroll)
        pendingScroll = .zero
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            endMomentum()
            if let v = wantedVideo, v.superview === canvas, let other = Self.newest, other !== self, other.window != nil, other.wantedVideo === v {
                other.adopt(v)
                other.setNeedsLayout()
            }
        }
    }

    /// Where the click landed: a ring that grows and fades (a double one for a right-click).
    private func ring(at p: CGPoint, right: Bool = false) {
        if right { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.ring(at: p) } }
        let r: CGFloat = 16
        let layer = CAShapeLayer()
        layer.path = UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)).cgPath
        layer.position = p
        layer.fillColor = UIColor(Light.cyan).withAlphaComponent(0.25).cgColor
        layer.strokeColor = UIColor(Light.cyan).cgColor
        layer.lineWidth = 2
        self.layer.addSublayer(layer)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = 0
        layer.add(group, forKey: "ring")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { layer.removeFromSuperlayer() }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { adjusted = true; onTouch() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { adjusted = true; onTouch() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerIfSmall(); placePointer() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { placePointer() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { keepView(); reportWhole() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { keepView() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { keepView() }
}

/// The kicker's dot: a breath of light driven by Core Animation while the window is live. The
/// animation runs on the render server, so the app's CPU stays idle between pictures.
private struct LiveDot: UIViewRepresentable {
    var color: UIColor
    var breathing: Bool

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.layer.cornerRadius = 4
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        v.layer.backgroundColor = color.cgColor
        let running = v.layer.animation(forKey: "breathe") != nil
        if breathing && !running {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.45
            a.duration = 1.1
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.layer.add(a, forKey: "breathe")
        } else if !breathing && running {
            v.layer.removeAnimation(forKey: "breathe")
        }
    }
}

/// On the whole screen: "Watch Claude" — the app in front's own window, the usual watch view.
private struct WatchFrontChip: View {
    @EnvironmentObject var model: AppModel
    let front: FrontApp

    var body: some View {
        Button { model.watchApp(front) } label: {
            HStack(spacing: 7) {
                if let icon = model.liveTargets.first(where: { $0.bundleID == front.bundleID })?.icon,
                   let img = UIImage(data: icon) {
                    Image(uiImage: img).resizable().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "macwindow").font(.footnote.weight(.semibold))
                }
                Text("Watch \(front.name)").font(.footnote.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Ink.tertiary)
            }
        }
        .buttonStyle(WatchCellStyle(inset: 12, height: 36))
        .watchGlass(Capsule())
        .accessibilityLabel("Watch \(front.name)'s window")
        .accessibilityHint("Leaves the whole screen for \(front.name)'s window, and sends there.")
        .accessibilityIdentifier("watch-front")
    }
}

extension View {
    /// What's only for a live window (the answers, the key row): shown and touchable while live;
    /// while the link comes back, in its place but dimmed and untouchable (Nov 5 2026 — taps never
    /// fire into nothing, and nothing round the picture moves); otherwise hidden.
    func watchLive(_ phase: Watcher.Phase) -> some View {
        opacity(phase == .live ? 1 : phase.holdsLayout ? 0.35 : 0)
            .allowsHitTesting(phase == .live)
            .accessibilityHidden(phase != .live)
    }
}
