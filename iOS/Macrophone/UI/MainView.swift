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
    /// Where the window shows (`phoneBody`, on screen): what it grows out of the Dock into.
    @State var watchArea: CGRect = .zero
    /// The window comes from the Dock and goes back into it (opened, Done) — but not when it
    /// steps aside for the words while the mic is open, or comes back after them: it grew out
    /// of the hidden Dock then, as if opened again (Nov 4 2026).
    @State var windowViaDock = true
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


    /// How the iPhone Duo is held (Oct 25 2026): the cover screen keeps this layout; the inner
    /// screen's poses are laid out in `UI/DuoView.swift`.
    @ObservedObject var posture = Posture.shared

    var body: some View {
        poseBody
        // A pose settling: the layouts cross-fade (the halves' own motion follows the hinge).
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: posture.pose)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: inFullScreen)
        // The laptop with a window in hand is a little Mac (Nov 1 2026, Sameer: "the view window
        // should take up the whole top half of the duo. Almost as if the duo was a mini Mac"):
        // the status bar goes, so the picture has the top edge too — folded or laid flat, the
        // same layout.
        .statusBarHidden(posture.pose.foldAcross && watcher.isShowing || inFullScreen)
        .persistentSystemOverlays(inFullScreen ? .hidden : .automatic)
        // The sky answers the state: cool when ready, ember while the mic is open, mint when it lands.
        // The Mac's own wallpaper behind everything; the state's light washes in from the foot —
        // orange while the mic is open, green when the words land; nothing at rest.
        .background(DesktopBackground(wallpaper: model.wallpaper, settings: model.settings, glow: filamentMode == .ready ? .clear : skyGlow)
            .animation(.easeInOut(duration: 0.7), value: filamentMode))
        // Siri's signal: the screen's edge glows while the mic listens.
        .overlay(ListeningEdge(active: isRecording && look == nil || look == "holding", meter: recorder.meter))
        .background(VerticalBarProbe(present: $verticalBar).frame(width: 0, height: 0).accessibilityHidden(true))
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
        .onChange(of: model.pulse) { _, _ in react() }
        .onChange(of: recorder.phase) { _, _ in react() }
        .onChange(of: recorder.hasWords) { _, _ in react() }
        .onChange(of: model.status) { _, _ in react() }
        .onAppear { react() }
        // A pose settling: a soft tick, and VoiceOver hears what's where now.
        .onChange(of: posture.settleSeq) { _, _ in
            Haptics.soft()
            UIAccessibility.post(notification: .layoutChanged, argument: posture.pose.spoken)
        }
    }

    /// The pose's layout: the phone's (the cover screen, every other iPhone), or the Duo's.
    /// The window has the whole inner screen (the Duo on its side, Full Screen).
    var inFullScreen: Bool { watcher.fullScreen && watcher.isShowing && Watcher.allowsFullScreen(posture.pose) }

    @ViewBuilder private var poseBody: some View {
        if inFullScreen {
            DuoFullScreen(main: self).transition(.opacity)
        } else {
            layoutBody
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
        switch posture.pose {
        // The inner screen's vertical bar (open on its side, the book) holds the cover's buttons.
        case .open(landscape: true): openLandscapeBody.transition(.opacity)
        case .book: bookBody.transition(.opacity)
        // Upright the fold runs across the middle, flat or folded: the laptop's layout either
        // way (one view, so folding it moves nothing — the halves follow the hinge).
        default: laptopBody.transition(.opacity)
        }
    }

    /// The inner screen's bar, one for every inner pose (Nov 4 2026): the pose's layout changes
    /// inside it, the stack itself never does. A stack per pose (and none on the laptop) made
    /// every fold a new stack, and a new stack lays its content out from nothing — the window and
    /// the mic grew out of the screen's corner as the laptop opened flat. Where the pose has no
    /// bar of the system's (the laptop: its controls are its own), the bar is hidden, not gone.
    @ViewBuilder func innerBarred<Content: View>(_ content: Content) -> some View {
        NavigationStack {
            content
                .toolbar { if barUsed { coverToolbar } }
                .toolbar(barUsed ? .automatic : .hidden, for: .navigationBar)
                .toolbar(barUsed ? .automatic : .hidden, for: .bottomBar)
                .navigationBarTitleDisplayMode(.inline)
                .coverBarStyle()
                .macSharePickers(photo: $coverPickingPhoto, file: $coverPickingFile, model: model)
        }
        .environment(\.controlsInVerticalBar, barUsed)
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
                                            // the pill would pop in and straight back out.)
                                            if !barUsed || (!model.isConnected && !model.settling) { topBar }
                                        }
                                    } else {
                                        // The phone: a little Mac desktop — the menu bar and the
                                        // last dictation as a widget (Nov 1 2026).
                                        // (The last-dictation widget is gone — Nov 1 2026,
                                        // Sameer: "I don't think is that useful".)
                                        PhoneMenuBar(watcher: watcher)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .scrollIndicators(.hidden)
                            .frame(maxHeight: .infinity, alignment: .top)
                            Color.clear.frame(height: compact ? 8 : 14)
                            dockArea
                        }
                        // Hidden, it keeps the height it had while it showed: the room changing
                        // under it as the window comes or goes never moves it.
                        .frame(width: area.size.width, height: showSettings || settingsRoom == 0 ? area.size.height : settingsRoom, alignment: .top)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if showSettings { settingsRoom = $0 } }
                    .onChange(of: showSettings) { _, on in if on { settingsRoom = 0 } }
                    // The mic row below changes size as a window opens or closes: the panel takes
                    // its new place at once and only fades — it used to slide down as it went and
                    // up as it came back, under the window's fade (Nov 3 2026, "elements …
                    // briefly stutter or glitch before correcting").
                    .animation(nil, value: watcher.isShowing)
                    .animation(nil, value: showLiveWords)
                    .opacity(showSettings ? 1 : 0)
                    // Out quickly (what comes in takes the stage), back in on the settle spring.
                    .animation(showSettings ? Motion.pick(Motion.settle, reduce: reduceMotion) : .easeOut(duration: 0.1), value: showSettings)
                    .allowsHitTesting(showSettings)
                    .accessibilityHidden(!showSettings)
                    // Watching: the window takes the area (Done brings the settings back).
                    if watcher.isShowing && !showLiveWords {
                        WatchPanel(watcher: watcher, compact: compact, cover: isCover,
                                   bare: isCover && input.keysUp).transition(windowTransition)
                    }
                    if showLiveWords {
                        VStack(spacing: 0) {
                            if watcher.isShowing {
                                WatchStrip(watcher: watcher, compact: compact)
                                    .padding(.horizontal, Space.margin)
                                    .padding(.top, 8)
                            }
                            transcriptArea
                        }
                        .transition(.opacity)
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
                .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: watcher.isShowing)
                // The Thread, one band in the same place in every state, and the mic under it —
                // and, while a window shows, the page row above the Thread and the keyboard and
                // the trackpad beside the mic (the Thread folds away on those pages: the trackpad
                // takes its room, the keyboard the foot of the screen). The mic page is the same
                // view on every page, so a hold on it is never lost.
                let coverWatching = isCover && watcher.isOpen && !showLiveWords
                InputCarousel(input: input, watcher: watcher, compact: compact,
                              // The cover: no Thread while a window shows; the trackpad page
                              // takes a thumb's worth of room instead.
                              threadHeight: coverWatching ? (input.page == .trackpad ? 116 : 0) : filamentSlot,
                              // The cover never draws the page row (its pages are the buttons
                              // beside the mic): tied to the window being open, it showed for a
                              // pass as the pages arrived first, and the window's top area
                              // shrank by the row before it grew (Nov 4 2026).
                              rowHidden: isCover,
                              trackpadBar: coverWatching,
                              rowDimmed: regularPhone && showLiveWords,
                              // The keyboard page's room, from the keyboard's own frame (this
                              // screen ignores the keyboard's safe area — below).
                              keyboardRoom: regularPhone ? max(0, input.keyboardRoom - geo.safeAreaInsets.bottom) : 0,
                              smoothHeight: isCover) {
                    // One mic button in every state: a hold on the cover's small mic flips the
                    // screen to the live words, and two branches made that a different button
                    // mid-press — the hold was lost (Oct 31 2026, Sameer: "press and hold on the
                    // mic button is not working").
                    VStack(spacing: coverWatching ? 2 : 0) {
                        if !coverWatching { Color.clear.frame(height: compact ? 14 : 30) }
                        // The cover, watching: one row under the thumb — the keyboard, the mic,
                        // the trackpad.
                        HStack(spacing: 0) {
                            if coverWatching { coverPageButton(.keyboard).frame(maxWidth: .infinity) }
                            micButton(size: coverWatching ? 64 : 92)
                            if coverWatching { coverPageButton(.trackpad).frame(maxWidth: .infinity) }
                        }
                        .padding(.top, coverWatching ? 4 : 0)
                        if coverWatching {
                            // One line in its 18 pt: a longer one (the trackpad's how-to) ran
                            // over the mic and its buttons above (Nov 4 2026).
                            StatusLine(recorder: recorder, holding: holding || look == "holding", font: .caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .padding(.horizontal, 12)
                                .frame(height: 18)
                        } else {
                            statusSlot
                                .padding(.bottom, compact ? 6 : 18)
                        }
                    }
                } thread: {
                    if !coverWatching {
                        threadBand
                    }
                }
            }
            // The keyboard and the trackpad are the window's: while the mic is open, the mic
            // stands alone.
            .onChange(of: showLiveWords) { _, live in
                if live, input.page != .mic { input.show(.mic, quiet: true) }
                // Back from the words (the window faded in): Done takes it into the Dock again.
                if !live, !windowViaDock { Task { @MainActor in windowViaDock = true } }
            }
            // The cover (Nov 4 2026): the window above moves with the pages, never ahead of them.
            // The trackpad taking its room shrank the window in one frame (only the pages had a
            // spring); and the keyboard's page folding away the moment the keyboard was asked for
            // stretched the window to the foot, then the keyboard rising squeezed it back — now
            // that fold rides the keyboard's own curve, so the window's foot moves once, up.
            // (Constant off the cover, so the phone and the inner screen are untouched.)
            .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: isCover ? input.page : .mic)
            .animation(reduceMotion ? nil : .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500), value: isCover && input.keysUp)
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
        .ignoresSafeArea(.keyboard, edges: regularPhone ? .bottom : [])
        .overlay(alignment: .bottom) {
            if regularPhone, showLiveWords, let draft = model.fixDraft {
                FixWordCard(draft: draft)
                    .padding(.horizontal, Space.margin - 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.fixDraft)
    }

    /// Every iPhone but the Duo (its cover and inner screen have layouts of their own).
    var regularPhone: Bool { !barUsed && !posture.pose.isInner }

    // MARK: The iPhone Duo's cover: the buttons in the vertical bar

    func micButton(size: CGFloat) -> some View {
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
                  size: size)
            .matchedGeometryEffect(id: micID, in: micSpace)
            .landedPill()
    }

    /// The keyboard or the trackpad, a round glass button beside the cover's mic.
    @ViewBuilder func coverPageButton(_ p: MacInput.Page) -> some View {
        if input.pages.contains(p) {
            // On the pages' spring, the whole screen at once (the window above moves with them).
            Button { withAnimation(Motion.pick(Motion.settle, reduce: reduceMotion)) { input.show(p) } } label: {
                Image(systemName: p.symbol).font(.title3.weight(.semibold)).frame(width: 30, height: 30)
            }
            .circleGlassButton()
            .accessibilityLabel(p.title)
            .accessibilityIdentifier("cover-page-\(p.rawValue)")
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
        Button { Haptics.tick(); watcher.done() } label: { Label("Done", systemImage: "checkmark") }
            .accessibilityHint(watcher.glanceOnDone ? "Puts the controls away; the window stays in view." : "Stops showing the window and brings back Send to and Cleanup.")
            .accessibilityIdentifier("watch-done")
    }

    /// Done first, then the window's own buttons (Apple's order for the bar); at rest History and
    /// Settings. While the mic is open nothing: the transcript has the screen.
    @ToolbarContentBuilder var coverToolbar: some ToolbarContent {
        if watcher.isShowing && !showLiveWords {
            // Done is the last to fold into the bar's overflow (the keyboard leaves it short).
            if #available(iOS 27.0, *) {
                ToolbarItem(placement: .topBarLeading) { coverDone }.visibilityPriority(.high)
            } else {
                ToolbarItem(placement: .topBarLeading) { coverDone }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // The keyboard up: putting it away is the first thing in the bar.
                if input.page == .keyboard {
                    Button { Haptics.tick(); input.hideKeyboard() } label: { Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") }
                        .accessibilityIdentifier("bar-keyboard-hide")
                }
                if model.macAudio.macCanPlay { CoverSoundItem(player: model.macAudio) }
                if model.canMacControls {
                    Button { Haptics.tick(); model.sheet = .macControls } label: { Label("Mac Controls", systemImage: "slider.horizontal.3") }
                        .accessibilityIdentifier("mac-controls")
                }
                if watcher.phase == .live {
                    Button { Haptics.tick(); watcher.setDrag(watcher.drag == .pan ? .scroll : .pan) } label: {
                        Label(watcher.drag == .pan ? "Pan" : "Scroll", systemImage: watcher.drag == .pan ? "hand.draw" : "arrow.up.and.down")
                    }
                    .tint(watcher.drag == .scroll ? Light.cyan : nil)
                    .accessibilityLabel("What one finger does")
                    .accessibilityValue(watcher.drag == .pan ? "Pan" : "Scroll")
                    .accessibilityHint("Switches between moving the picture and scrolling the window on your Mac.")
                    .accessibilityIdentifier("cover-drag")
                }
                if watcher.macCanFit, watcher.target != .clipboard {
                    Button { watcher.toggleWholeWindow() } label: {
                        Label(watcher.wholeWindow ? "Zoom Back In" : "Whole Window",
                              systemImage: watcher.wholeWindow ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    }
                    .disabled(watcher.phase != .live)
                    .accessibilityIdentifier("watch-whole")
                    if !watcher.isDesktop { WatchWindowMenu(watcher: watcher, bar: true) }
                }
            }
        } else if showSettings {
            // The upper group: the Mac and the app's own pages.
            ToolbarItemGroup(placement: .topBarTrailing) {
                CoverMacItem()
                Button { model.sheet = .history } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                Button { model.sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
            }
            // The lower group, nearer the thumb: what Send to's round buttons did.
            ToolbarItemGroup(placement: .bottomBar) {
                // What the Mac offered when last connected stays in its place, dimmed, while it
                // connects again — the buttons never arrive one by one (Nov 3 2026).
                if model.isConnected ? watcher.canWatchDesktop : barHadWholeScreen {
                    CoverWholeScreenItem(watcher: watcher).disabled(!model.isConnected)
                }
                if model.isConnected ? model.canMacControls : barHadControls {
                    Button { Haptics.tick(); model.sheet = .macControls } label: { Label("Mac Controls", systemImage: "slider.horizontal.3") }
                        .disabled(!model.isConnected)
                        .accessibilityIdentifier("mac-controls")
                }
                Menu {
                    if model.isConnected {
                        Button { model.refreshTargets(); Haptics.tick() } label: { Label("Refresh Open Apps", systemImage: "arrow.clockwise") }
                    }
                    MacShareItems(pickingPhoto: $coverPickingPhoto, pickingFile: $coverPickingFile)
                } label: { Label("More", systemImage: "ellipsis") }
                    .accessibilityIdentifier("send-to-more")
            }
        }
    }

    // MARK: Top

    var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                MacPill().fixedSize()
                WakeMacButton()
                Spacer(minLength: 8)
                topButtons
            }
            // Huge text: the buttons keep their corner, the Mac's name gets its own line.
            VStack(alignment: .leading, spacing: 8) {
                HStack { Spacer(); topButtons }
                MacPill()
                WakeMacButton()
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

    var threadBand: some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    ZStack {
                        Filament(mode: filamentMode, meter: recorder.meter, height: filamentHeight)
                        DeliveredCheck(visible: showCheck, color: checkColor)
                    }
                    .frame(height: 56)
                    if timerLine > 0 { timer.frame(height: timerLine).transition(.opacity) }
                }
            } else {
                ZStack {
                    Filament(mode: filamentMode, meter: recorder.meter, height: filamentHeight)
                        .frame(height: filamentSlot)
                    DeliveredCheck(visible: showCheck, color: checkColor)
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
            LiveWords(words: recorder.words, listening: isRecording, cardInline: !regularPhone)
                .padding(.horizontal, Space.text)
                .padding(.top, 8)
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
                        .foregroundStyle(recorder.softCapReached ? Light.ochre : Ink.secondary)
                        .accessibilityLabel("Recording time \(Int(ctx.date.timeIntervalSince(start))) seconds")
                }
            } else {
                Text(" ").font(.mono(.subheadline)).accessibilityHidden(true)
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
            StatusLine(recorder: recorder, holding: holding || look == "holding")
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
            // A long window name wraps to a second line rather than being cut with "…".
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
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
            Button { remember.toggle(); Haptics.tick() } label: {
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
                                .offset(x: 3, y: 2)
                        }
                        .accessibilityHidden(true)
                } else {
                    Circle().fill(dot).frame(width: 8, height: 8).shadow(color: dot.opacity(0.8), radius: 4)
                        .accessibilityHidden(true)
                }
                RollingName(name: title, key: model.pairedMac?.id.uuidString ?? "none", reduceMotion: reduceMotion,
                            font: menuBar ? .subheadline.weight(.bold) : .footnote.weight(.semibold),
                            color: menuBar ? Ink.ink : Ink.secondary, oneLine: menuBar)
                    .offset(y: several ? pull : 0)
                // The way it's connected, in a slot that's always there: the pill keeps its width
                // from launch to connected instead of growing when the sign arrives.
                if model.isPaired {
                    let route: LinkRoute? = { if case .connected = model.linkState { return model.linkRoute }; return nil }()
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
            .lineLimit(oneLine ? 1 : nil)
            .minimumScaleFactor(oneLine ? 0.85 : 1)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
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
                        Text("Get the free Mac app").font(.caption.weight(.semibold)).lineLimit(2)
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
    /// The window grows out of the pick's icon on the Dock and goes back into it (Nov 4 2026,
    /// Sameer picked "the Dock icon opens into the window"), on the settle spring that already
    /// carries it in and out. Where no Dock is drawn, or with Reduce Motion, it fades as before.
    var windowTransition: AnyTransition {
        guard !reduceMotion, windowViaDock, !(barUsed || posture.pose.isInner), let icon = DockSpot.shared.pick, watchArea.width > 0,
              watchArea.insetBy(dx: -40, dy: -40).contains(CGPoint(x: icon.midX, y: icon.midY)) else { return .opacity }
        let zoom = DockZoom(scale: max(0.06, icon.width / watchArea.width),
                            offset: CGSize(width: icon.midX - watchArea.midX, height: icon.midY - watchArea.midY), fade: 0)
        return .modifier(active: zoom, identity: DockZoom(scale: 1, offset: .zero, fade: 1))
    }
}

/// The window at the icon's size and place (active), or its own (identity).
private struct DockZoom: ViewModifier {
    var scale: CGFloat
    var offset: CGSize
    var fade: Double

    func body(content: Content) -> some View {
        content.scaleEffect(scale).offset(offset).opacity(fade)
    }
}

/// The cover's foot (`barred`): the screen's own inset at the bottom (the home indicator's),
/// never the bar's buttons' — they live in the vertical bar, not along the foot. The keyboard
/// still lifts the content as ever; while it's up the foot is the keyboard's.
private struct CoverFoot: ViewModifier {
    var on: Bool
    @State private var keyboard = false

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: on ? .bottom : [])
            .padding(.bottom, on && !keyboard ? Self.screenFoot : 0)
            // On the keyboard's own curve, beside it.
            .animation(on ? .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500) : nil, value: keyboard)
            // Heard as it's posted, inside the keyboard's own animation (as `MacInput` hears it).
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
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

