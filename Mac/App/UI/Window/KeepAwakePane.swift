import Carbon.HIToolbox
import MacrophoneKit
import SwiftUI

/// Keep Awake (Nov 7 2026): one switch, one sentence of what it does, the state in plain words —
/// then the few choices, with sensible defaults so most people never open them. The power
/// features (auto-dim, external displays, the battery floor, the screen lock) are all here, but
/// none of the machinery's names: no pmset, no helper, no caffeinate.
struct KeepAwakePane: View {
    @ObservedObject var keepAwake: KeepAwakeService
    @State private var advanced = false
    @State private var confirmingRemoval = false

    private var s: KeepAwakeStatus { keepAwake.status }
    private var laptop: Bool { keepAwake.machine == .laptop }

    var body: some View {
        PanePage {
            PaneHeader(title: "Keep Awake", subtitle: KeepAwakeWords.explainer(keepAwake.machine))
            if let d = keepAwake.disagreement { disagreementBanner(d) }
            mainPlate
            // The permission's own section says the helper's problems, with its button.
            if let p = keepAwake.problem, keepAwake.disagreement == nil, p != .needsHelper, p != .helperOutdated { banner(p.text, icon: "exclamationmark.triangle.fill", color: Light.ochre, button: p.fix) { keepAwake.fix(p) } }
            ForEach(keepAwake.warnings.filter { $0 != .lowPowerMode || s.on }, id: \.self) { w in
                banner(w.text, icon: w == .hot ? "thermometer.high" : (w == .lowPowerMode ? "bolt.fill" : "battery.25percent"), color: w == .lowPowerMode ? Ink.secondary : Light.ochre, button: nil) {}
            }
            sleepSettings
            if s.hasDisplays { displays }
            if laptop { battery }
            shortcuts
            advancedSection
        }
        .task {
            // While the page shows: the helper's approval (from System Settings) turns it green by itself.
            while !Task.isCancelled {
                await keepAwake.engine.helperMayHaveChanged()
                keepAwake.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .confirmationDialog("Restore normal sleep and remove Keep Awake's permission?", isPresented: $confirmingRemoval) {
            Button("Restore and Remove", role: .destructive) { keepAwake.prepareForRemoval() }
        } message: {
            Text("Keep Awake turns off, your Mac's sleep settings and screen lock go back to how they were, and Macrophone stops being allowed to change sleep settings. Do this before you delete Macrophone.")
        }
    }

    // MARK: The switch

    private var mainPlate: some View {
        Plate {
            PlateRow(title: "Keep Awake", subtitle: keepAwake.macLine,
                     subtitleColor: s.on ? Light.mint : (s.blocked != nil ? Light.ochre : Ink.tertiary),
                     icon: s.on ? "cup.and.heat.waves.fill" : "cup.and.heat.waves", iconColor: s.on ? Light.mint : Ink.secondary) {
                if s.busy { ProgressView().controlSize(.small) }
                Toggle("", isOn: Binding(get: { s.on }, set: { on in Task { await keepAwake.setOn(on, fromMac: true) } }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(s.busy || (!s.on && s.blocked != nil))
                    .accessibilityLabel("Keep Awake")
                    .accessibilityValue(keepAwake.macLine)
            }
            if s.on, s.hasDisplays {
                PlateDivider()
                PlateRow(title: "Displays", subtitle: displaysLine, icon: s.displaysOff ? "display" : "display", iconColor: s.displaysOff ? Ink.tertiary : Ink.secondary) {
                    Button(s.displaysOff ? "Turn On" : "Turn Off Now") { keepAwake.setDisplays(off: !s.displaysOff) }
                        .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                        .help(keepAwake.displaysKey.enabled ? "Or press \(keepAwake.displaysKey.display)" : "")
                }
            }
            PlateDivider()
            PlateRow(title: "Back at desk", subtitle: timerLine, icon: "clock") {
                Menu(s.backAt == nil ? "Choose…" : "Change…") {
                    ForEach(KeepAwakeWords.timerChoices, id: \.self) { m in
                        Button("In \(KeepAwakeWords.choice(minutes: m))") { keepAwake.setTimer(minutes: m) }
                    }
                    if s.backAt != nil { Divider(); Button("Don't Turn Off Automatically") { keepAwake.setTimer(minutes: nil) } }
                }
                .fixedSize()
                .disabled(!s.on && s.blocked != nil)
            }
            if laptop, let b = s.battery {
                PlateDivider()
                PlateRow(title: "Battery", subtitle: "\(b)%\(s.charging ? " · charging" : s.onPower ? " · on power" : "")",
                         icon: s.charging ? "battery.100percent.bolt" : "battery.75percent", iconColor: b < KeepAwakeRules.lowBatteryWarning && !s.onPower ? Light.ochre : Ink.secondary)
            }
        }
    }

    private var displaysLine: String {
        if s.displaysOff {
            let since = s.displaysOffSince.map { "Off since \(KeepAwakeService.time($0))" } ?? "Off"
            return "\(since). A key or the mouse on this Mac turns them on."
        }
        if keepAwake.autoDimMinutes > 0 { return "On. They turn off after \(keepAwake.autoDimMinutes) minutes without you." }
        return "On."
    }

    private var timerLine: String {
        if let at = s.backAt { return "Keep Awake turns off at \(KeepAwakeService.time(at)) and your Mac can sleep again." }
        return "Turn Keep Awake off by itself after a while."
    }

    // MARK: The one-time permission

    @ViewBuilder private var sleepSettings: some View {
        let h = keepAwake.helper
        PaneSection(laptop ? "With the lid closed" : "Sleep settings",
                    note: laptop ? "Macrophone changes your Mac's sleep settings while Keep Awake is on and puts them back exactly as they were when it turns off."
                                 : "Optional on this Mac — it already stays awake. With this, it also stays awake if someone chooses Sleep from the Apple menu.") {
            Plate {
                switch h {
                case .ready:
                    PlateRow(title: "Macrophone can change sleep settings",
                             subtitle: laptop ? "The lid can close without your Mac going to sleep." : "Allowed.",
                             icon: "checkmark.circle.fill", iconColor: Light.mint)
                case .needsApproval:
                    PlateRow(title: "Waiting for your approval",
                             subtitle: "In System Settings › General › Login Items & Extensions, turn on Macrophone. This page turns green by itself.",
                             subtitleColor: Light.ochre, icon: "hourglass", iconColor: Light.ochre) {
                        Button("Open Login Items") { keepAwake.openLoginItems() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                    }
                case .outdated:
                    PlateRow(title: "A quick update is needed", subtitle: "Macrophone was updated; its sleep settings part needs to restart.",
                             subtitleColor: Light.ochre, icon: "arrow.triangle.2.circlepath", iconColor: Light.ochre) {
                        Button("Update") { keepAwake.fix(.helperOutdated) }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                    }
                case .notInstalled:
                    PlateRow(title: "Allow Macrophone to change sleep settings",
                             subtitle: laptop ? "One time: macOS asks you to approve it in System Settings. Until then, keep the lid open while Keep Awake is on."
                                              : "One time: macOS asks you to approve it in System Settings.",
                             icon: "lock.open", iconColor: Light.cyan) {
                        Button("Allow…") { keepAwake.allowHelper() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                    }
                }
            }
            if let e = keepAwake.helperError { PlateNote(e, color: Light.ochre) }
            if h != .ready, laptop {
                Button("Or turn it on with your administrator password, just this once") { keepAwake.turnOnWithPassword() }
                    .buttonStyle(.link).font(.system(size: 11.5)).padding(.horizontal, 4)
            }
        }
    }

    // MARK: Displays

    private var displays: some View {
        PaneSection("Displays", note: DisplayControl.betterDisplayInstalled ? nil
                    : "External displays sleep while you're away. BetterDisplay, an optional app, can turn them fully off instead — Macrophone uses it when it's installed.") {
            Plate {
                PlateRow(title: "Turn off displays", subtitle: "Any key or mouse movement on this Mac turns them back on. Using it from your iPhone doesn't.", icon: "display") {
                    Picker("", selection: $keepAwake.autoDimMinutes) {
                        ForEach([2, 5, 10, 15], id: \.self) { Text("After \($0) minutes away").tag($0) }
                        Divider()
                        Text("Right away").tag(0)
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Turn off displays")
                }
                if DisplayControl.betterDisplayInstalled {
                    PlateDivider()
                    PlateRow(title: "Turn off external displays", subtitle: "With BetterDisplay, fully off — not just asleep.", icon: "display.2") {
                        Toggle("", isOn: $keepAwake.turnOffExternals).toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel("Turn off external displays")
                    }
                }
                PlateDivider()
                PlateRow(title: "Notify me when they turn off", icon: "bell") {
                    Toggle("", isOn: $keepAwake.notifyOnDim).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Notify me when displays turn off")
                }
            }
        }
    }

    // MARK: Battery

    private var battery: some View {
        PaneSection("Battery", note: "You'll get a notification. Keep Awake also turns off if your Mac gets too hot, and tells you when the battery is below 20% or it's been on battery for a while.") {
            Plate {
                PlateRow(title: "Turn off Keep Awake at", icon: "battery.25percent") {
                    Picker("", selection: $keepAwake.lowBatteryOffAt) {
                        ForEach([5, 10, 20], id: \.self) { Text("\($0)% battery").tag($0) }
                        Divider()
                        Text("Never").tag(0)
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Turn off Keep Awake at battery level")
                }
            }
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        PaneSection("Keyboard shortcuts", note: "These work in any app. ⇧⌘G is also Finder's Go to Folder — pick another if you use that.") {
            Plate {
                KeepAwakeShortcutRow(title: "Turn Keep Awake on or off", key: $keepAwake.toggleKey,
                                     standard: KeepAwakeService.defaultToggleKey, problem: keepAwake.hotkeyProblems[KeepAwakeService.toggleKeyID],
                                     id: KeepAwakeService.toggleKeyID)
                PlateDivider()
                KeepAwakeShortcutRow(title: "Turn displays on or off", key: $keepAwake.displaysKey,
                                     standard: KeepAwakeService.defaultDisplaysKey, problem: keepAwake.hotkeyProblems[KeepAwakeService.displaysKeyID],
                                     id: KeepAwakeService.displaysKeyID)
            }
        }
    }

    // MARK: Advanced

    @ViewBuilder private var advancedSection: some View {
        Button { withAnimation(Motion.reduceMotion ? nil : Motion.snap) { advanced.toggle() } } label: {
            Label(advanced ? "Hide Advanced" : "Show Advanced", systemImage: advanced ? "chevron.down" : "chevron.right")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        if advanced {
            PaneSection(note: "Your login password is kept in this Mac's Keychain, used only to turn the screen lock off while Keep Awake is on and back on after, and never sent anywhere. While the lock is off, anyone at this Mac can use it without a password.") {
                Plate {
                    PlateRow(title: "Don't lock the screen while on",
                             subtitle: "So the screen doesn't ask for your password when the displays come back on. Needs your login password once.",
                             icon: "lock.open.display") {
                        Toggle("", isOn: $keepAwake.screenLockOff).toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel("Don't lock the screen while Keep Awake is on")
                    }
                    if keepAwake.screenLockOff, ScreenLock.hasStoredPassword {
                        PlateDivider()
                        PlateRow(title: "Password saved in your Keychain", icon: "key") {
                            Button("Forget") { keepAwake.screenLockOff = false }
                                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                        }
                    }
                    PlateDivider()
                    PlateRow(title: "Keep sound on working speakers", subtitle: "When displays with speakers turn off and on, sound moves to your Mac's speakers and back.", icon: "speaker.wave.2") {
                        Toggle("", isOn: $keepAwake.protectAudio).toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel("Keep sound on working speakers")
                    }
                }
            }
            PaneSection(note: "Use this before you delete Macrophone, so nothing it changed is left behind.") {
                Plate {
                    PlateRow(title: "Restore normal sleep and remove permission", icon: "arrow.uturn.backward.circle") {
                        Button("Remove…", role: .destructive) { confirmingRemoval = true }
                            .buttonStyle(PillButtonStyle(tint: Light.rose, filled: false))
                    }
                }
            }
            if keepAwake.dryRun {
                PlateNote("Test build: Keep Awake only writes what it would change to the diagnostics log — nothing on this Mac is changed.", color: Light.violet)
            }
        }
    }

    // MARK: Banners

    private func disagreementBanner(_ d: KeepAwakeDisagreement) -> some View {
        let restart = d == .sleepCameBack
        return Plate(padding: Space.inset) {
            HStack(alignment: .top, spacing: Space.gap) {
                Image(systemName: "moon.zzz").font(.system(size: 16, weight: .medium)).foregroundStyle(Light.ochre).frame(width: 22)
                VStack(alignment: .leading, spacing: 8) {
                    Text(restart ? "Keep Awake was on before your Mac restarted" : "Your Mac is set never to sleep")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text(restart ? "Turn it back on to keep using this Mac from your iPhone, or let it sleep normally."
                                 : "Keep Awake isn't on, but your Mac's sleep settings are still changed.")
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Restore Normal Sleep") { keepAwake.restoreNormalSleep() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: !restart))
                        Button("Resume Keep Awake") { keepAwake.keepAwakeAnyway() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: restart))
                    }
                }
            }
        }
    }

    private func banner(_ text: String, icon: String, color: Color, button: String?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: Space.gap) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(color).frame(width: 22)
            Text(text).font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let button { Button(button, action: action).buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true)) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(color.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// A shortcut for Keep Awake: click to record, ⌫ or × removes it. ⇧⌘ combinations are allowed
/// here (⌘⇧G was On The Go's), the system's own shortcuts aren't.
struct KeepAwakeShortcutRow: View {
    let title: String
    @Binding var key: Hotkey
    let standard: Hotkey
    let problem: String?
    let id: UInt32
    @State private var recording = false
    @State private var live = ""
    @State private var monitor: Any?
    @State private var why: String?

    var body: some View {
        PlateRow(title: title, subtitle: why ?? problem ?? (recording ? "Press the keys, holding ⌘, ⌥ or ⌃. Esc cancels; Delete removes it." : nil),
                 subtitleColor: (why ?? problem) != nil ? Light.ochre : Ink.tertiary, icon: "keyboard") {
            HStack(spacing: 8) {
                if !recording, key != standard {
                    Button("Use \(standard.display)") { key = standard }
                        .buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                }
                Button { recording ? stop() : start() } label: {
                    Text(recording ? (live.isEmpty ? "Type Shortcut" : live) : (key.enabled ? key.display : "None"))
                        .font(recording || !key.enabled ? .system(size: 12, weight: .medium) : Typeface.mono(12.5, .semibold))
                        .foregroundStyle(recording ? Light.teal : (key.enabled ? Ink.ink : Ink.secondary))
                        .frame(minWidth: 96).padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .background(Capsule().fill(recording ? Light.teal.opacity(0.10) : Ink.sunk))
                .overlay(Capsule().strokeBorder(recording ? Light.teal.opacity(0.7) : Ink.lineHeavy, lineWidth: 1))
                .accessibilityLabel(title)
                .accessibilityValue(key.enabled ? key.words : "None")
                if key.enabled, !recording {
                    Button { key.enabled = false } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Ink.tertiary) }
                        .buttonStyle(.plain).help("Remove the shortcut").accessibilityLabel("Remove the shortcut")
                }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        why = nil
        live = ""
        recording = true
        // Let the current shortcut reach the recorder instead of firing.
        HotkeyCenter.shared.register(id: id, Hotkey(keyCode: 0, modifiers: 0, enabled: false)) {}
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            let mods = Hotkey.carbonModifiers(e.modifierFlags.intersection([.command, .option, .control, .shift]))
            if e.type == .flagsChanged { live = Hotkey.symbols(mods); return e }
            if Int(e.keyCode) == kVK_Escape, mods == 0 { stop(); return nil }
            if [kVK_Delete, kVK_ForwardDelete].contains(Int(e.keyCode)), mods == 0 { key.enabled = false; stop(); return nil }
            let cmd = UInt32(cmdKey), opt = UInt32(optionKey), ctl = UInt32(controlKey)
            var problem: String?
            if mods & (cmd | opt | ctl) == 0 { problem = "Add ⌘, ⌥ or ⌃ so it doesn't get in the way of typing." }
            else if mods & (cmd | ctl) == 0 { problem = "That types a character. Add ⌘ or ⌃." }
            else if mods & (opt | ctl) != 0 { problem = Hotkey.conflict(keyCode: UInt32(e.keyCode), modifiers: mods) }
            if let problem { NSSound.beep(); why = problem; live = ""; return nil }
            key = Hotkey(keyCode: UInt32(e.keyCode), modifiers: mods, enabled: true)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            // Put the shortcut back (setting `key` re-registers; an unchanged one needs a nudge).
            let k = key
            key = k
        }
        live = ""
    }
}
