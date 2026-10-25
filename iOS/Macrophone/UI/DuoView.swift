import MacrophoneKit
import SwiftUI
import UIKit

// The iPhone Duo (Oct 25 2026, Sameer: "Everything we built needs to work well on the front
// screen and then we need to come up with an epic inside screen experience … like a little
// MacBook with the window or full screen taking up the full half when partially folded and the
// bottom half being trackpad or keyboard or mic to control it"). The cover screen keeps the
// phone's layout (`MainView.phoneBody`). The inner screen is the Mac, in four poses, each laid
// out from the same pieces — the top bar, the window, the Send to panel, the transcript, the
// mic · keyboard · trackpad carousel. The second pass (the same day) made the folded poses a
// laptop in earnest:
//
//   laptop               the hinge across — the top half IS the Mac's screen: the picture edge to
//                        edge, filling the half (a window the Mac can reshape takes the half's
//                        shape by itself; one it can't is zoomed to cover it, scrolling), a slim
//                        translucent header laid over its top like a menu bar (the window's name
//                        and menu, Sound, Mac Controls, Pan | Scroll, zoom out, Window, Done)
//                        that fades after a few seconds and comes back on a touch, the question's
//                        answers floating over its foot. The bottom half is the deck, all of it:
//                        the trackpad the whole half (the three pages as a small cluster in its
//                        corner), the keyboard rising over it with the Mac's keys on its bar, or
//                        the mic with the Thread across the half — the words you say shown over
//                        the picture above while you talk
//   book                 the hinge up and down — the same, the Mac on the left page and the deck
//                        on the right (the right thumb drives the trackpad)
//   open, upright        the window large across the top (most of the height, the whole width;
//                        a first-run tip keeps to its corner); under it, side by side with the
//                        fold's line between them, Send to as a row of icons (left) and the mic
//                        with its pages (right)
//   open, on its side    the window tall on the left; a rail on the right: the top bar, Send to,
//                        then the deck filling the rest (the trackpad whole, or the mic, or the
//                        keyboard) — the rail keeps the window near-square, so a window fitted to
//                        it reads like a laptop's, puts the controls under the right thumb, and
//                        only the picture crosses the fold
//
// Done on the inner screen is the glance, not a closed window (`Watcher.glance`): the picked
// app's window stays live and big, its controls put away, Show it here to take it in hand again.
// Nothing sits on the fold: the folded poses split at the fold's region (`FoldHalves`), the flat
// ones keep a gap each side of its line. The split follows the hinge: the deck rises and the Mac's
// picture settles into its half as the angle closes (`Posture.rise`), and the poses cross-fade.
// Every pose keeps the state — the window, the zoom (kept per app), the carousel's page, a
// dictation under way, a sheet.

/// The Duo's measures.
enum DuoLook {
    /// The room kept clear each side of the fold's line on a flat inner screen.
    static let foldGap: CGFloat = 14
    /// The rail beside the window when the screen is open on its side.
    static let rail: CGFloat = 316
    /// A folded half's screen: a hair of bezel, the corner tight to the half's.
    static let halfBezel: CGFloat = 2
    static let halfCorner: CGFloat = 14
    /// How long the overlay header stays after a touch.
    static let headerHold: TimeInterval = 3.5
}

extension MainView {
    // MARK: Open, upright (669 × 951 points)

    var openPortraitBody: some View {
        GeometryReader { geo in
            // Each half a set width (the carousel sizes its pages to the width it's given — a
            // flexible split would have it chasing its own measure), the fold's line between.
            let half = max(0, (geo.size.width - DuoLook.foldGap) / 2)
            VStack(spacing: 0) {
                topBar
                DuoMacArea(main: self)
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity)
                HStack(alignment: .top, spacing: DuoLook.foldGap) {
                    lowerPanel
                        .frame(width: half, alignment: .top)
                    carousel(fill: nil, compact: true)
                        .frame(width: half)
                }
                .padding(.top, 8)
                .frame(minHeight: showLiveWords ? 230 : nil, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: showLiveWords)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: watcher.isShowing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FoldPose.open(landscape: false).spoken)
    }

    // MARK: Open, on its side (951 × 669 points)

