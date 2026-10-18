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
    /// The window just switched to, named for a moment ("Terminal — codex ~/api").
    @State private var switchedTo: String?
    @State private var switchedTask: Task<Void, Never>?
    /// The window slides in from the side it came from (a swipe's direction, or the menu's).
    @State private var slide: CGFloat = 0
    /// The window's height here: a tip waits until there's room for its card over the window.
    @State private var windowHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: compact ? 6 : 8) {
            header
            WatchWindow(watcher: watcher, interactive: true)
                .frame(maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
                // The first times: what a tap, a hold, a pinch and the side swipe do.
                .overlay(alignment: .top) { WatchTipCard(watcher: watcher, sessions: sessions.count, room: windowHeight) }
                .offset(x: slide)
            WatchActions(watcher: watcher)
                .opacity(watcher.phase == .live ? 1 : 0)
                .allowsHitTesting(watcher.phase == .live)
                .accessibilityHidden(watcher.phase != .live)
        }
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

    private var current: Int? {
        guard let t = watcher.target else { return nil }
        return sessions.firstIndex { t.matches($0) }
    }

    private func go(_ step: Int) {
        if let t = model.watchStep(step) { announce(t, from: step) }
    }

    private func show(_ t: LiveTarget) {
        let was = current
        if model.watchSession(t) {
            let now = sessions.firstIndex { $0.id == t.id }
            announce(t, from: (was.map { w in (now ?? w) >= w } ?? true) ? 1 : -1)
        }
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

    /// Every window on the Mac's screen that isn't already one of the places above (Finder, a
    /// dialog, a pop-up — anything).
    private var otherWindows: [LiveTarget] {
        model.everyWindow.filter { w in !sessions.contains { $0.bundleID == w.bundleID && ($0.windowKey == nil || $0.windowKey == w.windowKey) } }
    }

    private var sessionMenu: some View {
        Menu {
            // The whole screen first: for a pop-up that isn't in any one window.
            if watcher.canWatchDesktop {
                Section {
                    Button { model.watchWholeScreen() } label: {
                        Label("Whole Screen", systemImage: watcher.isDesktop ? "checkmark" : "display")
                        Text("Everything on your Mac, live")
                    }
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
                WatchKicker(watcher: watcher)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Ink.tertiary)
            }
            .frame(minHeight: WatchLook.header)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Window: \(watcher.name)")
        .accessibilityHint("Shows another window from your Mac — and sends there. You can also swipe in from the side.")
        .accessibilityIdentifier("watch-sessions")
    }

    private var header: some View {
        HStack(spacing: 10) {
            // The name keeps its room; the page dots step aside when the controls need it.
            if sessions.count > 1 || watcher.canWatchDesktop || !model.everyWindow.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        sessionMenu
                        if sessions.count <= 8, let i = current { WatchPageDots(count: sessions.count, current: i) }
                    }
                    sessionMenu
                }
                .layoutPriority(1)
            } else {
                WatchKicker(watcher: watcher).layoutPriority(1)
            }
            Spacer(minLength: 8)
            if watcher.macCanFit, watcher.target != .clipboard {
                HStack(spacing: 0) {
                    WatchWholeButton(watcher: watcher)
                    // The whole screen has no window to size, minimize or close.
                    if !watcher.isDesktop {
                        WatchCellDivider()
                        WatchWindowMenu(watcher: watcher)
                    }
                }
                .watchGlass(Capsule())
            }
            Button("Done") {
                Haptics.tick()
                watcher.close()
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(WatchCellStyle(inset: 14, height: WatchLook.header))
            .fixedSize()
            .watchGlass(Capsule())
            .accessibilityHint("Stops showing the window and brings back Send to and Cleanup.")
            .accessibilityIdentifier("watch-done")
        }
        .frame(minHeight: WatchLook.header)
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
    @State private var confirmClose = false
    @State private var pickingPhoto = false
    @State private var pickingFile = false

    var body: some View {
        Menu {
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
            Image(systemName: "macwindow")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(WatchCellStyle(width: 42, height: WatchLook.header, tint: watcher.fit == .normal ? Ink.ink : Light.cyan))
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

/// "● CLAUDE" (the dot breathing cyan says live), "PAUSED · CLAUDE", "MAC NOT CONNECTED".
struct WatchKicker: View {
    @ObservedObject var watcher: Watcher
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
                label(words)
                label(watcher.name)
                label(watcher.name, fits: false).minimumScaleFactor(0.6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("watch-kicker")
    }

    /// `fits`: measured at its full width (a rung of the ladder); the last rung may shrink instead.
    private func label(_ text: String, fits: Bool = true) -> some View {
        Text(text.uppercased())
            .font(.mono(.caption, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(watcher.phase == .live ? Ink.ink : Ink.tertiary)
            .lineLimit(1)
            .fixedSize(horizontal: fits, vertical: false)
    }

    /// Live: the name alone — the lit dot is the word. Anything else says what's up.
    private var words: String {
        let n = watcher.name
        switch watcher.phase {
        case .starting: return "Opening \(n)"
        case .live: return n
        case .paused(.mac): return "Stopped · \(n)"
        case .paused: return "Paused · \(n)"
        case .needsPermission, .unavailable: return n
        case .offline: return "Mac not connected"
        }
    }

    private var spoken: String { watcher.phase == .live ? "Live · \(watcher.name)" : words }

    private var color: Color {
        switch watcher.phase {
        case .live: return Light.cyan
        case .starting: return Ink.tertiary
        case .paused: return Ink.tertiary
        case .needsPermission, .unavailable, .offline: return Light.ochre
        }
    }
}

/// The window itself — a screen set in a bezel, with what's going on laid over it when it isn't live.
struct WatchWindow: View {
    @ObservedObject var watcher: Watcher
    var interactive: Bool
    /// A moment of words after the Pan | Scroll switch flips or Aa changes: what happens now.
    @State private var dragNote: String?
    @State private var dragNoteTask: Task<Void, Never>?
    /// "Opening …" shows only once a switch has taken a moment: a quick one never flashes it.
    @State private var opening = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let screen = RoundedRectangle(cornerRadius: WatchLook.screen, style: .continuous)
        let bezel = RoundedRectangle(cornerRadius: WatchLook.bezel, style: .continuous)
        let high = contrast == .increased
        ZStack {
            Ink.sunk
            if watcher.hasPicture {
                WindowViewer(image: watcher.image, video: watcher.videoSize != nil ? watcher.video : nil, videoSize: watcher.videoSize ?? .zero,
                             focus: watcher.focus, recenter: watcher.recenter, generation: watcher.windowSeq,
                             interactive: interactive && watcher.phase == .live,
                             drag: watcher.drag, phased: watcher.macCanScroll,
                             viewKey: interactive ? watcher.viewKey : nil,
                             onTouch: { watcher.touch() },
                             onTap: { watcher.click($0) }, onRightClick: { watcher.rightClick($0) }, whole: watcher.wholeWindow,
                             onScroll: { watcher.scroll(at: $0, by: $1) },
                             onScrollPhase: { watcher.scrollPhase($0, at: $1) },
                             onAdjusted: { moved in if interactive { watcher.setMovedAway(moved) } },
                             onWhole: { whole in if interactive { watcher.wholeShown(whole) } })
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { watcher.viewerSize = $0 }
                    .accessibilityLabel("\(watcher.name)'s window on your Mac")
                    .accessibilityHint(interactive ? (watcher.drag == .pan
                        ? "Tap to click there on your Mac; hold, or tap with two fingers, to right-click. Drag to look around the window; pinch to zoom. Switch to Scroll to scroll the window on your Mac."
                        : "Tap to click there on your Mac; hold, or tap with two fingers, to right-click. Swipe to scroll the window on your Mac; two fingers move the picture.") : "")
                    .accessibilityAddTraits(.isImage)
            }
            // A switch: the last window's picture stays, dimmed, until the new one's first frame.
            if watcher.stale {
                Ink.ground.opacity(0.5).transition(.opacity).allowsHitTesting(false).accessibilityHidden(true)
            }
            if interactive && watcher.movedAway && watcher.phase == .live {
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
            if interactive, watcher.isDesktop, watcher.phase == .live, let front = watcher.front {
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
            if interactive { overlay }
        }
        .clipShape(screen)
        // The screen sits a hair below the bezel: a dark line at its edge is the recess.
        .overlay(screen.strokeBorder(Color.black.opacity(high ? 0 : 0.55), lineWidth: 1))
        .padding(WatchLook.bezelWidth)
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
        .onChange(of: watcher.cameAlive) { _, _ in if interactive { Haptics.soft() } }
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
        .animation(.easeInOut(duration: 0.25), value: watcher.phase)
        .animation(.easeInOut(duration: 0.2), value: watcher.movedAway)
        .animation(.easeInOut(duration: 0.2), value: watcher.stale)
    }

    /// The light under the bezel: the window's state, in the kicker's colour.
    private var glow: Color {
        switch watcher.phase {
        case .live: return Light.cyan
        case .needsPermission, .unavailable, .offline: return Light.ochre
        case .starting, .paused: return Light.cyan
        }
    }

    private var glowStrength: Double {
        switch watcher.phase {
        case .live: return interactive ? 0.22 : 0.14
        case .needsPermission, .unavailable, .offline: return 0.16
        case .starting, .paused: return 0.06
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
                     detail: "The window comes back when it is.") { EmptyView() }
            }
        case .needsPermission:
            Dimmed {
                Note(symbol: "rectangle.dashed.badge.record", title: "Your Mac needs to allow Screen Recording",
                     detail: "Turn on Macrophone in Privacy & Security › Screen Recording on your Mac. It only ever shows the app you pick.") {
                    Button { watcher.perform(.openScreenRecordingSettings) } label: {
                        Text("Open the setting on my Mac").fontWeight(.semibold)
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
                .foregroundStyle(on ? Ink.ground : Ink.secondary)
                .padding(.horizontal, style == .glyphs ? 13 : 12)
                .frame(minHeight: WatchLook.control - 6)
                .background {
                    if on {
                        Capsule().fill(Light.cyan)
                            // Lit along its top, as the keys' glass is.
                            .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
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
/// default up, down, return, esc buttons"), with Esc and Keys kept small beside the switch.
struct WatchActions: View {
    @ObservedObject var watcher: Watcher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let p = watcher.answers {
                answers(p)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            } else {
                keys.transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: watcher.answers?.id)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// The question's answers: the one the arrows are on — what Return would pick — stands out
    /// in the window's light; a tap on any of them answers.
    private func answers(_ p: WatchPrompt) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(p.choices.enumerated()), id: \.offset) { i, c in
                let lit = p.highlighted == i
                Button { watcher.choose(i) } label: {
                    HStack(spacing: 10) {
                        if let n = c.number {
                            Text("\(n)")
                                .font(.mono(.caption, weight: .semibold))
                                .foregroundStyle(lit ? Ink.ground.opacity(0.8) : Ink.secondary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(lit ? Ink.ground.opacity(0.14) : Ink.ink.opacity(0.08)))
                        } else if let k = c.key {
                            Text(k)
                                .font(.mono(.caption, weight: .semibold))
                                .foregroundStyle(lit ? Ink.ground.opacity(0.8) : Ink.secondary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(lit ? Ink.ground.opacity(0.14) : Ink.ink.opacity(0.08)))
                        }
                        Text(c.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(lit ? Ink.ground : Ink.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if lit {
                            Image(systemName: "return")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Ink.ground.opacity(0.55))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: WatchLook.control, alignment: .leading)
                    .contentShape(WatchAnswerStyle.shape)
                }
                .buttonStyle(WatchAnswerStyle(lit: lit))
                .accessibilityLabel(c.label)
                .accessibilityHint(lit ? "What Return picks now. Answers \(watcher.name) on your Mac." : "Answers \(watcher.name) on your Mac.")
                .accessibilityIdentifier("watch-answer-\(i)")
            }
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    key(.escape, label: Text("Esc"), name: "Escape", inset: 16)
                    WatchCellDivider()
                    Button { watcher.showKeys() } label: {
                        Label("Keys", systemImage: "keyboard").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(WatchCellStyle(inset: 16))
                    .accessibilityHint("Shows Esc, the arrows and Return instead of these answers.")
                    .accessibilityIdentifier("watch-keys")
                }
                .watchGlass(Capsule())
                .fixedSize()
                Spacer(minLength: 0)
                ViewThatFits(in: .horizontal) {
                    WatchDragSwitch(watcher: watcher, style: .words).fixedSize()
                    WatchDragSwitch(watcher: watcher, style: .glyphs).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(p.question ?? "\(watcher.name) is asking")
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
            WatchDragSwitch(watcher: watcher, style: style)
                .fixedSize()
        }
    }

    /// More keys, from a menu (a Mac that can): what each does, with its keys under it, by section;
    /// the digits as one row at the foot.
    private var moreKeys: some View {
        Menu {
            ForEach(WatchKey.sections) { section in
                Section(section.title) {
                    ForEach(section.keys) { k in
                        Button { watcher.press(k) } label: {
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
                            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
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

private extension View {
    @ViewBuilder func watchProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Light.cyan).foregroundStyle(Ink.ground)
        } else {
            buttonStyle(.borderedProminent).tint(Light.cyan).foregroundStyle(Ink.ground)
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
    var interactive: Bool
    var drag: Watcher.Drag
    /// The Mac takes a swipe's phases (it named "scroll").
    var phased: Bool
    /// Where this viewer remembers the zoom you left it at (the window's, per app); nil: the strip.
    var viewKey: String? = nil
    var onTouch: () -> Void
    var onTap: (CGPoint) -> Void
    /// A press and hold or a two-finger tap; returns whether the Mac takes right-clicks.
    var onRightClick: (CGPoint) -> Bool = { _ in false }
    /// The whole window on screen (the zoom-out button).
    var whole = false
    var onScroll: (CGPoint, CGVector) -> Void
    var onScrollPhase: (WatchScrollPhase, CGPoint) -> Void
    var onAdjusted: (Bool) -> Void
    /// The whole window is on screen (fully zoomed out), or no longer is.
    var onWhole: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> ViewerScrollView {
        let v = ViewerScrollView()
        wire(v)
        return v
    }

    func updateUIView(_ v: ViewerScrollView, context: Context) {
        wire(v)
        v.viewKey = viewKey
        v.update(image: image, video: video, videoSize: videoSize, focus: focus, recenter: recenter, generation: generation, interactive: interactive, drag: drag, phased: phased)
        v.showWhole(whole)
    }

    private func wire(_ v: ViewerScrollView) {
        v.onTouch = onTouch
        v.onTap = onTap
        v.onRightClick = onRightClick
        v.onScroll = onScroll
        v.onScrollPhase = onScrollPhase
        v.onAdjusted = onAdjusted
        v.onWholeShown = onWhole
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
    private var focus: CGRect?
    /// The person zoomed or dragged: leave the view where they put it.
    private var adjusted = false { didSet { if adjusted != oldValue { onAdjusted(adjusted) } } }
    private var lastRecenter: Int?
    private var lastGeneration = 0
    /// A picture has been up: the next size change dissolves instead of jumping.
    private var hadPicture = false
    private var lastBounds: CGSize = .zero
    var onTouch: () -> Void = {}
    var onTap: (CGPoint) -> Void = { _ in }
    var onRightClick: (CGPoint) -> Bool = { _ in false }
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
        holder.allowableMovement = 10
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
        guard size != .zero else { return }
        if size != imageSize {
            // A new size (first picture, another window, or the window was resized): start over —
            // under a short dissolve when a picture was already up, so the view never jumps.
            let dissolve = hadPicture && !UIAccessibility.isReduceMotionEnabled
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
            reset(animated: false)
        }
        lastRecenter = recenter
    }

    /// Hosts the video canvas over the picture, or lets it go. Taken from another viewer (the
    /// window's, when the strip opens; the strip's, when it closes), that one keeps a snapshot
    /// in its place for its fade-out. Nothing per frame: the canvas draws itself.
    private func adopt(_ video: VideoCanvas?) {
        canvas.subviews.filter { $0.tag == Self.snapshotTag }.forEach { $0.removeFromSuperview() }
        guard let video else { return }
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

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBounds, imageSize != .zero, bounds.width > 0 else { return }
        lastBounds = bounds.size
        configureZoom()
        reset(animated: false)
    }

    /// The scale that shows the column you type in across the width (or the whole window, if
    /// it's narrow), never smaller than the whole window's width.
    private var startScale: CGFloat {
        guard imageSize.width > 0, bounds.width > 0 else { return 1 }
        let fitWidth = bounds.width / imageSize.width
        let fillHeight = bounds.height / imageSize.height
        // A window shaped like this view (Fit to iPhone gives it the view's own shape, square or
        // not): all of it, never zoomed onto a part.
        let shapeRatio = (imageSize.width / imageSize.height) / (bounds.width / max(1, bounds.height))
        if abs(shapeRatio - 1) < 0.15 { return min(fitWidth, fillHeight) }
        // A window taller than it's wide (Aa's Larger and Largest make it about the phone's shape)
        // already fits the phone across: its whole width, never zoomed onto a bar inside it.
        if imageSize.height > imageSize.width * 1.1 { return fitWidth }
        if let f = focus, f.width > 0.12 {
            return min(max(fitWidth, bounds.width / (f.width * imageSize.width * 1.08)), maximumZoomScale)
        }
        return max(fitWidth, min(fillHeight, fitWidth * 1.8))
    }

    private func configureZoom() {
        guard imageSize.width > 0, bounds.width > 0 else { return }
        let fitAll = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        minimumZoomScale = fitAll
        // In to one point per pixel of the Mac's picture (three screen pixels to one of the
        // Mac's): Retina text reads large there, and past it a pinch only blurred.
        maximumZoomScale = max(1.0, fitAll * 2)
    }

    /// Back to the start: where you last left this app's window (your zoom, your spot across it,
    /// and the bottom if you were there), else the column, at the bottom. `toBottom` keeps your
    /// zoom and goes to the newest (after a key, an answer or a dictation).
    private func reset(animated: Bool, toBottom: Bool = false) {
        guard imageSize != .zero, bounds.width > 0 else { return }
        let saved = savedView
        adjusted = saved != nil && !(saved!.bottom || toBottom)
        let s = saved.map { min(max($0.zoom * fitWidth, minimumZoomScale), maximumZoomScale) } ?? startScale
        let apply = {
            self.setZoomScale(s, animated: false)
            self.centerIfSmall()
            let w = self.imageSize.width * s, h = self.imageSize.height * s
            let cx = (saved?.x ?? self.focus.map { $0.midX } ?? 0.5) * w
            let x = min(max(cx - self.bounds.width / 2, 0), max(0, w - self.bounds.width))
            let bottom = max(0, h - self.bounds.height)
            let y = saved.flatMap { $0.bottom || toBottom ? nil : min(max($0.y * h - self.bounds.height / 2, 0), bottom) } ?? bottom
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
    private struct SavedView: Codable { var zoom, x, y, aspect: CGFloat; var bottom: Bool }

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
                          y: contentOffset.y + contentInset.top + bounds.height / 2)
        let bottom = contentOffset.y + contentInset.top >= max(0, h - bounds.height) - 24
        let v = SavedView(zoom: zoomScale / fitWidth, x: min(max(mid.x / w, 0), 1), y: min(max(mid.y / h, 0), 1),
                          aspect: imageSize.height / imageSize.width, bottom: bottom)
        if let data = try? JSONEncoder().encode(v) { UserDefaults.standard.set(data, forKey: viewKey) }
    }

    /// A picture smaller than the view sits in the middle of it.
    private func centerIfSmall() {
        let w = imageSize.width * zoomScale, h = imageSize.height * zoomScale
        let dx = max(0, (bounds.width - w) / 2), dy = max(0, (bounds.height - h) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
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

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let n = spot(g) else { return }
        heldAt = Date()
        if onRightClick(n) { ring(at: g.location(in: self), right: true) }
    }

    @objc private func twoTapped(_ g: UITapGestureRecognizer) {
        guard let n = spot(g) else { return }
        if onRightClick(n) { ring(at: g.location(in: self), right: true) }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard Date().timeIntervalSince(heldAt) > 1 else { return }
        guard imageSize.width > 0 else { return }
        let p = g.location(in: canvas)
        let n = CGPoint(x: p.x / imageSize.width, y: p.y / imageSize.height)
        guard (0...1).contains(n.x), (0...1).contains(n.y) else { return }
        // The ring grows out of the touch-down mark, at once.
        pressMarkTask?.cancel()
        pressMark?.removeFromSuperlayer()
        pressMark = nil
        ring(at: g.location(in: self))
        onTap(n)
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
        if newWindow == nil { endMomentum() }
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
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerIfSmall() }
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
