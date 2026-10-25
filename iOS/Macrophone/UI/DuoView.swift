import MacrophoneKit
import SwiftUI
import UIKit

// The iPhone Duo (Oct 25 2026, Sameer: "Everything we built needs to work well on the front
// screen and then we need to come up with an epic inside screen experience … like a little
// MacBook"). The cover screen keeps the phone's layout (`MainView.phoneBody`). The inner screen
// is the Mac, in four poses, each laid out from the same pieces — the top bar, the window view,
// the Send to panel, the transcript, the mic · keyboard · trackpad carousel:
//
//   open, upright        the window large across the top; below it, side by side with the fold's
//                        line between them, the Send to panel (left) and the mic (right)
//   open, on its side    the window tall and wide on the left; a rail on the right: the top bar,
//                        the panel above the fold's line, the mic below it
//   laptop               the hinge across — the Mac fills the top half edge to edge; the bottom
//                        half is the deck: the window's controls, then the trackpad (like a
//                        laptop), the keyboard (the iOS keyboard rising over that half) or the mic
//   book                 the hinge up and down — the Mac on the left page, the deck on the right
//                        (the right thumb drives the trackpad, and it reads as a laptop does, the
//                        screen then the keys)
//
// Nothing sits on the fold: the folded poses split at the fold's region (`FoldHalves`), the flat
// ones keep a gap each side of its line. The split follows the hinge: the deck rises and the Mac's
// picture settles into its half as the angle closes (`Posture.rise`). Every pose keeps the state —
// the window, the zoom (kept per app), the carousel's page, a dictation under way, a sheet.

