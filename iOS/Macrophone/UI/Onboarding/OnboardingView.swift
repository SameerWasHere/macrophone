import MacrophoneKit
import SwiftUI

/// Phone-first setup. Every step can be skipped, and the app comes back to the same step.
/// Five steps since Nov 7 2026 (the setup review: "simple and clean and not confusing"): the
/// microphone and speech recognition are one page (one Continue, iOS's two questions in a row),
/// and getting the Mac app carries the Local Network explanation, so the scanner comes straight
/// after it (the pre-ask page and the "Looking for your Mac…" page said what pairing says again).
/// The raw values are what was stored before: a stored 2 (speech) is the voice page, a stored 4
/// (finding the Mac) is pairing.
enum OnboardingStep: Int, CaseIterable {
    case welcome = 0, voice = 1, getMac = 3, pair = 5, test = 6

    init(stored: Int) {
        switch stored {
        case 2: self = .voice
        case 4: self = .pair
        default: self = OnboardingStep(rawValue: stored) ?? .welcome
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var next: OnboardingStep? { index + 1 < Self.allCases.count ? Self.allCases[index + 1] : nil }
}

/// Setup Assistant (Nov 1 2026): each step is a page on the system background — a big symbol, a
/// large title, a short body, Continue pinned at the foot — sliding in from the trailing edge.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    @AppStorage("onboarding.step") private var stepRaw = 0
    /// The step on screen, a plain state beside the stored one (Nov 4 2026): a change to an
    /// `@AppStorage` value reaches the view through UserDefaults, outside `withAnimation`, so a
    /// tapped Continue or Skip cut to the next page instead of sliding it in.
    @State private var shownRaw: Int?
    @State private var denied: String?
    /// iPhone SE-class heights: a smaller hero and title so every step's buttons are on screen.
    @State private var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var step: OnboardingStep { OnboardingStep(stored: shownRaw ?? stepRaw) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            // The page is one view (a ZStack round the step's switch), so the slide moves it
            // whole: on the bare switch the slide reached down to the step's own views, and a
            // step with transitions inside (pairing's phases, finding the Mac) faded in place.
            ZStack { content }
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
        .onChange(of: step) { _, _ in skipFinishedSteps() }
        // Back from Settings with the permission turned on: carry on from here.
        .onChange(of: scenePhase) { _, phase in if phase == .active { skipFinishedSteps() } }
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
                        .fill(s.index <= step.index ? Ink.ink.opacity(0.85) : Ink.ink.opacity(0.16))
                        .frame(width: s == step ? 18 : 6, height: 6)
                }
            }
            .frame(minHeight: 44)
            .accessibilityRepresentation {
                Rectangle().fill(.clear).frame(width: 90, height: 44)
                    .accessibilityElement()
                    .accessibilityLabel("Step \(step.index + 1) of \(OnboardingStep.allCases.count)")
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
        case .voice: voice
        case .getMac: getMac
        case .pair: PairingPanel(onDone: { advance() }, compact: compact, doneTitle: "Continue")
        case .test: OnboardingTest(recorder: recorder, compact: compact, onFinish: finish)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        SetupPage(title: "Steer your Mac from here",
                  message: "Watch Claude Code or any app working on your Mac, tap to click, and say your next prompt.",
                  compact: compact) {
            DemoVignette().scaleEffect(compact ? 0.82 : 1).frame(height: compact ? 172 : 210)
        } buttons: {
            SetupButton("Get Started") { advance() }
        }
    }

