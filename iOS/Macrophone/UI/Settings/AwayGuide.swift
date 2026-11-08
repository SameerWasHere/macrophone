import MacrophoneKit
import SwiftUI

/// Away from home, as a checklist that checks itself (Nov 7 2026; the five numbered steps of Nov 4
/// were words to follow with nothing to say whether they'd worked). Four steps, each with one
/// button and a green check once it's done — read again whenever the app comes back to the front
/// (from Tailscale, from the App Store) and every couple of seconds while it's open — and Test it,
/// which dials the Mac over Tailscale right now, even at home, and says exactly what's wrong.
/// The same steps as the Mac's own guide; without Tailscale is a small disclosure at the foot.
struct AwayGuideView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var phoneOn = TailscaleHere.isOn
    @State private var appAnswers = false
    @State private var testing = false
    @State private var result: AwayProbeResult?
    @State private var showManual = false
    @State private var address = ""
    @State private var addressProblem = false
    @FocusState private var addressFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var mac: MacAwayReadiness { model.macAway }
    private var macName: String { model.pairedMac?.name ?? "your Mac" }
    private var hasApp: Bool { appAnswers || phoneOn }
    private var works: Bool { result == .works }

    var body: some View {
        Form {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                macStep
                appStep
                signInStep
                testStep
            } footer: {
                Text("Tailscale is free and private: your iPhone and Mac talk to each other directly, and nothing goes through a server of ours.")
            }
            manualSection
        }
        .navigationTitle("Away from Home")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh(); address = model.typedAddress?.display ?? "" }
        .onReceive(tick) { _ in refresh() }
        .onChange(of: scenePhase) { _, p in if p == .active { refresh() } }
        // A test from before says nothing once either end has changed.
        .onChange(of: phoneOn) { _, _ in result = nil }
        .onChange(of: mac) { _, _ in result = nil }
        .onChange(of: addressFocused) { _, focused in if !focused { commitAddress() } }
        .animation(.easeInOut(duration: 0.25), value: phoneOn)
        .animation(.easeInOut(duration: 0.25), value: mac)
        .animation(.easeInOut(duration: 0.25), value: result)
        .animation(.easeInOut(duration: 0.25), value: testing)
    }

    private func refresh() {
        let on = TailscaleHere.isOn
        if on != phoneOn { phoneOn = on }
        let answers = TailscaleHere.appAnswers
        if answers != appAnswers { appAnswers = answers }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(works || (mac == .ready && phoneOn) ? Light.mint : Light.cyan).frame(width: 64, height: 64)
                Image(systemName: works || (mac == .ready && phoneOn) ? "checkmark" : "network.badge.shield.half.filled")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Ink.onTint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityHidden(true)
            Text("Use it anywhere")
                .font(.title2.bold())
                .foregroundStyle(Ink.ink)
            Text(works ? "Your iPhone reaches \(macName) over Tailscale. It works away from home."
                       : "With Tailscale on both, your iPhone reaches \(macName) from anywhere — not only on your Wi-Fi.")
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: The steps

    private var macStep: some View {
        let detail: String
        switch mac {
        case .ready:
            detail = model.macTailscaleAddress.map { "Tailscale and Away from home are on. Its address: \($0)" } ?? "Tailscale and Away from home are on."
        case .noTailscale:
            detail = "Away from home is on, but your Mac isn't on Tailscale yet. Install Tailscale on your Mac and sign in."
        case .off:
            detail = model.isConnected
                ? "In Macrophone on your Mac, turn on Away from home (Devices › Away from home)."
                : "In Macrophone on your Mac, turn on Away from home. Then open Macrophone here at home once, so your Mac can share its address."
        }
        return AwayStepRow(number: 1, title: "Your Mac", detail: detail, done: mac == .ready, id: "away-step-mac") {
            if mac == .noTailscale {
                ShareLink(item: TailscaleHere.macDownload, subject: Text("Tailscale for Mac"),
                          message: Text("Get Tailscale for your Mac: \(TailscaleHere.macDownload.absoluteString)")) {
                    Text("Send Tailscale to Your Mac")
                }
                .awayStepButton()
                .accessibilityIdentifier("away-send-tailscale")
            }
        }
    }

    private var appStep: some View {
        AwayStepRow(number: 2, title: "Get Tailscale on this iPhone",
                    detail: hasApp ? "Tailscale is on this iPhone." : "It's free on the App Store.",
                    done: hasApp, id: "away-step-app") {
            if !hasApp {
                Link(destination: TailscaleHere.appStore) { Text("Get Tailscale") }
                    .awayStepButton()
                    .accessibilityIdentifier("away-get-tailscale")
            }
        }
    }

    private var signInStep: some View {
        AwayStepRow(number: 3, title: "Sign in and turn it on",
                    detail: phoneOn ? "This iPhone is on Tailscale."
                                    : "Use the same account as on your Mac, then turn Tailscale on. Allow the VPN when iOS asks.",
                    done: phoneOn, id: "away-step-signin") {
            if !phoneOn {
                Button("Open Tailscale") { TailscaleHere.open() }
                    .awayStepButton()
                    .accessibilityIdentifier("away-open-tailscale")
            }
        }
    }

    private var testStep: some View {
        AwayStepRow(number: 4, title: "Test it", detail: testWords, done: works, failed: result.map { $0 != .works } ?? false,
                    id: "away-step-test") {
            HStack(spacing: 10) {
                Button(result == nil ? "Test Connection" : "Test Again") { runTest() }
                    .awayStepButton()
                    .disabled(testing || !model.isPaired)
                    .accessibilityIdentifier("away-test")
                if testing { ProgressView().controlSize(.small) }
            }
        }
    }

    /// What Test it found, in one sentence: what works, or exactly what's in the way.
    private var testWords: String {
        if testing { return "Reaching \(macName) over Tailscale…" }
        guard let result else { return "Checks that this iPhone reaches your Mac over Tailscale — it works from here at home too." }
        switch result {
        case .works: return "Works away from home."
        case .notPaired: return "Pair a Mac first."
        case .noAddress: return "Your Mac hasn't shared a Tailscale address yet — finish step 1."
        case .remoteOff: return "Your Mac is on Tailscale, but Away from home is off in Macrophone on your Mac."
        case .unreachable:
            return phoneOn ? "Your Mac didn't answer over Tailscale. Check it's awake, with Tailscale on and signed in to the same account."
                           : "Tailscale is off on this iPhone. Turn it on in the Tailscale app, then test again."
        case .notThisMac: return "Something else answered at your Mac's Tailscale address. Open Macrophone here at home once so your Mac shares its new address."
        }
    }

    private func runTest() {
        Haptics.press()
        testing = true
        result = nil
        Task {
            let r = await model.testAway()
            testing = false
            result = r
            if r == .works { Haptics.landed() } else { Haptics.caution() }
        }
    }

    // MARK: Without Tailscale

    private var manualSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showManual) {
                Text("Forward port \(String(RemoteAddressRule.defaultPort)) on your router to your Mac (the port is in Macrophone on your Mac, under Away from home), then type your home's address here.")
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let field = TextField("name or address:port", text: $address)
                    .foregroundStyle(Ink.secondary)
                    .focused($addressFocused)
                    .submitLabel(.done)
                    .onSubmit(commitAddress)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Your home's address")
                    .accessibilityIdentifier("away-address")
                let label = Text("Address")
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) { label; field }
                } else {
                    HStack { label; Spacer(); field.multilineTextAlignment(.trailing) }
                }
                if addressProblem {
                    Text("That doesn't look like an address. Try something like home.example.com:47821.")
                        .font(.footnote).foregroundStyle(Light.ochre)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } label: {
                Text("Without Tailscale")
            }
            .accessibilityIdentifier("away-without-tailscale")
        }
    }

    private func commitAddress() {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == (model.typedAddress?.display ?? "") || t == (model.typedAddress?.host ?? "") { addressProblem = false; return }
        addressProblem = !model.setTypedAddress(t)
        if !addressProblem { address = model.typedAddress?.display ?? "" }
    }
}

