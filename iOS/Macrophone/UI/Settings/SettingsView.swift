import MacrophoneKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    /// The Mac an Unpair tap is asking about.
    @State private var unpairing: PairedPeer?
    @State private var confirmClear = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var address = ""
    @State private var addressProblem = false
    @FocusState private var addressFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    var initialPath: [SettingsRoute] = []
    @State private var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                if model.isPaired { sendToSection }
                cleanupSection
                recordingSection
                macSection
                if model.isPaired { awaySection }
                historySection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Ink.ground.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { commitName(); dismiss() }.doneButtonStyle() }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .dictionary: DictionaryView(settings: settings)
                case .language: LanguageView(settings: settings)
                case .diagnostics: DiagnosticsView()
                case .pairing: PairingView(embedded: true)
                case .sendTo: SendToList(settings: settings).navigationTitle("Send to").navigationBarTitleDisplayMode(.inline)
                case .customCleanup: CustomCleanupView(settings: settings)
                }
            }
            .onAppear {
                name = settings.deviceName
                address = model.typedAddress?.display ?? ""
                if path.isEmpty, !initialPath.isEmpty { path = initialPath }
                model.refreshAvailability()
            }
        }
        .tint(Light.cyan)
    }

    // MARK: Send to (the same choice as the quick controls by the mic)

    // Each switch explains itself in its own row (the three explanations used to run together
    // as one nine-line footer, Oct 18 2026); the footer keeps the one fact about all of them.
    private var sendToSection: some View {
        let target = settings.selection.target
        return Section {
            NavigationLink(value: SettingsRoute.sendTo) {
                LabeledContent {
                    Text(target.displayName)
                } label: {
                    HStack(spacing: 12) {
                        TargetIcon(target: target, icon: model.liveTarget(for: target)?.icon, size: 28)
                        Text("Send to")
                    }
                }
            }
            Toggle(isOn: Binding(get: { settings.selection.send }, set: { model.setSend($0) })) {
                row("Send after pasting", symbol: settings.selection.send ? "paperplane.fill" : "paperplane", tint: Light.cyan,
                    detail: target.canSend
                        ? "Your Mac presses the app's send key after pasting. If you're at the Mac, you get a moment to cancel first."
                        : "\(target.displayName) can't send — sending after pasting is for apps.")
            }
            .disabled(!target.canSend)
            Toggle(isOn: $settings.watchAfterSending) {
                row("Show the app after sending", symbol: "eye", tint: Light.teal,
                    detail: "Your iPhone shows that app's window live, so you can read the answer, tap to click, swipe to scroll, and press Esc, the arrows or Return. Only that window, and only while you look.")
            }
            Toggle(isOn: $settings.agentAlerts) {
                row("Tell me when an agent asks something", symbol: "bell.badge", tint: Light.ember,
                    detail: "When an agent on your Mac stops to ask something while Macrophone is open here, you get a notification; tap it to answer.")
            }
            .onChange(of: settings.agentAlerts) { _, on in
                Task { if on { await AgentAlerts.shared.askIfNeeded() } else { await AgentAlerts.shared.unsubscribeInCloud() } }
            }
        } header: {
            Kicker("Send to")
        } footer: {
            Text("The choice is the same on your Mac: change it in either place.")
        }
        .listRowBackground(Ink.raised)
    }

    /// A row's title led by its mark — a symbol on a tinted plate in the same 28pt column as
    /// the Send to icon, so every label in Settings starts at one x — and, under it, one line
    /// of what the row does.
    private func row(_ title: String, symbol: String, tint: Color, detail: String? = nil) -> some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: 12) {
            GlyphPlate(symbol: symbol, tint: tint)
                .padding(.top, detail == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(Ink.tertiary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, detail == nil ? 0 : 4)
    }

    // MARK: Cleanup

    private var cleanupDisabledReason: String? {
        if !settings.isEnglish { return "Cleanup and the dictionary fix work in English only for now. Other languages are sent exactly as heard." }
        if !model.cleanupAvailability.isAvailable { return model.cleanupAvailability.explanation + " Until then, dictations are sent exactly as heard." }
        return nil
    }

    private var levelSummary: String {
        guard settings.cleanupLevel == .custom else { return settings.cleanupLevel.summary }
        return model.customInstructionsEdited ? "Follows your own instructions." : "Follows your own instructions — the same as Medium until you edit them."
    }

    private var cleanupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // The same five levels as by the mic.
                CleanupPicker(settings: settings)
                Text(cleanupDisabledReason ?? levelSummary)
                    .font(.footnote)
                    .foregroundStyle(cleanupDisabledReason == nil ? Ink.secondary : Light.ochre)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
            NavigationLink(value: SettingsRoute.customCleanup) {
                LabeledContent { Text(model.customInstructionsEdited ? "Your own" : "Default") } label: {
                    row("Custom instructions", symbol: "text.quote", tint: Light.violet)
                }
            }
            .accessibilityIdentifier("custom-instructions-link")
            NavigationLink(value: SettingsRoute.dictionary) {
                LabeledContent { Text("\(settings.dictionary.count) of \(DictionaryPass.maxTerms)") } label: {
                    row("Dictionary", symbol: "character.book.closed", tint: Light.gold)
                }
            }
        } header: {
            Kicker("Cleanup")
        } footer: {
            Text("Cleanup runs on this iPhone with Apple's on-device model. The raw words are always one tap away.")
        }
        .listRowBackground(Ink.raised)
    }

    // MARK: Recording

    private var recordingSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.language) {
                LabeledContent { Text(Languages.displayName(settings.language)) } label: {
                    row("Language", symbol: "globe", tint: Light.cyan)
                }
            }
            Toggle(isOn: $settings.autoStop) { row("Stop when I stop talking", symbol: "ear", tint: Light.teal) }
            if settings.autoStop {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("After")
                        Spacer()
                        Text("\(Int(settings.autoStopDelay)) seconds of quiet")
                            .foregroundStyle(Ink.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.autoStopDelay, in: 2...8, step: 1) { Text("Silence before stopping") }
                        minimumValueLabel: { Text("2").font(.caption).foregroundStyle(Ink.tertiary) }
                        maximumValueLabel: { Text("8").font(.caption).foregroundStyle(Ink.tertiary) }
                        .accessibilityValue("\(Int(settings.autoStopDelay)) seconds")
                }
            }
        } header: {
            Kicker("Recording")
        } footer: {
            Text("Tap the button to start and tap again to send, or hold it while you talk and let go to send. Quiet only counts after you've started talking. One dictation can run up to 10 minutes.")
        }
        .listRowBackground(Ink.raised)
    }

    // MARK: Mac

    private var macSection: some View {
        Section {
            // Every paired Mac (Oct 19 2026): a tap makes one active, Unpair beside each.
            ForEach(model.pairedMacs) { mac in
                HStack(spacing: 8) {
                    MacRow(mac: mac, active: mac.id == model.pairedMac?.id, standing: model.standing(of: mac)) {
                        model.switchMac(to: mac.id)
                    }
                    Button("Unpair") { unpairing = mac }
                        .buttonStyle(.borderless)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Light.rose)
                        .accessibilityLabel("Unpair \(mac.name)")
                        .accessibilityIdentifier("unpair-\(mac.name)")
                }
            }
            NavigationLink(value: SettingsRoute.pairing) {
                row(model.isPaired ? "Pair Another Mac" : "Pair Your Mac", symbol: "qrcode.viewfinder", tint: Light.cyan)
            }
            .accessibilityIdentifier("pair-another-mac")
            let field = TextField("iPhone", text: $name)
                .foregroundStyle(Ink.secondary)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit(commitName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .accessibilityLabel("This iPhone's name")
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    row("This iPhone's name", symbol: "iphone", tint: Light.violet)
                    field
                }
            } else {
                HStack {
                    row("This iPhone's name", symbol: "iphone", tint: Light.violet)
                    Spacer()
                    field.multilineTextAlignment(.trailing)
                }
            }
            if let suggestion = DeviceNameSuggestion.from(macName: model.pairedMac?.name), suggestion != settings.deviceName, !nameFocused {
                Button("Use “\(suggestion)”") { name = suggestion; commitName() }
                    .foregroundStyle(Light.cyan)
            }
        } header: {
            Kicker(model.pairedMacs.count > 1 ? "Macs" : "Mac")
        } footer: {
            Text((model.pairedMacs.count > 1 ? "What you say goes to the active Mac. Tap another to switch, or swipe up or down on the Mac's name at the top. " : "")
                 + "What your Mac calls this iPhone shows next to each dictation; your Mac picks up a new name the next time this iPhone connects.")
        }
        .listRowBackground(Ink.raised)
        .confirmationDialog("Unpair \(unpairing?.name ?? model.macName)?", isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }),
                            titleVisibility: .visible, presenting: unpairing) { mac in
            Button("Unpair", role: .destructive) { Task { await model.unpair(mac.id) } }
        } message: { mac in
            Text(model.pairedMacs.count > 1 && mac.id == model.pairedMac?.id
                 ? "This iPhone stops sending to it and switches to your other Mac. To send to it again, pair with the QR code on it."
                 : "This iPhone stops sending to it. To send again, pair with the QR code on your Mac.")
        }
        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
    }

    private func commitName() {
        model.renameDevice(name)
        name = settings.deviceName
    }

    // MARK: Away from home

    private var awaySection: some View {
        Section {
            if let route = model.linkRoute {
                LabeledContent { Text(route.short).foregroundStyle(Ink.ink) } label: {
                    row("Connected now", symbol: MacPill.symbol(route), tint: Light.cyan)
                }
                .accessibilityLabel("Connected now: \(route.words)")
            }
            // Whether this iPhone is on a Tailscale network right now: it has a Tailscale address.
            LabeledContent {
                Text(TailscaleHere.isOn ? "On" : "Not on").foregroundStyle(TailscaleHere.isOn ? Ink.ink : Light.ochre)
            } label: {
                row("Tailscale on this iPhone", symbol: "network.badge.shield.half.filled", tint: TailscaleHere.isOn ? Light.mint : Light.ochre)
            }
            if let ts = model.macToldAddresses.first(where: \.isTailscale) {
                LabeledContent {
                    Text(ts.display).font(.system(.body, design: .monospaced)).foregroundStyle(Ink.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } label: {
                    row("Over Tailscale", symbol: "laptopcomputer", tint: Light.cyan)
                }
            } else if let a = model.macToldAddresses.first {
                LabeledContent {
                    Text(a.display).font(.system(.body, design: .monospaced)).foregroundStyle(Ink.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } label: {
                    row("From your Mac", symbol: "laptopcomputer", tint: Light.cyan)
                }
            } else {
                Text("Your Mac hasn't shared an address yet. Turn on Remote access in Macrophone on your Mac (Devices), then connect here at home once.")
                    .font(.footnote).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let field = TextField("name or address:port", text: $address)
                .foregroundStyle(Ink.secondary)
                .focused($addressFocused)
                .submitLabel(.done)
                .onSubmit(commitAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Your Mac's address from away")
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    row("Or type its address", symbol: "keyboard", tint: Light.violet)
                    field
                }
            } else {
                HStack {
                    row("Or type its address", symbol: "keyboard", tint: Light.violet)
                    Spacer()
                    field.multilineTextAlignment(.trailing)
                }
            }
            if addressProblem {
                Text("That doesn't look like an address. Try something like 100.101.2.3 or home.example.com:47821.")
                    .font(.footnote).foregroundStyle(Light.ochre)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Kicker("Away from home")
        } footer: {
            Text("""
            When your Mac isn't nearby, this iPhone reaches it through Tailscale — free, and still no server of ours.
            1. Install Tailscale on your Mac and on this iPhone.
            2. Sign in to both with the same account (the same Google or Apple sign-in). In the iPhone's Tailscale app, your Mac should be in its list of devices.
            3. Turn Tailscale on here, and allow the VPN when iOS asks. "Tailscale on this iPhone" above says On.
            4. In Macrophone on your Mac: Devices › Away from home › turn on Remote access.
            5. Open Macrophone here once at home: your Mac's address arrives by itself.
            To try it, turn off Wi-Fi and Bluetooth here — otherwise a nearby iPhone talks to the Mac directly. No Tailscale? Forward the port on your router and type your home's address above.
            """)
        }
        .listRowBackground(Ink.raised)
        .onChange(of: addressFocused) { _, focused in if !focused { commitAddress() } }
    }

    private func commitAddress() {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == (model.typedAddress?.display ?? "") || t == (model.typedAddress?.host ?? "") { addressProblem = false; return }
        addressProblem = !model.setTypedAddress(t)
        if !addressProblem { address = model.typedAddress?.display ?? "" }
    }

    // MARK: History

    private var historySection: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.historyEnabled }, set: { model.setHistoryEnabled($0) })) {
                row("Keep history", symbol: "clock.arrow.circlepath", tint: Light.gold)
            }
            Button("Clear History", role: .destructive) { confirmClear = true }
                .foregroundStyle(Light.rose)
                .disabled(model.historyItems.isEmpty)
        } header: {
            Kicker("History")
        } footer: {
            Text("The last 50 dictations, on this iPhone only. Clearing them doesn't touch your Mac's history.")
        }
        .listRowBackground(Ink.raised)
        .confirmationDialog("Clear all history on this iPhone?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { model.clearHistory() }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.diagnostics) {
                row("Share Diagnostics", symbol: "stethoscope", tint: Light.teal)
            }
            Link(destination: Product.website) {
                LabeledContent {
                    Text(Product.macDownloadDisplay).foregroundStyle(Light.cyan)
                } label: {
                    row("Website", symbol: "safari", tint: Light.cyan)
                }
            }
            .foregroundStyle(Ink.ink)
            LabeledContent {
                Text("\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
            } label: {
                row("Version", symbol: "info.circle", tint: Ink.secondary)
            }
        } header: {
            Kicker("About")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speech is transcribed on this iPhone. No audio is kept. Nothing leaves your devices — at home or away, it travels straight to your Mac.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Ink.secondary)
                Text("No account, no analytics.")
            }
            .padding(.top, 4)
        }
        .listRowBackground(Ink.raised)
    }
}

enum SettingsRoute: Hashable {
    case dictionary, language, diagnostics, pairing, sendTo, customCleanup
}
