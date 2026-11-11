import MacrophoneKit
import SwiftUI

/// The mic screen. Two parts:
///
/// - **The bottom, fixed:** the mic and the status line, near the foot of the screen. Their slot
///   never changes size, so **the mic never moves** — idle, held, recording, sending, delivered.
/// - **Everything above, one area:** idle, it holds the top bar and the header at the top, then —
///   in thumb reach, just above the Thread — the controls panel (Send to, Send after pasting,
///   Cleanup). While the mic is open — and until the words have gone out — all of that steps aside
///   and the area is the transcript: as much of what you're saying as fits, from the top down.
///
/// The last dictation isn't on this screen any more (Oct 13 2026): it's in History.
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    @ObservedObject var watcher: Watcher
    /// The three ways in while a window shows (Oct 19 2026): which page is up.
    @ObservedObject var input: MacInput
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    init(recorder: Recorder, watcher: Watcher) {
        self.recorder = recorder
        self.watcher = watcher
        _input = ObservedObject(wrappedValue: watcher.input)
    }
    @Environment(\.dynamicTypeSize) var typeSize

    @State var startedByPress = false
    @State var stopOnRelease = false
    @State var holding = false
    @State var filamentMode: FilamentMode = .ready
    @State var showCheck = false
    @State var settleTask: Task<Void, Never>?
    /// iPhone SE-class heights: a shorter stage and card; History lives in the top bar only.
    @State var compact = false
    /// The system puts a vertical bar on this screen (the iPhone Duo's cover, iOS 27.1).
    @State var verticalBar = VerticalBarProbe.atLaunch
    /// The settings' room while they last showed (`phoneBody`).
    @State var settingsRoom: CGFloat = 0
    /// The menu bar's (the cover's top bar's) height: the desktop's empty state sits under it.
    @State var desktopTop: CGFloat = 0
    /// Where the window shows (`phoneBody`, on screen): what it grows out of the Dock into.
    @State var watchArea: CGRect = .zero
    /// The window comes from the Dock and goes back into it (opened, Done) — but not when it
    /// steps aside for the words while the mic is open, or comes back after them: it grew out
    /// of the hidden Dock then, as if opened again (Nov 4 2026).
    @State var windowViaDock = true
    /// The desktop's window card opened it: it grows out of the card, and Done puts it back there.
    @State var windowFromCard = false
    /// The phone layout's window panel is built and kept (Nov 7 2026): under the words it gives up
    /// its viewer (the strip has the video then).
    @State var panelDormant = true
    /// The first open's pages and header, built unseen once after launch has settled (`warmPanel`).
    @State var panelWarm = false
    @State var panelUp = false
    @State var panelTask: Task<Void, Never>?
    /// The pose's layout lies under full screen: its windows have no viewer (`poseBody`).
    @State var innerAsleep = false
    @State var innerAsleepTask: Task<Void, Never>?
    /// The picture's flight into and out of full screen (Nov 8 2026): the status bar waits for it.
    @ObservedObject var fullScreenZoom = FullScreenZoom.shared
    /// The mic is one thing wherever a layout puts it (Nov 4 2026): as one layout gives way to
    /// another (a window coming into hand on the Duo's inner screen, a pose) it moves to its new
    /// place instead of one fading out where it was while another fades in somewhere else.
    @Namespace var micSpace
    /// …within one screen: the cover's mic and the inner screen's are different screens, and
    /// matched across the fold the inner one flew in from where the cover's sat, unseen for its
    /// first frames as the phone opened (Nov 4 2026).
    var micID: String { posture.pose.isInner ? "mic.inner" : "mic" }
    /// The cover's lower buttons the Mac offered when it was last connected.
    @AppStorage("bar.had.wholeScreen") var barHadWholeScreen = false
    @AppStorage("bar.had.controls") var barHadControls = false
    @State var coverPickingPhoto = false
    @State var coverPickingFile = false
    /// The iPhone Duo's cover: its buttons go in the vertical bar, the window takes the room.
    var isCover: Bool { barUsed && posture.pose == .closed }
    /// This layout's buttons are in the vertical bar: the cover, and the inner screen on its side
    /// (open, or the book — the bar is on the camera side there too, 84 pt). Upright, the inner
    /// screen has a status bar on top and no vertical bar, so the laptop and flat portrait draw
    /// their own (the trait says so on his phone; on the simulator the inner screen is a frame
    /// drawn on the cover, whose trait would otherwise speak for every pose — Nov 1 2026).
    /// Open flat and upright the controls go in the bar too (Nov 1 2026, Sameer: "in this fully
    /// opened portrait mode you should put controls into the duo side bar area").
    /// On the inner screen on its side the pose says so by itself (Nov 4 2026): opening the phone,
    /// the scene's first frames on the inner screen carry no vertical bar yet, and the layout drew
    /// its own top bar (the Mac's pill, History, Settings) for a moment before the bar came.
    var barUsed: Bool { ((verticalBar || posture.pose.isInner) && posture.pose.hasVerticalBar) || posture.pose == .open(landscape: false) }

    var isRecording: Bool { recorder.phase == .recording || recorder.phase == .starting || look == "starting" }

    /// The mic has closed and the last words are settling (a tap waits for them).
    var isFinishing: Bool { recorder.phase == .finishing || look == "finishing" }

    /// The mic can't open until a permission is turned on in Settings: the button says so and waits.
    var micOff: Bool {
        if look == "disabled" { return true }
        if case .problem(_, true) = model.status { return true }
        return false
    }

    /// `MACROPHONE_MIC_LOOK` holds one of the button's looks for a screenshot (DEBUG only).
    var look: String? {
        #if DEBUG
        return DebugHooks.env["MACROPHONE_MIC_LOOK"]
        #else
        return nil
        #endif
    }

    /// The words stay on screen from the first word until the text has gone out.
    var showLiveWords: Bool {
        isRecording || recorder.phase == .finishing || model.processing
    }

    /// The top bar, header and controls: at rest, when nothing else has the area.
    var showSettings: Bool { !showLiveWords && !watcher.isShowing }

    /// The bar holds the window's buttons (Done, Sound, …) rather than the app's (the Mac, History,
    /// Settings, …) — changed in the same transaction as the layout, in every pose (Nov 7 2026: on
    /// the inner screen it followed 0.55 s behind, so after Done the window's items stayed a beat
    /// and empty glass flashed at the foot; in hand, the rest group sat over the mic meanwhile).
    var barWindow: Bool { innerSideBar ? innerBarWindow : watcher.isShowing }

    /// The inner screen on its side, where the vertical bar holds the window's buttons in hand.
    var innerSideBar: Bool { posture.pose.isInner && !posture.pose.foldAcross }
    /// The inner side bar's set (Nov 7 2026): the deck fades in on the settle spring and the bar
    /// changed on the tap, a beat ahead of it, so Show it here changes it `Motion.leave` later —
    /// about when the deck is half in. Done changes it at once, as the deck starts to go (a
    /// delay there left the window's items a beat over the cover's view).
    @State var innerBarWindow = false
    @State var innerBarTask: Task<Void, Never>?

    func followBar(_ showing: Bool) {
        innerBarTask?.cancel()
        guard showing, innerSideBar, !innerBarWindow else { innerBarWindow = showing; return }
        innerBarTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, watcher.isShowing else { return }
            innerBarWindow = true
        }
    }

    /// The phone's layout shows the window in its own area — not on the Duo's inner screen, where
    /// it's the cover's view beside the window and stays at rest (Nov 4 2026: it stays built, hidden,
    /// while a window is in hand, so the change is a fade, not a rebuild).
    var windowHere: Bool { watcher.isShowing && !posture.pose.isInner }
    /// The phone layout's settings show.
    var phoneSettings: Bool { !showLiveWords && !windowHere }


    /// How the iPhone Duo is held (Oct 25 2026): the cover screen keeps this layout; the inner
    /// screen's poses are laid out in `UI/DuoView.swift`.
    @ObservedObject var posture = Posture.shared

    var body: some View {
        poseBody
        // A pose settling: the layouts cross-fade (the halves' own motion follows the hinge).
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: posture.pose)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: inFullScreen)
        // Full screen has the whole screen. (Upright on the inner screen the status bar stays —
        // see `hidesStatusBar`.)
        // (And through the picture's flight out of full screen, until the window has shrunk.)
        .statusBarHidden(hidesStatusBar || fullScreenZoom.flying)
        .preference(key: StatusBarHiddenKey.self, value: hidesStatusBar || fullScreenZoom.flying)
        .persistentSystemOverlays(inFullScreen || fullScreenZoom.flying ? .hidden : .automatic)
        // Full screen is one continuous grow (Nov 8 2026): the picture flies between the window's
        // frame and the screen while the two layouts swap under it.
        .onChange(of: watcher.fullScreen) { _, on in fullScreenFlight(entering: on) }
        .overlay { FullScreenZoomFlight() }
        // The sky answers the state: cool when ready, ember while the mic is open, mint when it lands.
        // The Mac's own wallpaper behind everything; the state's light washes in from the foot —
        // orange while the mic is open, green when the words land; nothing at rest.
        .background(DesktopBackground(wallpaper: model.wallpaper, settings: model.settings, glow: filamentMode == .ready ? .clear : skyGlow)
            .animation(.easeInOut(duration: 0.7), value: filamentMode))
        // Siri's signal: the screen's edge glows while the mic listens.
        .overlay(ListeningEdge(active: isRecording && look == nil || look == "holding", meter: recorder.meter))
        // Delight (Nov 8 2026): the words fly into their Dock icon as they go; a milestone's note.
        .overlay { WordFlightLayer(allowed: (regularPhone || isCover) && !inFullScreen, window: windowHere ? watchArea : nil, selection: model.selection.target) }
        .overlay { MilestoneBanner(atRest: phoneSettings && !inFullScreen && model.sheet == nil) }
        .background(VerticalBarProbe(present: $verticalBar).frame(width: 0, height: 0).accessibilityHidden(true))
        // The first open's pages, built once ahead of it, unseen (`warmPanel`).
        .background(alignment: .bottom) { if panelWarm { PagesWarmup(input: input, watcher: watcher) } }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if DebugHooks.env["MACROPHONE_ROUTE_PROBE"] == "1" {
                Text(model.routeProbe).font(.system(size: 1)).opacity(0.01).frame(width: 1, height: 1)
                    .accessibilityIdentifier("debug-route").accessibilityLabel(model.routeProbe)
            }
        }
        #endif
        .onChange(of: model.isConnected ? [watcher.canWatchDesktop, model.canMacControls] : []) { _, had in
            if had.count == 2 { barHadWholeScreen = had[0]; barHadControls = had[1] }
        }
        .onChange(of: model.isConnected, initial: true) { _, on in warmPanel(connected: on) }
        .onChange(of: model.pulse) { _, _ in react() }
        .onChange(of: recorder.phase) { _, _ in react() }
        .onChange(of: recorder.hasWords) { _, _ in react() }
        .onChange(of: model.status) { _, _ in react() }
        .onAppear { react() }
        // A pose settling: a soft tick, and VoiceOver hears what's where now.
        .onChange(of: posture.settleSeq) { _, _ in
            Haptics.arrived()
            UIAccessibility.post(notification: .layoutChanged, argument: posture.pose.spoken)
        }
        .onChange(of: watcher.isShowing, initial: true) { _, on in followBar(on) }
        // A pose change takes the bar's set as it is, with the layout.
        .onChange(of: posture.pose) { _, _ in innerBarTask?.cancel(); innerBarWindow = watcher.isShowing }
    }

    /// Full screen hides the status bar, and so does the inner screen upright with a window in hand
    /// (the laptop, and flat upright): the Mac's picture runs from the screen's top edge to the
    /// fold, a little Mac's display (Nov 7 2026, Sameer: "I would rather not accommodate those
    /// elements in laptop view … fill up as much of the screen without being cut off by the Duo's
    /// rounded corners"). On iOS 27.1 hiding it there left SwiftUI's root laid out 82 pt down
    /// under an empty band, the mic cut at the foot — `StatusBarRoomFix` (RootView) pulls the
    /// root back up to the screen's top, so the band is never drawn.
    var hidesStatusBar: Bool { inFullScreen || (posture.pose.foldAcross && watcher.isShowing) }

    /// The laptop's picture under the screen's top edge (the status bar hidden) or under the status
    /// bar: how far it sits down and in. At the top edge the screen's rounded corners (55 pt) would
    /// cut a square picture's top corners, so it sits just far enough down that each corner point
    /// is on the curve — its sides keep the deck's margins, so the window, the answers and the
    /// modes still line up. Square, never rounded: a rounded plate would cut into the Mac window's
    /// traffic lights in that corner, which is what the inset is there to save.
    var uprightPictureTop: CGFloat { hidesStatusBar ? DuoLook.cornerClear(side: DuoLook.uprightMargin) : DuoLook.uprightTop }

    /// The inner screen's system bar shows: on its side (the vertical bar), and flat upright at
    /// rest (Mac · History · Settings beside the clock). Upright with a window in hand there's
    /// none — the deck's own header has Done and the window's controls, the laptop's and flat
    /// upright's alike, so folding one into the other moves nothing.
    var innerBarShown: Bool { barUsed && !(posture.pose.foldAcross && watcher.isShowing) }

    /// The pose's layout: the phone's (the cover screen, every other iPhone), or the Duo's.
    /// The window has the whole screen (Full Screen — every pose, the cover and every other
    /// iPhone since Nov 8 2026).
    var inFullScreen: Bool { watcher.fullScreen && watcher.isShowing }

    @ViewBuilder private var poseBody: some View {
        // Full screen lies over the pose's layout, which stays built underneath, hidden, its
        // windows without viewers (`innerAsleep`) — leaving full screen built the whole inner
        // screen again, its bar and both of its halves, a quarter of a second before anything
        // moved (Nov 4 2026).
        ZStack {
            layoutBody
                // Not drawn from a pose guessed before the hinge spoke (`Posture.provisional`).
                .opacity(inFullScreen || posture.provisional ? 0 : 1)
                .allowsHitTesting(!inFullScreen && !posture.provisional)
                .accessibilityHidden(inFullScreen || posture.provisional)
                .environment(\.innerAsleep, innerAsleep)
                // A sheet that covers the screen (Settings, History, pairing…) has nothing to
                // show the Thread to: its 60 fps stops competing with the sheet's own first
                // frames (Nov 7 2026).
                .environment(\.threadPaused, inFullScreen || model.sheet?.coversScreen == true)
            if inFullScreen {
                // In under the flight's picture; out at once (the picture shrinks over the layout
                // coming back — a fade of the full-screen view would double under it).
                // Removed at once under the flight (no fade to double under the shrinking picture);
                // with Reduce Motion there is no flight, so it fades out under the window fading
                // in (Nov 8 2026, round 3: gone at once, one frame showed the window at half
                // opacity over the wallpaper).
                DuoFullScreen(main: self).transition(.asymmetric(insertion: .opacity, removal: reduceMotion ? .opacity : .identity))
            }
        }
        .onChange(of: inFullScreen) { _, on in
            innerAsleepTask?.cancel()
            guard on else { innerAsleep = false; return }
            // Asleep once full screen has faded in over it (its window keeps its picture meanwhile).
            innerAsleepTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                innerAsleep = true
            }
        }
    }

    @ViewBuilder private var layoutBody: some View {
        switch posture.pose {
        case .closed: if isCover { coverBody.transition(.opacity) } else { phoneBody.transition(.opacity) }
        default: innerBarred(innerLayout).transition(.opacity)
        }
    }

    /// The inner screen's layouts, inside the one bar they share.
    @ViewBuilder private var innerLayout: some View {
        // One layout per way the screen is held, folded or flat: folding never swaps it, so it
        // moves nothing — the halves follow the hinge. On its side (the book, open flat) the
        // vertical bar holds the cover's buttons; upright (the laptop, open flat) the fold runs
        // across the middle.
        // Across a turn the layout leaving goes at once (Nov 7 2026): fading out in the new
        // screen's bounds it drew its controls where nothing is — a "Show it here" stranded on an
        // empty screen as the phone turned upright.
        if posture.pose.foldAcross {
            laptopBody.transition(Self.turn)
        } else {
            sideBody.transition(Self.turn)
        }
    }

    static let turn = AnyTransition.asymmetric(insertion: .opacity, removal: .identity)

    /// The inner screen's bar, one for every inner pose (Nov 4 2026): the pose's layout changes
    /// inside it, the stack itself never does. A stack per pose (and none on the laptop) made
    /// every fold a new stack, and a new stack lays its content out from nothing — the window and
    /// the mic grew out of the screen's corner as the laptop opened flat. Where the pose has no
    /// bar of the system's (the laptop: its controls are its own), the bar is hidden, not gone.
    @ViewBuilder func innerBarred<Content: View>(_ content: Content) -> some View {
        NavigationStack {
            content
                // Upright there's no vertical bar, so no room at the sides to keep (Nov 7 2026):
                // turning upright from a pose that has one (the cover, the book), the stack kept
                // the bar's 84 pt at the trailing side for most of a second after the turn — the
                // laptop's window and deck laid out 585 wide and then sprang out to 669, and the
                // mic, shown in the narrower layout, glided across after it.
                .ignoresSafeArea(.container, edges: posture.pose.foldAcross ? .horizontal : [])
                // The one mic, over whichever layout is on screen (`innerMic`).
                .overlayPreferenceValue(MicSlotKey.self) { innerMic($0) }
                .toolbar { if innerBarShown { coverToolbar } }
                .toolbar(innerBarShown ? .automatic : .hidden, for: .navigationBar)
                .toolbar(innerBarShown ? .automatic : .hidden, for: .bottomBar)
                .navigationBarTitleDisplayMode(.inline)
                .coverBarStyle()
                .macSharePickers(photo: $coverPickingPhoto, file: $coverPickingFile, model: model)
        }
        .environment(\.controlsInVerticalBar, innerBarShown)
    }

    // MARK: The phone's layout (the cover screen too)

    var phoneBody: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // The top area: the settings at rest; the transcript while the mic is open.
                ZStack(alignment: .top) {
                    // At rest the settings fill the area: the top bar at the top, the panel in
                    // thumb reach just above the Thread, and the header centred in the room
                    // between them (Oct 18 2026 — it used to hug the top bar, leaving all the
                    // spare height as one gap over the panel). At large text sizes, when they
                    // don't fit, they scroll instead of being cut off at the Thread.
                    GeometryReader { area in
                        // The Dock (Send to) is pinned at the foot of the area and never scrolls or
                        // gets cut (Nov 1 2026, Sameer: "I should never have to scroll to see the
                        // dock"); only what's above it scrolls when the room runs short.
                        VStack(spacing: 0) {
                            ScrollView(.vertical) {
                                Group {
                                    if barUsed || posture.pose.isInner {
                                        // The cover: the Mac is in the vertical bar; its pill only
                                        // while it isn't connected (to say so, and to wake it).
                                        VStack(spacing: 0) {
                                            // (Not in the moment after launch while it connects:
                                            // the pill would pop in and straight back out — nor
                                            // while a dropped link comes back.)
                                            if !barUsed || (!model.looksConnected && !model.settling && !model.reconnecting) { topBar }
                                        }
                                    } else {
                                        // The phone: a little Mac desktop — the menu bar and the
                                        // last dictation as a widget (Nov 1 2026).
                                        // (The last-dictation widget is gone — Nov 1 2026,
                                        // Sameer: "I don't think is that useful".)
                                        PhoneMenuBar(watcher: watcher, wakeElsewhere: desktopTrouble == .notFound)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { desktopTop = $0 }
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .scrollIndicators(.hidden)
                            .frame(maxHeight: .infinity, alignment: .top)
                            // What stands between the mic and the Mac, in the desktop's empty room
                            // under the menu bar (Nov 5 2026): one symbol, one sentence, the fix.
                            .overlay {
                                if let trouble = desktopTrouble {
                                    DesktopEmptyState(trouble: trouble)
                                        .padding(.top, desktopTop)
                                } else if showsDesktopWindow {
                                    // Nothing in the way: the pick's window, one tap from the
                                    // desktop (Nov 7 2026) — centred in the room that's there,
                                    // air above and below, never moving the Dock under it.
                                    GeometryReader { g in
                                        let room = g.size.height - desktopTop
                                        // What's in front on the Mac, a line under the card (Nov 7
                                        // 2026, UI/MacOS/FrontWindowLine.swift): its room is kept
                                        // while the Mac tells it, so the card never moves for it.
                                        let line: CGFloat = model.macTellsFront && room - FrontWindowLook.room >= DesktopWindowLook.leastRoom ? FrontWindowLook.room : 0
                                        let width = g.size.width - 2 * Space.margin
                                        if room >= DesktopWindowLook.leastRoom {
                                            VStack(spacing: 0) {
                                                DesktopWindowCard(target: model.selection.target,
                                                                  room: CGSize(width: width,
                                                                               height: room - 2 * (compact ? DesktopWindowLook.air / 2 : DesktopWindowLook.air) - line),
                                                                  hidden: !phoneSettings,
                                                                  onWatch: watchFromCard)
                                                if line > 0 {
                                                    ZStack {
                                                        if phoneSettings, let w = model.frontOffer {
                                                            FrontWindowLine(window: w, width: min(width, DesktopWindowLook.widest))
                                                                .transition(.opacity)
                                                        }
                                                    }
                                                    .frame(height: FrontWindowLook.height)
                                                    .padding(.top, FrontWindowLook.gap)
                                                    .animation(.easeInOut(duration: 0.25), value: model.frontOffer)
                                                }
                                            }
                                            .frame(width: g.size.width, height: room)
                                            .padding(.top, desktopTop)
                                        }
                                    }
                                    .transition(.opacity)
                                }
                            }
                            .animation(.easeInOut(duration: 0.25), value: desktopTrouble)
                            .animation(.easeInOut(duration: 0.25), value: showsDesktopWindow)
                            Color.clear.frame(height: compact ? 8 : 14)
                            dockArea
                        }
                        // Hidden, it keeps the height it had while it showed: the room changing
                        // under it as the window comes or goes never moves it.
                        .frame(width: area.size.width, height: phoneSettings || settingsRoom == 0 ? area.size.height : settingsRoom, alignment: .top)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if phoneSettings { settingsRoom = $0 } }
                    .onChange(of: phoneSettings) { _, on in if on { settingsRoom = 0 } }
                    // The mic row below changes size as a window opens or closes: the panel takes
                    // its new place at once and only fades — it used to slide down as it went and
                    // up as it came back, under the window's fade (Nov 3 2026, "elements …
                    // briefly stutter or glitch before correcting").
                    .animation(nil, value: watcher.isShowing)
                    .animation(nil, value: showLiveWords)
                    .opacity(phoneSettings ? 1 : 0)
                    .animation(settingsAnimation, value: phoneSettings)
                    .modifier(OutOfReach(hidden: !phoneSettings))
                    // Watching: the window takes the area (Done brings the settings back). Built
                    // once and kept (Nov 7 2026): building it on every open held the main thread
                    // for the best part of half a second before anything moved; now opening and
                    // Done only change its opacity, while its picture flies (`WindowZoom`).
                    // At rest it holds the pick's kept picture, ready; under the words it has no
                    // viewer (`panelDormant`: the strip has the video then).
                    if keepsPanel {
                        WithWindowZoom { zoom in
                            // (Done's flight keeps the header while the view fades: laid out
                            // without it, the picture under the flying one jumped.)
                            // The header stays through the fade to the words (Nov 8 2026: it
                            // went at once and the picture jumped up 40 pt before the fade);
                            // bare once the panel sleeps.
                            WatchPanel(watcher: watcher, compact: compact, cover: isCover,
                                       bare: isCover && input.keysUp || !panelShown && panelDormant && !zoom.leaving && !panelWarm,
                                       // Under full screen (Nov 8 2026) the panel sleeps as the
                                       // inner screen's halves do: no viewer of its own.
                                       dormant: panelDormant && !panelShown && windowHere || innerAsleep)
                                // Full Screen beside the name (the cover has it in its bar).
                                .environment(\.fullScreenAvailable, true)
                                // The response time is the row's under the window, not the header's.
                                .environment(\.responseInRow, isCover || regularPhone)
                                // Hidden under full screen too: not live, so it never measures
                                // for the window's shape nor takes the video from the screen.
                                .environment(\.watchWindowHidden, !panelShown || inFullScreen)
                                .environment(\.watchRestPicture, panelShown || watcher.isOpen ? nil
                                             : WindowSnapshots.cached(WindowSnapshots.key(mac: model.pairedMac?.id, target: model.selection.target)))
                                // Only the picture moves (`WindowZoom`): the view itself is laid
                                // out at once, at its own size, and only fades.
                                .scaleEffect(zoom.panelParked ? DockZoom.parked : 1)
                                .animation(nil, value: panelShown)
                                .modifier(DockZoom(fade: panelShown && !zoom.holdsPanel ? 1 : DockZoom.asleep))
                                .animation(panelFade, value: panelShown)
                                .modifier(OutOfReach(hidden: !panelShown))
                        }
                        .onChange(of: panelShown) { _, on in flyWindow(shown: on) }
                        WindowZoomFlight(origin: watchArea.origin)
                    }
                    if showLiveWords {
                        VStack(spacing: 0) {
                            if windowHere {
                                WatchStrip(watcher: watcher, compact: compact)
                                    .padding(.horizontal, Space.margin)
                                    .padding(.top, 8)
                            }
                            transcriptArea
                        }
                        // The cover: the words leave at once as the window comes back (they were
                        // read through it as it faded in — Nov 4 2026), as the window leaves for them.
                        .transition(isCover && !reduceMotion ? .handoffAfter : .opacity)
                    }
                }
                // Whatever is above takes the room that's left — it can never push the mic. Held
                // at the top: for a moment as the keyboard rises the window's panel can need more
                // than the room left, and centred it rode up under the status bar (Nov 4 2026).
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { watchArea = $0 }
                // Clipped at the foot alone, so nothing above runs into the mic — the window's
                // glow spills past the sides and the top as it should (Oct 31 2026, Sameer: "the
                // glow around the window looks cut off on the sidebar").
                .clipShape(FootOnly())
                .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: showLiveWords)
                .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: windowHere)
                // The Thread, one band in the same place in every state, and the mic under it.
                // While a window shows (the cover since Oct 31, every iPhone since Nov 7 2026) the
                // window takes the room: no Thread, no page row — one row under the key row, the
                // keyboard · the mic · the trackpad. The mic page is the same view on every page,
                // so a hold on it is never lost.
                let watching = rowWatching
                InputCarousel(input: input, watcher: watcher, compact: compact,
                              // No Thread while a window shows; the trackpad page takes a thumb's
                              // worth of room instead (`trackpadRoom`).
                              threadHeight: watching ? (input.page == .trackpad ? trackpadRoom : 0) : filamentSlot,
                              // The page row is never drawn here (the pages are the buttons beside
                              // the mic): tied to the window being open, it showed for a pass as
                              // the pages arrived first, and the window's top area shrank by the
                              // row before it grew (Nov 4 2026).
                              rowHidden: isCover || regularPhone,
                              trackpadBar: watching,
                              // The phone's plate lines up with the window's edges above it.
                              trackpadInset: regularPhone ? WatchLook.sideMargin : nil,
                              // (The row is hidden; this keeps a swipe from changing the page
                              // while the mic is open.)
                              rowDimmed: regularPhone && showLiveWords,
                              // The keyboard page's room, from the keyboard's own frame (this
                              // screen ignores the keyboard's safe area — below).
                              // (The cover's foot is padded by `CoverFoot`, outside this view.)
                              keyboardRoom: laysOutKeyboard ? max(0, input.keyboardRoom - (isCover ? CoverFoot.screenFoot : geo.safeAreaInsets.bottom)) : 0,
                              smoothHeight: isCover || regularPhone,
                              // The inner screen: this is the cover's view beside the window, never
                              // the window's own pages (it stays built, hidden, while one is in hand).
                              restOnly: posture.pose.isInner) {
                    // One mic button in every state: a hold on the cover's small mic flips the
                    // screen to the live words, and two branches made that a different button
                    // mid-press — the hold was lost (Oct 31 2026, Sameer: "press and hold on the
                    // mic button is not working").
                    VStack(spacing: watching ? 2 : 0) {
                        // (Upright inside, the cover's view shares the screen with the window and the
                        // bar: a breath less over the mic, and the status on one line.)
                        if !watching { Color.clear.frame(height: tightInner ? 4 : compact ? 14 : 30) }
                        // Watching: one row under the thumb — the keyboard, the mic, the trackpad.
                        HStack(spacing: 0) {
                            if watching { pageButton(.keyboard).frame(maxWidth: .infinity) }
                            if posture.pose.isInner {
                                // The inner screen's one mic sits here at rest (`innerMic`).
                                micSlot(size: 92, inHand: false)
                            } else {
                                micButton(size: watching ? 64 : 92)
                            }
                            if watching { pageButton(.trackpad).frame(maxWidth: .infinity) }
                        }
                        // The response time (Settings › Watching), in the row's free corner beyond
                        // the trackpad's button: laid over, so it moves nothing.
                        .overlay(alignment: .trailing) {
                            if watching { ResponseCorner(watcher: watcher).padding(.trailing, 6) }
                        }
                        .padding(.top, watching ? 4 : 0)
                        if watching {
                            // One line in its 18 pt: a longer one (the trackpad's how-to) ran
                            // over the mic and its buttons above (Nov 4 2026).
                            StatusLine(recorder: recorder, holding: holding || look == "holding", font: .caption2, swap: true, legible: true)
                                // (Never cut: a longer one grows down, toward the screen's foot.)
                                .padding(.horizontal, 12)
                                .frame(height: 18, alignment: .top)
                                // The landed pill sits here while it shows: centred on the line,
                                // clear of the mic and the buttons beside it (hung from the mic's
                                // frame it rode up over the disc and both buttons — Nov 4 2026);
                                // then Undo, in the same place (Nov 7 2026).
                                .opacity(model.landedChip == nil ? 1 : 0)
                                .animation(.easeOut(duration: 0.15), value: model.landedChip == nil)
                                .overlay { LandedSlot(namespace: micSpace) }
                        } else {
                            Group {
                                if tightInner {
                                    FixedSlot(alignment: .top) {
                                        Text("A").font(.subheadline).frame(maxWidth: .infinity)
                                    } content: {
                                        StatusLine(recorder: recorder, holding: holding || look == "holding", font: .subheadline, legible: true)
                                    }
                                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                                } else {
                                    statusSlot
                                }
                            }
                                // The landed pill is the status line's on every phone (Nov 7 2026,
                                // round 4 — the cover's since Nov 4): one quiet word under the mic,
                                // then Undo in the same place. Hung over the mic it had sat across
                                // the Thread and the mic's ring, beside a check on the Thread and
                                // a chip on its end — three sayings of one landing.
                                // (In hand on the inner screen the one mic floats the pill
                                // itself, `InnerMic` — the deck has no slot under it.)
                                .opacity(model.landedChip != nil ? 0 : 1)
                                .animation(.easeOut(duration: 0.15), value: model.landedChip == nil)
                                .overlay { LandedSlot(namespace: micSpace) }
                                .padding(.bottom, tightInner ? 2 : compact ? 6 : 18)
                        }
                    }
                } thread: {
                    if !watching {
                        threadBand
                            // The mic opening over a window: the Thread and the clock come once
                            // the window has gone (it leaves in `Motion.leave`) — they were drawn
                            // over its answers as it faded (Nov 4 2026).
                            .transition(!reduceMotion ? .asymmetric(insertion: .opacity.animation(Motion.afterLeave), removal: .opacity) : .opacity)
                    }
                }
            }
            // The keyboard and the trackpad are the window's: while the mic is open, the mic
            // stands alone.
            .onChange(of: showLiveWords) { _, live in
                if live, input.page != .mic { input.show(.mic, quiet: true) }
                // The words take a window in place — never a flight into the card and out of it
                // again after (Nov 8 2026: a dictation started by a hook, a Shortcut or a Siri
                // request never passed the mic's own touch, which was the only thing that set this).
                if live, windowHere { windowViaDock = false }
                // Back from the words (the window faded in): Done takes it into the Dock again.
                if !live, !windowViaDock { Task { @MainActor in windowViaDock = true } }
            }
            // The kept panel gives up its viewer once it has faded out, and Done's zoom has gone
            // back into the card before the next open grows out of the Dock again.
            .onChange(of: panelShown) { _, on in
                panelTask?.cancel()
                panelUp = on
                guard !on else { panelDormant = false; return }
                panelTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    panelDormant = true
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    windowFromCard = false
                }
            }
            // The cover (Nov 4 2026): the window above moves with the pages, never ahead of them.
            // The trackpad taking its room shrank the window in one frame (only the pages had a
            // spring); and the keyboard's page folding away the moment the keyboard was asked for
            // stretched the window to the foot, then the keyboard rising squeezed it back — now
            // that fold rides the keyboard's own time (`MacInput.keysUp` changes inside a spring
            // of the keyboard's duration), so the window's foot moves once, up.
            // Every phone since Nov 7 2026: the page row's tap changed the pages on their spring
            // while the window above took its new height in one frame.
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: input.page)
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { compact = geo.size.height < 700 }
            .onChange(of: geo.size.height) { _, h in compact = h < 700 }
        }
        // The regular iPhone lays the keyboard out itself (Nov 4 2026). Fixing a word: the
        // keyboard rises over the mic as it would over any screen, and the word's card rides on
        // the keyboard — the whole mic screen had shoved up for it, the Thread squeezed flat for
        // a frame and the mic jumping down again when it went. The keyboard page: its room is
        // the pages' own (`MacInput.keyboardRoom`), changed in the same motion as everything
        // that gives way to it, so the window moves once.
        .ignoresSafeArea(.keyboard, edges: laysOutKeyboard ? .bottom : [])
        .overlay(alignment: .bottom) {
            if regularPhone, showLiveWords, let draft = model.fixDraft {
                FixWordCard(draft: draft)
                    .padding(.horizontal, Space.margin - 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.fixDraft)
    }

    /// The inner screen upright (the laptop, flat upright): the cover's view under the window.
    var tightInner: Bool { posture.pose.isInner && posture.pose.foldAcross }

    /// Every iPhone but the Duo (its cover and inner screen have layouts of their own).
    var regularPhone: Bool { !barUsed && !posture.pose.isInner }

    /// The desktop's empty state (the regular iPhone and the Duo's cover — inside, the glance
    /// says it in the Mac's half).
    var desktopTrouble: DesktopTrouble? {
        posture.pose.isInner ? nil : DesktopTrouble.current(model, micOff: micOff)
    }

    /// The mic screen lays the keyboard's room out itself (`MacInput.keyboardRoom`) rather than
    /// taking the keyboard's safe area: the regular iPhone, and the Duo's cover (Nov 4 2026 —
    /// inside the cover's NavigationStack the keyboard's safe area left in one step as the
    /// keyboard went, so the window ran to the foot for ~5 frames before the mic row came back).
    var laysOutKeyboard: Bool { regularPhone || isCover }

    // MARK: The iPhone Duo's cover: the buttons in the vertical bar

    func micButton(size: CGFloat) -> some View {
        micCore(size: size)
            .matchedGeometryEffect(id: micID, in: micSpace)
            // The pill is the status line's, under the mic, on every phone (Nov 7 2026); only full
            // screen's floating mic, which has no line under it, keeps it floating above.
            .landedPill(on: watcher.fullScreen, size: size, namespace: micSpace)
    }

    /// Full screen's floating mic (`FloatingMic`): the same button, not matched with the layout's
    /// own mic under it (Nov 8 2026: on the phone and the cover the layout stays built under full
    /// screen, and two sources of one matched id put the floating one at the hidden one's place).
    func floatingMicButton(size: CGFloat) -> some View {
        // (Its × takes the trackpad button's place in the trio while the mic is open.)
        var mic = micCore(size: size)
        mic.cancelDistance = 59
        return mic
            .landedPill(on: true, size: size, namespace: micSpace)
    }

    /// The mic button itself, wherever a layout puts it.
    func micCore(size: CGFloat) -> MicButton {
        MicButton(recording: isRecording,
                  finishing: isFinishing,
                  mode: filamentMode,
                  disabled: micOff,
                  meter: recorder.meter,
                  onDown: pressDown,
                  onUp: pressUp,
                  onAccessibilityToggle: {
                      if watcher.isShowing, !isRecording { windowViaDock = false }
                      model.toggleRecording()
                  },
                  size: size,
                  onCancel: { holding = false; stopOnRelease = false; startedByPress = false; model.cancelRecording() })
    }

    /// A window shows on the cover or a regular iPhone (not while the mic is open over it): the
    /// window takes the room, and the keyboard, the mic and the trackpad share one row under it.
    var rowWatching: Bool { (isCover || regularPhone) && watcher.isOpen && !showLiveWords }

    /// The trackpad page's room over the mic row's: a plate of ~144 pt on the cover (its screen is
    /// short), ~150 on an SE and ~200 on a Pro, with its bar (close) under it.
    var trackpadRoom: CGFloat { isCover ? 116 : compact ? 122 : 172 }

    /// The keyboard or the trackpad, a round glass button beside the mic while a window shows.
    @ViewBuilder func pageButton(_ p: MacInput.Page) -> some View {
        if input.pages.contains(p) {
            // On the pages' spring, the whole screen at once (the window above moves with them).
            Button { withAnimation(Motion.pick(Motion.settle, reduce: reduceMotion)) { input.show(p) } } label: {
                Image(systemName: p.symbol).font(.title3.weight(.semibold)).frame(width: 30, height: 30)
            }
            .circleGlassButton()
            .accessibilityLabel(p.title)
            .accessibilityIdentifier(isCover ? "cover-page-\(p.rawValue)" : "phone-page-\(p.rawValue)")
        }
    }

    var coverBody: some View { barred(phoneBody) }

    /// A screen with a vertical bar (the cover; the inner screen on its side, open or a book): the
    /// same buttons in it on both screens — only the room beside them changes (Nov 1 2026).
    @ViewBuilder func barred<Content: View>(_ content: Content) -> some View {
        if barUsed {
            NavigationStack {
                content
                    // The cover: the lower group of bar buttons sits in the vertical bar, yet the
                    // stack still kept a toolbar's height free at the foot (82 pt, not the home
                    // indicator's 34) — and gave it back the moment a window opened, so everything
                    // dropped 48 pt in one frame, then rose again on Done (Nov 4 2026). The foot is
                    // the screen's own inset in every state.
                    .modifier(CoverFoot(on: isCover))
                    // Fixing a word on the cover: the card rides on the keyboard (the screen under
                    // it ignores the keyboard — `CoverFoot`), as on the regular iPhone.
                    .overlay(alignment: .bottom) {
                        if isCover, showLiveWords, let draft = model.fixDraft {
                            FixWordCard(draft: draft)
                                .padding(.horizontal, Space.margin - 8)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: model.fixDraft)
                    .toolbar { coverToolbar }
                    .navigationBarTitleDisplayMode(.inline)
                    .coverBarStyle()
                    .macSharePickers(photo: $coverPickingPhoto, file: $coverPickingFile, model: model)
            }
            .environment(\.controlsInVerticalBar, true)
        } else {
            content
        }
    }

    var coverDone: some View {
        Button { watcher.done() } label: { Label("Done", systemImage: "checkmark") }
            .accessibilityHint(watcher.glanceOnDone ? "Puts the controls away; the window stays in view." : "Stops showing the window and brings back Send to and Cleanup.")
            .accessibilityIdentifier("watch-done")
    }

    /// Done first, then the window's own buttons (Apple's order for the bar); at rest the Mac,
    /// History and Settings, with Whole Screen, Mac Controls and ⋯ nearer the thumb.
    ///
    /// The bar's items are UIKit's, vended again whenever the set changes — the bar empties into
    /// its glass and refills item by item (Nov 7 2026: the keyboard's hide button arriving and
    /// leaving did it on every keyboard). So each set is fixed while it shows: an item changes
    /// only by being dimmed or by its symbol, never by coming or going. While the mic is open the
    /// set stays, dimmed (the transcript has the screen; the bar never empties under it).
    @ToolbarContentBuilder var coverToolbar: some ToolbarContent {
        if barWindow {
            // Each item its own, in a tier (`BarTier`): the keyboard spans the cover, so with it up
            // the system gives the column two positions and folds the lowest tiers into ⋯ — one
            // item at a time, from the foot. As one group the whole set went in at once, Done
            // alone left (Nov 7 2026, round 5). Nothing here comes or goes with the keyboard.
            barItem(.done, placement: .topBarLeading) { coverDone.disabled(showLiveWords) }
            if input.pages.contains(.keyboard), !posture.pose.isInner {
                barItem(.keyboard) { coverKeyboardItem.disabled(showLiveWords) }
            }
            // Full Screen (Nov 8 2026, Sameer: "on [the] outer screen too"): the window takes the
            // whole screen — the bar, the status bar and the home indicator go.
            barItem(.fullScreen) {
                Button { watcher.setFullScreen(true) } label: {
                    Label("Full Screen", systemImage: "arrow.up.backward.and.arrow.down.forward.rectangle")
                }
                .disabled(watcher.phase != .live || showLiveWords)
                .accessibilityHint("Shows \(watcher.name) on the whole screen.")
                .accessibilityIdentifier("watch-fullscreen")
            }
            // While the link comes back the bar's items hold their places, dimmed.
            if model.macAudio.macCanPlay || watcher.heldFeature(MacSound.feature) {
                barItem(.sound) { CoverSoundItem(player: model.macAudio).disabled(!model.macAudio.macCanPlay || showLiveWords) }
            }
            if model.canMacControls || watcher.heldFeature(MacControl.feature) {
                barItem(.controls) {
                    Button { model.sheet = .macControls } label: { Label("Mac Controls", systemImage: MacControlsButton.symbol) }
                        .disabled(!model.canMacControls || showLiveWords)
                        .accessibilityIdentifier("mac-controls")
                }
            }
            if let t = watcher.target, model.canAlert || watcher.heldFeature(MacAlerts.feature), case .app = t, !DesktopWatch.isDesktop(t) {
                let on = model.alertWatch(for: t) != nil
                barItem(.alerts) {
                    Button { model.toggleAlertWatch(t) } label: {
                        Label(on ? "Alerts On" : "Alerts Off", systemImage: on ? "bell.fill" : "bell")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .tint(on ? Light.gold : nil)
                    .disabled(!model.canAlert || showLiveWords)
                    .accessibilityLabel("Alerts")
                    .accessibilityValue(on ? "On" : "Off")
                    .accessibilityHint("Notifies you when this window changes.")
                    .accessibilityIdentifier("cover-alert")
                }
            }
            // From the window's first moment, dimmed until its first picture (it arrived
            // with the picture, and the bar re-vended for it).
            barItem(.drag) {
                Button { watcher.setDrag(watcher.drag == .pan ? .scroll : .pan) } label: {
                    Label(watcher.drag == .pan ? "Pan" : "Scroll", systemImage: watcher.drag == .pan ? "hand.draw" : "arrow.up.and.down")
                        .contentTransition(.symbolEffect(.replace))
                }
                .tint(watcher.drag == .scroll ? Light.cyan : nil)
                .disabled(watcher.phase != .live || showLiveWords)
                .accessibilityLabel("What one finger does")
                .accessibilityValue(watcher.drag == .pan ? "Pan" : "Scroll")
                .accessibilityHint("Switches between moving the picture and scrolling the window on your Mac.")
                .accessibilityIdentifier("cover-drag")
            }
            if watcher.macCanFit, watcher.target != .clipboard {
                barItem(.whole) {
                    Button { watcher.toggleWholeWindow() } label: {
                        Label(watcher.wholeWindow ? "Zoom Back In" : "Whole Window",
                              systemImage: watcher.wholeWindow ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .disabled(watcher.phase != .live || showLiveWords)
                    .accessibilityIdentifier("watch-whole")
                }
                if !watcher.isDesktop {
                    barItem(.window) { WatchWindowMenu(watcher: watcher, bar: true).disabled(showLiveWords) }
                }
            }
        } else {
            // The upper group: the Mac and the app's own pages.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Group {
                    CoverMacItem()
                    Button { model.sheet = .history } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    Button { model.sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
                }
                .disabled(showLiveWords)
            }
            // The lower group, nearer the thumb: what Send to's round buttons did.
            ToolbarItemGroup(placement: .bottomBar) {
                Group {
                    // What the Mac offered when last connected stays in its place, dimmed, while it
                    // connects again — the buttons never arrive one by one (Nov 3 2026).
                    if barWholeScreen {
                        CoverWholeScreenItem(watcher: watcher).disabled(!model.looksConnected)
                    }
                    if barMacControls {
                        Button { model.sheet = .macControls } label: { Label("Mac Controls", systemImage: MacControlsButton.symbol) }
                            .disabled(!model.looksConnected)
                            .accessibilityIdentifier("mac-controls")
                    }
                    // (Attach is by the Dock now, and Refresh in Open an App — Nov 7 2026.)
                }
                .disabled(showLiveWords)
            }
        }
    }

    /// The bar's lower group at rest: Whole Screen and Mac Controls, each when the Mac offers it (or
    /// did when last connected, while it connects again).
    // With no Mac paired there's nothing to hold a place for (Nov 8 2026: after an unpair the
    // bar kept a dimmed Whole Screen and Control Center beside "Pair your Mac").
    var barWholeScreen: Bool { model.isConnected ? watcher.canWatchDesktop : (model.isPaired && barHadWholeScreen) }
    var barMacControls: Bool { model.isConnected ? model.canMacControls : (model.isPaired && barHadControls) }
    /// Upright on the inner screen at rest, the system lays those out in a bar at the foot.
    var uprightFootBar: Bool { posture.pose.foldAcross && innerBarShown && (barWholeScreen || barMacControls) }

    /// The cover's bar while a window shows, from the top: what the system folds into ⋯ last when
    /// the column is short (the keyboard up: two positions, Done and ⋯) comes first — Done, then
    /// the keyboard's item, then the Window menu, which holds the rest's long forms too.
    enum BarTier: Int, CaseIterable { case done, keyboard, window, fullScreen, sound, controls, drag, alerts, whole }

    /// One item of the cover's bar in its tier (iOS 27; an older system lays them out as they come).
    @ToolbarContentBuilder
    func barItem<V: View>(_ tier: BarTier, placement: ToolbarItemPlacement = .topBarTrailing, @ViewBuilder content: () -> V) -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarItem(placement: placement) { content() }.visibilityPriority(.bar(tier))
        } else {
            ToolbarItem(placement: placement) { content() }
        }
    }

    /// The keyboard in the bar, one item in both states (Nov 7 2026): it raises the keyboard page
    /// and, while that's up, puts it away — the symbol turns, the item stays. One identity (one
    /// id; the title says the state, and is what the system's ⋯ shows), so the tap never gives
    /// the bar a new item to vend (round 5).
    var coverKeyboardItem: some View {
        let up = input.page == .keyboard
        return Button {
            if up { input.hideKeyboard() } else { withAnimation(Motion.pick(Motion.settle, reduce: reduceMotion)) { input.show(.keyboard) } }
        } label: {
            // The title is what the system's ⋯ shows when the column is short.
            Label(up ? "Hide Keyboard" : "Keyboard", systemImage: up ? "keyboard.chevron.compact.down" : "keyboard")
                .contentTransition(.symbolEffect(.replace))
        }
        .tint(up ? Light.cyan : nil)
        .accessibilityHint(up ? "Puts the keyboard away." : "Types on your Mac with the iPhone's keyboard.")
        .accessibilityIdentifier("bar-keyboard")
    }

    // MARK: Top

    var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                MacPill().fixedSize()
                if desktopTrouble != .notFound { WakeMacButton() }
                Spacer(minLength: 8)
                topButtons
            }
            // Huge text: the buttons keep their corner, the Mac's name gets its own line.
            VStack(alignment: .leading, spacing: 8) {
                HStack { Spacer(); topButtons }
                MacPill()
                if desktopTrouble != .notFound { WakeMacButton() }
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, 6)
        .opacity(isRecording ? 0.35 : 1)
        .allowsHitTesting(!isRecording)
        .animation(.easeInOut(duration: 0.25), value: isRecording)
    }

    @ViewBuilder var topButtons: some View {
        // A screen with a vertical bar has them there.
        if !barUsed { drawnTopButtons }
    }

    @ViewBuilder var drawnTopButtons: some View {
        Button { model.sheet = .history } label: {
            Image(systemName: "clock.arrow.circlepath").topBarGlyph()
        }
        .circleGlassButton()
        .accessibilityLabel("History")
        .accessibilityShowsLargeContentViewer { Label("History", systemImage: "clock.arrow.circlepath") }
        Button { model.sheet = .settings } label: {
            Image(systemName: "gearshape").topBarGlyph()
        }
        .circleGlassButton()
        .accessibilityLabel("Settings")
        .accessibilityShowsLargeContentViewer { Label("Settings", systemImage: "gearshape") }
    }

    // MARK: The Thread — fixed above the mic

    var filamentHeight: CGFloat { compact ? 56 : 96 }
    /// A short screen (the Duo's cover, an SE) gives the recording's clock a line of its own
    /// under the Thread while the mic is open — in the Thread's 56 pt the crests ran through it
    /// (Oct 31 2026). The room comes from the transcript above; the mic never moves.
    var timerLine: CGFloat { compact && isRecording ? 24 : 0 }
    var filamentSlot: CGFloat { compact ? 56 + timerLine : 84 }

    /// The Thread takes a finger at rest (Delight, Nov 8 2026): plucked, it rings like a string.
    /// Never while the mic is open or the words are on their way, never over a window.
    var threadPluckable: Bool {
        !showLiveWords && !watcher.isShowing && !micOff
            && (filamentMode == .ready || filamentMode == .delivered || filamentMode == .queued)
    }

    var threadBand: some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    ZStack {
                        Filament(mode: filamentMode, meter: recorder.meter, height: filamentHeight, pluckable: threadPluckable)
                        // The landed pill says it, under the mic — the Thread's mint is enough here
                        // (the check had said it a second time, every phone since Nov 7 2026).
                        DeliveredCheck(visible: showCheck && model.landedChip == nil, color: checkColor)
                    }
                    .frame(height: 56)
                    if timerLine > 0 { timer.frame(height: timerLine).transition(.opacity) }
                }
            } else {
                ZStack {
                    Filament(mode: filamentMode, meter: recorder.meter, height: filamentHeight, pluckable: threadPluckable)
                        .frame(height: filamentSlot)
                    DeliveredCheck(visible: showCheck && model.landedChip == nil, color: checkColor)
                    timer.frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .frame(height: filamentSlot)
        .padding(.horizontal, -4)
    }

    // MARK: While the mic is open: the transcript takes the whole area

    var transcriptArea: some View {
        VStack(spacing: 0) {
            DestinationLine(words: recorder.words)
                .padding(.horizontal, Space.text)
                .padding(.top, 14)
            LiveWords(words: recorder.words, listening: isRecording, cardInline: !laysOutKeyboard)
                .padding(.horizontal, Space.text)
                .padding(.top, 8)
                // Where the words were, for their flight out (`WordFlightLayer`).
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { Delight.shared.wordsFrame = $0 }
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
        }
    }

    var timer: some View {
        Group {
            if isRecording, let start = recorder.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { ctx in
                    Text(timerString(ctx.date.timeIntervalSince(start)))
                        .font(.mono(.subheadline, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(recorder.softCapReached ? Light.ochre : Ink.tertiary)
                        .accessibilityLabel("Recording time \(Int(ctx.date.timeIntervalSince(start))) seconds")
                }
            } else {
                // Hidden, not merely out of VoiceOver's way: the blank placeholder was a node the
                // accessibility audit stopped on (Nov 7 2026).
                Text(" ").font(.mono(.subheadline)).hidden()
            }
        }
        .frame(minHeight: 22)
        .padding(.bottom, 2)
        // A clock, not a line to read: at accessibility sizes it stays small enough to sit under
        // the Thread instead of across it.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    // MARK: Quick controls, the mic, the status line

    /// The foot of the area at rest: the Dock and its options (paired), else the places panel.
    var dockArea: some View {
        Group {
            if model.isPaired, !(barUsed || posture.pose.isInner) {
                VStack(spacing: 0) {
                    SendToDock(current: model.selection.target)
                    DockOptions(settings: model.settings)
                        .padding(.horizontal, Space.margin)
                        .padding(.top, 8)
                        .padding(.bottom, compact ? 4 : 8)
                }
            } else if model.isPaired || barUsed || posture.pose.isInner {
                quickControls
            } else {
                QuickControls(settings: model.settings, compact: compact, glow: skyGlow)
                    .padding(.bottom, compact ? 10 : 18)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var quickControls: some View {
        Group {
            // The Duo (the cover, and the same view on the inner screen's half): every place's
            // icon in even columns across the width (the pick's name is the line above them).
            if (barUsed || posture.pose.isInner), model.isPaired {
                // The same picker as the phone's: the Dock and its options (Nov 1 2026, Sameer:
                // "I'm getting the old app selector … not the new version").
                VStack(spacing: 0) {
                    SendToDock(current: model.selection.target)
                    DockOptions(settings: model.settings)
                        .padding(.horizontal, Space.margin)
                        .padding(.top, 8)
                }
            } else if barUsed || posture.pose.isInner {
                QuickControls(settings: model.settings, compact: true, layout: .tiles(maxRows: 3), glow: skyGlow, cover: true)
            } else {
                QuickControls(settings: model.settings, compact: compact, glow: skyGlow)
            }
        }
        .padding(.bottom, compact ? 10 : 18)
    }

    var statusSlot: some View {
        FixedSlot(alignment: .top) {
            // Two lines of the status font (three at accessibility sizes); longer lines step down a size.
            Text(typeSize.isAccessibilitySize ? "A\nB\nC" : "A\nB").font(.subheadline).lineSpacing(0)
                .frame(maxWidth: .infinity)
        } content: {
            StatusLine(recorder: recorder, holding: holding || look == "holding", swap: isCover,
                       // The desktop's empty state says it (the cover's, too short for its
                       // sentence, only gives the fix).
                       desktopSays: regularPhone && phoneSettings && desktopTrouble != nil,
                       desktopFixes: phoneSettings && desktopTrouble != nil, legible: true)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    func pressDown() {
        // The mic opening over a window: the window gives way to the words in place, not back
        // into the Dock (hidden under it) — said before the mic opens, so the window's last
        // look carries the plain fade.
        if watcher.isShowing, !isRecording {
            windowViaDock = false
            // A press that opened nothing (the mic off): Done goes into the Dock again.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if !showLiveWords { windowViaDock = true }
            }
        }
        if isRecording {
            stopOnRelease = true
            startedByPress = false
        } else {
            startedByPress = true
            stopOnRelease = false
            holding = true
            Task { await model.startRecording() }
        }
    }

    func pressUp(_ held: TimeInterval) {
        holding = false
        if stopOnRelease {
            stopOnRelease = false
            model.stopRecording()
        } else if startedByPress {
            startedByPress = false
            // Held past the threshold: hold-to-talk, so letting go sends.
            if held >= MicButton.holdThreshold { model.stopRecording() }
        }
    }

    // MARK: Filament state

    var checkColor: Color { Light.mint }

    var skyGlow: Color {
        switch filamentMode {
        case .ready: return Light.cyan
        case .listening, .live: return Light.ember
        case .sending: return Light.teal
        case .delivered: return Light.mint
        case .queued: return Light.ochre
        case .error: return Light.rose
        }
    }

    func react() {
        settleTask?.cancel()
        var mode: FilamentMode
        if isRecording {
            mode = recorder.hasWords ? .live : .listening
        } else {
            switch model.status {
            case .cleaning, .sending, .landing: mode = .sending
            case .delivered, .duplicate, .copiedOnPhone: mode = .delivered
            case .landed(let l): mode = l.isSuccess ? .delivered : (l.copiedInstead ? .queued : .error)
            case .unconfirmed: mode = .queued
            case .queued: mode = .queued
            case .failed, .problem: mode = .error
            case .listening: mode = recorder.phase == .finishing ? .sending : .listening
            default: mode = recorder.phase == .finishing ? .sending : .ready
            }
        }
        #if DEBUG
        // A held look (screenshots): the Thread, the sky and the button all show it.
        switch look {
        case "sending", "finishing": mode = .sending
        case "sent": mode = .delivered
        case "queued": mode = .queued
        case "error": mode = .error
        default: break
        }
        #endif
        withAnimation(.easeInOut(duration: 0.2)) { filamentMode = mode }
        showCheck = (mode == .delivered)
        // A miss stays in view longer than a success.
        let landedMiss: Bool = { if case .landed(let l) = model.status { return !l.isSuccess }; if case .unconfirmed = model.status { return true }; return false }()
        if mode == .delivered || mode == .error || landedMiss {
            settleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: mode == .delivered ? 2_600_000_000 : 6_000_000_000)
                guard !Task.isCancelled, look == nil else { return }
                showCheck = false
                if filamentMode == .delivered || filamentMode == .error || landedMiss { filamentMode = .ready }
            }
        }
    }
}

/// A slot whose size is its hidden template's — whatever the content shows. The content is laid
/// over the template (an overlay never sizes its parent), so a state change can't move anything.
struct FixedSlot<Template: View, Content: View>: View {
    var alignment: Alignment = .center
    @ViewBuilder var template: Template
    @ViewBuilder var content: Content

    var body: some View {
        template
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: alignment) { content }
    }
}

/// Where this dictation is going, in one quiet line (the quick controls have stepped aside —
/// and saying an app's name first changes it as you speak). Observes the words itself, so a
/// partial result redraws this line and LiveWords, not the mic screen.
struct DestinationLine: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var words: LiveTranscript

    var body: some View {
        let live = model.liveRoute(words.text)
        let name = live.target.displayName
        let where_ = live.byVoice ? "You said \(name)" : "To \(name)"
        let parts = [where_, live.target.canSend && live.send ? "sends" : nil,
                     model.effectiveCleanupLevel == .off ? "no cleanup" : "\(model.effectiveCleanupLevel.title) cleanup"].compactMap { $0 }
        return Text(parts.joined(separator: " · "))
            .font(.footnote.weight(.medium))
            .foregroundStyle(live.byVoice ? Light.ember : Ink.tertiary)
            // A long window name wraps to a second line; past that it fades, never "…".
            .lines(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(parts.joined(separator: ", "))
    }
}

/// The words as they're heard: serif, written from the top of the area downward like a page.
/// Only once they fill it does it scroll, keeping the newest line in view. The words still being
/// decided are dimmer; they settle into ink as the recognizer commits them.
struct LiveWords: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var words: LiveTranscript
    var listening: Bool
    /// The fix card under the words (false: the screen draws it on the keyboard itself — the
    /// regular iPhone, `MainView.phoneBody`).
    var cardInline = true

    var body: some View {
        let parts = words.parts
        VStack(spacing: 8) {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // Room under the fade, so unscrolled words start clear of it.
                    Color.clear.frame(height: 22)
                    label(parts)
                        // The words are links (to their fix), drawn in ink, not link blue.
                        .tint(Ink.ink)
                        .font(.serif(.title2))
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        // A fix (and its card coming and going) lands at once: a fixed word
                        // re-flows the lines, and the cross-fade drew both versions over each
                        // other for a moment (Nov 4 2026).
                        .animation(nil, value: model.wordFixes)
                        .animation(nil, value: model.fixDraft)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.top)
            // A word's card up (the keyboard too): two lines of the words stay in sight above it.
            .frame(minHeight: model.fixDraft == nil ? 0 : 76)
            // Once the words fill the area, the line leaving the top fades instead of being sliced.
            .mask(VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 22)
                Color.black
            })
            .onChange(of: parts) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        // A settled word tapped: its card (Nov 3 2026 — fix a word before it goes).
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "macrophone-fix", let i = Int(url.host() ?? "") else { return .systemAction }
            model.beginFix(i)
            return .handled
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.isEmpty ? "Listening" : WordFixes.apply(model.wordFixes, to: parts.text))
        .accessibilityHint(parts.settled.isEmpty ? "" : "Words can be fixed before they're sent: tap one.")
        if cardInline, let draft = model.fixDraft {
            FixWordCard(draft: draft)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        }
        .animation(.easeOut(duration: 0.2), value: model.fixDraft)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    /// One Text (one layout pass): each settled word a link to its fix (in ink, a fixed one with a
    /// cyan underline, a taken-out one struck through), the words still settling dimmer.
    private func label(_ parts: LiveTranscript.Parts) -> Text {
        if parts.isEmpty { return Text(listening ? "Listening…" : " ").foregroundStyle(Ink.tertiary) }
        var settled = AttributedString()
        let ns = parts.settled as NSString
        var at = 0
        for (i, r) in WordFixes.words(parts.settled).enumerated() {
            if r.location > at { settled += AttributedString(ns.substring(with: NSRange(location: at, length: r.location - at))) }
            let fix = model.wordFixes.first { $0.index == i }
            var word = AttributedString(fix.map { $0.replacement.isEmpty ? $0.original : $0.replacement } ?? ns.substring(with: r))
            word.link = URL(string: "macrophone-fix://\(i)")
            if let fix {
                word.underlineStyle = fix.replacement.isEmpty ? nil : Text.LineStyle(pattern: .solid, color: Light.cyan)
                word.strikethroughStyle = fix.replacement.isEmpty ? Text.LineStyle(pattern: .solid, color: Ink.tertiary) : nil
            }
            if model.fixDraft?.index == i { word.backgroundColor = Light.cyan.opacity(0.18) }
            settled += word
            at = NSMaxRange(r)
        }
        if at < ns.length { settled += AttributedString(ns.substring(from: at)) }
        let settledText = Text(settled).foregroundStyle(Ink.ink)
        guard !parts.pending.isEmpty else { return settledText }
        let pending = Text(parts.pending).foregroundStyle(Ink.secondary)
        return parts.settled.isEmpty ? pending : settledText + Text(" ") + pending
    }
}