/// One step: its number (a green check once done, an orange mark after a failed test), the
/// title, one sentence and at most one button under it.
private struct AwayStepRow<Action: View>: View {
    var number: Int
    var title: String
    var detail: String
    var done: Bool
    var failed = false
    var id: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : failed ? "exclamationmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .symbolRenderingMode(done || failed ? .palette : .monochrome)
                .foregroundStyle(done || failed ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.tertiary),
                                 done ? AnyShapeStyle(Light.mint) : AnyShapeStyle(Light.ember))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Ink.ink)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(failed ? Light.ember : Ink.secondary)
                    .textSelection(.enabled)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("\(id)-detail")
                action.padding(.top, 4)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title)")
        .accessibilityValue(done ? "Done" : "To do")
        .accessibilityIdentifier(id)
    }
}

private extension View {
    /// A step's one button: a small bordered capsule in the accent, as Settings' own inline actions.
    func awayStepButton() -> some View {
        font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(Light.cyan)
    }
}

/// Once, after the first Mac is paired (Nov 7 2026): use it away from home? Set Up opens the
/// guide; Not Now closes it. Either way it's never asked again (`AppModel.awayOffered`).
struct AwayOfferSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        SetupPage(title: "Use it away from home",
                  message: "Set up Tailscale once — it's free — and your iPhone reaches \(model.pairedMac?.name ?? "your Mac") from anywhere, not only on your Wi-Fi.",
                  compact: true) {
            SetupSymbol(name: "network.badge.shield.half.filled", style: Light.cyan, compact: true)
        } buttons: {
            SetupButton("Set Up") {
                model.awayOffered = true
                model.openAwayGuide()
            }
            .accessibilityIdentifier("away-offer-setup")
            Button("Not Now") {
                model.awayOffered = true
                model.sheet = nil
            }
            .setupSecondary()
            .accessibilityIdentifier("away-offer-later")
        }
        // Half the screen, as Apple's one-time offers; taller at the large text sizes (it scrolls).
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .interactiveDismissDisabled(false)
        .onDisappear { model.awayOffered = true }
    }
}
