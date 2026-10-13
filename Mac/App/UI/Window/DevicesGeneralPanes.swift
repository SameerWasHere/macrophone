import Carbon.HIToolbox
import MacrophoneKit
import SwiftUI

struct DevicesPane: View {
    @ObservedObject var model: AppModel
    @State private var forgetting: PairedPeer?
    @State private var editing: UUID?
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        PanePage {
            HStack(alignment: .bottom) {
                PaneHeader(title: "Devices", subtitle: "iPhones paired with this Mac. They talk directly over your network — no account, no server.")
                Button { AppDelegate.shared?.openSetup(.pair) } label: { Label("Pair iPhone…", systemImage: "qrcode") }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: model.peers.isEmpty))
                    .padding(.bottom, 2)
            }

            if model.peers.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "iphone.gen3").font(.system(size: 34, weight: .light)).foregroundStyle(Ink.tertiary)
                    Text("No iPhone yet").font(Typeface.serif(18)).foregroundStyle(Ink.secondary)
                    Text("Get Macrophone for iPhone from the App Store, then choose Pair iPhone.")
                        .font(.system(size: 12.5)).foregroundStyle(Ink.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else {
                Plate {
                    ForEach(Array(model.peers.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { PlateDivider(inset: 62) }
                        phoneRow(p)
                    }
                }
                Text("Names you give a phone here show in the menu, the popup, History and the API. The phone keeps its own name.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("This Mac")
                Plate {
                    PlateRow(title: AppPaths.computerName, subtitle: listenerLine, subtitleColor: listenerOK ? Ink.tertiary : Light.ochre,
                             icon: "laptopcomputer", iconColor: listenerOK ? Light.cyan : Light.ochre) {
                        if case .failed = model.listenerState {
                            Button("Open System Settings") { NSWorkspace.shared.open(Self.localNetworkSettings) }
                                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                        }
                    }
                }
                Text("Your iPhone sees this name. Change it in System Settings › General › Sharing.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).padding(.leading, 4)
            }
        }
        .confirmationDialog("Forget \(forgetting.map(model.displayName) ?? "this iPhone")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) { if let p = forgetting { model.forget(p) }; forgetting = nil }
        } message: {
            Text("It won't be able to send to this Mac until you pair it again. Use this if the phone is lost.")
        }
    }

    static let localNetworkSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    private var listenerOK: Bool { if case .ready = model.listenerState { return true }; return false }

    private var listenerLine: String {
        switch model.listenerState {
        case .ready: return "Visible to your iPhone on this network and nearby (peer-to-peer)."
        case .starting: return "Getting ready to listen on your network…"
        case .failed: return "Your iPhone can't reach this Mac. Turn on Macrophone in System Settings › Privacy & Security › Local Network."
        }
    }

    private func phoneRow(_ p: PairedPeer) -> some View {
        let on = model.connected.contains(p.id)
        let isEditing = editing == p.id
        let named = model.customName(p)
        let generic = named == nil && AppModel.isGenericName(p.name)
        return HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 32, height: 32)
                Circle().fill(on ? Light.cyan : Ink.tertiary.opacity(0.5)).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Ink.raised, lineWidth: 1.5))
                    .shadow(color: on ? Light.cyan.opacity(0.9) : .clear, radius: 3)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if isEditing {
                    TextField("Name", text: $draft, prompt: Text(p.name))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .frame(maxWidth: 280)
                        .focused($nameFocused)
                        .onSubmit { save(p) }
                        .onExitCommand { editing = nil }
                        .accessibilityLabel("Name for this iPhone")
                } else {
                    Text(model.displayName(p)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.ink)
                }
                Text(line(p, on: on)).font(.system(size: 11.5)).foregroundStyle(on ? Light.cyan : Ink.tertiary)
                if let named, named != p.name, !isEditing {
                    Text("Calls itself “\(p.name)”").font(.system(size: 11)).foregroundStyle(Ink.tertiary)
                } else if generic && !isEditing {
                    Text("iOS only shares “\(p.name)” — give it a name so you can tell it apart.")
                        .font(.system(size: 11)).foregroundStyle(Light.ochre)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: isEditing ? .contain : .combine)
            Spacer(minLength: 12)
            if isEditing {
                Button("Cancel") { editing = nil }
                    .buttonStyle(.borderless).foregroundStyle(Ink.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(p) }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
            } else {
                Button(generic ? "Name It…" : "Rename…") {
                    draft = model.customName(p) ?? (generic ? AppModel.suggestedPhoneName : p.name)
                    editing = p.id
                    DispatchQueue.main.async { nameFocused = true }
                }
                .buttonStyle(PillButtonStyle(tint: generic ? Light.teal : Ink.ink, filled: false))
                .accessibilityLabel("Rename \(model.displayName(p))")
                Button("Forget…") { forgetting = p }
                    .buttonStyle(PillButtonStyle(tint: Light.rose, filled: false))
                    .accessibilityLabel("Forget \(model.displayName(p))")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func save(_ p: PairedPeer) {
        model.rename(p, to: draft)
        editing = nil
    }

    private func line(_ p: PairedPeer, on: Bool) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        let paired = "paired \(f.string(from: p.pairedAt))"
        if on { return "Connected · \(paired)" }
        if let s = p.lastSeen { return "Last seen \(s.relativeShort) · \(paired)" }
        return "Not seen yet · \(paired)"
    }
}