/// A word's fix (Nov 3 2026): the word to edit, Take Out, Add to Dictionary, Done — the words wait
/// for it when the mic closes meanwhile.
struct FixWordCard: View {
    @EnvironmentObject var model: AppModel
    var draft: WordFix
    @State private var text = ""
    @State private var remember = false
    @FocusState private var focused: Bool

    var body: some View {
        // One row, so it fits over the keyboard on the cover's short screen too: Cancel, the
        // word, Add to Dictionary, Take Out, Done.
        HStack(spacing: 6) {
            Button { model.cancelFix() } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 30, height: 34) }
                .foregroundStyle(Ink.secondary)
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("fix-cancel")
            TextField("Fix “\(draft.original)”", text: $text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit { model.commitFix(text, remember: remember) }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Ink.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityIdentifier("fix-field")
            Button { remember.toggle(); Haptics.pick() } label: {
                Image(systemName: remember ? "character.book.closed.fill" : "character.book.closed").frame(width: 30, height: 34)
            }
            .foregroundStyle(remember ? Light.cyan : Ink.secondary)
            .accessibilityLabel("Add to Dictionary")
            .accessibilityValue(remember ? "On" : "Off")
            .accessibilityHint("The recognizer will expect this word next time.")
            Button { model.commitFix("") } label: { Image(systemName: "minus.circle").frame(width: 30, height: 34) }
                .foregroundStyle(Light.rose)
                .accessibilityLabel("Take Out")
                .accessibilityIdentifier("fix-remove")
            Button { model.commitFix(text, remember: remember) } label: { Text("Done").fontWeight(.semibold) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("fix-done")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .watchGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // Clear of the area's foot, which is clipped.
        .padding(.bottom, 10)
        .accessibilityLabel("Fix “\(draft.original)”")
        .onAppear { text = draft.replacement; focused = true }
        .onChange(of: draft.index) { _, _ in text = draft.replacement }
    }
}

extension Image {
    /// A top-bar glyph, sized so the native circular glass button comes out 44pt — the same
    /// height as the Mac's pill beside it.
    func topBarGlyph() -> some View {
        font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.ink).frame(width: 30, height: 30)
    }
}