    var openLandscapeBody: some View {
        HStack(alignment: .top, spacing: DuoLook.foldGap) {
            DuoMacArea(main: self)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                topBar
                lowerPanel
                    .padding(.top, 12)
                    .frame(height: showLiveWords ? 250 : nil)
                // The deck takes the rest of the rail: the trackpad whole, the mic in the middle.
                GeometryReader { g in
                    carousel(fill: g.size.height, compact: true)
                        .frame(width: g.size.width, height: g.size.height, alignment: .top)
                }
                .padding(.top, 6)
            }
            .frame(width: DuoLook.rail)
        }
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: showLiveWords)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: watcher.isShowing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FoldPose.open(landscape: true).spoken)
    }

    // MARK: The laptop (the hinge across)

    var laptopBody: some View {
        GeometryReader { geo in
            let h = posture.halves ?? FoldHalves.split(geo.size, pose: .laptop, division: nil)!
            let rise = posture.rise
            VStack(spacing: 0) {
                DuoMacHalf(main: self, vertical: false, room: h.mac.size)
                    .frame(height: max(0, h.mac.height))
                    // The picture settles into its half as the hinge closes.
                    .scaleEffect(reduceMotion ? 1 : 0.97 + 0.03 * rise, anchor: .top)
                    .opacity(0.6 + 0.4 * rise)
                // The fold: nothing sits here.
                Color.clear.frame(height: max(0, h.deck.minY - h.mac.maxY))
                DuoDeck(main: self, vertical: false)
                    .frame(height: max(0, h.deck.height))
                    // The deck rises as the hinge folds.
                    .offset(y: reduceMotion ? 0 : (1 - rise) * 36)
                    .opacity(0.2 + 0.8 * rise)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: rise)
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: h)
        }
        // The keyboard rises over the deck's half; the Mac's half never shrinks for it.
        .ignoresSafeArea(.keyboard)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FoldPose.laptop.spoken)
    }

    // MARK: The book (the hinge up and down)

    var bookBody: some View {
        GeometryReader { geo in
            let h = posture.halves ?? FoldHalves.split(geo.size, pose: .book, division: nil)!
            let rise = posture.rise
            HStack(spacing: 0) {
                DuoMacHalf(main: self, vertical: true, room: h.mac.size)
                    .frame(width: max(0, h.mac.width))
                    .scaleEffect(reduceMotion ? 1 : 0.97 + 0.03 * rise, anchor: .leading)
                    .opacity(0.6 + 0.4 * rise)
                Color.clear.frame(width: max(0, h.deck.minX - h.mac.maxX))
                DuoDeck(main: self, vertical: true)
                    .frame(width: max(0, h.deck.width))
                    .offset(x: reduceMotion ? 0 : (1 - rise) * 36)
                    .opacity(0.2 + 0.8 * rise)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: rise)
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: h)
        }
        // The keyboard is the screen's width: it rises over the foot of both pages; the Mac's
        // page keeps its height.
        .ignoresSafeArea(.keyboard)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FoldPose.book.spoken)
    }

    // MARK: The pieces

    /// Under or beside the window on a flat inner screen: the Send to panel, or the transcript
    /// while the mic is open (and until the words have gone out).
    @ViewBuilder var lowerPanel: some View {
        if showLiveWords {
            transcriptArea
                .transition(.opacity)
        } else {
            sendToPanel(compact: true)
                .transition(.opacity)
        }
    }

    /// The Send to panel at a size.
    func sendToPanel(compact: Bool) -> some View {
        QuickControls(settings: model.settings, compact: compact, glow: skyGlow)
            .padding(.bottom, compact ? 8 : 18)
    }

    /// The carousel — the page row, the Thread, the mic · keyboard · trackpad pages — as the phone
    /// builds it. `fill`: the room the pages take whole (the trackpad fills it, the mic sits in
    /// the middle of it); `rowHidden`: a folded deck, where the switcher is a cluster in the
    /// corner and the Thread has its full slot across the half.
    func carousel(fill: CGFloat?, compact: Bool, rowHidden: Bool = false) -> some View {
        let deck = fill != nil
        // A flat inner screen's bottom bar is kept tight (the window has the room): the Thread's
        // slot a step slimmer and the status one line, as a deck's.
        let slot: CGFloat = rowHidden ? 84 : deck ? 48 : compact ? 48 : 84
        let oneLine = deck || compact
        return InputCarousel(input: input, watcher: watcher, compact: compact, threadHeight: slot, fill: fill, rowHidden: rowHidden) {
            VStack(spacing: 0) {
                Color.clear.frame(height: deck ? 8 : compact ? 10 : 30)
                MicButton(recording: isRecording,
                          finishing: isFinishing,
                          mode: filamentMode,
                          disabled: micOff,
                          meter: recorder.meter,
                          onDown: pressDown,
                          onUp: pressUp,
                          onAccessibilityToggle: { model.toggleRecording() })
                if oneLine {
                    FixedSlot(alignment: .top) {
                        Text("A").font(.subheadline).frame(maxWidth: .infinity)
                    } content: {
                        StatusLine(recorder: recorder, holding: holding || look == "holding")
                    }
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                    .padding(.bottom, deck ? 2 : 6)
                    // The Thread above and the mic together sit in the middle of the half.
                    if rowHidden { Color.clear.frame(height: slot / 2) }
                } else {
                    statusSlot
                        .padding(.bottom, compact ? 6 : 18)
                }
            }
        } thread: {
            ZStack {
                Filament(mode: filamentMode, meter: recorder.meter, height: rowHidden ? 96 : deck ? 56 : compact ? 56 : 96)
                    .frame(height: slot)
                DeliveredCheck(visible: showCheck, color: checkColor)
                timer.frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: slot)
            .padding(.horizontal, -4)
        }
        .onChange(of: showLiveWords) { _, live in if live, input.page != .mic { input.show(.mic, quiet: true) } }
    }
}

