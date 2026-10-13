import MacrophoneKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false
    @State private var confirmClear = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool
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
                historySection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Ink.ground.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { commitName(); dismiss() }.fontWeight(.semibold) }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .dictionary: DictionaryView(settings: settings)
                case .language: LanguageView(settings: settings)
                case .diagnostics: DiagnosticsView()
                case .pairing: PairingView(embedded: true)
                case .sendTo: SendToList(settings: settings).navigationTitle("Send To").navigationBarTitleDisplayMode(.inline)
                }
            }
            .onAppear {
                name = settings.deviceName
                if path.isEmpty, !initialPath.isEmpty { path = initialPath }
                model.refreshAvailability()
            }
        }
        .tint(Light.cyan)
    }

    // MARK: Send to (the same choice as the quick controls by the mic)

    private var sendToSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.sendTo) {
                HStack(spacing: 12) {
                    TargetIcon(target: settings.selection.target, icon: model.liveTarget(for: settings.selection.target)?.icon, size: 28)
                    LabeledContent("Send to", value: settings.selection.target.displayName)
                }
            }
            Toggle("Paste & send", isOn: Binding(get: { settings.selection.send }, set: { model.setSend($0) }))
                .disabled(!settings.selection.target.canSend)
        } header: {
            Text("Send to")
        } footer: {
            Text(settings.selection.target.canSend
                 ? "Paste & send presses the app's send key after a short countdown on your Mac. The choice is the same on your Mac: change it in either place."
                 : "\(settings.selection.target.displayName) can't send — Paste & send is for apps. The choice is the same on your Mac: change it in either place.")
        }
    }

    // MARK: Cleanup

    private var cleanupDisabledReason: String? {
        if !settings.isEnglish { return "Cleanup and the dictionary fix work in English only for now. Other languages are sent exactly as heard." }
        if !model.cleanupAvailability.isAvailable { return model.cleanupAvailability.explanation + " Until then, dictations are sent exactly as heard." }
        return nil
    }

    private var cleanupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                CleanupDial(level: $settings.cleanupLevel, enabled: cleanupDisabledReason == nil)
                Text(cleanupDisabledReason ?? settings.cleanupLevel.summary)
                    .font(.footnote)
                    .foregroundStyle(cleanupDisabledReason == nil ? Ink.secondary : Light.ochre)
                    .fixedSize(horizontal: false, vertical: true)
                if cleanupDisabledReason == nil, let p = model.selectedProfile, let level = p.cleanupLevel {
                    Text("Your Mac's “\(p.name)” profile uses \(level.title) — it wins while that profile is picked.")
                        .font(.footnote)
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            NavigationLink(value: SettingsRoute.dictionary) {
                LabeledContent("Dictionary", value: "\(settings.dictionary.count) of \(DictionaryPass.maxTerms)")
            }
        } header: {
            Text("Cleanup")
        } footer: {
            Text("Cleanup runs on this iPhone with Apple's on-device model. The raw words are always one tap away.")
        }
        .listRowBackground(Ink.raised)
    }

    // MARK: Recording

    private var recordingSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.language) {
                LabeledContent("Language", value: Languages.displayName(settings.language))
            }
            Toggle("Stop when I stop talking", isOn: $settings.autoStop)
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
            Toggle("Show the tap-or-hold hint", isOn: $settings.showHoldHint)
        } header: {
            Text("Recording")
        } footer: {
            Text("Tap the button to start and tap again to send, or hold it while you talk and let go to send. Quiet only counts after you've started talking. One dictation can run up to 10 minutes.")
        }
        .listRowBackground(Ink.raised)
    }

    // MARK: Mac

    private var macSection: some View {
        Section {
            if let mac = model.pairedMac {
                LabeledContent("Paired Mac") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(mac.name).foregroundStyle(Ink.ink)
                        Text(connectionWord).font(.caption).foregroundStyle(connectionColor)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Paired Mac")
                .accessibilityValue("\(mac.name), \(connectionWord.lowercased())")
                Button("Unpair This Mac", role: .destructive) { confirmUnpair = true }
                    .foregroundStyle(Light.rose)
            } else {
                NavigationLink(value: SettingsRoute.pairing) {
                    Label("Pair Your Mac", systemImage: "qrcode.viewfinder")
                }
            }
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
                    Text("This iPhone's name")
                    field
                }
            } else {
                HStack {
                    Text("This iPhone's name")
                    Spacer()
                    field.multilineTextAlignment(.trailing)
                }
            }
            if let suggestion = DeviceNameSuggestion.from(macName: model.pairedMac?.name), suggestion != settings.deviceName, !nameFocused {
                Button("Use “\(suggestion)”") { name = suggestion; commitName() }
                    .foregroundStyle(Light.cyan)
            }
        } header: {
            Text("Mac")
        } footer: {
            Text("What your Mac calls this iPhone. It shows next to each dictation, and your Mac picks up a new name the next time this iPhone connects.")
        }
        .listRowBackground(Ink.raised)
        .confirmationDialog("Unpair \(model.macName)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { Task { await model.unpair() } }
        } message: {
            Text("This iPhone stops sending to it. To send again, pair with the QR code on your Mac.")
        }
        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
    }

    private var connectionWord: String {
        switch model.linkState {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .unreachable: return "Not found right now"
        case .searching: return "Looking for it"
        case .notPaired: return "Not paired"
        }
    }

    private var connectionColor: Color {
        if case .connected = model.linkState { return Light.cyan }
        if case .unreachable = model.linkState { return Light.ochre }
        return Ink.tertiary
    }

    private func commitName() {
        model.renameDevice(name)
        name = settings.deviceName
    }

    // MARK: History

    private var historySection: some View {
        Section {
            Toggle("Keep history", isOn: Binding(get: { settings.historyEnabled }, set: { model.setHistoryEnabled($0) }))
            Button("Clear History", role: .destructive) { confirmClear = true }
                .foregroundStyle(Light.rose)
                .disabled(model.historyItems.isEmpty)
        } header: {
            Text("History")
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
                Label("Share Diagnostics", systemImage: "stethoscope")
            }
            Link(destination: Product.website) {
                LabeledContent("Website") {
                    Text(Product.macDownloadDisplay).foregroundStyle(Light.cyan)
                }
            }
            .foregroundStyle(Ink.ink)
            LabeledContent("Version", value: "\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
        } header: {
            Text("About")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speech is transcribed on this iPhone. No audio is kept. Nothing leaves your devices.")
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
    case dictionary, language, diagnostics, pairing, sendTo
}

/// Off · Light · Medium · Heavy as a slider with labelled stops.
struct CleanupDial: View {
    @Binding var level: CleanupLevel
    var enabled: Bool
    private let levels = CleanupLevel.allCases

    var body: some View {
        let index = Binding<Double>(
            get: { Double(levels.firstIndex(of: enabled ? level : .off) ?? 0) },
            set: { level = levels[Int($0.rounded())] }
        )
        let current = enabled ? level : .off
        VStack(spacing: 6) {
            Slider(value: index, in: 0...Double(levels.count - 1), step: 1)
                .tint(enabled ? Light.teal : Ink.tertiary)
                .disabled(!enabled)
                .accessibilityLabel("Cleanup")
                .accessibilityValue(enabled ? level.title : "Off, unavailable")
            // The four stops under the slider; under huge type, just the one that's picked.
            ViewThatFits(in: .horizontal) {
                HStack {
                    ForEach(Array(levels.enumerated()), id: \.offset) { i, l in
                        Button(l.title) { if enabled { level = l } }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(current == l ? .semibold : .regular))
                            .foregroundStyle(current == l ? Ink.ink : Ink.tertiary)
                            .fixedSize()
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: i == 0 ? .leading : (i == levels.count - 1 ? .trailing : .center))
                            .contentShape(Rectangle())
                            .accessibilityLabel("\(l.title) cleanup")
                            .accessibilityAddTraits(current == l ? .isSelected : [])
                    }
                }
                Text(current.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
        .opacity(enabled ? 1 : 0.55)
    }
}