/// The active Mac and its connection, top left: the light, the Mac's name and — when connected —
/// a small sign of how (Oct 17 2026, Sameer: "a little Wi-Fi logo ... over Tailscale ... a little
/// VPN logo"): Wi-Fi at home, the direct link nearby, a shielded network through Tailscale, a
/// globe over the internet. Taps through to pairing when unpaired, to Settings with one Mac, and
/// with several (Oct 19 2026, Sameer: "pair multiple Macs to my phone and switch easily by swiping
/// up and down in the top left") to the Macs list; a swipe up or down on it is the shortcut — the
/// name rolls to the next or previous Mac with a tick. The pill's width follows the name on the
/// same spring, so the top bar never jumps.
struct MacPill: View {
    @EnvironmentObject var model: AppModel
    /// The bold name at the menu bar's left (the phone's desktop, Nov 1 2026), not a glass pill.
    var menuBar = false
    /// One width for every connection sign (Wi-Fi, globe, shield), so none moves the pill.
    @ScaledMetric(relativeTo: .caption) private var iconSlot: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A drag under way: how far the name has been pulled (a hint of the roll to come).
    @GestureState private var pull: CGFloat = 0

    var body: some View {
        let several = model.pairedMacs.count > 1
        Button {
            model.sheet = several ? .macs : model.isPaired ? .settings : .pairing
        } label: {
            HStack(spacing: 8) {
                if menuBar {
                    // The menu bar's bold name, the light as a mark before it.
                    Image(systemName: "laptopcomputer").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                        .overlay(alignment: .bottomTrailing) {
                            Circle().fill(dot).frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground).opacity(0.8), lineWidth: 1.2))
                                .modifier(ConnectRipple(connected: model.looksConnected))
                                .offset(x: 3, y: 2)
                        }
                        .accessibilityHidden(true)
                } else {
                    Circle().fill(dot).frame(width: 8, height: 8).shadow(color: dot.opacity(0.8), radius: 4)
                        .modifier(ConnectRipple(connected: model.looksConnected))
                        .accessibilityHidden(true)
                }
                RollingName(name: title, key: model.pairedMac?.id.uuidString ?? "none", reduceMotion: reduceMotion,
                            font: menuBar ? .subheadline.weight(.bold) : .footnote.weight(.semibold),
                            color: menuBar ? Ink.ink : Ink.secondary, oneLine: menuBar)
                    .offset(y: several ? pull : 0)
                // The way it's connected, in a slot that's always there: the pill keeps its width
                // from launch to connected instead of growing when the sign arrives.
                if model.isPaired {
                    let route = model.shownRoute
                    Image(systemName: Self.symbol(route ?? .homeNetwork))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(route?.isAway == true ? Light.cyan : Ink.tertiary)
                        .frame(width: iconSlot)
                        .opacity(route == nil ? 0 : 1)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.easeOut(duration: 0.25), value: route)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, menuBar ? 8 : 2)
            .frame(minHeight: menuBar ? MacOSLook.menuBar : 37)
        }
        .modifier(PillLook(menuBar: menuBar))
        // The width follows the name's on the roll's own spring.
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: model.pairedMac?.id)
        .simultaneousGesture(swipe, including: several ? .all : .subviews)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityIdentifier("mac-pill")
        .accessibilityLabel(accessibility)
        .accessibilityValue(several ? "\(position) of \(model.pairedMacs.count) Macs" : "")
        .accessibilityHint(several ? "Opens your Macs. Swipe up or down to switch Macs."
                           : model.isPaired ? "Opens Settings." : "Pairs this iPhone with Macrophone on your Mac.")
        .accessibilityAdjustableAction { direction in
            guard several else { return }
            switch direction {
            case .increment: model.stepMac(1)
            case .decrement: model.stepMac(-1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Choose a Mac") { if several { model.sheet = .macs } }
    }

    /// A swipe up goes to the next Mac, down to the one before (a sideways drag is ignored, so a
    /// scroll near the top bar never switches). The tap still works: the gesture only acts on a
    /// clear vertical pull.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($pull) { v, state, _ in
                let dy = v.translation.height
                guard abs(dy) > abs(v.translation.width) else { state = 0; return }
                // A hint of the roll: the name follows the finger a little, never far.
                state = max(-8, min(8, dy / 4))
            }
            .onEnded { v in
                let dy = v.translation.height
                guard abs(dy) > 24, abs(dy) > abs(v.translation.width) * 1.2 else { return }
                #if DEBUG
                if model.debugPairingLocked { model.debugFakeStep(dy < 0 ? 1 : -1); return }
                #endif
                model.stepMac(dy < 0 ? 1 : -1)
            }
    }

    static func symbol(_ route: LinkRoute) -> String {
        switch route {
        case .homeNetwork: return "wifi"
        case .nearby: return "dot.radiowaves.left.and.right"
        case .tailscale: return "network.badge.shield.half.filled"
        case .internet: return "globe"
        }
    }

    private var title: String {
        guard let mac = model.pairedMac else { return "Pair your Mac" }
        return mac.name
    }

    private var position: Int { (model.pairedMacs.firstIndex { $0.id == model.pairedMac?.id } ?? 0) + 1 }

    private var dot: Color {
        if model.looksConnected { return Light.cyan }
        switch model.linkState {
        case .connected: return Light.cyan
        case .unreachable: return Light.ochre
        case .notPaired: return Light.ember
        default: return Ink.tertiary
        }
    }

    private var accessibility: String {
        switch model.linkState {
        case .notPaired: return "Not paired. Pair your Mac."
        case .connected(let n): return model.linkRoute.map { "Connected to \(n), \($0.words)" } ?? "Connected to \(n)"
        case .connecting(let n): return "Connecting to \(n)"
        case .unreachable(let n): return "\(n) not found"
        case .searching: return "Looking for \(model.macName)"
        }
    }
}

