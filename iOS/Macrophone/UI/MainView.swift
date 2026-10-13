import MacrophoneKit
import SwiftUI

/// The mic screen: the words and the Filament, the quick controls, one big button, the status
/// line, the last dictation.
///
/// **The mic never moves.** Everything under the stage sits in a fixed slot whose size comes from
/// a hidden worst-case template (`FixedSlot`), never from what's showing: the quick controls, the
/// status line and the last-dictation card keep their room in every state (idle, holding,
/// recording, sending, delivered, queued, failed, no history, unpaired, a long or short target).
/// Only the words area above flexes, and the live words grow into it without pushing anything.
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
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

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    topBar
                    stage
                    quickControls
                    MicButton(recording: isRecording,
                              busy: false,
                              meter: recorder.meter,
                              onDown: pressDown,
                              onUp: pressUp,
                              onAccessibilityToggle: { model.toggleRecording() })
                    statusSlot
                    bottom
                }
                .frame(minHeight: geo.size.height)
            }
            .onAppear { compact = geo.size.height < 700 }
            .onChange(of: geo.size.height) { _, h in compact = h < 700 }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(isRecording)
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
        .onChange(of: recorder.transcript.isEmpty) { _, _ in react() }
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
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .opacity(isRecording ? 0.35 : 1)
        .allowsHitTesting(!isRecording)
        .animation(.easeInOut(duration: 0.25), value: isRecording)
    }

    @ViewBuilder private var topButtons: some View {
        Button { model.sheet = .history } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel("History")
        .accessibilityShowsLargeContentViewer { Label("History", systemImage: "clock.arrow.circlepath") }
        Button { model.sheet = .settings } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel("Settings")
        .accessibilityShowsLargeContentViewer { Label("Settings", systemImage: "gearshape") }
    }

    // MARK: Stage: the words and the Filament

    private var filamentHeight: CGFloat { compact ? 56 : 96 }
    private var filamentSlot: CGFloat { compact ? 50 : 74 }

    /// The one flexible part of the page. Idle words and live words share one area whose size
    /// never depends on which is showing.
    private var stage: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(minHeight: compact ? 36 : 82, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    ZStack(alignment: .bottom) {
                        if showLiveWords {
                            LiveWords(text: recorder.transcript, listening: isRecording)
                                .transition(.opacity)
                        } else {
                            idleWords.transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .clipped()
                .padding(.top, 6)
            ZStack {
                // The Thread's band is taller than its slot: its quiet top edge sits under the words'
                // last line, so the words keep room for their hint without a shorter Thread.
                Filament(mode: filamentMode, meter: recorder.meter, height: filamentHeight)
                    .frame(height: filamentSlot, alignment: .bottom)
                DeliveredCheck(visible: showCheck, color: checkColor)
                if !typeSize.isAccessibilitySize { timer.frame(maxHeight: .infinity, alignment: .bottom) }
            }
            .frame(height: filamentSlot)
            .padding(.horizontal, -4)
            if typeSize.isAccessibilitySize { timer }
        }
        .frame(maxHeight: .infinity)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: showLiveWords)
    }

    /// Whatever fits of: the line and the hint; the line; the line smaller.
    private var idleWords: some View {
        let line = model.isPaired ? "Speak, and it's on your Mac." : "Speak, and it's on your clipboard."
        let hint = "Tap to talk, tap again to send. Or hold, and let go."
        return ViewThatFits(in: .vertical) {
            if model.settings.showHoldHint {
                VStack(spacing: 10) { idleLine(line, compact ? .title3 : .title2); idleHint(hint) }
            }
            idleLine(line, compact ? .title3 : .title2)
            idleLine(line, .headline)
            // Huge text in a short area: the line, shrunk to fit whole rather than cut off.
            Text(line).font(.serif(.headline)).foregroundStyle(Ink.ink).multilineTextAlignment(.center)
                .lineLimit(3).minimumScaleFactor(0.4)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private func idleLine(_ s: String, _ style: Font.TextStyle) -> some View {
        Text(s)
            .font(.serif(style))
            .foregroundStyle(Ink.ink)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func idleHint(_ s: String) -> some View {
        Text(s)
            .font(.subheadline)
            .foregroundStyle(Ink.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
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
        FixedSlot {
            QuickControlsTemplate(compact: compact)
        } content: {
            QuickControls(settings: model.settings, recorder: recorder, recording: isRecording, compact: compact)
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
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

    // MARK: Bottom: last dictation and the way to history

    private var cardTextHeight: CGFloat { typeSize.isAccessibilitySize ? 200 : (compact ? 44 : 72) }

    private var bottom: some View {
        VStack(spacing: 10) {
            FixedSlot(alignment: .top) {
                LastDictationCard.template(maxTextHeight: cardTextHeight)
            } content: {
                if let item = model.latest {
                    LastDictationCard(item: item,
                                      onCopy: { model.copy(item, cleaned: $0) },
                                      onResend: { model.resend(item) },
                                      maxTextHeight: cardTextHeight,
                                      canResend: model.isPaired)
                        .id(item.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        // Recording: the card keeps its room and fades, so nothing below the mic moves.
                        .opacity(showLiveWords ? 0.22 : 1)
                        .allowsHitTesting(!showLiveWords)
                } else {
                    Text("Your last dictation shows here, ready to copy or send again.")
                        .font(.footnote)
                        .foregroundStyle(Ink.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                        .opacity(showLiveWords ? 0 : 1)
                }
            }
            if !compact {
                Button { model.sheet = .history } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.compact.up").font(.title3.weight(.semibold))
                        Text(model.historyItems.isEmpty ? "History" : "History · \(model.historyItems.count)")
                            .font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isRecording ? 0 : 1)
                .allowsHitTesting(!isRecording)
                .accessibilityLabel("Show history")
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(Motion.pick(Motion.arrive, reduce: reduceMotion), value: model.latest?.id)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: showLiveWords)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { v in
                if v.translation.height < -50, abs(v.translation.width) < abs(v.translation.height), !isRecording {
                    model.sheet = .history
                }
            }
        )
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
            mode = recorder.transcript.isEmpty ? .listening : .live
        } else {
            switch model.status {
            case .cleaning, .sending: mode = .sending
            case .delivered, .duplicate, .copiedOnPhone: mode = .delivered
            case .queued: mode = .queued
            case .failed, .problem: mode = .error
            case .listening: mode = recorder.phase == .finishing ? .sending : .listening
            default: mode = recorder.phase == .finishing ? .sending : .ready
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) { filamentMode = mode }
        showCheck = (mode == .delivered)
        if mode == .delivered || mode == .error {
            settleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                guard !Task.isCancelled else { return }
                showCheck = false
                if filamentMode == .delivered || filamentMode == .error { filamentMode = .ready }
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

/// The words as they're heard: serif, newest at the bottom, older lines fading out the top.
struct LiveWords: View {
    var text: String
    var listening: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack {
                    Spacer(minLength: 0)
                    Text(text.isEmpty ? (listening ? "Listening…" : " ") : text)
                        .font(.serif(.title2))
                        .foregroundStyle(text.isEmpty ? Ink.tertiary : Ink.ink)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .edgeFade(top: 36, bottom: 0)
            .onChange(of: text) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.isEmpty ? "Listening" : text)
    }
}

/// The paired Mac and its connection, top left. Taps through to pairing when unpaired.
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Ink.ink.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
            // The plate is 36pt; the hit area is the full 44.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityLabel(accessibility)
        .accessibilityHint(model.isPaired ? "Opens Settings." : "Pairs this iPhone with Macrophone on your Mac.")
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
        case .connected(let n): return "Connected to \(n)"
        case .connecting(let n): return "Connecting to \(n)"
        case .unreachable(let n): return "\(n) not found"
        case .searching: return "Looking for \(model.macName)"
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Ink.secondary)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Ink.ink.opacity(configuration.isPressed ? 0.12 : 0.05)))
            .overlay(Circle().strokeBorder(Ink.line, lineWidth: 1))
            .contentShape(Circle())
    }
}

/// In the quick controls' first line, after the first dictations made without a Mac: the free
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
                .padding(.leading, 14)
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
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Light.cyan.opacity(0.08)).padding(.vertical, 3))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Light.cyan.opacity(0.35), lineWidth: 1).padding(.vertical, 3))
    }
}
