import MacrophoneKit
import SwiftUI

/// Phone-first setup. Every step can be skipped, and the app comes back to the same step.
enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, speech, getMac, findMac, pair, test

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    @AppStorage("onboarding.step") private var stepRaw = 0
    @State private var looking = false
    @State private var denied: String?
    /// Looked for a while and found nothing: say what else to check.
    @State private var lookingLong = false
    /// iPhone SE-class heights: smaller pictures so every step's buttons are on screen.
    @State private var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var step: OnboardingStep { OnboardingStep(rawValue: stepRaw) ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        content
                            .id(step)
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                                              removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(minHeight: geo.size.height * 0.92, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onAppear { compact = geo.size.height < 620 }
                .onChange(of: geo.size.height) { _, h in compact = h < 620 }
            }
        }
        .background(GroundBackground(glow: step == .test && recorder.isActive ? Light.ember : Light.cyan))
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
                        .fill(s.rawValue <= step.rawValue ? Ink.ink.opacity(0.8) : Ink.ink.opacity(0.18))
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
            .font(.body.weight(.medium))
            .foregroundStyle(Ink.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: step)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .microphone: microphone
        case .speech: speech
        case .getMac: getMac
        case .findMac: findMac
        case .pair: pair
        case .test: OnboardingTest(recorder: recorder, onFinish: finish)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        page(hero: AnyView(DemoVignette().scaleEffect(compact ? 0.82 : 1).frame(height: compact ? 172 : 210).padding(.top, compact ? 4 : 20)),
             kicker: "Macrophone",
             title: "Your Mac does the work. You steer from here.",
             body: "See the window where Claude Code or any app is working on your Mac, tap to click, and say your next prompt. Your iPhone turns your voice into text right here and sends it in.") {
            Button("Get Started") { advance() }.pillStyle(.primary, tint: Ink.ink)
        }
    }

    private var microphone: some View {
        page(hero: AnyView(symbolHero("mic.fill", Light.ember)),
             kicker: "Step 1 · Microphone",
             title: "It listens only while you ask it to.",
             body: "Macrophone uses the microphone while you tap or hold the button — never in the background. The sound is turned into text and thrown away. No audio is ever kept.") {
            if Recorder.micStatus == .denied {
                note("The microphone is off for Macrophone. Turn it on in Settings, then come back — or skip for now.")
                openSettingsButton
            } else {
                Button("Allow Microphone") {
                    Task {
                        _ = await Recorder.requestMic()
                        if Recorder.micStatus == .granted { advance() } else { denied = "mic" }
                    }
                }
                .pillStyle(.primary, tint: Ink.ink)
            }
        }
    }

    private var speech: some View {
        page(hero: AnyView(symbolHero("waveform", Light.teal)),
             kicker: "Step 2 · Speech recognition",
             title: "Your words are transcribed on this iPhone.",
             body: "iOS will ask to allow speech recognition. Macrophone only uses languages your iPhone can transcribe by itself, so what you say isn't sent to Apple or anyone else.") {
            if Recorder.speechStatus == .denied || Recorder.speechStatus == .restricted {
                note(Recorder.speechStatus == .restricted
                     ? "Speech recognition is turned off on this iPhone (Screen Time or a profile). You can skip for now."
                     : "Speech recognition is off for Macrophone. Turn it on in Settings, then come back — or skip for now.")
                if Recorder.speechStatus == .denied { openSettingsButton }
            } else {
                Button("Allow Speech Recognition") {
                    Task {
                        _ = await Recorder.requestSpeech()
                        if Recorder.speechStatus == .authorized { advance() } else { denied = "speech" }
                    }
                }
                .pillStyle(.primary, tint: Ink.ink)
            }
        }
    }

    private var getMac: some View {
        page(hero: AnyView(symbolHero("laptopcomputer.and.iphone", Light.cyan)),
             kicker: "Step 3 · The Mac app",
             title: "Get Macrophone for your Mac.",
             body: "It's free. On your Mac, go to:") {
            VStack(spacing: 18) {
                Text(Product.macDownloadDisplay)
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Light.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .glass(Radius.medium)
                    .accessibilityLabel("sameer dot u s slash macrophone")
                ShareLink(item: Product.website,
                          subject: Text("Macrophone for Mac"),
                          message: Text("Get Macrophone for your Mac: \(Product.website.absoluteString)")) {
                    Label("Send the Link to Yourself", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .pillStyle(.secondary, tint: Ink.ink)
                Button("I Have It") { advance() }.pillStyle(.primary, tint: Ink.ink)
            }
        }
    }

    @ViewBuilder private var findMac: some View {
        if !looking {
            page(hero: AnyView(symbolHero("wifi", Light.cyan)),
                 kicker: "Step 4 · Find your Mac",
                 title: "Next, iOS asks to find devices on your network.",
                 body: "That's how your iPhone finds your Mac. They talk to each other directly — nothing goes to the internet. Tap Allow when iOS asks.") {
                Button("Look for My Mac") {
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
                .pillStyle(.primary, tint: Ink.ink)
            }
        } else {
            page(hero: AnyView(Searching(found: !model.discoveredMacs.isEmpty)),
                 kicker: "Step 4 · Find your Mac",
                 title: model.discoveredMacs.first.map { "Found \($0.name)." } ?? "Looking for your Mac…",
                 body: model.discoveredMacs.isEmpty
                    ? "Open Macrophone on your Mac. Keep both on the same Wi-Fi, or close together with Wi-Fi turned on."
                    : "Next, pair them so only your iPhone can send to it.") {
                if model.discoveredMacs.isEmpty, model.localNetworkDenied {
                    note("Local Network is off for Macrophone, so it can't see your Mac. Turn it on in Settings › Privacy & Security › Local Network.")
                    openSettingsButton
                } else if model.discoveredMacs.isEmpty, lookingLong {
                    note("Still nothing? Check that Local Network is on for Macrophone in Settings.")
                    openSettingsButton
                }
                Button("Continue") { advance() }
                    .pillStyle(model.discoveredMacs.isEmpty ? .secondary : .primary, tint: Ink.ink)
            }
        }
    }

    private var pair: some View {
        VStack(spacing: 18) {
            // The heading is for scanning; once pairing is under way the panel speaks for itself.
            if model.pairing == .idle {
                VStack(spacing: 8) {
                    Kicker("Step 5 · Pair")
                    Text("Scan the code on your Mac.")
                        .font(.serif(.title)).foregroundStyle(Ink.ink).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("In Macrophone on your Mac, choose Pair iPhone. The camera is used only for this.")
                        .font(.subheadline).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 16)
                .transition(.opacity)
            }
            PairingPanel(onDone: { advance() }, compact: true, doneTitle: "Continue")
                .padding(.top, model.pairing == .idle ? 0 : 24)
        }
    }

    // MARK: Building blocks

    private func page<Actions: View>(hero: AnyView, kicker: String, title: String, body: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 22) {
            hero.frame(minHeight: compact ? 150 : 200)
            VStack(spacing: 12) {
                Kicker(kicker)
                Text(title)
                    .font(.serif(.title, weight: .regular))
                    .foregroundStyle(Ink.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(body)
                    .font(.body)
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 12) { actions() }.padding(.top, 8)
        }
        .padding(.top, 12)
    }

    private var openSettingsButton: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        .pillStyle(.primary, tint: Ink.ink)
    }

    private func symbolHero(_ name: String, _ color: Color) -> some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [color.opacity(0.28), .clear], center: .center, startRadius: 4, endRadius: 110))
                .frame(width: 220, height: 220)
            Circle().fill(Ink.raised).frame(width: 104, height: 104)
                .overlay(Circle().strokeBorder(Ink.lineStrong))
            Image(systemName: name).font(.system(size: 40, weight: .medium)).foregroundStyle(color)
        }
        .scaleEffect(compact ? 0.72 : 1)
        .frame(height: compact ? 160 : 220)
        .accessibilityHidden(true)
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