/// The pill's glass, or — in the menu bar — a Mac menu title's pressed highlight.
private struct PillLook: ViewModifier {
    var menuBar: Bool
    func body(content: Content) -> some View {
        if menuBar { content.buttonStyle(MenuBarNameStyle()) } else { content.nativeGlassButton().buttonBorderShape(.capsule) }
    }
}

/// The Mac's name on the pill. On a switch the old name rolls out (up for the next Mac, down for
/// the one before) and the new one rolls in behind it on the settle spring; under Reduce Motion
/// the two cross-fade. The slot is the current name's size, so the pill's width animates with it
/// and nothing else in the top bar moves. `MACROPHONE_PILL_ROLL=<0…1>` (DEBUG) holds the roll
/// at that point for a screenshot.
struct RollingName: View {
    var name: String
    /// Changes with the Mac (not the name: two Macs can share one).
    var key: String
    var reduceMotion: Bool
    var font: Font = .footnote.weight(.semibold)
    var color: Color = Ink.secondary
    /// One line, cut with "…" when it runs out of room (the menu bar's name).
    var oneLine = false
    /// What's drawn as the current name, by Mac.
    @State private var shown: (key: String, name: String)?
    /// The name on its way out, and how far the roll has got (0 = just started, 1 = done).
    @State private var leaving: (name: String, up: Bool)?
    @State private var progress: CGFloat = 1
    /// Which way this switch rolls (`AppModel.macRollUp`), and the Macs for the held roll.
    @EnvironmentObject private var model: AppModel

