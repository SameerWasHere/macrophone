import MacrophoneKit
import SwiftUI

/// Settings, as an iPhone's own Settings reads (Nov 1 2026): the active Mac as the banner at the
/// top (a tap opens how it's connected and Away from Home), then inset-grouped sections whose rows
/// each lead with a Settings icon, and the explanations in the sections' footers.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    /// The Mac an Unpair tap is asking about.
    @State private var unpairing: PairedPeer?
    @State private var confirmClear = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    var initialPath: [SettingsRoute] = []
    @State private var path: [SettingsRoute] = []
    /// The Duo's inner screen lays Settings out as an iPad's (Nov 1 2026); every other screen,
    /// and the cover, keep the one list.
    @ObservedObject private var posture = Posture.shared
    /// The group shown in the inner screen's second column (nil: the first one).
    @State private var group: SettingsGroup?

    var body: some View {
        Group {
            if posture.pose.isInner { split } else { stack }
        }
        .tint(Light.cyan)
        .onAppear {
            name = settings.deviceName
            if path.isEmpty, !initialPath.isEmpty {
                if posture.pose.isInner, let first = initialPath.first {
                    let (g, rest) = first.place(paired: model.isPaired)
                    group = g
                    path = rest + initialPath.dropFirst()
                } else {
                    path = initialPath
                }
            }
            model.refreshAvailability()
        }
    }

    private var stack: some View {
        NavigationStack(path: $path) {
            Form {
                bannerSection
                // Where the words go and how they're cleaned first; then watching and alerts.
                if model.isPaired { sendToSection }
                cleanupSection
                cleanupMoreSection
                if model.isPaired {
                    watchSection
                    alertsSection
                }
                recordingSection
                appearanceSection
                macSection
                historySection
                aboutSection
            }
            .toggleStyle(.settings)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { commitName(); dismiss() }.doneButtonStyle() }
            }
            .navigationDestination(for: SettingsRoute.self) { destination($0) }
        }
    }

    @ViewBuilder private func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .dictionary: DictionaryView(settings: settings)
        case .language: LanguageView(settings: settings)
        case .diagnostics: DiagnosticsView()
        case .pairing: PairingView(embedded: true)
        case .sendTo: SendToList(settings: settings).navigationTitle("Send to").navigationBarTitleDisplayMode(.inline)
        case .customCleanup: CustomCleanupView(settings: settings)
        case .connection: MacConnectionView()
        }
    }

    // MARK: The inner screen: two columns, as iPad Settings (Nov 1 2026)

    /// Sameer, on the Duo: "take advantage of the extra space. I shouldn't have to scroll that
    /// much." The sidebar lists the groups — the Mac as the banner, then the sections of the one
    /// list, gathered — and the detail column shows the chosen group's rows and footers, the same
    /// rows as the phone's list; the pages they open (Dictionary, Language, Custom Cleanup, Send
    /// to, pairing, Diagnostics) push inside the detail column.
    private var split: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: sidebarWidth, max: 340)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack(path: $path) {
                groupPage(shown)
                    .modifier(SettingsDoneButton { commitName(); dismiss() })
                    .navigationDestination(for: SettingsRoute.self) { route in
                        destination(route).modifier(SettingsDoneButton { commitName(); dismiss() })
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: group) { _, _ in path = [] }
    }

    /// Narrower upright (669 pt), so the detail keeps a phone's width.
    private var sidebarWidth: CGFloat { posture.pose.foldAcross ? 250 : 300 }

    /// The groups the sidebar lists, in the phone's order.
    private var groups: [SettingsGroup] {
        SettingsGroup.allCases.filter { model.isPaired || !$0.needsMac }
    }

    /// The chosen group, else the first under the banner (Send to) — or the banner itself when no
    /// Mac is paired yet, where pairing is the one thing to do.
    private var shown: SettingsGroup {
        if let group, groups.contains(group) { return group }
        return model.isPaired ? .sendTo : .mac
    }

    private var sidebar: some View {
        List(selection: Binding(get: { shown }, set: { group = $0 })) {
            Section {
                sidebarBanner.tag(SettingsGroup.mac)
            }
            Section {
                ForEach(groups.filter(\.isFirstBlock)) { g in sidebarRow(g) }
            }
            Section {
                ForEach(groups.filter { $0 != .mac && !$0.isFirstBlock }) { g in sidebarRow(g) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var sidebarBanner: some View {
        if let mac = model.pairedMac {
            let standing = model.standing(of: mac)
            MacBanner(name: mac.name, status: standing.words, routeSymbol: RouteGlyph.symbol(standing), plate: 48)
                .accessibilityHint("How this iPhone reaches it, at home and away.")
                .accessibilityIdentifier("settings-mac")
        } else {
            MacBanner(name: "Pair Your Mac", status: "Scan the code on your Mac to send your words to it.", paired: false, plate: 48)
                .accessibilityIdentifier("settings-mac")
        }
    }

    private func sidebarRow(_ g: SettingsGroup) -> some View {
        Label { Text(g.title(macs: model.pairedMacs.count)) } icon: {
            SettingsIcon(symbol: g == .macs ? MacGlyph.symbol(for: model.pairedMac?.name) : g.symbol, color: g.color)
        }
        .tag(g)
        .accessibilityIdentifier("settings-group-\(g.rawValue)")
    }

    /// A group's page in the detail column: the phone's sections for it, as they are.
    @ViewBuilder private func groupPage(_ g: SettingsGroup) -> some View {
        switch g {
        case .mac:
            if model.pairedMac != nil { MacConnectionView() } else { PairingView(embedded: true) }
        default:
            Form {
                switch g {
                case .sendTo: sendToSection
                case .cleanup: cleanupSection; cleanupMoreSection
                case .watching: watchSection; alertsSection
                case .recording: recordingSection
                case .appearance: appearanceSection
                case .macs: macSection
                case .history: historySection
                case .about: aboutSection
                case .mac: EmptyView()
                }
            }
            .toggleStyle(.settings)
            .navigationTitle(g.title(macs: model.pairedMacs.count))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: The Mac, as the banner

    @ViewBuilder private var bannerSection: some View {
        Section {
            if let mac = model.pairedMac {
                let standing = model.standing(of: mac)
                NavigationLink(value: SettingsRoute.connection) {
                    MacBanner(name: mac.name, status: standing.words, routeSymbol: RouteGlyph.symbol(standing))
                }
                .accessibilityHint("How this iPhone reaches it, at home and away.")
                .accessibilityIdentifier("settings-mac")
            } else {
                NavigationLink(value: SettingsRoute.pairing) {
                    MacBanner(name: "Pair Your Mac", status: "Scan the code on your Mac to send your words to it.", paired: false)
                }
                .accessibilityIdentifier("settings-mac")
            }
        }
    }

    // MARK: Send to (the same choice as the Dock)

    private var sendToSection: some View {
        let target = settings.selection.target
        return Section {
            NavigationLink(value: SettingsRoute.sendTo) {
                LabeledContent {
                    Text(target.displayName).multilineTextAlignment(.trailing)
                } label: {
                    Label {
                        Text("Send to")
                    } icon: {
                        PlaceIcon(target: target, icon: model.liveTarget(for: target)?.icon)
                    }
                }
            }
            // Only the switch is disabled for a place that can't send, the label dimmed beside it:
            // a disabled Toggle's own label read as clipped text to the accessibility audit.
            HStack {
                Label { Text("Send after pasting") } icon: { SettingsIcon(symbol: "paperplane.fill", color: Light.cyan) }
                    .foregroundStyle(target.canSend ? Ink.ink : Ink.secondary)
                Spacer(minLength: 8)
                Toggle("Send after pasting", isOn: Binding(get: { settings.selection.send }, set: { model.setSend($0) }))
                    .labelsHidden()
                    .disabled(!target.canSend)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Send to")
        } footer: {
            Text((target.canSend
                  ? "Your Mac presses the app's send key after pasting. If you're at the Mac, you get a moment to cancel first."
                  : "\(target.displayName) can't send — sending after pasting is for apps.")
                 + " The choice is the same on your Mac: change it in either place.")
        }
    }

    // Each switch explains itself in its own footer (the three explanations used to run together
    // as one nine-line footer, Oct 18 2026).
    private var watchSection: some View {
        Section {
            Toggle(isOn: $settings.watchAfterSending) {
                Label { Text("Show the app after sending") } icon: { SettingsIcon(symbol: "eye.fill", color: Color(uiColor: .systemIndigo)) }
            }
        } footer: {
            Text("Your iPhone shows that app's window live, so you can read the answer, tap to click, swipe to scroll, and press Esc, the arrows or Return. Only that window, and only while you look.")
        }
    }

    private var alertsSection: some View {
        Section {
            Toggle(isOn: $settings.agentAlerts) {
                Label { Text("Tell me when an agent asks something") } icon: { SettingsIcon(symbol: "bell.badge.fill", color: Light.rose) }
            }
            .onChange(of: settings.agentAlerts) { _, on in
                Task { if on { await AgentAlerts.shared.askIfNeeded() } else { await AgentAlerts.shared.unsubscribeInCloud() } }
            }
        } footer: {
            Text("When an agent on your Mac stops to ask something while Macrophone is open here, you get a notification; tap it to answer.")
        }
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
            // The same five levels as by the mic.
            CleanupPicker(settings: settings)
                .padding(.vertical, 2)
        } header: {
            Text("Cleanup")
        } footer: {
            Text(cleanupDisabledReason ?? levelSummary)
                .foregroundStyle(cleanupDisabledReason == nil ? Ink.secondary : Light.ochre)
        }
    }

    private var cleanupMoreSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.customCleanup) {
                LabeledContent { Text(model.customInstructionsEdited ? "Your own" : "Default") } label: {
                    Label { Text("Custom instructions") } icon: { SettingsIcon(symbol: "text.quote", color: Light.violet) }
                }
            }
            .accessibilityIdentifier("custom-instructions-link")
            NavigationLink(value: SettingsRoute.dictionary) {
                LabeledContent { Text("\(settings.dictionary.count) of \(DictionaryPass.maxTerms)") } label: {
                    Label { Text("Dictionary") } icon: { SettingsIcon(symbol: "character.book.closed.fill", color: Light.ember) }
                }
            }
        } footer: {
            Text("Cleanup runs on this iPhone with Apple's on-device model. The raw words are always one tap away.")
        }
    }

    // MARK: Recording

    private var recordingSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.language) {
                LabeledContent { Text(Languages.displayName(settings.language)) } label: {
                    Label { Text("Language") } icon: { SettingsIcon(symbol: "globe", color: Light.cyan) }
                }
            }
            Toggle(isOn: $settings.autoStop) {
                Label { Text("Stop when I stop talking") } icon: { SettingsIcon(symbol: "waveform", color: Color(uiColor: .systemPink)) }
            }
            if settings.autoStop {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("After") {
                        Text("\(Int(settings.autoStopDelay)) seconds of quiet").monospacedDigit()
                    }
                    Slider(value: $settings.autoStopDelay, in: 2...8, step: 1) { Text("Silence before stopping") }
                        minimumValueLabel: { Text("2").font(.caption).foregroundStyle(Ink.secondary) }
                        maximumValueLabel: { Text("8").font(.caption).foregroundStyle(Ink.secondary) }
                        .accessibilityValue("\(Int(settings.autoStopDelay)) seconds")
                }
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("Tap the button to start and tap again to send, or hold it while you talk and let go to send. Quiet only counts after you've started talking. One dictation can run up to 10 minutes.")
        }
    }

    // MARK: Appearance (Nov 1 2026)

    private var appearanceSection: some View {
        Section {
            Picker(selection: $settings.appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            } label: {
                Label { Text("Appearance") } icon: { SettingsIcon(symbol: "circle.lefthalf.filled", color: Light.cyan) }
            }
            .accessibilityIdentifier("appearance")
            Toggle(isOn: $settings.macWallpaper) {
                Label { Text("Use My Mac's Wallpaper") } icon: { SettingsIcon(symbol: "photo.fill", color: Light.teal) }
            }
            .accessibilityIdentifier("mac-wallpaper")
        } footer: {
            Text("Automatic follows this iPhone's Light or Dark setting. Your Mac's wallpaper sits behind the app; turn it off if it makes things hard to read.")
        }
    }

    // MARK: Macs

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
                        .font(.subheadline)
                        .foregroundStyle(Light.rose)
                        .accessibilityLabel("Unpair \(mac.name)")
                        .accessibilityIdentifier("unpair-\(mac.name)")
                }
            }
            NavigationLink(value: SettingsRoute.pairing) {
                Label { Text(model.isPaired ? "Pair Another Mac" : "Pair Your Mac") } icon: {
                    SettingsIcon(symbol: "qrcode.viewfinder", color: Light.cyan)
                }
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
            // "This iPhone", its name the value beside it (as Settings › General › About › Name).
            let label = Label { Text("This iPhone") } icon: { SettingsIcon(symbol: "iphone", color: Color(uiColor: .systemGray)) }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) { label; field }
            } else {
                HStack { label; Spacer(); field.multilineTextAlignment(.trailing) }
            }
            if let suggestion = DeviceNameSuggestion.from(macName: model.pairedMac?.name), suggestion != settings.deviceName, !nameFocused {
                Button("Use “\(suggestion)”") { name = suggestion; commitName() }
            }
        } header: {
            Text(model.pairedMacs.count > 1 ? "Macs" : "Mac")
        } footer: {
            Text((model.pairedMacs.count > 1 ? "What you say goes to the active Mac. Tap another to switch, or swipe up or down on the Mac's name at the top. " : "")
                 + "What your Mac calls this iPhone shows next to each dictation; your Mac picks up a new name the next time this iPhone connects."
                 + (model.isPaired ? " To reach your Mac away from home, tap it at the top." : ""))
        }
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

    // MARK: History

    private var historySection: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.historyEnabled }, set: { model.setHistoryEnabled($0) })) {
                Label { Text("Keep history") } icon: { SettingsIcon(symbol: "clock.fill", color: Color(uiColor: .systemGray)) }
            }
            Button("Clear History", role: .destructive) { confirmClear = true }
                .disabled(model.historyItems.isEmpty)
        } header: {
            Text("History")
        } footer: {
            Text("The last 50 dictations, on this iPhone only. Clearing them doesn't touch your Mac's history.")
        }
        .confirmationDialog("Clear all history on this iPhone?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { model.clearHistory() }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.diagnostics) {
                Label { Text("Share Diagnostics") } icon: { SettingsIcon(symbol: "stethoscope", color: Light.mint) }
            }
            Link(destination: Product.website) {
                LabeledContent {
                    Text(Product.macDownloadDisplay)
                } label: {
                    Label { Text("Website").foregroundStyle(Ink.ink) } icon: { SettingsIcon(symbol: "safari.fill", color: Light.cyan) }
                }
            }
            LabeledContent {
                Text("\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
            } label: {
                Label { Text("Version") } icon: { SettingsIcon(symbol: "info", color: Color(uiColor: .systemGray)) }
            }
        } header: {
            Text("About")
        } footer: {
            Text("Speech is transcribed on this iPhone. No audio is kept. Nothing leaves your devices — at home or away, it travels straight to your Mac. No account, no analytics.")
        }
    }
}