/// The Duo's measures.
enum DuoLook {
    /// The room kept clear each side of the fold's line on a flat inner screen.
    static let foldGap: CGFloat = 14
    /// The rail beside the window when the screen is open on its side.
    static let rail: CGFloat = 352
    /// The Mac's half: the bezel runs almost to the edges.
    static let halfInset: CGFloat = 4
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
                DuoMacArea(watcher: watcher, compact: false)
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity)
                HStack(alignment: .top, spacing: DuoLook.foldGap) {
                    lowerPanel
                        .frame(width: half, alignment: .top)
                    carousel(fill: nil, compact: false)
                        .frame(width: half)
                }
                .padding(.top, 10)
                .frame(minHeight: showLiveWords ? 250 : nil, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: showLiveWords)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: watcher.isOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FoldPose.open(landscape: false).spoken)
    }

    // MARK: Open, on its side (951 × 669 points)

    var openLandscapeBody: some View {
        HStack(alignment: .top, spacing: DuoLook.foldGap) {
            DuoMacArea(watcher: watcher, compact: false)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                topBar
                lowerPanel
                    .padding(.top, 14)
                Spacer(minLength: 8)
                carousel(fill: nil, compact: false)
            }
            .frame(width: DuoLook.rail)
        }
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: showLiveWords)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: watcher.isOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FoldPose.open(landscape: true).spoken)
    }

    // MARK: The laptop (the hinge across)

    var laptopBody: some View {
        GeometryReader { geo in
            let h = posture.halves ?? FoldHalves.split(geo.size, pose: .laptop, division: nil)!
            let rise = posture.rise
            VStack(spacing: 0) {
                DuoMacHalf(watcher: watcher)
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
                DuoMacHalf(watcher: watcher)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FoldPose.book.spoken)
    }

    // MARK: The pieces

    /// Under the window on a flat inner screen: the Send to panel, or the transcript while the
    /// mic is open (and until the words have gone out).
    @ViewBuilder var lowerPanel: some View {
        if showLiveWords {
            transcriptArea
                .transition(.opacity)
        } else {
            quickControls
                .transition(.opacity)
        }
    }

    /// The carousel — the page row, the Thread, the mic · keyboard · trackpad pages — as the phone
    /// builds it. `fill`: the deck's room, which the pages take whole (the trackpad fills it, the
    /// mic sits in the middle of it); a deck is short, so its Thread's slot is slimmer (the
    /// Thread's light runs past its slot as ever), the mic nearer it and the status one line.
    func carousel(fill: CGFloat?, compact: Bool) -> some View {
        let deck = fill != nil
        let slot: CGFloat = deck ? 40 : compact ? 56 : 84
        return InputCarousel(input: input, watcher: watcher, compact: compact, threadHeight: slot, fill: fill) {
            VStack(spacing: 0) {
                Color.clear.frame(height: deck ? 8 : compact ? 14 : 30)
                MicButton(recording: isRecording,
                          finishing: isFinishing,
                          mode: filamentMode,
                          disabled: micOff,
                          meter: recorder.meter,
                          onDown: pressDown,
                          onUp: pressUp,
                          onAccessibilityToggle: { model.toggleRecording() })
                if deck {
                    FixedSlot(alignment: .top) {
                        Text("A").font(.subheadline).frame(maxWidth: .infinity)
                    } content: {
                        StatusLine(recorder: recorder, holding: holding || look == "holding")
                    }
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                    .padding(.bottom, 2)
                } else {
                    statusSlot
                        .padding(.bottom, compact ? 6 : 18)
                }
            }
        } thread: {
            ZStack {
                Filament(mode: filamentMode, meter: recorder.meter, height: deck ? 48 : compact ? 56 : 96)
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
/// the keys), or — nothing watched — the glance: the picked app, and a tap to show it live.
struct DuoMacArea: View {
    @ObservedObject var watcher: Watcher
    var compact: Bool

    var body: some View {
        ZStack {
            if watcher.isOpen {
                WatchPanel(watcher: watcher, compact: compact)
                    .transition(.opacity)
            } else {
                DuoGlance()
                    .padding(.horizontal, WatchLook.sideMargin)
                    .padding(.vertical, 4)
                    .transition(.opacity)
            }
        }
    }
}

/// The Mac's half of a folded screen: the window edge to edge (its controls live on the deck),
/// or the glance.
struct DuoMacHalf: View {
    @ObservedObject var watcher: Watcher

    var body: some View {
        ZStack {
            if watcher.isOpen {
                WatchWindow(watcher: watcher, interactive: true)
                    .overlay(alignment: .bottom) { MacPermissionBanner(watcher: watcher) }
                    .transition(.opacity)
            } else {
                DuoGlance()
                    .transition(.opacity)
            }
        }
        .padding(DuoLook.halfInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Mac")
    }
}

/// The deck of a folded screen: the window's controls (the name and its menu, Sound, Mac
/// Controls, zoom out, Window, Done), its keys or the question's answers, then the carousel —
/// the trackpad by default in these poses, the keyboard, the mic — filling the rest. Not
/// watching: the main screen's top bar and the Send to panel over the mic. `vertical`: the
/// book's page (narrow and tall), where the controls take two rows.
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
            if watcher.isOpen {
                WatchHeaderBar(watcher: watcher, twoRows: vertical) { t, _ in watcher.say(t.title, symbol: "arrow.left.and.right") }
                    .padding(.horizontal, WatchLook.sideMargin)
                    .padding(.top, 4)
                if main.showLiveWords {
                    main.transcriptArea
                        .frame(maxHeight: .infinity)
                } else {
                    WatchActions(watcher: watcher, wide: !vertical)
                        .padding(.horizontal, WatchLook.sideMargin)
                        .opacity(watcher.phase == .live ? 1 : 0)
                        .allowsHitTesting(watcher.phase == .live)
                        .accessibilityHidden(watcher.phase != .live)
                }
            } else {
                main.topBar
                if main.showLiveWords {
                    main.transcriptArea
                        .frame(maxHeight: .infinity)
                } else {
                    main.quickControls
                        .padding(.top, 8)
                }
            }
            // The pages take what's left: the trackpad whole, the mic in the middle of it.
            GeometryReader { g in
                main.carousel(fill: g.size.height, compact: true)
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
            }
            .frame(minHeight: main.showLiveWords ? 150 : 160)
        }
        .animation(Motion.pick(Motion.settle, reduce: main.reduceMotion), value: main.showLiveWords)
        .animation(Motion.pick(Motion.settle, reduce: main.reduceMotion), value: watcher.isOpen)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The deck: trackpad, keyboard and mic")
    }
}

/// Nothing watched on the inner screen: the picked app on a plate of the window's bezel, and one
/// tap to show it live (the Whole Screen for the Clipboard or Where I'm typing) — or what's
/// missing: a Mac to pair, a Mac to connect.
struct DuoGlance: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let bezel = RoundedRectangle(cornerRadius: WatchLook.bezel, style: .continuous)
        let target = model.selection.target
        ZStack {
            bezel.fill(Ink.sunk)
                .overlay(bezel.strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
                .padding(WatchLook.bezelWidth)
                .background { bezel.fill(Ink.raised).shadow(color: .black.opacity(reduceTransparency ? 0 : 0.5), radius: 16, y: 10) }
                .overlay(SpecularEdge(shape: bezel))
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
                    if let icon = model.liveTarget(for: target)?.icon, let img = UIImage(data: icon) {
                        Image(uiImage: img).resizable().frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityHidden(true)
                    } else {
                        GlyphPlate(symbol: target == .clipboard || target == .frontApp ? "macwindow.on.rectangle" : "app", tint: Light.cyan, size: 56)
                    }
                    Text(Places.appName(target, in: model)).font(.serif(.title2)).foregroundStyle(Ink.ink)
                    Text(target == .clipboard || target == .frontApp ? "Your Mac's whole screen, live." : "Its window on your Mac, live — and your words go there.")
                        .font(.footnote).foregroundStyle(Ink.secondary)
                    Button { model.showWindowForPose() } label: { Label("Show it here", systemImage: "eye").fontWeight(.semibold) }
                        .duoProminentButton()
                        .disabled(target == .clipboard || target == .frontApp ? !model.watcher.canWatchDesktop : false)
                        .accessibilityIdentifier("duo-show")
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .frame(maxWidth: 360)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your Mac")
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