    /// How far a name travels: its own line and a little more, so it clears the slot.
    private let travel: CGFloat = 30

    #if DEBUG
    /// `MACROPHONE_PILL_ROLL=<0…1>`: the roll held at that point (a screenshot of it mid-way).
    private var held: CGFloat? { DebugHooks.env["MACROPHONE_PILL_ROLL"].flatMap(Double.init).map { CGFloat(max(0, min(1, $0))) } }
    #endif

    var body: some View {
        let rolling = leaving != nil && progress < 1
        Text(shown?.name ?? name)
            .font(font)
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .oneLine(if: oneLine)
            .opacity(rolling ? (reduceMotion ? Double(progress) : Double(0.2 + 0.8 * progress)) : 1)
            .offset(y: rolling && !reduceMotion ? (1 - progress) * travel * (leaving?.up == true ? 1 : -1) : 0)
            .overlay(alignment: .leading) {
                if let leaving, rolling {
                    Text(leaving.name)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(reduceMotion ? Double(1 - progress) : max(0, 1 - Double(progress) * 1.6))
                        .offset(y: reduceMotion ? 0 : -progress * travel * (leaving.up ? 1 : -1))
                        .accessibilityHidden(true)
                }
            }
            // The slot is the pill's height, so a name rolls the whole way in view before it leaves.
            .padding(.vertical, 9)
            .clipped()
            .padding(.vertical, -9)
            .onAppear {
                shown = (key, name)
                #if DEBUG
                if let held {
                    // Held mid-roll: the Mac before this one on its way up and out.
                    let before = MacRoster.step(-1, from: model.pairedMac?.id, in: model.pairedMacs)?.name ?? "Studio Mac"
                    leaving = (before, true)
                    progress = held
                }
                #endif
            }
            .onChange(of: key) { _, new in
                guard let s = shown, s.key != new else { shown = (new, name); return }
                leaving = (s.name, model.macRollUp)
                shown = (new, name)
                #if DEBUG
                if let held { progress = held; return }
                #endif
                progress = 0
                // The roll starts on the next pass: a write in this one would animate 1 → 1.
                Task { @MainActor in
                    withAnimation(Motion.pick(Motion.settle, reduce: reduceMotion)) { progress = 1 }
                }
            }
            .onChange(of: name) { _, new in
                // The same Mac under a new name (it was renamed): no roll.
                if shown?.key == key { shown = (key, new) }
            }
    }

}

