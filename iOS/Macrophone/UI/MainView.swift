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
                    if !model.profiles.isEmpty { ProfileMenu().padding(.top, 2) }
                    stage
                    controls
                    bottom
                }
                .frame(minHeight: geo.size.height)
            }
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
        HStack(spacing: 10) {
            MacPill()
            Spacer(minLength: 8)
            Button { model.sheet = .history } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("History")
            Button { model.sheet = .settings } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .opacity(isRecording ? 0.35 : 1)
        .allowsHitTesting(!isRecording)
        .animation(.easeInOut(duration: 0.25), value: isRecording)
    }

    // MARK: Stage: the words and the Filament

    /// The words grow into the room the card leaves while recording, so the line stays put.
    private var stage: some View {
        VStack(spacing: 0) {
            if showLiveWords {
                LiveWords(text: recorder.transcript, listening: isRecording)
                    .frame(minHeight: 110, maxHeight: .infinity)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 8)
                    idleWords
                }
                .frame(minHeight: 110, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .transition(.opacity)
            }
            ZStack {
                Filament(mode: filamentMode, meter: recorder.meter, height: 112)
                DeliveredCheck(visible: showCheck, color: checkColor)
                timer.frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 112)
            .padding(.horizontal, -4)
        }
        .frame(maxHeight: .infinity)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: showLiveWords)
    }

    private var idleWords: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Text(model.isPaired ? "Speak, and it's on your Mac." : "Speak, and it's on your clipboard.")
                .font(.serif(.title2))
                .foregroundStyle(Ink.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.settings.showHoldHint {
                Text("Tap to talk, tap again to send — or hold, and let go to send.")
                    .font(.subheadline)
                    .foregroundStyle(Ink.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
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
                                  maxTextHeight: typeSize.isAccessibilitySize ? 220 : 96)
                    .id(item.id)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
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
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(Capsule().fill(Ink.ink.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel(accessibility)
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

/// The Mac's profiles, as a small chip with a menu. The choice is remembered.
struct ProfileMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            Picker("Profile", selection: Binding(get: { model.selectedProfile?.id }, set: { model.selectProfile($0) })) {
                ForEach(model.profiles) { p in
                    Text(p.cleanupLevel.map { "\(p.name) · \($0.title) cleanup" } ?? p.name).tag(Optional(p.id))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Kicker("Profile")
                Text(model.selectedProfile?.name ?? "Default")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 34)
            .background(Capsule().fill(Ink.ink.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 1))
        }
        .frame(minHeight: 44)
        .accessibilityLabel("Profile: \(model.selectedProfile?.name ?? "Default")")
        .accessibilityHint("Choose which of your Mac's profiles handles the next dictation.")
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