struct GeneralPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        PanePage {
            PaneHeader(title: "General", subtitle: "Macrophone \(AppPaths.appVersion) (\(AppPaths.buildNumber))")

            Plate {
                PlateRow(title: "Open at login", subtitle: "Macrophone can only receive while it's running.", icon: "power") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                PlateDivider(inset: 50)
                HotkeyRow(settings: model.settings)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Updates")
                Plate {
                    PlateRow(title: "Check for updates automatically", subtitle: updateLine, icon: "arrow.triangle.2.circlepath") {
                        Toggle("", isOn: $updater.automaticallyChecks).toggleStyle(.switch).labelsHidden()
                    }
                    PlateDivider(inset: 50)
                    HStack {
                        Spacer()
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                            .disabled(!updater.canCheck)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Help")
                Plate {
                    PlateRow(title: "Share diagnostics", subtitle: "A plain-text log of connections and deliveries to send with a bug report. Never what you dictated.", icon: "stethoscope") {
                        Button("Share Diagnostics…") { AppDelegate.shared?.showDiagnostics() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                    }
                    PlateDivider(inset: 50)
                    PlateRow(title: "Show the welcome again", subtitle: "Walk through pairing and the delivery modes.", icon: "sparkle") {
                        Button("Show") { AppDelegate.shared?.openSetup(.pair) }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                    }
                    PlateDivider(inset: 50)
                    PlateRow(title: "Macrophone on the web", subtitle: Product.macDownloadDisplay, icon: "safari") {
                        Link("Open", destination: Product.website).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Light.teal)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Privacy").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.secondary)
                Text("Speech is transcribed on your iPhone. No audio is kept, there's no account, and nothing leaves your devices unless an automation uses a webhook, a script or Ask Claude. Macrophone collects no analytics.")
                    .font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)

            HStack {
                Spacer()
                Button("Quit Macrophone") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }

    private var updateLine: String {
        if let d = updater.lastCheck { return "Last checked \(d.relativeShort)." }
        return "Signed updates from sameer.us. Checked once a day."
    }
}

/// General › "Open Macrophone from anywhere": the global shortcut, for when the menu bar
/// icon is hidden behind the notch. Click to record, ⌫ or the clear button removes it.
struct HotkeyRow: View {
    @ObservedObject var settings: Settings
    @State private var recording = false
    @State private var live = ""
    @State private var monitor: Any?
    @State private var problem: String?

    private var key: Hotkey { settings.hotkey }

    var body: some View {
        PlateRow(title: "Open Macrophone from anywhere", subtitle: subtitle,
                 subtitleColor: problem == nil ? Ink.tertiary : Light.ochre, icon: "keyboard") {
            HStack(spacing: 10) {
                if !recording && key.enabled && (key.keyCode != Hotkey.default.keyCode || key.modifiers != Hotkey.default.modifiers) {
                    Button("Use \(Hotkey.default.display)") { set(Hotkey.default) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.tertiary)
                        .help("Go back to the standard shortcut, \(Hotkey.default.words)")
                }
                recorder
            }
        }
        .onAppear { problem = HotkeyCenter.shared.lastError }
        .onDisappear { stop() }
    }

    private var subtitle: String {
        if let problem { return problem }
        if recording { return "Press the keys you want, holding ⌘, ⌥ or ⌃. Esc cancels; Delete removes the shortcut." }
        if key.enabled {
            return "Press \(key.display) anywhere to open this window — useful when your menu bar hides Macrophone's icon."
        }
        return "No shortcut. You can still open Macrophone from Spotlight or Finder."
    }

    private var recorder: some View {
        HStack(spacing: 6) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? (live.isEmpty ? "Type Shortcut" : live) : (key.enabled ? key.display : "Record Shortcut"))
                    .font(recording || !key.enabled ? .system(size: 12, weight: .medium) : Typeface.mono(12.5, .semibold))
                    .foregroundStyle(recording ? Light.teal : (key.enabled ? Ink.ink : Ink.secondary))
                    .frame(minWidth: 104)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shortcut to open Macrophone")
            .accessibilityValue(recording ? "Recording. Press the new shortcut" : (key.enabled ? key.words : "None"))
            .accessibilityHint(recording ? "Escape cancels" : "Click to record a new shortcut")
            .help(recording ? "Esc cancels" : "Click to record a new shortcut")
            if key.enabled && !recording {
                Button { clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove the shortcut")
                .accessibilityLabel("Remove the shortcut")
            }
        }
        .padding(.leading, 10).padding(.trailing, key.enabled && !recording ? 7 : 10)
        .background(Capsule().fill(recording ? Light.teal.opacity(0.10) : Ink.sunk))
        .overlay(Capsule().strokeBorder(recording ? Light.teal.opacity(0.7) : Ink.lineHeavy, lineWidth: 1))
        .animation(Motion.reduceMotion ? nil : Motion.snap, value: recording)
    }

    private func start() {
        problem = nil
        live = ""
        recording = true
        // Let the current shortcut through to the recorder instead of opening the window.
        HotkeyCenter.shared.apply(Hotkey(keyCode: 0, modifiers: 0, enabled: false))
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
            let mods = Hotkey.carbonModifiers(flags)
            if e.type == .flagsChanged {
                live = Hotkey.symbols(mods)
                return e
            }
            switch Int(e.keyCode) {
            case kVK_Escape where mods == 0:
                stop(); return nil
            case kVK_Delete where mods == 0, kVK_ForwardDelete where mods == 0:
                clear(); return nil
            default: break
            }
            if let why = Hotkey.conflict(keyCode: UInt32(e.keyCode), modifiers: mods) {
                // Keep listening: say why and let them try another.
                NSSound.beep()
                problem = why
                live = ""
                return nil
            }
            set(Hotkey(keyCode: UInt32(e.keyCode), modifiers: mods, enabled: true))
            return nil
        }
    }

    private func set(_ new: Hotkey) {
        settings.hotkey = new
        stop()
    }

    private func clear() {
        settings.hotkey.enabled = false
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false }
        live = ""
        HotkeyCenter.shared.apply(settings.hotkey)
        problem = HotkeyCenter.shared.lastError
    }
}