/// In the controls panel's first row, after the first dictations made without a Mac: the free
/// Mac app, one tap to send yourself the link. Closed for good with ×; gone once a Mac is paired.
struct MacAppNudge: View {
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ShareLink(item: Product.website,
                      subject: Text("Macrophone for Mac"),
                      message: Text("Get Macrophone for your Mac: \(Product.website.absoluteString)")) {
                HStack(spacing: 8) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Light.cyan)
                        .accessibilityHidden(true)
                    ViewThatFits(in: .horizontal) {
                        Text("Want it on your Mac? Get the free app").lineLimit(1).fixedSize()
                        Text("Get the free Mac app").lineLimit(1).fixedSize()
                        Text("Get the free Mac app").font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                }
                .padding(.leading, Space.inset)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Want it on your Mac? Get the free Mac app")
            .accessibilityHint("Shares the download link, so you can open it on your Mac.")
            .accessibilityIdentifier("mac-app-nudge")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide this")
        }
        .padding(.vertical, 6)
        .padding(.trailing, 4)
    }
}

extension MainView {
    /// The phone layout's window panel is kept built: the regular iPhone and the Duo's cover,
    /// once a Mac is paired (on the inner screen this layout is the cover's view beside the
    /// window, never the window).
    var keepsPanel: Bool { model.isPaired && !posture.pose.isInner }