enum SettingsRoute: Hashable {
    case dictionary, language, diagnostics, pairing, sendTo, customCleanup, connection

    /// Where a page opens on the inner screen: the group it belongs to, and what's pushed in the
    /// detail column over that group's page (the Mac's page is the banner's group itself).
    func place(paired: Bool) -> (SettingsGroup, [SettingsRoute]) {
        switch self {
        case .dictionary, .customCleanup: return (.cleanup, [self])
        case .language: return (.recording, [self])
        case .diagnostics: return (.about, [self])
        case .sendTo: return (paired ? .sendTo : .mac, paired ? [self] : [])
        case .connection: return (.mac, [])
        case .pairing: return paired ? (.macs, [self]) : (.mac, [])
        }
    }
}

/// Settings' groups, as the inner screen's sidebar lists them: the Mac as the banner, then the
/// phone list's sections gathered — the everyday ones first, then the Macs, History and About.
enum SettingsGroup: String, CaseIterable, Identifiable, Hashable {
    case mac, sendTo, cleanup, watching, recording, appearance, macs, history, about
    var id: String { rawValue }

    /// Only with a Mac paired (the phone list leaves these sections out too).
    var needsMac: Bool { self == .sendTo || self == .watching }
    /// The sidebar's first block (under the banner).
    var isFirstBlock: Bool { [.sendTo, .cleanup, .watching, .recording, .appearance].contains(self) }

