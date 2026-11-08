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
    @State private var withoutTailscale = false

    var body: some View {
        PanePage {
            PaneHeader(title: "Devices", subtitle: "The iPhones paired with this Mac. They talk to it directly — no account, no server.") {
                if !model.peers.isEmpty {
                    Button("Pair Another iPhone…") { AppDelegate.shared?.openSetup(.pair) }
                        .help("Show a code to scan with another iPhone")
                }
            }

            if model.peers.isEmpty {
                Section {
                    EmptyState(title: "No iPhone paired yet",
                               detail: "Get Macrophone for iPhone from the App Store, then scan the code this Mac shows.") {
                        Image(systemName: "iphone.gen3").font(.system(size: 36, weight: .light))
                            .accessibilityHidden(true)
                    } action: {
                        Button("Pair Your iPhone…") { AppDelegate.shared?.openSetup(.pair) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                PaneSection("iPhones", note: "A name you give a phone here shows in the menu, the popup, History and the API. The phone keeps its own.") {
                    ForEach(model.peers, id: \.id) { p in phoneRow(p) }
                }
            }

            PaneSection("This Mac", note: "Your iPhone sees this name. Change it in System Settings › General › Sharing.") {
                PlateRow(title: AppPaths.computerName, subtitle: listenerLine, subtitleColor: listenerOK ? Ink.secondary : Light.ochre,
                         icon: "laptopcomputer", iconColor: listenerOK ? MacTint.blue : MacTint.orange) {
                    if case .failed = model.listenerState {
                        Button("Open System Settings") { NSWorkspace.shared.open(Self.localNetworkSettings) }
                    }
                }
            }

            awayFromHome
            WakeForNetworkNote()
        }
        .onAppear {
            portDraft = String(model.settings.remotePort)
            #if DEBUG
            if ProcessInfo.processInfo.environment["MACROPHONE_WITHOUT_TAILSCALE"] == "1" { withoutTailscale = true }
            #endif
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
        case .ready: return model.settings.remoteAccess
            ? "Visible to your iPhone on this network, nearby (peer-to-peer), and away from home."
            : "Visible to your iPhone on this network and nearby (peer-to-peer)."
        case .starting: return "Getting ready to listen on your network…"
        case .failed: return "Your iPhone can't reach this Mac. Turn on Macrophone in System Settings › Privacy & Security › Local Network."
        }
    }

    // MARK: Away from home (remote access)

    /// Tailscale, step by step (AwayGuide), then the way without it, folded away.
    @ViewBuilder private var awayFromHome: some View {
        PaneSection("Away from home",
                    note: "Tailscale is free. Your iPhone and this Mac find each other through your own Tailscale account — Macrophone still has no server, and only iPhones paired here can connect.") {
            AwayGuide(model: model).environment(\.guideLook, .pane)
        }
        // The way without Tailscale, folded away as a disclosure row of the form's.
        Section {
            DisclosureGroup(isExpanded: $withoutTailscale) {
                if model.settings.remoteAccess {
                    ForEach(model.localAddresses, id: \.self) { a in
                        addressRow(title: "On this network", address: a, icon: "wifi", tint: MacTint.blue,
                                   note: "Reachable from outside only if your router forwards port \(a.port) to this Mac.")
                    }
                }
                PlateRow(title: "Port", subtitle: "Change it only if something else on this Mac uses it.", icon: "number") {
                    TextField("Port", text: $portDraft)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(Typeface.digits(13))
                        .frame(width: 76)
                        .multilineTextAlignment(.trailing)
                        .focused($portFocused)
                        .onSubmit { commitPort() }
                        .onChange(of: portFocused) { _, f in if !f { commitPort() } }
                        .accessibilityLabel("Remote access port")
                }
            } label: {
                Text("Without Tailscale")
            }
        } footer: {
            if withoutTailscale {
                SectionFooter("Turn on Remote access, forward port \(model.settings.remotePort) on your router to this Mac, then type your home's address into Macrophone on your iPhone (Settings › your Mac › Away from home).")
            }
        }
    }

    private func addressRow(title: String, address: RemoteAddress, icon: String, tint: Color, note: String) -> some View {
        PlateRow(title: title, subtitle: note, icon: icon, iconColor: tint) {
            HStack(spacing: 8) {
                Text(address.display).font(Typeface.mono(12, .regular)).foregroundStyle(Ink.ink).textSelection(.enabled)
                Button(copied == address.display ? "Copied" : "Copy") {
                    Clipboard.copyPlain(address.display)
                    copied = address.display
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if copied == address.display { copied = nil } }
                }
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
        return HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                SettingsIcon("iphone", color: on ? MacTint.blue : MacTint.gray, size: 32)
                Circle().fill(on ? Light.mint : Color.clear).frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Ink.raised, lineWidth: on ? 1.5 : 0))
                    .offset(x: 2, y: 2)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("Name", text: $draft, prompt: Text(p.name))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .frame(maxWidth: 280)
                        .focused($nameFocused)
                        .onSubmit { save(p) }
                        .onExitCommand { editing = nil }
                        .accessibilityLabel("Name for this iPhone")
                } else {
                    Text(model.displayName(p)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                }
                Text(line(p, on: on)).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                if let named, named != p.name, !isEditing {
                    Text("Calls itself “\(p.name)”").font(.system(size: 11)).foregroundStyle(Ink.secondary)
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
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(p) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(generic ? "Name It…" : "Rename…") {
                    draft = model.customName(p) ?? (generic ? AppModel.suggestedPhoneName : p.name)
                    editing = p.id
                    DispatchQueue.main.async { nameFocused = true }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Rename \(model.displayName(p))")
                Button("Forget…", role: .destructive) { forgetting = p }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Forget \(model.displayName(p))")
            }
        }
        .padding(.vertical, 3)
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
            PaneHeader(title: "General", subtitle: "Macrophone \(AppPaths.appVersion) (\(AppPaths.buildNumber)) — how it opens, how it looks, what it's allowed to do.")

            PaneSection {
                PlateRow(title: "Open at login", subtitle: "Macrophone can only receive while it's running.", icon: "power", iconColor: MacTint.graphite) {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Open at login")
                }
                HotkeyRow(settings: settings)
                PlateRow(title: "Show a notification when copying",
                         subtitle: settings.clipboardNotification
                            ? "When Send to is Clipboard, a popup shows what arrived. If you're away, it waits in Notification Center."
                            : "Off: it's copied quietly and the menu bar icon ticks.",
                         icon: "bell.badge", iconColor: MacTint.red) {
                    Toggle("", isOn: $settings.clipboardNotification).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Show a notification when copying")
                }
            }

            PaneSection("Appearance", note: "Automatic follows your Mac's light or dark appearance.") {
                PlateRow(title: "Appearance", icon: "circle.lefthalf.filled", iconColor: MacTint.graphite) {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { a in Text(a.title).tag(a) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            PaneSection("Permissions", note: "Each button opens the right place in System Settings. Turn on Macrophone there.") {
                // Accessibility and Screen Recording, live (PermissionRows.swift).
                PermissionRows(monitor: model.permissions)
                PlateRow(title: "Notifications", subtitle: notificationLine,
                         icon: "bell", iconColor: notificationsOn ? MacTint.green : MacTint.red) {
                    if notifier.status == .denied {
                        Button("Open System Settings") { NSWorkspace.shared.open(Paster.notificationSettingsURL) }
                    } else if notifier.status == .notDetermined {
                        Button("Allow…") { notifier.requestIfNeeded() }
                    } else if notificationsOn {
                        AllowedMark(name: "Notifications")
                    }
                }
            }

            PaneSection("Updates") {
                PlateRow(title: "Check for updates automatically", subtitle: updateLine, icon: "arrow.triangle.2.circlepath", iconColor: MacTint.blue) {
                    Toggle("", isOn: $updater.automaticallyChecks).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Check for updates automatically")
                }
                PlateRow(title: "Check now", subtitle: "Signed updates from sameer.us.", icon: "arrow.down.circle", iconColor: MacTint.blue) {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                }
            }

            PaneSection("Help", note: "Speech is transcribed and cleaned up on your iPhone (or on this Mac when you dictate here). No audio is kept, there's no account, and what you dictate travels only between your iPhone and this Mac — at home or, with Remote access, from away. Macrophone collects no analytics.") {
                PlateRow(title: "Share diagnostics", subtitle: "A plain-text log of connections and deliveries for a bug report. Never what you dictated.",
                         icon: "stethoscope", iconColor: MacTint.teal) {
                    Button("Share…") { AppDelegate.shared?.showDiagnostics() }
                }
                PlateRow(title: "Set up again", subtitle: "Permissions, away from home and open at login — whatever is done already is skipped. To pair another iPhone, use Devices.",
                         icon: "sparkles", iconColor: MacTint.purple) {
                    Button("Set Up…") { AppDelegate.shared?.openSetup(.firstRun) }
                }
                PlateRow(title: "Macrophone on the web", subtitle: Product.macDownloadDisplay, icon: "safari", iconColor: MacTint.blue) {
                    Link("Open", destination: Product.website)
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Open the Macrophone website")
                }
                PlateRow(title: "Quit Macrophone", subtitle: "Dictations can't arrive while it isn't running.", icon: "power.circle", iconColor: MacTint.gray) {
                    Button("Quit") { NSApp.terminate(nil) }
                }
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
        if let d = updater.lastCheck { return "Once a day. Last checked \(d.relativeShort)." }
        return "Once a day."
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
                 subtitleColor: problem == nil ? Ink.secondary : Light.ochre, icon: "keyboard", iconColor: MacTint.graphite) {
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
                    .font(.system(size: 12.5, weight: recording || !key.enabled ? .regular : .medium))
                    .foregroundStyle(recording ? Color.accentColor : (key.enabled ? Ink.ink : Ink.secondary))
                    .frame(minWidth: 104)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .accessibilityLabel("Shortcut to open Macrophone")
            .accessibilityValue(recording ? "Recording. Press the new shortcut" : (key.enabled ? key.words : "None"))
            .accessibilityHint(recording ? "Escape cancels" : "Click to record a new shortcut")
            .help(recording ? "Esc cancels" : "Click to record a new shortcut")
            if key.enabled && !recording {
                Button { clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove the shortcut")
                .accessibilityLabel("Remove the shortcut")
            }
        }
        .padding(.leading, 8).padding(.trailing, key.enabled && !recording ? 6 : 8)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.sunk))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(recording ? Color.accentColor : Ink.lineStrong, lineWidth: recording ? 2 : 0.5))
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
                row(name: "Claude Code", status: claude, icon: "sparkles", tint: MacTint.orange) {
                    problem = AgentSetup.setClaude(claude != .connected)
                    claude = AgentSetup.claude
                }
                PlateDivider()
                row(name: "Codex", status: codex, icon: "chevron.left.forwardslash.chevron.right", tint: MacTint.graphite) {
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
    private func row(name: String, status: AgentSetup.Status, icon: String, tint: Color, toggle: @escaping () -> Void) -> some View {
        PlateRow(title: name, subtitle: line(name, status), icon: icon,
                 iconColor: status == .missing || status == .taken ? MacTint.gray : tint) {
            switch status {
            case .connected:
                HStack(spacing: 10) {
                    AllowedMark(name: name, word: "Connected")
                    Button("Disconnect", action: toggle)
                }
            case .notConnected:
                Button("Connect", action: toggle).buttonStyle(.borderedProminent)
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