    /// The window in hand shows in this layout's area.
    var panelShown: Bool { windowHere && !showLiveWords }

    /// The pick's window on the desktop (`DesktopWindowCard`): the regular iPhone and the cover,
    /// paired, a place with a window (the Clipboard has none).
    var showsDesktopWindow: Bool { model.isPaired && !posture.pose.isInner && model.selection.target != .clipboard }

    /// The first open after launch, warmed ahead (Nov 7 2026): it held the main thread ~200 ms to
    /// its first frame on the simulator, later opens ~75 — the difference SwiftUI building and
    /// measuring, for the first time in the process, what only a window shows: the carousel's
    /// keyboard and trackpad pages (the keyboard's field is the text system's first text view) and
    /// the window's header. Once per launch, 0.7 s after the Mac first connects (past launch's own
    /// frames and the connect's updates), those are built unseen for a quarter of a second — the
    /// pages in `PagesWarmup`, the hidden panel's header (`bare` off) — then let go. Nothing shows,
    /// takes a touch or is sent; a window already open, or the words up, skips it.
    func warmPanel(connected: Bool) {
        guard connected, !PanelWarmup.done, keepsPanel else { return }
        PanelWarmup.done = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !panelShown, !showLiveWords else { return }
            #if DEBUG
            // MACROPHONE_NO_WARMUP=1: without it, to compare.
            guard DebugHooks.env["MACROPHONE_NO_WARMUP"] != "1" else { return }
            NSLog("WARM the first open's pages and header")
            #endif
            panelWarm = true
            try? await Task.sleep(nanoseconds: 250_000_000)
            panelWarm = false
        }
    }

    /// The card's tap: what the Dock's second tap does. The card's picture lifts off at once, and
    /// flies to the window as it opens on the next turn of the run loop (`WindowZoom`).
    func watchFromCard() {
        let t = model.selection.target
        guard t != .clipboard, model.looksConnected, !model.isNotOpen(t) else { return }
        windowFromCard = true
        if flightAllowed {
            WindowZoom.shared.liftFromCard(image: WindowSnapshots.cached(WindowSnapshots.key(mac: model.pairedMac?.id, target: t)),
                                           card: DesktopWindowSpot.shared.frame)
        }
        // Back from the background the link may only look up: it opens on the connect.
        DispatchQueue.main.async { model.watchWhenConnected(t) }
    }

    /// Only the window's picture moves between the desktop and the window view (Nov 7 2026, round
    /// 4 — it used to be the whole view scaled down into the card or the Dock icon, chrome and
    /// all). Stepping aside for the words, on the cover (its own overlapped cross-fade) or the
    /// inner screen, or with Reduce Motion, the view only fades.
    var flightAllowed: Bool {
        !reduceMotion && windowViaDock && !(barUsed || posture.pose.isInner) && watchArea.width > 0 && watchArea.height > 0
    }

    /// Into or out of full screen: the window's picture flies between the window's frame and the
    /// screen (`FullScreenZoom`) while the layouts swap under it — every screen, every pose.
    /// In, it covers the screen from its top-left (a Mac window's content while it zooms); out,
    /// it lands whole in the window's frame, where the windowed viewer opens it whole too until
    /// the Mac's reshaped picture lands. On the phone the landing frame is known from the layout;
    /// on the inner screen it's read off the window's viewer once it has laid out (a re-aim 60 ms
    /// in; the spring keeps its speed).
    func fullScreenFlight(entering: Bool) {
        let zoom = FullScreenZoom.shared
        // The start, read before the layouts changed (`Watcher.setFullScreen` → `prepare`, round
        // 3): by now the full-screen viewer may be the one on screen.
        let prepared = zoom.takePrepared()
        guard !reduceMotion, let image = prepared?.image ?? windowPictureNow,
              let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds else { zoom.cancel(); return }
        let from = prepared?.place ?? WindowZoom.viewerPlace(in: screen)
        // The window's corner per picture pixel (the place's is at the viewer's zoom).
        let corner = from.map { $0.picture.width > 0 ? $0.corner / ($0.picture.width / max(1, image.size.width)) : 0 } ?? 0
        #if DEBUG
        model.log.add("full screen flight \(entering ? "in" : "out"): from \(from.map { "\(Int($0.clip.width))×\(Int($0.clip.height)) at \(Int($0.clip.minX)),\(Int($0.clip.minY))" } ?? "nowhere")\(prepared != nil ? " (prepared)" : "")")
        #endif
        if entering {
            zoom.enter(image: image, from: from, screen: screen, corner: corner)
            return
        }
        let phone = regularPhone || isCover
        // The landing: the phone's layout says it; the inner screen's window in hand reports its
        // place (`InnerWindowSpot`, round 3 — the flight had landed at near full-screen size and
        // re-laid to the page); else a guess the viewer corrects once laid out.
        let inner = InnerWindowSpot.shared.frame
        let to = phone && watchArea.width > 0 ? WindowZoom.estimate(image: image.size, area: watchArea, compact: compact).clip
            : !phone && inner.width > 40 && inner.height > 40 && (inner.height < screen.height - 40 || inner.width < screen.width - 40) ? inner
            : (from?.clip ?? screen).insetBy(dx: screen.width * 0.08, dy: screen.height * 0.08)
        zoom.exit(image: image, from: from, to: to, corner: corner)
        for delay in [0.06, 0.16] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard zoom.flying, let real = WindowZoom.viewerPlace(in: screen), real.clip.height < screen.height - 40 else { return }
                // The windowed viewer, laid out: its picture whole (`otherShape`) is the landing.
                zoom.aim(WindowZoomPlace(clip: real.picture.intersection(real.clip), picture: real.picture, corner: real.corner))
            }
        }
    }

    func flyWindow(shown: Bool) {
        let zoom = WindowZoom.shared
        zoom.panelChanged(shown: shown)
        guard flightAllowed else { zoom.cancel(); return }
        if shown {
            let key = WindowSnapshots.key(mac: model.pairedMac?.id, target: watcher.target ?? model.selection.target)
            zoom.opened(image: zoom.image ?? WindowSnapshots.cached(key), area: watchArea, compact: compact)
        } else {
            zoom.closing(image: windowPictureNow, area: watchArea, compact: compact, fromCard: windowFromCard)
        }
    }

    /// What the window shows this moment, as a picture: Done flies it home. (The kept one may be
    /// up to half a minute old until the save that Done starts has finished.)
    private var windowPictureNow: UIImage? {
        if watcher.videoSize != nil, let frame = watcher.video.displayedFrame(), let ui = WindowSnapshots.image(from: frame) { return ui }
        return watcher.image ?? watcher.lastPicture
            ?? WindowSnapshots.cached(WindowSnapshots.key(mac: model.pairedMac?.id, target: watcher.target ?? model.selection.target))
    }

    /// The window view's own fade: in on the settle spring (after the flight's most of the way),
    /// out quickly so the flying picture is all that's left.
    var panelFade: Animation {
        if !panelShown, !isCover, !reduceMotion { return Motion.leave }
        return panelAnimation
    }

    /// The cover (Nov 7 2026): the desktop and the window cross-fade with an overlap — the
    /// window's kept picture is in place on the first frame and the desktop fades out under it
    /// (one leaving before the other arrived left an empty frame between them).
    var panelAnimation: Animation {
        guard isCover else { return Motion.pick(Motion.settle, reduce: reduceMotion) }
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return panelShown ? .easeOut(duration: 0.18) : Motion.leave
    }

    /// The settings (the desktop): out quickly as the words take the stage, back in on the settle
    /// spring. The cover: under the window coming in, slower than it arrives, and back with the
    /// window going (overlapped); after the words, once they've gone (`Motion.afterLeave`).
    var settingsAnimation: Animation {
        if phoneSettings {
            guard isCover, !reduceMotion else { return Motion.pick(Motion.settle, reduce: reduceMotion) }
            return panelUp ? .easeOut(duration: 0.22) : Motion.afterLeave
        }
        if isCover, windowHere, !showLiveWords, !reduceMotion { return .easeOut(duration: 0.3) }
        return .easeOut(duration: 0.1)
    }
}