    func title(macs: Int) -> String {
        switch self {
        case .mac: return "Your Mac"
        case .sendTo: return "Send to"
        case .cleanup: return "Cleanup"
        case .watching: return "Watching and alerts"
        case .recording: return "Recording"
        case .appearance: return "Appearance"
        case .macs: return macs > 1 ? "Your Macs" : "Your Mac and iPhone"
        case .history: return "History"
        case .about: return "About"
        }
    }

    /// Each group's Settings icon (the rows' own where a group has one).
    var symbol: String {
        switch self {
        case .mac, .macs: return "laptopcomputer"
        case .sendTo: return "paperplane.fill"
        case .cleanup: return "wand.and.sparkles"
        case .watching: return "eye.fill"
        case .recording: return "waveform"
        case .appearance: return "circle.lefthalf.filled"
        case .history: return "clock.fill"
        case .about: return "info"
        }
    }

    var color: Color {
        switch self {
        case .mac, .sendTo, .appearance: return Light.cyan
        case .cleanup: return Light.violet
        case .watching: return Color(uiColor: .systemIndigo)
        case .recording: return Color(uiColor: .systemPink)
        case .macs, .history, .about: return Color(uiColor: .systemGray)
        }
    }
}

/// Done at the trailing end of the inner screen's detail column, on every page in it (the
/// sidebar keeps its own bar clear, as iPad Settings').
private struct SettingsDoneButton: ViewModifier {
    var action: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Done", action: action).doneButtonStyle() }
        }
    }
}