/// The Mac on a flat inner screen: the window view as the phone has it (its header, the window,
/// the keys or the answers in a row), or — Done, or nothing watched — the glance.
struct DuoMacArea: View {
    let main: MainView
    @ObservedObject private var watcher: Watcher

    init(main: MainView) {
        self.main = main
        _watcher = ObservedObject(wrappedValue: main.watcher)
    }

    var body: some View {
        ZStack {
            if watcher.isShowing {
                WatchPanel(watcher: watcher, compact: false, duo: true)
                    .transition(.opacity)
            } else {
                DuoGlance(watcher: watcher, fill: false)
                    .padding(.horizontal, WatchLook.sideMargin)
                    .padding(.vertical, 4)
                    .transition(.opacity)
            }
        }
    }
}

/// The Mac's half of a folded screen — a MacBook's screen: the picture edge to edge, filling the
/// half; a slim header laid over its top like a menu bar that fades after a few seconds and
/// comes back on a touch (never fades for VoiceOver); the question's answers floating over its
/// foot; the words you're saying over the picture while the mic is open. Or the glance.
struct DuoMacHalf: View {
    let main: MainView
    /// The book's page: narrow and tall, so the header takes two rows.
    var vertical: Bool
    /// The half's size (what the words over the picture may take).
    var room: CGSize
    @ObservedObject private var watcher: Watcher
    @State private var headerShown = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(main: MainView, vertical: Bool, room: CGSize) {
        self.main = main
        self.vertical = vertical
        self.room = room
        _watcher = ObservedObject(wrappedValue: main.watcher)
    }

    var body: some View {
        ZStack {
            if watcher.isShowing {
                WatchWindow(watcher: watcher, interactive: true, bezelWidth: DuoLook.halfBezel, corner: DuoLook.halfCorner, fill: true)
                    .overlay(alignment: .bottom) { MacPermissionBanner(watcher: watcher) }
                    .overlay(alignment: .bottom) {
                        if main.showLiveWords {
                            DuoLiveWords(main: main, room: room)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else {
                            WatchActions(watcher: watcher, floating: true)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                                .opacity(watcher.phase == .live ? 1 : 0)
                                .allowsHitTesting(watcher.phase == .live)
                                .accessibilityHidden(watcher.phase != .live)
                        }
                    }
                    .overlay(alignment: .top) {
                        // Down, it's gone (not merely faded): nothing of it for a finger or
                        // VoiceOver to find over the screen.
                        if headerUp {
                            DuoOverlayHeader(watcher: watcher, twoRows: vertical)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
                        }
                    }
                    .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.3), value: headerUp)
                    // A touch anywhere on the screen brings the header back (the window's own
                    // gestures go on as before).
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in reveal() })
                    .transition(.opacity)
            } else {
                DuoGlance(watcher: watcher, fill: true)
                    .transition(.opacity)
            }
        }
        .onAppear { reveal() }
        .onChange(of: watcher.isShowing) { _, _ in reveal() }
        .onChange(of: watcher.answers?.id) { _, _ in reveal() }
        .onChange(of: watcher.phase) { _, _ in reveal() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Mac")
    }

    /// The header shows: lately touched, or always for VoiceOver (and held for a screenshot).
    private var headerUp: Bool {
        #if DEBUG
        if DebugHooks.duoHeaderHeld { return true }
        #endif
        return headerShown || voiceOver || watcher.phase != .live
    }

    private func reveal() {
        hideTask?.cancel()
        if !headerShown { headerShown = true }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(DuoLook.headerHold * 1e9))
            guard !Task.isCancelled else { return }
            headerShown = false
        }
    }
}