/// Where the words landed, rising from the mic and fading (Sameer chose "a clear 'it landed'
/// moment"): "Pasted into Claude", "Sent to Claude", "On your Mac's clipboard" — and, for a paste
/// that wasn't sent, Undo for a few seconds (the Mac takes it back with ⌘Z, `UndoPaste`).
struct LandedPill: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let c = model.landedChip {
                pill(c)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.92, anchor: .bottom)),
                                                                     removal: .opacity.combined(with: .offset(y: -6))))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.82), value: model.landedChip)
    }

    private func pill(_ c: AppModel.LandedChip) -> some View {
        HStack(spacing: 8) {
            Image(systemName: c.undone ? "arrow.uturn.backward.circle.fill" : c.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(c.ok ? Light.mint : Light.ochre)
            Text(c.words).font(.footnote.weight(.semibold)).foregroundStyle(Ink.ink).lineLimit(1)
            if c.undoing {
                ProgressView().controlSize(.small)
            } else if c.canUndo {
                Rectangle().fill(Ink.line).frame(width: 1, height: 16)
                Button { model.undoLanded() } label: { Text("Undo").font(.footnote.weight(.semibold)) }
                    .tint(Light.cyan)
                    .accessibilityHint("Takes the paste back on your Mac.")
                    .accessibilityIdentifier("landed-undo")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .watchGlass(Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("landed-pill")
    }
}

extension View {
    /// The landed pill floats just above this (the mic), never moving it.
    func landedPill() -> some View {
        overlay(alignment: .top) {
            LandedPill().alignmentGuide(.top) { $0[.bottom] + 12 }
        }
    }
}
