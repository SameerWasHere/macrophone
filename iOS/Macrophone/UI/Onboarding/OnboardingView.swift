import MacrophoneKit
import SwiftUI

/// Phone-first setup. Every step can be skipped, and the app comes back to the same step.
enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, speech, getMac, findMac, pair, test

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
}

/// Setup Assistant (Nov 1 2026): each step is a page on the system background — a big symbol, a
/// large title, a short body, Continue pinned at the foot — sliding in from the trailing edge.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    @AppStorage("onboarding.step") private var stepRaw = 0
    @State private var looking = false
    @State private var denied: String?
    /// Looked for a while and found nothing: say what else to check.
    @State private var lookingLong = false
    /// iPhone SE-class heights: a smaller hero and title so every step's buttons are on screen.
    @State private var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var step: OnboardingStep { OnboardingStep(rawValue: stepRaw) ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
                .id(step)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                                  removal: .move(edge: .leading).combined(with: .opacity)))
                .frame(maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        // Siri's signal while the last step listens: the screen's edge in Apple Intelligence's colours.
        .overlay { if step == .test { ListeningEdge(active: recorder.phase == .recording, meter: recorder.meter) } }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { compact = $0 < 680 }
        .onAppear(perform: skipFinishedSteps)
        .onChange(of: stepRaw) { _, _ in skipFinishedSteps() }
        // Back from Settings with the permission turned on: carry on from here.
        .onChange(of: scenePhase) { _, phase in if phase == .active { skipFinishedSteps() } }
        .onChange(of: model.discoveredMacs.count) { _, n in
            if step == .findMac, looking, n > 0 {
                Task { try? await Task.sleep(nanoseconds: 1_200_000_000); if step == .findMac { advance() } }
            }
        }
        .onChange(of: model.pairing) { _, p in
            // A pairing link opened from the Camera app lands here too.
            if case .connecting = p, step != .pair { go(.pair) }
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Ink.ink.opacity(0.85) : Ink.ink.opacity(0.16))
                        .frame(width: s == step ? 18 : 6, height: 6)
                }
            }
            .frame(minHeight: 44)
            .accessibilityRepresentation {
                Rectangle().fill(.clear).frame(width: 90, height: 44)
                    .accessibilityElement()
                    .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
            }
            Spacer()
            Button {
                if step == .test { finish() } else { advance() }
            } label: {
                // The 44pt frame inside the label, so the whole of it takes the tap.
                Text(step == .test ? "Finish" : "Skip")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .font(.body)
            .tint(Light.cyan)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: step)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .microphone: microphone
        case .speech: speech
        case .getMac: getMac
        case .findMac: findMac
        case .pair: PairingPanel(onDone: { advance() }, compact: compact, doneTitle: "Continue")
        case .test: OnboardingTest(recorder: recorder, compact: compact, onFinish: finish)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        SetupPage(title: "Your Mac does the work. You steer from here.",
                  message: "See the window where Claude Code or any app is working on your Mac, tap to click, and say your next prompt. Your iPhone turns your voice into text right here and sends it in.",
                  compact: compact) {
            DemoVignette().scaleEffect(compact ? 0.82 : 1).frame(height: compact ? 172 : 210)
        } buttons: {
            SetupButton("Get Started") { advance() }
        }
    }

    private var microphone: some View {
        SetupPage(title: "It listens only while you ask it to.",
                  message: "Macrophone uses the microphone while you tap or hold the button — never in the background. The sound is turned into text and thrown away. No audio is ever kept.",
                  compact: compact) {
            SetupSymbol(name: "mic.fill", style: Light.ember, compact: compact)
        } content: {
            if Recorder.micStatus == .denied {
                note("The microphone is off for Macrophone. Turn it on in Settings, then come back — or skip for now.")
            }
        } buttons: {
            if Recorder.micStatus == .denied {
                openSettingsButton
            } else {
                SetupButton("Continue") {
                    Task {
                        _ = await Recorder.requestMic()
                        if Recorder.micStatus == .granted { advance() } else { denied = "mic" }
                    }
                }
            }
        }
    }

    private var speech: some View {
        let off = Recorder.speechStatus == .denied || Recorder.speechStatus == .restricted
        return SetupPage(title: "Your words are transcribed on this iPhone.",
                         message: "iOS will ask to allow speech recognition. Macrophone only uses languages your iPhone can transcribe by itself, so what you say isn't sent to Apple or anyone else.",
                         compact: compact) {
            SetupSymbol(name: "waveform", style: LinearGradient(colors: MacOSLook.intelligence, startPoint: .leading, endPoint: .trailing),
                        compact: compact)
        } content: {
            if off {
                note(Recorder.speechStatus == .restricted
                     ? "Speech recognition is turned off on this iPhone (Screen Time or a profile). You can skip for now."
                     : "Speech recognition is off for Macrophone. Turn it on in Settings, then come back — or skip for now.")
            }
        } buttons: {
            if off {
                if Recorder.speechStatus == .denied { openSettingsButton }
            } else {
                SetupButton("Continue") {
                    Task {
                        _ = await Recorder.requestSpeech()
                        if Recorder.speechStatus == .authorized { advance() } else { denied = "speech" }
                    }
                }
            }
        }
    }

    private var getMac: some View {
        SetupPage(title: "Get Macrophone for your Mac.", message: "It's free. On your Mac, go to:", compact: compact) {
            SetupSymbol(name: "laptopcomputer.and.arrow.down", style: Light.cyan, compact: compact)
        } content: {
            Text(Product.macDownloadDisplay)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Light.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .textSelection(.enabled)
                .padding(.vertical, 16)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
                .accessibilityLabel("sameer dot u s slash macrophone")
        } buttons: {
            SetupButton("I Have It") { advance() }
            ShareLink(item: Product.website,
                      subject: Text("Macrophone for Mac"),
                      message: Text("Get Macrophone for your Mac: \(Product.website.absoluteString)")) {
                Text("Send the Link to Yourself")
            }
            .setupSecondary()
        }
    }

    @ViewBuilder private var findMac: some View {
        if !looking {
            SetupPage(title: "Next, iOS asks to find devices on your network.",
                      message: "That's how your iPhone finds your Mac. They talk to each other directly — nothing goes to the internet.",
                      compact: compact) {
                SetupSymbol(name: "wifi", style: Light.cyan, compact: compact)
            } buttons: {
                // "Continue", never words that press for the permission (App Review 5.1.1(iv), Oct 2026).
                SetupButton("Continue") {
                    looking = true
                    model.startLink()
                    Task {
                        try? await Task.sleep(nanoseconds: 12_000_000_000)
                        if model.discoveredMacs.isEmpty { withAnimation { lookingLong = true } }
                    }
                    if !model.discoveredMacs.isEmpty {
                        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); advance() }
                    }
                }
            }
        } else {
            let found = !model.discoveredMacs.isEmpty
            let stuck = !found && (model.localNetworkDenied || lookingLong)
            SetupPage(title: model.discoveredMacs.first.map { "Found \($0.name)." } ?? "Looking for your Mac…",
                      message: found
                        ? "Next, pair them so only your iPhone can send to it."
                        : "Open Macrophone on your Mac. Keep both on the same Wi-Fi, or close together with Wi-Fi turned on.",
                      compact: compact) {
                Searching(found: found, compact: compact)
            } content: {
                if !found, model.localNetworkDenied {
                    note("Local Network is off for Macrophone, so it can't see your Mac. Turn it on in Settings › Privacy & Security › Local Network.")
                } else if !found, lookingLong {
                    note("Still nothing? Check that Local Network is on for Macrophone in Settings.")
                }
            } buttons: {
                if found {
                    SetupButton("Continue") { advance() }
                } else {
                    if stuck { openSettingsButton }
                    Button("Continue") { advance() }.setupSecondary()
                }
            }
        }
    }

    // MARK: Building blocks

    private var openSettingsButton: some View {
        SetupButton("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.footnote).foregroundStyle(Light.ochre).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Flow

    private func advance() {
        denied = nil
        if let n = step.next { go(n) } else { finish() }
    }

    private func go(_ s: OnboardingStep) {
        withAnimation(Motion.pick(Motion.settle, reduce: reduceMotion)) { stepRaw = s.rawValue }
    }

    /// Steps that are already done (a permission granted, a Mac already paired) pass by themselves.
    private func skipFinishedSteps() {
        switch step {
        case .microphone where Recorder.micStatus == .granted: advance()
        case .speech where Recorder.speechStatus == .authorized: advance()
        case .findMac where model.isPaired, .pair where model.isPaired:
            if case .paired = model.pairing { return }   // let the success show
            go(.test)
        default: break
        }
    }

    private func finish() {
        model.onboardingDone = true
        model.networkExplained = true
        withAnimation(Motion.pick(Motion.depart, reduce: reduceMotion)) { model.showOnboarding = false }
        model.startLink()
    }
}

/// Rings rippling out from a Mac while the phone browses (AirDrop's, in the accent).
private struct Searching: View {
    var found: Bool
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || found)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3) { i in
                    let p = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .strokeBorder((found ? Light.mint : Light.cyan).opacity((1 - p) * 0.45), lineWidth: 1.5)
                        .frame(width: 96 + 124 * p, height: 96 + 124 * p)
                        .opacity(reduceMotion || found ? (i == 0 ? 0.6 : 0) : 1)
                }
                if found {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64, weight: .regular))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Light.mint)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 52, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Light.cyan)
                }
            }
            .frame(height: 220)
        }
        .scaleEffect(compact ? 0.75 : 1)
        .frame(height: compact ? 165 : 220)
        .accessibilityHidden(true)
    }
}