/// The menu bar over a folded half's picture: the window's header on a dark gradient that
/// fades into the picture, so the top of the screen is still the screen.
struct DuoOverlayHeader: View {
    @ObservedObject var watcher: Watcher
    var twoRows: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        WatchHeaderBar(watcher: watcher, twoRows: twoRows, dragSwitch: !twoRows) { t, _ in watcher.say(t.title, symbol: "arrow.left.and.right") }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .background {
                LinearGradient(colors: [Ink.ground.opacity(reduceTransparency ? 0.96 : 0.82), Ink.ground.opacity(reduceTransparency ? 0.96 : 0.5), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: DuoLook.halfCorner, style: .continuous))
            .padding(DuoLook.halfBezel)
    }
}

/// The words you're saying, over the picture (a folded half): where they're going and the words
/// themselves on a card of glass over the foot of the screen, up to half the half.
struct DuoLiveWords: View {
    let main: MainView
    var room: CGSize

    var body: some View {
        VStack(spacing: 0) {
            DestinationLine(words: main.recorder.words)
                .padding(.horizontal, 18)
                .padding(.top, 14)
            LiveWords(words: main.recorder.words, listening: main.isRecording)
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .frame(maxWidth: 640)
        .frame(height: max(120, min(room.height * 0.62, 320)))
        .watchGlass(RoundedRectangle(cornerRadius: WatchLook.card, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }
}

/// The deck of a folded screen, all of it: the trackpad the whole half (the three pages as a
/// cluster in its corner), the keyboard rising over it with the Mac's keys on its bar, or the mic
/// with the Thread across the half. Not watching: the main screen's top bar and the Send to panel
/// over the mic. `vertical`: the book's page (narrow and tall).
struct DuoDeck: View {
    let main: MainView
    var vertical: Bool
    @ObservedObject private var watcher: Watcher
    @ObservedObject private var input: MacInput

    init(main: MainView, vertical: Bool) {
        self.main = main
        self.vertical = vertical
        _watcher = ObservedObject(wrappedValue: main.watcher)
        _input = ObservedObject(wrappedValue: main.watcher.input)
    }

    var body: some View {
        VStack(spacing: 6) {
            if watcher.isShowing {
                // The pages take the whole half; the switcher sits in the corner over them.
                GeometryReader { g in
                    main.carousel(fill: g.size.height, compact: true, rowHidden: true)
                        .frame(width: g.size.width, height: g.size.height, alignment: .top)
                }
                .overlay(alignment: .topTrailing) {
                    if input.pages.count > 1 {
                        InputCornerSwitcher(input: input)
                            .padding(.top, 16)
                            .padding(.trailing, WatchLook.sideMargin + 8)
                    }
                }
            } else {
                main.topBar
                if main.showLiveWords {
                    main.transcriptArea
                        .frame(maxHeight: .infinity)
                } else {
                    main.sendToPanel(compact: true)
                        .padding(.top, 8)
                }
                // The mic in the middle of what's left.
                GeometryReader { g in
                    main.carousel(fill: g.size.height, compact: true)
                        .frame(width: g.size.width, height: g.size.height, alignment: .top)
                }
                .frame(minHeight: main.showLiveWords ? 150 : 160)
            }
        }
        .animation(Motion.pick(Motion.settle, reduce: main.reduceMotion), value: main.showLiveWords)
        .animation(Motion.pick(Motion.settle, reduce: main.reduceMotion), value: watcher.isShowing)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The deck: trackpad, keyboard and mic")
    }
}

/// The glance (Oct 25 2026): the picked app's window, live and big, with its controls put away —
/// a bar over its foot names it and one tap takes it in hand (Show it here). Nothing watched yet:
/// the picked app on a plate of the window's bezel and the same tap; or what's missing — a Mac
/// to pair, a Mac to connect.
struct DuoGlance: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    /// A folded half: the picture fills it, edge to edge.
    var fill: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let target = model.selection.target
        ZStack {
            if watcher.isOpen, watcher.hasPicture {
                // Live, the pictures still coming: the same screen, without its controls.
                WatchWindow(watcher: watcher, interactive: false,
                            bezelWidth: fill ? DuoLook.halfBezel : WatchLook.bezelWidth,
                            corner: fill ? DuoLook.halfCorner : WatchLook.bezel, fill: fill)
                    .overlay(alignment: .bottom) { liveBar }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(watcher.name)'s window on your Mac, live")
            } else {
                plate
                VStack(spacing: 14) {
                    if !model.isPaired {
                        GlyphPlate(symbol: "macbook.and.iphone", tint: Light.cyan, size: 56)
                        Text("Pair your Mac").font(.serif(.title2)).foregroundStyle(Ink.ink)
                        Text("Your Mac's windows show here, live, once Macrophone on your Mac is paired.")
                            .font(.footnote).foregroundStyle(Ink.secondary)
                        Button { model.sheet = .pairing } label: { Label("Pair a Mac", systemImage: "qrcode.viewfinder").fontWeight(.semibold) }
                            .duoProminentButton()
                            .accessibilityIdentifier("duo-pair")
                    } else if !model.isConnected {
                        GlyphPlate(symbol: "wifi.exclamationmark", tint: Ink.secondary, size: 56)
                        Text("Looking for \(model.macName)").font(.serif(.title2)).foregroundStyle(Ink.ink)
                        Text("Its window shows here the moment it's connected.")
                            .font(.footnote).foregroundStyle(Ink.secondary)
                    } else {
                        icon(target, size: 64)
                        Text(Places.appName(target, in: model)).font(.serif(.title2)).foregroundStyle(Ink.ink)
                        Text(target == .clipboard || target == .frontApp ? "Your Mac's whole screen, live." : "Its window on your Mac, live — and your words go there.")
                            .font(.footnote).foregroundStyle(Ink.secondary)
                        showButton
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .frame(maxWidth: 360)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Mac")
    }

    /// The empty screen: a plate of the window's bezel.
    private var plate: some View {
        let bezel = RoundedRectangle(cornerRadius: fill ? DuoLook.halfCorner : WatchLook.bezel, style: .continuous)
        return bezel.fill(Ink.sunk)
            .overlay(bezel.strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
            .padding(fill ? DuoLook.halfBezel : WatchLook.bezelWidth)
            .background { bezel.fill(Ink.raised).shadow(color: .black.opacity(reduceTransparency ? 0 : 0.5), radius: 16, y: 10) }
            .overlay(SpecularEdge(shape: bezel))
    }

    /// Over the live picture's foot: the app, that it's live (or paused), and Show it here.
    private var liveBar: some View {
        let target = model.selection.target
        return HStack(spacing: 12) {
            icon(target, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(watcher.name).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                Text(watcher.phase.isPaused ? "Paused · Show it here to go on" : "Live on your Mac")
                    .font(.caption).foregroundStyle(watcher.phase.isPaused ? Light.ochre : Ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            showButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .background {
            LinearGradient(colors: [.clear, Ink.ground.opacity(reduceTransparency ? 0.96 : 0.55), Ink.ground.opacity(reduceTransparency ? 0.96 : 0.86)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: fill ? DuoLook.halfCorner : WatchLook.bezel, style: .continuous))
        .padding(fill ? DuoLook.halfBezel : WatchLook.bezelWidth)
    }

    private var showButton: some View {
        let target = model.selection.target
        return Button { model.showWindowForPose() } label: { Label("Show it here", systemImage: "eye").fontWeight(.semibold) }
            .duoProminentButton()
            .disabled(target == .clipboard || target == .frontApp ? !model.watcher.canWatchDesktop : false)
            .accessibilityHint("Takes the window in hand: tap to click, the trackpad, the keyboard and the mic.")
            .accessibilityIdentifier("duo-show")
    }

    @ViewBuilder private func icon(_ target: TargetRef, size: CGFloat) -> some View {
        if let icon = model.liveTarget(for: target)?.icon, let img = UIImage(data: icon) {
            Image(uiImage: img).resizable().frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .accessibilityHidden(true)
        } else {
            GlyphPlate(symbol: target == .clipboard || target == .frontApp ? "macwindow.on.rectangle" : "app", tint: Light.cyan, size: size * 0.875)
        }
    }
}

private extension View {
    @ViewBuilder func duoProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Light.cyan).foregroundStyle(Ink.ground)
        } else {
            buttonStyle(.borderedProminent).tint(Light.cyan).foregroundStyle(Ink.ground)
        }
    }
}

/// Where the inner screen turns (Oct 25 2026): every way on the Duo's inner screen; the cover,
/// and every other iPhone, stays upright as before (`UISupportedInterfaceOrientations` lists
/// them all; this narrows it by the screen the window is on).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let screen = window?.screen else { return .portrait }
        let b = screen.bounds.size
        return min(b.width, b.height) >= FoldPose.innerShortSide ? .all : .portrait
    }
}
