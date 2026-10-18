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
            PaneHeader(title: "Devices", subtitle: "iPhones paired with this Mac. They talk directly over your network — no account, no server.") {
                if !model.peers.isEmpty {
                    Button { AppDelegate.shared?.openSetup(.pair) } label: { Label("Pair iPhone…", systemImage: "qrcode") }
                        .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                        .help("Show a code to scan with another iPhone")
                }
            }

            if model.peers.isEmpty {
                Plate {
                    EmptyState(title: "No iPhone paired yet",
                               detail: "Get Macrophone for iPhone from the App Store, then pair it with a code this Mac shows.") {
                        Image(systemName: "iphone.gen3").font(.system(size: 34, weight: .light)).foregroundStyle(Ink.tertiary)
                            .accessibilityHidden(true)
                    } action: {
                        Button { AppDelegate.shared?.openSetup(.pair) } label: { Label("Pair iPhone…", systemImage: "qrcode") }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                            .keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                PaneSection(note: "Names you give a phone here show in the menu, the popup, History and the API. The phone keeps its own name.") {
                    Plate {
                        ForEach(Array(model.peers.enumerated()), id: \.element.id) { i, p in
                            if i > 0 { PlateDivider(inset: Space.inset + 32 + 14) }
                            phoneRow(p)
                        }
                    }
                }
            }

            PaneSection("This Mac", note: "Your iPhone sees this name. Change it in System Settings › General › Sharing.") {
                Plate {
                    PlateRow(title: AppPaths.computerName, subtitle: listenerLine, subtitleColor: listenerOK ? Ink.tertiary : Light.ochre,
                             icon: "laptopcomputer", iconColor: listenerOK ? Light.cyan : Light.ochre) {
                        if case .failed = model.listenerState {
                            Button("Open System Settings") { NSWorkspace.shared.open(Self.localNetworkSettings) }
                                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                        }
                    }
                }
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
        PaneSection("Away from home") {
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
                    PlateDivider()
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
                        PlateDivider()
                        addressRow(title: "On this network", address: a, icon: "wifi", tint: Ink.secondary,
                                   note: "From outside, only if you forward port \(a.port) to this Mac on your router.")
                    }
                    PlateDivider()
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
            howToSetUpRemote
        }
    }

    /// The one-time setup, as numbered steps (a wall of text read as one paragraph).
    private var howToSetUpRemote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Set up once, with Tailscale (free, and still no server of ours):")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Ink.secondary)
            ForEach(Array(Self.remoteSteps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1).").font(Typeface.mono(11, .medium)).foregroundStyle(Ink.tertiary).frame(width: 14, alignment: .trailing)
                    Text(step).font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("No Tailscale? Forward the port to this Mac on your router and type your home's address into Macrophone on the iPhone (Settings › Away from home).")
                .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private static let remoteSteps = [
        "Install Tailscale on this Mac and on your iPhone.",
        "Sign in to both with the same account. On the iPhone, the Tailscale app should list this Mac.",
        "Turn on Remote access here.",
        "Open Macrophone on your iPhone once at home — it learns this Mac's address and reaches it from anywhere after that. Its Settings say “Tailscale on this iPhone: On” when it's ready.",
    ]

    private func addressRow(title: String, address: RemoteAddress, icon: String, tint: Color, note: String) -> some View {
        PlateRow(title: title, subtitle: note, icon: icon, iconColor: tint) {
            HStack(spacing: 10) {
                Text(address.display).font(Typeface.mono(12.5, .medium)).foregroundStyle(Ink.ink).textSelection(.enabled)
                Button(copied == address.display ? "Copied" : "Copy") {
                    Clipboard.copyPlain(address.display)
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
        .padding(.horizontal, Space.inset).padding(.vertical, 12)
        .frame(minHeight: 56)
        .animation(Motion.reduceMotion ? nil : .easeOut(duration: 0.15), value: isEditing)
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
                PlateDivider()
                HotkeyRow(settings: settings)
                PlateDivider()
                PlateRow(title: "Show a notification when copying",
                         subtitle: settings.clipboardNotification
                            ? "When Send to is Clipboard, a popup shows what arrived. If you're away, it waits in Notification Center."
                            : "Off: it's copied quietly and the menu bar icon ticks.",
                         icon: "bell.badge") {
                    Toggle("", isOn: $settings.clipboardNotification).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Show a notification when copying")
                }
            }

            PaneSection("Permissions") {
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
                    PlateDivider()
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

            PaneSection("Updates") {
                Plate {
                    PlateRow(title: "Check for updates automatically", subtitle: updateLine, icon: "arrow.triangle.2.circlepath") {
                        HStack(spacing: Space.gap) {
                            Button("Check Now") { updater.checkForUpdates() }
                                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                                .disabled(!updater.canCheck)
                            Toggle("", isOn: $updater.automaticallyChecks).toggleStyle(.switch).labelsHidden()
                                .accessibilityLabel("Check for updates automatically")
                        }
                    }
                }
            }

            PaneSection("Help") {
                Plate {
                    PlateRow(title: "Share diagnostics", subtitle: "A plain-text log of connections and deliveries for a bug report. Never what you dictated.", icon: "stethoscope") {
                        Button("Share…") { AppDelegate.shared?.showDiagnostics() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                    }
                    PlateDivider()
                    PlateRow(title: "Show the welcome again", subtitle: "Pairing, open at login, and where dictations go.", icon: "sparkle") {
                        Button("Show") { AppDelegate.shared?.openSetup(.pair) }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                    }
                    PlateDivider()
                    PlateRow(title: "Macrophone on the web", subtitle: Product.macDownloadDisplay, icon: "safari") {
                        Link("Open", destination: Product.website)
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                            .accessibilityLabel("Open the Macrophone website")
                    }
                }
            }

            PaneSection("Privacy") {
                Text("Speech is transcribed and cleaned up on your iPhone. No audio is kept, there's no account, and what you dictate travels only between your iPhone and this Mac — at home or, with Remote access, from away. Macrophone collects no analytics.")
                    .font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            HStack {
                Spacer()
                Button("Quit Macrophone") { NSApp.terminate(nil) }
                    .buttonStyle(PillButtonStyle(tint: Ink.secondary, filled: false))
                    .help("Dictations can't arrive while Macrophone isn't running")
            }
            .padding(.top, 4)
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

/// Agents (Oct 18 2026, its own page — in General nobody found it): connect Claude Code and Codex.
struct AgentsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        PanePage {
            PaneHeader(title: "Agents",
                       subtitle: "Your iPhone buzzes the moment an agent needs you — exactly, from the agent itself.")
            AgentsSection(apiOn: settings.apiEnabled, labeled: false,
                          note: "Connected agents tell Macrophone when they start working, ask you something, finish or close, and your iPhone alerts you with the question. Other apps still alert you when Macrophone reads them asking on screen. Works for sessions started after you connect.")
        }
    }
}

/// Claude Code and Codex, connected: they tell Macrophone themselves when they work, ask or
/// finish, so your iPhone knows exactly which one waits on you (AgentSetup).
struct AgentsSection: View {
    var apiOn: Bool
    /// The kicker above the plate (off on the Agents pane, whose title already says it).
    var labeled = true
    /// The quiet line under the plate.
    var note: String?
    @State private var claude = AgentSetup.claude
    @State private var codex = AgentSetup.codex
    @State private var problem: String?

    var body: some View {
        PaneSection(labeled ? "Agents" : nil, note: note) {
            Plate {
                row(name: "Claude Code", status: claude, icon: "sparkles") {
                    problem = AgentSetup.setClaude(claude != .connected)
                    claude = AgentSetup.claude
                }
                PlateDivider()
                row(name: "Codex", status: codex, icon: "chevron.left.forwardslash.chevron.right") {
                    problem = AgentSetup.setCodex(codex != .connected)
                    codex = AgentSetup.codex
                }
            }
            if let problem {
                PlateNote(problem, color: Light.ochre)
            } else if !apiOn, claude == .connected || codex == .connected {
                PlateNote("Turn on Local API in Developer — the agents tell Macrophone through it.", color: Light.ochre)
            }
        }
        .onAppear { claude = AgentSetup.claude; codex = AgentSetup.codex }
    }

    @ViewBuilder
    private func row(name: String, status: AgentSetup.Status, icon: String, toggle: @escaping () -> Void) -> some View {
        PlateRow(title: name, subtitle: line(name, status),
                 icon: status == .connected ? "checkmark.circle.fill" : icon,
                 iconColor: status == .connected ? Light.mint : Ink.tertiary) {
            switch status {
            case .connected:
                Button("Disconnect", action: toggle).buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
            case .notConnected:
                Button("Connect", action: toggle).buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
            case .missing, .taken:
                EmptyView()
            }
        }
    }

    private func line(_ name: String, _ s: AgentSetup.Status) -> String {
        switch s {
        case .connected: return "Your iPhone knows the moment \(name) asks you something or finishes. New sessions only."
        case .notConnected: return "Tells your iPhone exactly when \(name) needs you, instead of reading its window."
        case .missing: return "\(name) isn't set up on this Mac."
        case .taken: return "Codex already runs another program when a turn ends, so Macrophone can't connect."
        }
    }
}