/// The first open's warm-up has run in this process (`MainView.warmPanel`): once per launch.
@MainActor enum PanelWarmup { static var done = false }

/// The window view's fade, kept drawn while hidden.
struct DockZoom: ViewModifier {
    var fade: Double

    /// Hidden, but still drawn: at 0 the renderer drops its layers, and the first frame of every
    /// open drew the panel's glass and picture afresh (on the simulator an open's first frame came
    /// 189–214 ms after it, then 72–102; kept drawn, 129, then 49–56).
    static let asleep: Double = 0.001
    /// …and once faded out, drawn tiny (`WindowZoom.panelParked`): a dot's worth of pixels.
    static let parked: CGFloat = 0.02

    func body(content: Content) -> some View {
        content.opacity(fade)
    }
}

/// The cover's foot (`barred`): the screen's own inset at the bottom (the home indicator's),
/// never the bar's buttons' — they live in the vertical bar, not along the foot. The same in
/// every state, the keyboard's too: the mic screen lays the keyboard's room out itself
/// (`MainView.laysOutKeyboard`), so nothing here moves with it. The keyboard's region is ignored
/// here, not inside: what's inside is laid out in the room this gives it, and the stack's
/// keyboard inset (which leaves in one step as the keyboard goes) would already have been taken.
private struct CoverFoot: ViewModifier {
    var on: Bool

    func body(content: Content) -> some View {
        content
            // Padded inside, ignored outside: the other way round the padding was laid out in the
            // stack's safe area (the keyboard's room already taken, and the foot's 34 twice).
            .padding(.bottom, on ? Self.screenFoot : 0)
            .ignoresSafeArea(.all, edges: on ? .bottom : [])
    }

    /// The window's own inset at the foot: the system's, with no toolbar in it.
    @MainActor static var screenFoot: CGFloat {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.safeAreaInsets.bottom ?? 34
    }
}

/// A clip at the foot alone: room above and at the sides for any glow.
private struct FootOnly: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - 200, y: rect.minY - 200, width: rect.width + 400, height: rect.height + 200))
    }
}


// MARK: The landed pill (Nov 3 2026)

/// One quiet confirmation in one place (Nov 7 2026, round 4): the pill, then the Undo that follows
/// it, both centred in the status line's slot under the mic — the pill shrinks into the chip where
/// it stands (`LandedMatch`). `pill` off: the pill is drawn elsewhere (the inner screen's one mic
/// floats it) and the slot carries only the Undo after it.
struct LandedSlot: View {
    var pill = true
    var namespace: Namespace.ID? = nil

    var body: some View {
        ZStack {
            if pill { LandedPill(namespace: namespace) }
            UndoChip(namespace: namespace)
        }
    }
}

/// Where the words landed, for a moment (Sameer chose "a clear 'it landed' moment"): "Pasted into
/// Claude", "Sent to Claude", "On your Mac's clipboard", a photo's "Added to Claude" with the photo
/// — and, for a paste that wasn't sent, Undo (the Mac takes it back with ⌘Z, `UndoPaste`).
struct LandedPill: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shared with the Undo chip it shrinks into (`UndoChip`), when one is drawn on this screen.
    var namespace: Namespace.ID? = nil

    var body: some View {
        ZStack {
            if let c = model.landedChip, !c.compact {
                pill(c)
                    .modifier(LandedMatch(namespace: reduceMotion ? nil : namespace))
                    // Going as the chip arrives it follows the chip's frame (the matched geometry).
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.92)),
                                                                     removal: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.82), value: model.landedChip)
    }

    private func pill(_ c: AppModel.LandedChip) -> some View {
        HStack(spacing: 8) {
            LandedGlyph(chip: c)
            Text(c.words).font(.footnote.weight(.semibold)).foregroundStyle(Ink.ink).oneLine(shrink: 0.75)
            if c.undoing {
                ProgressView().controlSize(.small)
            } else if c.canUndo {
                Rectangle().fill(Ink.line).frame(width: 1, height: 16)
                // The word in ink (Nov 8 2026): systemBlue on the glass over a wallpaper read at
                // 1.5 : 1 in dark. Its touch is the pill's whole end, 44 pt tall — it was the
                // word's own 16 pt.
                Button { model.undo(id: c.id) } label: {
                    Text("Undo").font(.footnote.weight(.semibold)).foregroundStyle(Ink.ink)
                        .padding(.leading, 2).padding(.trailing, 14)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                        .watchTouch(4)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Takes the paste back on your Mac.")
                .accessibilityIdentifier("landed-undo")
            }
        }
        .padding(.leading, c.thumbnail == nil ? 14 : 8)
        .padding(.trailing, c.canUndo && !c.undoing ? 0 : 14)
        .frame(height: 36)
        .watchGlass(Capsule())
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("landed-pill")
    }
}

/// The pill's and the chip's shared geometry: as the pill's moment ends it shrinks into the
/// chip's place (one leaves as the other arrives, as SwiftUI's own hero pairs do).
private struct LandedMatch: ViewModifier {
    var namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "landed", in: namespace, properties: .frame)
        } else {
            content
        }
    }
}

/// Undo, for as long as the Mac can take the paste back (Nov 7 2026, round 2: "Undo kept
/// longer"): once the landed pill has had its moment it becomes this small glass chip in the
/// same place — `arrow.uturn.backward` in a thin ring that drains over the undo's remaining
/// life, and "Undo Paste" — a 44 pt target drawn 32 pt tall, never moving the mic, the Thread
/// or the status line. It stays until a breath under the Mac's own 30 s (`AppModel.undoLife`),
/// the next dictation, the next landing, or Undo; it fades a little for its last seconds. A
/// shake asks the same question (`ShakeToUndo`).
struct UndoChip: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var namespace: Namespace.ID? = nil

    var body: some View {
        ZStack {
            if let c = model.landedChip, c.compact, c.canUndo {
                chip(c)
                    .modifier(LandedMatch(namespace: reduceMotion ? nil : namespace))
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.9))))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.84), value: model.landedChip)
    }

    private func chip(_ c: AppModel.LandedChip) -> some View {
        Button { model.undo(id: c.id) } label: {
            HStack(spacing: 7) {
                ZStack {
                    UndoRing(until: c.undoUntil)
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Light.cyan)
                }
                .frame(width: 20, height: 20)
                // Ink, the accent kept for the ring and its arrow (Nov 8 2026): blue words on the
                // glass over a wallpaper read at ~1.5 : 1 in dark, ~2.5 : 1 in light.
                Text("Undo Paste")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.ink)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 32)
            .watchGlass(Capsule())
            // The touch target: 44 pt tall, the glass 32.
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(c.fading ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.8), value: c.fading)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityLabel("Undo paste into \(model.undoable?.appName ?? "your Mac")")
        .accessibilityHint("Takes the paste back on your Mac.")
        .accessibilityIdentifier("landed-undo-chip")
    }
}

/// The ring round Undo's arrow: full when the chip arrives, drained when the Mac can no longer
/// take the paste back (a static ring under Reduce Motion).
private struct UndoRing: View {
    var until: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var left: CGFloat = 1

    var body: some View {
        ZStack {
            Circle().stroke(Light.cyan.opacity(0.22), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: left)
                .stroke(Light.cyan, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .task {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: max(0.1, until.timeIntervalSinceNow))) { left = 0 }
        }
    }
}

/// The pill's glyph, which says how it landed: the check draws itself on for a paste (iOS 26; a
/// bounce before), the paper plane flies up for a send, a photo shows itself small, a file its
/// page, and Undo's arrow replaces the check in place. Under Reduce Motion it's simply there.
private struct LandedGlyph: View {
    var chip: AppModel.LandedChip
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        if let thumb = chip.thumbnail, chip.ok {
            Image(uiImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Ink.line, lineWidth: 0.5))
                .accessibilityHidden(true)
        } else {
            let symbol = chip.undone ? "arrow.uturn.backward.circle.fill"
                : !chip.ok ? "exclamationmark.circle.fill"
                : chip.kind == .file ? "doc.fill"
                : chip.kind == .downloads ? "arrow.down.circle.fill"
                : chip.kind == .photo ? "photo.fill"
                : chip.sent ? "paperplane.circle.fill" : "checkmark.circle.fill"
            Image(systemName: symbol)
                .foregroundStyle(chip.ok ? Light.mint : Light.ochre)
                .contentTransition(.symbolEffect(.replace))
                .modifier(Arrival(sent: chip.sent && chip.ok && !chip.undone, shown: shown || reduceMotion))
                .onAppear { shown = true }
        }
    }

    private struct Arrival: ViewModifier {
        var sent: Bool
        var shown: Bool
        func body(content: Content) -> some View {
            if sent {
                content.symbolEffect(.bounce.up.byLayer, value: shown)
            } else if #available(iOS 26.0, *) {
                content.symbolEffect(.drawOn.byLayer, options: .nonRepeating, isActive: !shown)
            } else {
                content.symbolEffect(.bounce, value: shown)
            }
        }
    }
}

extension View {
    /// The landed pill floats just above this (the mic), never moving it — where there's no status
    /// line under the mic to carry it (full screen's floating mic, the inner screen's one mic).
    /// Off: the slot under the mic has it (`LandedSlot`).
    func landedPill(on: Bool = true, size: CGFloat = 92, namespace: Namespace.ID? = nil) -> some View {
        overlay(alignment: .top) {
            // The mic's frame is 1.25 × its disc; its ring sits 6 pt outside the disc. The pill's
            // foot is 18 pt clear of the ring at every size (hung a fixed 12 from the frame it
            // sat 14 over the 64 pt mic's ring and 17 over the 92's — Nov 7 2026).
            // (An alignment guide here was ignored — the pill sat on the disc's top, its own frame's
            // top at the mic's; the pill is a fixed 36 tall, so it's lifted by an offset instead.)
            if on { LandedPill(namespace: namespace).offset(y: -(36 + 18 + 6 - size * 0.125)) }
        }
    }

    /// The Undo chip at the trailing end of this, centred on it (kept for a layout with no slot
    /// under the mic; the phone's Thread no longer wears it — the slot does).
    func undoChip(on: Bool = true, namespace: Namespace.ID? = nil) -> some View {
        overlay(alignment: .trailing) {
            // In from the band's end: on the inner screen upright the Thread runs edge to edge.
            if on { UndoChip(namespace: namespace).padding(.trailing, 14) }
        }
    }
}