/// Rings rippling out from a Mac while the phone browses.
private struct Searching: View {
    var found: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || found)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3) { i in
                    let p = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .strokeBorder((found ? Light.mint : Light.cyan).opacity((1 - p) * 0.5), lineWidth: 1.5)
                        .frame(width: 90 + 150 * p, height: 90 + 150 * p)
                        .opacity(reduceMotion || found ? (i == 0 ? 0.6 : 0) : 1)
                }
                Circle().fill(Ink.raised).frame(width: 96, height: 96).overlay(Circle().strokeBorder(Ink.lineStrong))
                Image(systemName: found ? "checkmark" : "laptopcomputer")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(found ? Light.mint : Light.cyan)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(height: 230)
        }
        .accessibilityHidden(true)
    }
}

/// The last step: one real dictation through the whole path.
private struct OnboardingTest: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
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
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Kicker("Step 6 · Try it")
                Text(worked ? "It works." : (model.isPaired ? "Say something to your Mac." : "Try it here first."))
                    .font(.serif(.title)).foregroundStyle(Ink.ink).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(worked
                     ? (model.isPaired ? "Look at your Mac — your words are there." : "Your words are on this iPhone's clipboard, ready to paste. Pair your Mac any time from the top of the main screen.")
                     : "Tap the button, say “Hello from my iPhone,” then tap again.")
                    .font(.body).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 16)
            ZStack(alignment: .bottom) {
                if recording || model.processing || recorder.phase == .finishing {
                    LiveWords(words: recorder.words, listening: recording)
                } else if let item = model.latest, worked {
                    Text(item.dictation.text)
                        .font(.serif(.title3))
                        .foregroundStyle(Ink.ink)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(height: 110)
            let mode: FilamentMode = recording ? .live : (worked ? .delivered : (model.processing ? .sending : .ready))
            Filament(mode: mode, meter: recorder.meter, height: 100)
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
            if worked {
                Button("Start Using Macrophone", action: onFinish)
                    .pillStyle(.primary, tint: Ink.ink)
                    .transition(.opacity)
            }
        }
        .onAppear { model.status = .ready }
        .animation(.easeInOut(duration: 0.3), value: worked)
    }
}
