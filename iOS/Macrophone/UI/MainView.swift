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
    var showSettings: Bool { !showLiveWords && !watcher.isOpen }


    /// How the iPhone Duo is held (Oct 25 2026): the cover screen keeps this layout; the inner
    /// screen's poses are laid out in `UI/DuoView.swift`.
    @ObservedObject var posture = Posture.shared

    var body: some View {
        poseBody
        // The sky answers the state: cool when ready, ember while the mic is open, mint when it lands.
        .background(GroundBackground(glow: skyGlow).animation(.easeInOut(duration: 0.7), value: filamentMode))
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if DebugHooks.env["MACROPHONE_ROUTE_PROBE"] == "1" {
                Text(model.routeProbe).font(.system(size: 1)).opacity(0.01).frame(width: 1, height: 1)
                    .accessibilityIdentifier("debug-route").accessibilityLabel(model.routeProbe)
            }
        }
        #endif
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
    @ViewBuilder private var poseBody: some View {
        switch posture.pose {
        case .closed: phoneBody
        case .open(let landscape): if landscape { openLandscapeBody } else { openPortraitBody }
        case .laptop: laptopBody
        case .book: bookBody
        }
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
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                // No header (Oct 19 2026, Sameer: "the speak and it's on your Mac and
                                // sub header are also useless"): the top bar, then the panel in thumb
                                // reach above the Thread.
                                topBar
                                Spacer(minLength: compact ? 10 : 20)
                                quickControls
                            }
                            .frame(minHeight: area.size.height)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.hidden)
                        // At a text size where the panel runs past the area, its edge dissolves
                        // toward the Thread instead of being sliced (the fade sits in the panel's
                        // own bottom padding, so a panel that fits is never touched).
                        .edgeFade(bottom: compact ? 8 : 16)
                    }
                    .opacity(showSettings ? 1 : 0)
                    .allowsHitTesting(showSettings)
                    .accessibilityHidden(!showSettings)
                    // Watching: the window takes the area (Done brings the settings back).
                    if watcher.isOpen && !showLiveWords {
                        WatchPanel(watcher: watcher, compact: compact).transition(.opacity)
                    }
                    if showLiveWords {
                        VStack(spacing: 0) {
                            if watcher.isOpen {
                                WatchStrip(watcher: watcher, compact: compact)
                                    .padding(.horizontal, Space.margin)
                                    .padding(.top, 8)
                            }
                            transcriptArea
                        }
                        .transition(.opacity)
                    }
                }
                // Whatever is above takes the room that's left — it can never push the mic.
                .frame(minHeight: 0, maxHeight: .infinity)
                .clipped()
                .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: showLiveWords)
                .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: watcher.isOpen)
                // The Thread, one band in the same place in every state, and the mic under it —
                // and, while a window shows, the page row above the Thread and the keyboard and
                // the trackpad beside the mic (the Thread folds away on those pages: the trackpad
                // takes its room, the keyboard the foot of the screen). The mic page is the same
                // view on every page, so a hold on it is never lost.
                InputCarousel(input: input, watcher: watcher, compact: compact, threadHeight: filamentSlot) {
                    VStack(spacing: 0) {
                        // Room between the Thread and the mic.
                        Color.clear.frame(height: compact ? 14 : 30)
                        MicButton(recording: isRecording,
                                  finishing: isFinishing,
                                  mode: filamentMode,
                                  disabled: micOff,
                                  meter: recorder.meter,
                                  onDown: pressDown,
                                  onUp: pressUp,
                                  onAccessibilityToggle: { model.toggleRecording() })
                        statusSlot
                            .padding(.bottom, compact ? 6 : 18)
                    }
                } thread: {
                    threadBand
                }
            }
            // The keyboard and the trackpad are the window's: while the mic is open, the mic
            // stands alone.
            .onChange(of: showLiveWords) { _, live in if live, input.page != .mic { input.show(.mic, quiet: true) } }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { compact = geo.size.height < 700 }
            .onChange(of: geo.size.height) { _, h in compact = h < 700 }
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
    var filamentSlot: CGFloat { compact ? 56 : 84 }

    var threadBand: some View {
        ZStack {
            Filament(mode: filamentMode, meter: recorder.meter, height: filamentHeight)
                .frame(height: filamentSlot)
            DeliveredCheck(visible: showCheck, color: checkColor)
            timer.frame(maxHeight: .infinity, alignment: .bottom)
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
            LiveWords(words: recorder.words, listening: isRecording)
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

    var quickControls: some View {
        QuickControls(settings: model.settings, compact: compact, glow: skyGlow)
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
        return Text(parts.joined(separator: " · ").uppercased())
            .font(.mono(.caption2, weight: .medium))
            .tracking(1.1)
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
    @ObservedObject var words: LiveTranscript
    var listening: Bool

    var body: some View {
        let parts = words.parts
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // Room under the fade, so unscrolled words start clear of it.
                    Color.clear.frame(height: 22)
                    label(parts)
                        .font(.serif(.title2))
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.top)
            // Once the words fill the area, the line leaving the top fades instead of being sliced.
            .mask(VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 22)
                Color.black
            })
            .onChange(of: parts) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.isEmpty ? "Listening" : parts.text)
    }

    /// One Text (one layout pass), the settled words in ink and the rest dimmer.
    private func label(_ parts: LiveTranscript.Parts) -> Text {
        if parts.isEmpty { return Text(listening ? "Listening…" : " ").foregroundStyle(Ink.tertiary) }
        let settled = Text(parts.settled).foregroundStyle(Ink.ink)
        guard !parts.pending.isEmpty else { return settled }
        let pending = Text(parts.pending).foregroundStyle(Ink.secondary)
        return parts.settled.isEmpty ? pending : settled + Text(" ") + pending
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
                Circle().fill(dot).frame(width: 8, height: 8).shadow(color: dot.opacity(0.8), radius: 4)
                    .accessibilityHidden(true)
                RollingName(name: title, key: model.pairedMac?.id.uuidString ?? "none", reduceMotion: reduceMotion)
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
            .padding(.horizontal, 2)
            .frame(minHeight: 37)
        }
        .nativeGlassButton()
        .buttonBorderShape(.capsule)
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
        let font = Font.footnote.weight(.semibold)
        let rolling = leaving != nil && progress < 1
        Text(shown?.name ?? name)
            .font(font)
            .foregroundStyle(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .opacity(rolling ? (reduceMotion ? Double(progress) : Double(0.2 + 0.8 * progress)) : 1)
            .offset(y: rolling && !reduceMotion ? (1 - progress) * travel * (leaving?.up == true ? 1 : -1) : 0)
            .overlay(alignment: .leading) {
                if let leaving, rolling {
                    Text(leaving.name)
                        .font(font)
                        .foregroundStyle(Ink.secondary)
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