    /// The microphone and speech recognition on one page: one Continue, and iOS asks its two
    /// questions back to back. What's still off says so here, with the one button that fixes it.
    private var voice: some View {
        let micOff = Recorder.micStatus == .denied
        let speechOff = Recorder.speechStatus == .denied || Recorder.speechStatus == .restricted
        return SetupPage(title: "It listens only while you ask it to",
                         message: "Macrophone hears you only while you tap or hold the button, and turns your voice into text on this iPhone. No audio is kept. iOS asks to allow the microphone and speech recognition.",
                         compact: compact) {
            SetupSymbol(name: "mic.fill", style: Light.ember, compact: compact)
        } content: {
            if micOff {
                note("The microphone is off for Macrophone. Turn it on in Settings, then come back — or skip for now.")
            } else if speechOff {
                note(Recorder.speechStatus == .restricted
                     ? "Speech recognition is turned off on this iPhone (Screen Time or a profile). You can skip for now."
                     : "Speech recognition is off for Macrophone. Turn it on in Settings, then come back — or skip for now.")
            }
        } buttons: {
            if micOff || Recorder.speechStatus == .denied {
                openSettingsButton
            } else if !speechOff {
                SetupButton("Continue") {
                    Task {
                        if Recorder.micStatus != .granted { _ = await Recorder.requestMic() }
                        guard Recorder.micStatus == .granted else { denied = "mic"; return }
                        if Recorder.speechStatus != .authorized { _ = await Recorder.requestSpeech() }
                        if Recorder.speechStatus == .authorized { advance() } else { denied = "speech" }
                    }
                }
            }
        }
    }

    /// Where to get the Mac app, and — since Continue is what makes iOS ask — why iOS is about
    /// to ask about the local network ("Continue", never words that press for the permission:
    /// App Review 5.1.1(iv), Oct 2026).
    private var getMac: some View {
        SetupPage(title: "Get Macrophone for your Mac", message: "It's free. On your Mac, go to:", compact: compact) {
            SetupSymbol(name: "laptopcomputer.and.arrow.down", style: Light.cyan, compact: compact)
        } content: {
            VStack(spacing: compact ? 14 : 20) {
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
                Label {
                    Text("Next, iOS asks to find devices on your network — that's how your iPhone finds your Mac. Nothing goes to the internet.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "wifi").foregroundStyle(Light.cyan)
                }
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } buttons: {
            SetupButton("Continue") {
                model.networkExplained = true
                model.startLink()
                advance()
            }
            ShareLink(item: Product.website,
                      subject: Text("Macrophone for Mac"),
                      message: Text("Get Macrophone for your Mac: \(Product.website.absoluteString)")) {
                Text("Send the Link to Yourself")
            }
            .setupSecondary()
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
        // Past any step that's already done in the same slide (Nov 4 2026): with the microphone
        // already allowed, Get Started slid to its page and the page skipping itself cut the
        // slide off — the speech page arrived in one frame.
        var n = step.next
        while let s = n, isDone(s) { n = s.next }
        if let n { go(n) } else { finish() }
    }

    /// A step there's nothing left to do on (its permission given, its Mac paired).
    private func isDone(_ s: OnboardingStep) -> Bool {
        switch s {
        case .voice: return Recorder.micStatus == .granted && Recorder.speechStatus == .authorized
        // A Mac already in sight (the link running from before): the app is there.
        case .getMac: return model.networkExplained && !model.discoveredMacs.isEmpty
        case .pair:
            if case .paired = model.pairing { return false }   // let the success show
            return model.isPaired
        default: return false
        }
    }

    private func go(_ s: OnboardingStep) {
        withAnimation(Motion.pick(Motion.settle, reduce: reduceMotion)) { shownRaw = s.rawValue }
        stepRaw = s.rawValue
    }

    /// Steps that are already done (a permission granted, a Mac already paired) pass by themselves.
    private func skipFinishedSteps() {
        switch step {
        case .voice where isDone(.voice): advance()
        case .getMac where model.isPaired, .pair where model.isPaired:
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
        // Paired in setup: once, "Use it away from home?" (Nov 7 2026).
        model.offerAwayIfDue(after: 1.0)
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
        SetupPage(title: worked ? "It works" : (model.isPaired ? "Say something to your Mac" : "Try it here first"),
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