/// The active Mac's page, from the banner: how this iPhone reaches it right now, and how to reach
/// it away from home through Tailscale (or a forwarded port).
struct MacConnectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var address = ""
    @State private var addressProblem = false
    @FocusState private var addressFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Form {
            if let mac = model.pairedMac {
                Section {
                    let standing = model.standing(of: mac)
                    MacPageHeader(name: mac.name, status: standing.words, routeSymbol: RouteGlyph.symbol(standing))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            connectionSection
            awaySection
        }
        .navigationTitle(model.pairedMac?.name ?? "Your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { address = model.typedAddress?.display ?? "" }
        .onChange(of: addressFocused) { _, focused in if !focused { commitAddress() } }
    }

    private var connectionSection: some View {
        Section {
            if let route = model.linkRoute {
                LabeledContent { Text(route.short) } label: {
                    Label { Text("Connected now") } icon: { SettingsIcon(symbol: RouteGlyph.symbol(route), color: Light.cyan) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Connected now: \(route.words)")
            }
            // Whether this iPhone is on a Tailscale network right now: it has a Tailscale address.
            LabeledContent {
                Text(TailscaleHere.isOn ? "On" : "Not on").foregroundStyle(TailscaleHere.isOn ? Ink.secondary : Light.ochre)
            } label: {
                Label { Text("Tailscale on this iPhone") } icon: {
                    SettingsIcon(symbol: "network.badge.shield.half.filled", color: TailscaleHere.isOn ? Light.mint : Color(uiColor: .systemGray))
                }
            }
            if let ts = model.macToldAddresses.first(where: \.isTailscale) {
                addressRow("Over Tailscale", ts.display)
            } else if let a = model.macToldAddresses.first {
                addressRow("From your Mac", a.display)
            }
        } header: {
            Text("Connection")
        } footer: {
            if model.macToldAddresses.isEmpty {
                Text("Your Mac hasn't shared an address yet. Turn on Remote access in Macrophone on your Mac (Devices), then connect here at home once.")
            }
        }
    }

    private func addressRow(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).textSelection(.enabled)
        } label: {
            Label { Text(title) } icon: { SettingsIcon(symbol: "laptopcomputer", color: Light.cyan) }
        }
    }

    private var awaySection: some View {
        Section {
            let field = TextField("name or address:port", text: $address)
                .foregroundStyle(Ink.secondary)
                .focused($addressFocused)
                .submitLabel(.done)
                .onSubmit(commitAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Your Mac's address from away")
            // Typed here, it's dialled beside the ones your Mac told (the footer says how).
            let label = Label { Text("Address") } icon: { SettingsIcon(symbol: "keyboard.fill", color: Light.violet) }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) { label; field }
            } else {
                HStack { label; Spacer(); field.multilineTextAlignment(.trailing) }
            }
            if addressProblem {
                Text("That doesn't look like an address. Try something like 100.101.2.3 or home.example.com:47821.")
                    .font(.footnote).foregroundStyle(Light.ochre)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Away from home")
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
    }

    private func commitAddress() {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == (model.typedAddress?.display ?? "") || t == (model.typedAddress?.host ?? "") { addressProblem = false; return }
        addressProblem = !model.setTypedAddress(t)
        if !addressProblem { address = model.typedAddress?.display ?? "" }
    }
}
