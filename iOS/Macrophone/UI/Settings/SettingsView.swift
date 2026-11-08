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
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Two columns only when the sheet is wide enough for them (Nov 4 2026): a sheet the system
    /// gives a compact width collapsed the columns into the detail, so Settings opened on Send to
    /// with a back button instead of on its list.
    private var twoColumns: Bool { posture.pose.isInner && sizeClass == .regular }

    var body: some View {
        Group {
            if twoColumns { split } else { stack }
        }
        .tint(Light.cyan)
        .onAppear {
            name = settings.deviceName
            if path.isEmpty, !initialPath.isEmpty {
                if twoColumns, let first = initialPath.first {
                    let (g, rest) = first.place(paired: model.isPaired)
                    group = g
                    path = rest + initialPath.dropFirst()
                } else {
                    path = initialPath
                }
            }
        }
        // The availability check (the cleanup model, the speech engine made ready, the haptic
        // prepared) runs once the sheet has risen, not in its first frame's pass (Nov 7 2026).
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            model.refreshAvailability()
        }
    }

    private var stack: some View {
        NavigationStack(path: $path) {
            Form {
                // The settings review (Nov 7 2026): every section has a heading and a short footer,
                // in the order of use — where the words go, how they're cleaned, the window, alerts,
                // then the look, the devices, history and about.
                bannerSection
                dictationSection
                cleanupSection
                if model.isPaired {
                    watchSection
                    alertsSection
                }
                appearanceSection
                devicesSection
                historySection
                aboutSection
            }
            .toggleStyle(.settings)
            // On the Duo's cover the sheet's ground is a card beside the vertical bar
            // (`InnerScreenSheet`): the Form's own would run under the column.
            .scrollContentBackground(VerticalBarProbe.edge == nil ? .automatic : .hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.visible, for: .navigationBar)
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
        case .awaySetup: AwayGuideView()
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

    /// The chosen group, else the first under the banner (Dictation) — or the banner itself when
    /// no Mac is paired yet, where pairing is the one thing to do.
    private var shown: SettingsGroup {
        if let group, groups.contains(group) { return group }
        return model.isPaired ? .dictation : .mac
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
            SettingsIcon(symbol: g.symbol, color: g.color)
        }
        .tag(g)
        .accessibilityIdentifier("settings-group-\(g.rawValue)")
    }

    /// A group's page in the detail column: the phone's sections for it, as they are.
    @ViewBuilder private func groupPage(_ g: SettingsGroup) -> some View {
        switch g {
        case .mac:
            if model.pairedMac != nil { MacConnectionView(popsOnUnpair: false) } else { PairingView(embedded: true) }
        default:
            Form {
                switch g {
                case .dictation: dictationSection
                case .cleanup: cleanupSection
                case .watching: watchSection
                case .alerts: alertsSection
                case .appearance: appearanceSection
                case .devices: devicesSection
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

    // MARK: Dictation — where the words go, and how the mic listens

    /// Send to and Send after pasting (paired only), then the language and the auto-stop: the
    /// whole path of a dictation in one section, the explanations a sentence each.
    private var dictationSection: some View {
        let target = settings.selection.target
        return Section {
            if model.isPaired {
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
                // Only the switch is disabled for a place that can't send, the label dimmed beside
                // it: a disabled Toggle's own label read as clipped text to the accessibility audit.
                HStack {
                    Label { Text("Send after pasting") } icon: { SettingsIcon(symbol: "paperplane.fill", color: Light.cyan) }
                        .foregroundStyle(target.canSend ? Ink.ink : Ink.secondary)
                    Spacer(minLength: 8)
                    Toggle("Send after pasting", isOn: Binding(get: { settings.selection.send }, set: { model.setSend($0) }))
                        .labelsHidden()
                        .disabled(!target.canSend)
                }
                .accessibilityElement(children: .combine)
            }
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
            Text("Dictation")
        } footer: {
            Text(dictationFooter(target))
        }
    }

    private func dictationFooter(_ target: TargetRef) -> String {
        var words: [String] = []
        if model.isPaired {
            words.append(target.canSend
                         ? "Send after pasting presses the app's send key for you. Send to is shared with your Mac."
                         : "\(target.displayName) can't send — sending after pasting is for apps.")
        }
        if settings.autoStop { words.append("Quiet counts only after you start talking.") }
        return words.isEmpty ? "Hold the mic while you talk, or tap to start and tap again to send." : words.joined(separator: " ")
    }

    // MARK: Cleanup

    private var cleanupDisabledReason: String? {
        if !settings.isEnglish { return "Cleanup and the dictionary work in English only for now. Other languages are sent exactly as heard." }
        if !model.cleanupAvailability.isAvailable { return model.cleanupAvailability.explanation + " Until then, dictations are sent exactly as heard." }
        return nil
    }

    private var levelSummary: String {
        guard settings.cleanupLevel == .custom else { return settings.cleanupLevel.summary }
        return model.customInstructionsEdited ? "Follows your own instructions." : "Follows your own instructions — the same as Medium until you edit them."
    }

    /// The level, what it does right under it, then the instructions and the dictionary: one
    /// section (the level's words used to be a footer between two sections).
    private var cleanupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                // The same five levels as by the mic. At the accessibility sizes a segmented
                // control keeps its small type (five segments can't grow on a phone's width), so
                // the levels are a list with a check, as Settings' own choices are there.
                if typeSize.isAccessibilitySize {
                    let available = CleanupWords.available(model, settings)
                    Picker("Cleanup", selection: Binding(get: { available ? settings.cleanupLevel : .off }, set: { l in
                        guard l != settings.cleanupLevel else { return }
                        Haptics.pick()
                        model.setCleanupLevel(l)
                    })) {
                        ForEach(CleanupLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(!available)
                    .accessibilityIdentifier("cleanup-level")
                } else {
                    CleanupPicker(settings: settings)
                }
                Text(cleanupDisabledReason ?? levelSummary)
                    .font(.footnote)
                    .foregroundStyle(cleanupDisabledReason == nil ? Ink.secondary : Light.ochre)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: settings.cleanupLevel)
            }
            .padding(.vertical, 4)
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
        } header: {
            Text("Cleanup")
        } footer: {
            Text("Runs on this iPhone with Apple's on-device model. The raw words are always one tap away in History.")
        }
    }

    // MARK: Watching — the window on the phone

    private var watchSection: some View {
        Section {
            Toggle(isOn: $settings.watchAfterSending) {
                Label { Text("Show the app after sending") } icon: { SettingsIcon(symbol: "eye.fill", color: Color(uiColor: .systemIndigo)) }
            }
            trackpadSpeedRow
        } header: {
            Text("Watching")
        } footer: {
            Text("After a dictation lands, that app's window opens here live, so you can read the answer, tap to click and swipe to scroll. Only that window, and only while you look.")
        }
    }

    /// Trackpad speed (Nov 7 2026, Sameer: "a trackpad sensitivity toggle in settings") — the
    /// Mac's own Tracking speed: a slider from the tortoise to the hare, Normal in the middle. Off
    /// Normal, Reset sits beside the value (no extra row that comes and goes).
    private var trackpadSpeedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label { Text("Trackpad speed") } icon: { SettingsIcon(symbol: "rectangle.and.hand.point.up.left.fill", color: Color(uiColor: .systemGray)) }
                Spacer(minLength: 8)
                if abs(settings.trackpadSpeed - 1) > 0.01 {
                    Button("Reset") {
                        Haptics.pick()
                        withAnimation(Motion.settle) { settings.trackpadSpeed = 1 }
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .accessibilityLabel("Back to Normal")
                    .accessibilityIdentifier("trackpad-speed-reset")
                    .transition(.opacity)
                }
                Text(TrackpadSpeedWords.words(settings.trackpadSpeed))
                    .foregroundStyle(Ink.secondary)
                    .contentTransition(.opacity)
            }
            Slider(value: TrackpadSpeedWords.position($settings.trackpadSpeed), in: 0...1, step: 0.1) {
                Text("Trackpad speed")
            } minimumValueLabel: {
                Image(systemName: "tortoise.fill").foregroundStyle(Ink.secondary).accessibilityHidden(true)
            } maximumValueLabel: {
                Image(systemName: "hare.fill").foregroundStyle(Ink.secondary).accessibilityHidden(true)
            } onEditingChanged: { editing in
                if !editing { Haptics.pick() }
            }
            .accessibilityValue(TrackpadSpeedWords.words(settings.trackpadSpeed))
            .accessibilityIdentifier("trackpad-speed")
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: abs(settings.trackpadSpeed - 1) > 0.01)
    }

    // MARK: Alerts

    private var alertsSection: some View {
        Section {
            Toggle(isOn: $settings.agentAlerts) {
                Label { Text("When an agent asks something") } icon: { SettingsIcon(symbol: "bell.badge.fill", color: Light.rose) }
            }
            .onChange(of: settings.agentAlerts) { _, on in
                Task {
                    if on { await AgentAlerts.shared.askIfNeeded() }
                    else if model.alertWatches.isEmpty { await AgentAlerts.shared.unsubscribeInCloud() }
                }
            }
            // Why an alert couldn't reach this iPhone with the app closed, and the button that
            // fixes it (Nov 7 2026) — only while something wants alerts and something's in the way.
            if settings.agentAlerts || !model.alertWatches.isEmpty { CloudAlertsStatusRow() }
            // Windows on watch (Nov 6 2026): each one a row; a swipe ends it.
            ForEach(model.alertWatches) { w in
                HStack(spacing: 12) {
                    SettingsIcon(symbol: "bell.fill", color: w.calm ? Color(uiColor: .systemGray) : Light.gold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title).lineLimit(1)
                        let who = w.appName == w.title ? "" : "\(w.appName) · "
                        Text(w.calm ? "\(who)only when it stops changing" : "\(who)on watch")
                            .font(.footnote)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Stop") { model.setAlertWatch(w.ref, on: false) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(Light.rose)
                        .accessibilityLabel("Stop alerts for \(w.title)")
                }
                .accessibilityElement(children: .combine)
                .swipeActions { Button("Stop", role: .destructive) { model.setAlertWatch(w.ref, on: false) } }
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text(model.canAlert || !model.alertWatches.isEmpty
                 ? "Put any window on watch from its Window menu, or by holding its icon. You get a notification with a picture when it finishes or needs you, even with Macrophone closed."
                 : "When an agent on your Mac stops to ask something, you get a notification with a picture of its window. Tap it to answer.")
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
                Label { Text("Use my Mac’s wallpaper") } icon: { SettingsIcon(symbol: "photo.fill", color: Light.teal) }
            }
            .accessibilityIdentifier("mac-wallpaper")
            if settings.macWallpaper {
                HStack(spacing: 12) {
                    Image(systemName: "circle.dotted").foregroundStyle(Ink.secondary)
                    Slider(value: $settings.wallpaperStrength, in: 0.1...1)
                    Image(systemName: "photo.fill").foregroundStyle(Ink.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Wallpaper strength")
                .accessibilityValue("\(Int((settings.wallpaperStrength * 100).rounded())) percent")
                .accessibilityAdjustableAction { dir in
                    let step = dir == .increment ? 0.1 : -0.1
                    settings.wallpaperStrength = min(1, max(0.1, settings.wallpaperStrength + step))
                }
                .accessibilityIdentifier("wallpaper-strength")
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text(settings.macWallpaper
                 ? "Fade your Mac's wallpaper, or turn it off, if it makes things hard to read."
                 : "Automatic follows this iPhone's Light or Dark setting.")
        }
    }

    // MARK: Devices — the Macs and this iPhone

    /// One Mac is the banner at the top (its page has Unpair); listing it again here read as a
    /// stutter, so the Macs are listed only when there are several to choose between.
    private var devicesSection: some View {
        Section {
            if model.pairedMacs.count > 1 {
                ForEach(model.pairedMacs) { mac in
                    HStack(spacing: 8) {
                        MacRow(mac: mac, active: mac.id == model.pairedMac?.id, standing: model.standing(of: mac)) {
                            model.switchMac(to: mac.id)
                        }
                        // A small red capsule, as Open an App's Quit (a bare red word beside the
                        // check read as a stray label, Nov 4 2026); a swipe or a long press says it too.
                        Button("Unpair") { unpairing = mac }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .tint(Light.rose)
                            .accessibilityLabel("Unpair \(mac.name)")
                            .accessibilityIdentifier("unpair-\(mac.name)")
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Unpair", role: .destructive) { unpairing = mac }.tint(Light.rose)
                    }
                    .contextMenu {
                        if mac.id != model.pairedMac?.id {
                            Button { model.switchMac(to: mac.id) } label: { Label("Make Active", systemImage: "checkmark.circle") }
                        }
                        Button(role: .destructive) { unpairing = mac } label: { Label("Unpair…", systemImage: "minus.circle") }
                    }
                }
            }
            // Unpaired, the banner at the top is the way to pair; the row would say it twice.
            if model.isPaired {
                NavigationLink(value: SettingsRoute.pairing) {
                    Label { Text("Pair Another Mac") } icon: {
                        SettingsIcon(symbol: "qrcode.viewfinder", color: Light.cyan)
                    }
                }
                .accessibilityIdentifier("pair-another-mac")
            }
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
            Text("Devices")
        } footer: {
            Text((model.pairedMacs.count > 1 ? "What you say goes to the checked Mac; tap another to switch. " : "")
                 + "Your Mac shows this iPhone's name next to each dictation.")
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
            Text("Your last 50 dictations, kept on this iPhone only. Clearing them leaves your Mac's history alone.")
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
            Text("Speech turns into text on this iPhone, and no audio is kept. Your words go straight to your Mac, at home or away. No account, no analytics.")
        }
    }
}

enum SettingsRoute: Hashable {
    case dictionary, language, diagnostics, pairing, sendTo, customCleanup, connection, awaySetup

    /// Where a page opens on the inner screen: the group it belongs to, and what's pushed in the
    /// detail column over that group's page (the Mac's page is the banner's group itself).
    func place(paired: Bool) -> (SettingsGroup, [SettingsRoute]) {
        switch self {
        case .dictionary, .customCleanup: return (.cleanup, [self])
        case .language: return (.dictation, [self])
        case .diagnostics: return (.about, [self])
        case .sendTo: return (paired ? .dictation : .mac, paired ? [self] : [])
        case .connection: return (.mac, [])
        case .awaySetup: return (.mac, [self])
        case .pairing: return paired ? (.devices, [self]) : (.mac, [])
        }
    }
}

/// Settings' groups, as the inner screen's sidebar lists them: the Mac as the banner, then the
/// phone list's sections one for one — the everyday ones first, then Devices, History and About.
enum SettingsGroup: String, CaseIterable, Identifiable, Hashable {
    case mac, dictation, cleanup, watching, alerts, appearance, devices, history, about
    var id: String { rawValue }

    /// Only with a Mac paired (the phone list leaves these sections out too).
    var needsMac: Bool { self == .watching || self == .alerts }
    /// The sidebar's first block (under the banner).
    var isFirstBlock: Bool { [.dictation, .cleanup, .watching, .alerts, .appearance].contains(self) }

    func title(macs: Int) -> String {
        switch self {
        case .mac: return "Your Mac"
        case .dictation: return "Dictation"
        case .cleanup: return "Cleanup"
        case .watching: return "Watching"
        case .alerts: return "Alerts"
        case .appearance: return "Appearance"
        case .devices: return "Devices"
        case .history: return "History"
        case .about: return "About"
        }
    }

    /// Each group's Settings icon (the rows' own where a group has one).
    var symbol: String {
        switch self {
        case .mac: return "laptopcomputer"
        case .dictation: return "mic.fill"
        case .cleanup: return "wand.and.sparkles"
        case .watching: return "eye.fill"
        case .alerts: return "bell.badge.fill"
        case .appearance: return "circle.lefthalf.filled"
        case .devices: return "laptopcomputer.and.iphone"
        case .history: return "clock.fill"
        case .about: return "info"
        }
    }

    var color: Color {
        switch self {
        case .mac, .appearance: return Light.cyan
        case .dictation: return Color(uiColor: .systemPink)
        case .cleanup: return Light.violet
        case .watching: return Color(uiColor: .systemIndigo)
        case .alerts: return Light.rose
        case .devices, .history, .about: return Color(uiColor: .systemGray)
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
    /// Pushed from the banner it goes back once its Mac is unpaired; as the inner screen's
    /// group page there's nothing to go back to, so it shows the next Mac (or pairing).
    var popsOnUnpair = true
    @State private var confirmUnpair = false
    /// The header's name has scrolled under the bar: the bar says it instead (as Settings'
    /// Apple Account page) — never the same name twice on screen.
    @State private var headerGone = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss

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
            if model.pairedMac != nil { unpairSection }
        }
        .modifier(ScrolledPast(150, past: $headerGone))
        .navigationTitle(model.pairedMac?.name ?? "Your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(model.pairedMac?.name ?? "Your Mac")
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(model.pairedMac == nil || headerGone ? 1 : 0)
                    .accessibilityHidden(!(model.pairedMac == nil || headerGone))
            }
        }
    }

    @ViewBuilder private var connectionSection: some View {
        if let route = model.linkRoute {
            Section {
                LabeledContent { Text(route.short) } label: {
                    Label { Text("Connected now") } icon: { SettingsIcon(symbol: RouteGlyph.symbol(route), color: Light.cyan) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Connected now: \(route.words)")
            } header: {
                Text("Connection")
            }
        }
    }

    /// Away from home is one row now (Nov 7 2026): the guide behind it checks every step itself;
    /// the Tailscale state, the Mac's addresses and the typed address (jargon on the Mac's own
    /// page) moved into it.
    private var awaySection: some View {
        Section {
            NavigationLink(value: SettingsRoute.awaySetup) {
                LabeledContent {
                    Text(model.awayReady ? "Ready" : "Set Up")
                        .foregroundStyle(model.awayReady ? Light.mint : Ink.secondary)
                } label: {
                    Label { Text("Away from Home") } icon: {
                        SettingsIcon(symbol: "network.badge.shield.half.filled", color: model.awayReady ? Light.mint : Light.cyan)
                    }
                }
            }
            .accessibilityIdentifier("away-setup")
        } footer: {
            Text("Reach your Mac from anywhere with Tailscale — free and private.")
        }
    }

    private var unpairSection: some View {
        Section {
            Button("Unpair This Mac", role: .destructive) { confirmUnpair = true }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("unpair-this-mac")
        } footer: {
            Text("To send to it again, pair with the code on your Mac.")
        }
        .confirmationDialog("Unpair \(model.macName)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                guard let id = model.pairedMac?.id else { return }
                if popsOnUnpair { dismiss() }
                Task { await model.unpair(id) }
            }
        } message: {
            Text(model.pairedMacs.count > 1
                 ? "This iPhone stops sending to it and switches to your other Mac."
                 : "This iPhone stops sending to it.")
        }
    }

}

/// Whether a list has scrolled more than `distance` down (iOS 18+; before, it never has — the
/// bar's title then stays hidden behind the page's own header, as it was).
struct ScrolledPast: ViewModifier {
    var distance: CGFloat
    @Binding var past: Bool
    init(_ distance: CGFloat, past: Binding<Bool>) { self.distance = distance; _past = past }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top > distance
            } action: { _, now in
                withAnimation(.easeInOut(duration: 0.2)) { past = now }
            }
        } else {
            content
        }
    }
}