/// The last step: one real dictation through the whole path.
private struct OnboardingTest: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    var compact = false
    var onFinish: () -> Void
    @State private var holding = false
    @State private var startedByPress = false
    @State private var stopOnRelease = false

    private var recording: Bool { recorder.phase == .recording || recorder.phase == .starting }
    private var worked: Bool {
        switch model.status {
        case .delivered, .duplicate, .copiedOnPhone, .unconfirmed: return true
        case .landed(let l): return l.isSuccess || l.copiedInstead
        default: return false
        }
    }

    var body: some View {
        SetupPage(title: worked ? "It works." : (model.isPaired ? "Say something to your Mac." : "Try it here first."),
                  message: worked
                    ? (model.isPaired ? "Look at your Mac — your words are there." : "Your words are on this iPhone's clipboard, ready to paste. Pair your Mac any time from the top of the main screen.")
                    : "Tap the button, say “Hello from my iPhone,” then tap again.",
                  compact: compact) {
            EmptyView()
        } content: {
            VStack(spacing: compact ? 12 : 18) {
                // The live words in a set slot; what landed grows the slot rather than being cut
                // off at a large text size (the page scrolls).
                let slot: CGFloat = compact ? 88 : 110
                if recording || model.processing || recorder.phase == .finishing {
                    LiveWords(words: recorder.words, listening: recording)
                        .frame(height: slot)
                } else if let item = model.latest, worked {
                    Text(item.dictation.text)
                        .font(.title3)
                        .foregroundStyle(Ink.ink)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: slot, alignment: .bottom)
                } else {
                    Color.clear.frame(height: slot)
                }
                let mode: FilamentMode = recording ? .live : (worked ? .delivered : (model.processing ? .sending : .ready))
                Filament(mode: mode, meter: recorder.meter, height: compact ? 80 : 100)
                MicButton(recording: recording, finishing: recorder.phase == .finishing, mode: mode, meter: recorder.meter,
                          onDown: {
                              if recording { stopOnRelease = true; startedByPress = false }
                              else { startedByPress = true; holding = true; Task { await model.startRecording() } }
                          },
                          onUp: { held in
                              holding = false
                              if stopOnRelease { stopOnRelease = false; model.stopRecording() }
                              else if startedByPress { startedByPress = false; if held >= MicButton.holdThreshold { model.stopRecording() } }
                          },
                          onAccessibilityToggle: { model.toggleRecording() })
                StatusLine(recorder: recorder, holding: holding).frame(minHeight: 44, alignment: .top)
            }
        } buttons: {
            if worked {
                SetupButton("Start Using Macrophone", action: onFinish)
                    .transition(.opacity)
            }
        }
        .onAppear { model.status = .ready }
        .animation(.easeInOut(duration: 0.3), value: worked)
    }
}
