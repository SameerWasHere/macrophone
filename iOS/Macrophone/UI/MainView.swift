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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var startedByPress = false
    @State private var stopOnRelease = false
    @State private var holding = false
    @State private var filamentMode: FilamentMode = .ready
    @State private var showCheck = false
    @State private var settleTask: Task<Void, Never>?
    /// iPhone SE-class heights: a shorter stage and card; History lives in the top bar only.
    @State private var compact = false

    private var isRecording: Bool { recorder.phase == .recording || recorder.phase == .starting }

    /// The words stay on screen from the first word until the text has gone out.
    private var showLiveWords: Bool {
        isRecording || recorder.phase == .finishing || model.processing
    }

    /// The top bar, header and controls: at rest, when nothing else has the area.
    private var showSettings: Bool { !showLiveWords && !watcher.isOpen }

    var body: some View {
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
                                topBar
                                Spacer(minLength: compact ? 10 : 20)
                                header
                                    .padding(.horizontal, Space.text)
                                Spacer(minLength: compact ? 10 : 20)
                                quickControls
                            }
                            .frame(minHeight: area.size.height)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.hidden)
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
                // The Thread: one band, the same place in every state.
                threadBand
                // Room between the Thread and the mic.
                Color.clear.frame(height: compact ? 14 : 30)
                MicButton(recording: isRecording,
                          busy: false,
                          meter: recorder.meter,
                          onDown: pressDown,
                          onUp: pressUp,
                          onAccessibilityToggle: { model.toggleRecording() })
                statusSlot
                    .padding(.bottom, compact ? 6 : 18)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { compact = geo.size.height < 700 }
            .onChange(of: geo.size.height) { _, h in compact = h < 700 }
        }
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
    }

    // MARK: Top

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                MacPill().fixedSize()
                Spacer(minLength: 8)
                topButtons
            }
            // Huge text: the buttons keep their corner, the Mac's name gets its own line.
            VStack(alignment: .leading, spacing: 8) {
                HStack { Spacer(); topButtons }
                MacPill()
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, 6)
        .opacity(isRecording ? 0.35 : 1)
        .allowsHitTesting(!isRecording)
        .animation(.easeInOut(duration: 0.25), value: isRecording)
    }

    @ViewBuilder private var topButtons: some View {
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

    private var filamentHeight: CGFloat { compact ? 56 : 96 }
    private var filamentSlot: CGFloat { compact ? 56 : 84 }

    private var threadBand: some View {
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

    private var transcriptArea: some View {
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

    /// The header at the top of the page: the line, and how to use the mic.
    private var header: some View {
        let line = model.isPaired ? "Speak, and it's on your Mac." : "Speak, and it's on your clipboard."
        return VStack(spacing: 8) {
            Text(line)
                .font(.serif(compact ? .title3 : .title2))
                .foregroundStyle(Ink.ink)
            Text("Tap to talk, tap again to send. Or hold, and let go.")
                .font(compact ? .footnote : .subheadline)
                .foregroundStyle(Ink.tertiary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var timer: some View {
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
    }

    // MARK: Quick controls, the mic, the status line

    private var quickControls: some View {
        QuickControls(settings: model.settings, compact: compact)
            .padding(.bottom, compact ? 10 : 18)
    }

    private var statusSlot: some View {
        FixedSlot(alignment: .top) {
            // Two lines of the status font (three at accessibility sizes); longer lines step down a size.
            Text(typeSize.isAccessibilitySize ? "A\nB\nC" : "A\nB").font(.subheadline).lineSpacing(0)
                .frame(maxWidth: .infinity)
        } content: {
            StatusLine(recorder: recorder, holding: holding)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private func pressDown() {
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

    private func pressUp(_ held: TimeInterval) {
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

    private var checkColor: Color { Light.mint }

    private var skyGlow: Color {
        switch filamentMode {
        case .ready: return Light.cyan
        case .listening, .live: return Light.ember
        case .sending: return Light.teal
        case .delivered: return Light.mint
        case .queued: return Light.ochre
        case .error: return Light.rose
        }
    }

    private func react() {
        settleTask?.cancel()
        let mode: FilamentMode
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
        withAnimation(.easeInOut(duration: 0.2)) { filamentMode = mode }
        showCheck = (mode == .delivered)
        // A miss stays in view longer than a success.
        let landedMiss: Bool = { if case .landed(let l) = model.status { return !l.isSuccess }; if case .unconfirmed = model.status { return true }; return false }()
        if mode == .delivered || mode == .error || landedMiss {
            settleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: mode == .delivered ? 2_600_000_000 : 6_000_000_000)
                guard !Task.isCancelled else { return }
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

/// The paired Mac and its connection, top left: the light, the Mac's name and — when connected —
/// a small sign of how (Oct 17 2026, Sameer: "a little Wi-Fi logo ... over Tailscale ... a little
/// VPN logo"): Wi-Fi at home, the direct link nearby, a shielded network through Tailscale, a
/// globe over the internet. Taps through to pairing when unpaired.
struct MacPill: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.sheet = model.isPaired ? .settings : .pairing
        } label: {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8).shadow(color: dot.opacity(0.8), radius: 4)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if case .connected = model.linkState, let route = model.linkRoute {
                    Image(systemName: Self.symbol(route))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(route.isAway ? Light.cyan : Ink.tertiary)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 2)
            .frame(minHeight: 37)
        }
        .nativeGlassButton()
        .buttonBorderShape(.capsule)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityLabel(accessibility)
        .accessibilityHint(model.isPaired ? "Opens Settings." : "Pairs this iPhone with Macrophone on your Mac.")
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