/// The trackpad speed slider's scale: the slider runs 0…1 with Normal (1×) in the middle, on a
/// curve so each step feels like the same change (0.4× … 1× … 2.5×).
enum TrackpadSpeedWords {
    static func speed(at position: Double) -> Double {
        let r = TrackpadMotion.speeds
        return r.lowerBound * pow(r.upperBound / r.lowerBound, min(max(position, 0), 1))
    }

    static func position(of speed: Double) -> Double {
        let r = TrackpadMotion.speeds
        let s = min(max(speed, r.lowerBound), r.upperBound)
        return log(s / r.lowerBound) / log(r.upperBound / r.lowerBound)
    }

    @MainActor static func position(_ value: Binding<Double>) -> Binding<Double> {
        Binding(get: { position(of: value.wrappedValue) },
                set: { p in
                    let rounded = (p * 10).rounded() / 10
                    value.wrappedValue = abs(rounded - 0.5) < 0.001 ? 1 : speed(at: rounded)
                })
    }

    static func words(_ speed: Double) -> String {
        let p = position(of: speed)
        if abs(speed - 1) < 0.01 { return "Normal" }
        if p <= 0.001 { return "Slowest" }
        if p >= 0.999 { return "Fastest" }
        return p < 0.5 ? "Slower" : "Faster"
    }
}
