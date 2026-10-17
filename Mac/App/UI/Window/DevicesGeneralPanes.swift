import Carbon.HIToolbox
import MacrophoneKit
import SwiftUI
import UserNotifications

struct DevicesPane: View {
    @ObservedObject var model: AppModel
    @State private var forgetting: PairedPeer?
    @State private var editing: UUID?
    @State private var draft = ""
    @FocusState private var nameFocused: Bool
    @State private var portDraft = ""
    @FocusState private var portFocused: Bool
    @State private var copied: String?

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

            awayFromHome
        }
        .onAppear { portDraft = String(model.settings.remotePort) }
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
        case .ready: return model.settings.remoteAccess
            ? "Visible to your iPhone on this network, nearby (peer-to-peer), and away from home."
            : "Visible to your iPhone on this network and nearby (peer-to-peer)."
        case .starting: return "Getting ready to listen on your network…"
        case .failed: return "Your iPhone can't reach this Mac. Turn on Macrophone in System Settings › Privacy & Security › Local Network."
        }
    }

    // MARK: Away from home (remote access)

    @ViewBuilder private var awayFromHome: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Away from home")
            Plate {
                PlateRow(title: "Remote access",
                         subtitle: settings.remoteAccess
                            ? "Your paired iPhone can reach this Mac from anywhere it can reach this address — only iPhones paired here, and the link is encrypted the same way as at home."
                            : "Off: your iPhone reaches this Mac only on this network and nearby.",
                         icon: "globe") {
                    Toggle("", isOn: Binding(get: { settings.remoteAccess }, set: { settings.remoteAccess = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Remote access")
                }
                if settings.remoteAccess {
                    PlateDivider(inset: 50)
                    if let ts = model.tailscaleAddress {
                        addressRow(title: "Over Tailscale", address: ts, icon: "point.3.connected.trianglepath.dotted", tint: Light.cyan,
                                   note: model.tailscaleName.map { "Also \($0.display)" } ?? "Works from anywhere, as long as Tailscale is on for both.")
                    } else {
                        PlateRow(title: "Over Tailscale", subtitle: "Tailscale isn't running on this Mac. Install it (free), sign in, and this Mac's Tailscale address appears here.",
                                 subtitleColor: Light.ochre, icon: "point.3.connected.trianglepath.dotted", iconColor: Light.ochre) {
                            Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
                                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Light.teal)
                        }
                    }
                    ForEach(model.localAddresses, id: \.self) { a in
                        PlateDivider(inset: 50)
                        addressRow(title: "On this network", address: a, icon: "wifi", tint: Ink.secondary,
                                   note: "From outside, only if you forward port \(a.port) to this Mac on your router.")
                    }
                    PlateDivider(inset: 50)
                    PlateRow(title: "Port", subtitle: "The port in the addresses above. Change it only if something else on this Mac uses it.", icon: "number") {
                        TextField("Port", text: $portDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(Typeface.mono(12.5, .medium))
                            .frame(width: 76)
                            .multilineTextAlignment(.trailing)
                            .focused($portFocused)
                            .onSubmit { commitPort() }
                            .onChange(of: portFocused) { _, f in if !f { commitPort() } }
                            .accessibilityLabel("Remote access port")
                    }
                }
            }
            Text("The easy way is Tailscale (free): install it on this Mac and on your iPhone and sign in to both with the same account — then your iPhone learns this Mac's address the next time it connects here at home, and reaches it from anywhere. Without Tailscale, forward the port to this Mac on your router and type your home's address into Macrophone on the iPhone (Settings › Mac). Nothing goes through a server either way.")
                .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).padding(.leading, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addressRow(title: String, address: RemoteAddress, icon: String, tint: Color, note: String) -> some View {
        PlateRow(title: title, subtitle: note, icon: icon, iconColor: tint) {
            HStack(spacing: 10) {
                Text(address.display).font(Typeface.mono(12.5, .medium)).foregroundStyle(Ink.ink).textSelection(.enabled)
                Button(copied == address.display ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address.display, forType: .string)
                    copied = address.display
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if copied == address.display { copied = nil } }
                }
                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                .accessibilityLabel("Copy \(address.display)")
            }
        }
    }

    private func commitPort() {
        let settings = model.settings
        if let p = Int(portDraft.trimmingCharacters(in: .whitespaces)), (1024...65_535).contains(p) {
            if p != settings.remotePort { settings.remotePort = p }
        }
        portDraft = String(settings.remotePort)
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
    @ObservedObject var settings: Settings
    @ObservedObject var updater: Updater
    @ObservedObject var notifier: Notifier

    var body: some View {
        PanePage {
            PaneHeader(title: "General", subtitle: "Macrophone \(AppPaths.appVersion) (\(AppPaths.buildNumber))")

            Plate {
                PlateRow(title: "Open at login", subtitle: "Macrophone can only receive while it's running.", icon: "power") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Open at login")
                }
                PlateDivider(inset: 50)
                HotkeyRow(settings: settings)
                PlateDivider(inset: 50)
                PlateRow(title: "Show a notification when copying",
                         subtitle: settings.clipboardNotification
                            ? "When Send to is Clipboard, a popup shows what arrived. If you're away, it waits in Notification Center."
                            : "Off: it's copied quietly and the menu bar icon ticks.",
                         icon: "bell.badge") {
                    Toggle("", isOn: $settings.clipboardNotification).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Show a notification when copying")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Permissions")
                Plate {
                    PlateRow(title: "Accessibility",
                             subtitle: model.accessibilityGranted
                                ? "Allowed. Macrophone can see which apps have somewhere to type, paste, and press send."
                                : "Needed to list your open apps and to paste into them. Until it's on, dictations are copied.",
                             subtitleColor: model.accessibilityGranted ? Ink.tertiary : Light.ochre,
                             icon: model.accessibilityGranted ? "checkmark.circle.fill" : "hand.raised",
                             iconColor: model.accessibilityGranted ? Light.mint : Light.ochre) {
                        if !model.accessibilityGranted {
                            Button("Open System Settings") {
                                Paster.requestTrust()
                                NSWorkspace.shared.open(Paster.accessibilitySettingsURL)
                            }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                        }
                    }
                    PlateDivider(inset: 50)
                    PlateRow(title: "Notifications", subtitle: notificationLine,
                             icon: notificationsOn ? "checkmark.circle.fill" : "bell",
                             iconColor: notificationsOn ? Light.mint : Ink.tertiary) {
                        if notifier.status == .denied {
                            Button("Open System Settings") { NSWorkspace.shared.open(Paster.notificationSettingsURL) }
                                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                        } else if notifier.status == .notDetermined {
                            Button("Allow…") { notifier.requestIfNeeded() }
                                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Updates")
                Plate {
                    PlateRow(title: "Check for updates automatically", subtitle: updateLine, icon: "arrow.triangle.2.circlepath") {
                        HStack(spacing: 12) {
                            Button("Check Now") { updater.checkForUpdates() }
                                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                                .disabled(!updater.canCheck)
                            Toggle("", isOn: $updater.automaticallyChecks).toggleStyle(.switch).labelsHidden()
                                .accessibilityLabel("Check for updates automatically")
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Help")
                Plate {
                    PlateRow(title: "Share diagnostics", subtitle: "A plain-text log of connections and deliveries for a bug report. Never what you dictated.", icon: "stethoscope") {
                        Button("Share…") { AppDelegate.shared?.showDiagnostics() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                    }
                    PlateDivider(inset: 50)
                    PlateRow(title: "Show the welcome again", subtitle: "Pairing, open at login, and where dictations go.", icon: "sparkle") {
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
                Text("Speech is transcribed and cleaned up on your iPhone. No audio is kept, there's no account, and what you dictate travels only between your iPhone and this Mac — at home or, with Remote access, from away. Macrophone collects no analytics.")
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

    private var notificationsOn: Bool { notifier.status == .authorized || notifier.status == .provisional }

    private var notificationLine: String {
        switch notifier.status {
        case .authorized, .provisional, .ephemeral:
            return "On. Anything that arrives while your Mac is locked waits in Notification Center."
        case .denied:
            return "Off in System Settings. The popup still shows while you're at your Mac."
        default:
            return "Macrophone asks after your first dictation arrives, so anything that lands while your Mac is locked can wait in Notification Center."
        }
    }

    private var updateLine: String {
        if let d = updater.lastCheck { return "Signed updates from sameer.us. Last checked \(d.relativeShort)." }
        return "Signed updates from sameer.us, checked once a day."
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
