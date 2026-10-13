import MacrophoneKit
import SwiftUI

/// The mic screen: the Filament, the words, one big button, the status line, the last dictation.
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
    /// iPhone SE-class heights: a shorter stage so the last dictation still shows.
    @State private var compact = false
    @AppStorage("onboarding.macNudgeDismissed") private var macNudgeDismissed = false

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
                    controls
                    bottom
                }
                .frame(minHeight: geo.size.height)
            }
            .onAppear { compact = geo.size.height < 700 }
            .onChange(of: geo.size.height) { _, h in compact = h < 700 }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(isRecording)
        }
        .background(GroundBackground(glow: isRecording ? Light.ember : Light.cyan).animation(.easeInOut(duration: 0.6), value: isRecording))
        .onChange(of: model.pulse) { _, _ in react() }
        .onChange(of: recorder.phase) { _, _ in react() }
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

    private var filamentHeight: CGFloat { compact ? 84 : 112 }

    /// The words grow into the room the card leaves while recording, so the line stays put.
    private var stage: some View {
        VStack(spacing: 0) {
            if showLiveWords {
                LiveWords(text: recorder.transcript, listening: isRecording)
                    .frame(minHeight: compact ? 84 : 110, maxHeight: .infinity)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 8)
                    idleWords
                }
                .frame(minHeight: compact ? 64 : 110, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .transition(.opacity)
            }
            ZStack {
                Filament(mode: filamentMode, meter: recorder.meter, height: filamentHeight)
                DeliveredCheck(visible: showCheck, color: checkColor)
                if !typeSize.isAccessibilitySize { timer.frame(maxHeight: .infinity, alignment: .bottom) }
            }
            .frame(height: filamentHeight)
            .padding(.horizontal, -4)
            if typeSize.isAccessibilitySize { timer }
        }
        .frame(maxHeight: .infinity)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: showLiveWords)
    }

    private var idleWords: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Text(model.isPaired ? "Speak, and it's on your Mac." : "Speak, and it's on your clipboard.")
                .font(.serif(compact ? .title3 : .title2))
                .foregroundStyle(Ink.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // On a small screen the hint gives its room to the last dictation once there is one.
            if model.settings.showHoldHint, !(compact && model.latest != nil) {
                Text("Tap to talk, tap again to send — or hold, and let go to send.")
                    .font(.subheadline)
                    .foregroundStyle(Ink.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
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

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            if model.isPaired, !model.profiles.isEmpty {
                SendToChip(recorder: recorder, recording: isRecording)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }
            MicButton(recording: isRecording,
                      busy: false,
                      meter: recorder.meter,
                      onDown: pressDown,
                      onUp: pressUp,
                      onAccessibilityToggle: { model.toggleRecording() })
            StatusLine(recorder: recorder, holding: holding)
                .frame(minHeight: 40, alignment: .top)
        }
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

    private var bottom: some View {
        VStack(spacing: 10) {
            if let item = model.latest, !showLiveWords {
                LastDictationCard(item: item,
                                  onCopy: { model.copy(item, cleaned: $0) },
                                  onResend: { model.resend(item) },
                                  maxTextHeight: typeSize.isAccessibilitySize ? 220 : (compact ? 72 : 96),
                                  canResend: model.isPaired)
                    .id(item.id)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                // The first dictations without a Mac: it worked here; this is how to get it there.
                if !model.isPaired, item.delivery == .copiedOnPhone, !macNudgeDismissed {
                    MacAppNudge { withAnimation(Motion.pick(Motion.depart, reduce: reduceMotion)) { macNudgeDismissed = true } }
                        .transition(.opacity)
                }
            }
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
            .accessibilityLabel("Show history")
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

    private func react() {
        settleTask?.cancel()
        let mode: FilamentMode
        if isRecording {
            mode = .live
        } else {
            switch model.status {
            case .cleaning, .sending: mode = .sending
            case .delivered, .duplicate, .copiedOnPhone: mode = .delivered
            case .queued: mode = .queued
            case .failed, .problem: mode = .error
            case .listening: mode = recorder.phase == .finishing ? .sending : .live
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
            .edgeFade(top: 48, bottom: 0)
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

/// Under the first dictations made without a Mac: the free Mac app, one tap to send yourself
/// the link. Dismissed for good with the close button; gone once a Mac is paired.
struct MacAppNudge: View {
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ShareLink(item: Product.website,
                      subject: Text("Macrophone for Mac"),
                      message: Text("Get Macrophone for your Mac: \(Product.website.absoluteString)")) {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Light.cyan)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Light.cyan.opacity(0.12)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Want it on your Mac?")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Ink.ink)
                        Text("The free Mac app puts your words right where you're typing. Tap to send yourself the link.")
                            .font(.footnote)
                            .foregroundStyle(Ink.tertiary)
                    }
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                .padding(.leading, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shares the download link, so you can open it on your Mac.")
            .accessibilityIdentifier("mac-app-nudge")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide this")
        }
        .padding(.trailing, 2)
        .glass(Radius.medium)
    }
}
