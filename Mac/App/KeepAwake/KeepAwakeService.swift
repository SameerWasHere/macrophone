import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import MacrophoneKit
import ServiceManagement

/// Keep Awake in the Mac app (Nov 7 2026): the engine (MacrophoneKit's KeepAwakeEngine), its
/// timers, its settings, the hot keys, the phones, the launch-time question and the one-time
/// helper step. The page, the menu, the API and the phone all read `status` and call in here.
@MainActor
final class KeepAwakeService: ObservableObject {
    static let toggleKeyID: UInt32 = 20
    static let displaysKeyID: UInt32 = 21

    let system: KeepAwakeMacSystem
    let engine: KeepAwakeEngine
    private let log: DiagnosticLog
    private let d = AppPaths.defaults

    @Published private(set) var status = KeepAwakeStatus()
    @Published private(set) var helper: KeepAwakeHelperState = .notInstalled
    @Published private(set) var problem: KeepAwakeProblem?
    @Published private(set) var disagreement: KeepAwakeDisagreement?
    @Published private(set) var warnings: [KeepAwakeWarning] = []
    /// Words for a hot key another app owns, by id.
    @Published private(set) var hotkeyProblems: [UInt32: String] = [:]
    /// The helper step is open (System Settings waits for the person): look every 2 s.
    @Published private(set) var awaitingApproval = false
    @Published private(set) var helperError: String?

    // Settings — the defaults are what most people want, so most never open them.
    @Published var autoDimMinutes: Int { didSet { d.set(autoDimMinutes, forKey: "keepAwake.autoDim"); prefsChanged() } }
    @Published var turnOffExternals: Bool { didSet { d.set(turnOffExternals, forKey: "keepAwake.externals") } }
    @Published var protectAudio: Bool { didSet { d.set(protectAudio, forKey: "keepAwake.protectAudio") } }
    @Published var notifyOnDim: Bool { didSet { d.set(notifyOnDim, forKey: "keepAwake.notifyOnDim") } }
    @Published var lowBatteryOffAt: Int { didSet { d.set(lowBatteryOffAt, forKey: "keepAwake.lowBatteryOff") } }
    @Published var screenLockOff: Bool { didSet { d.set(screenLockOff, forKey: "keepAwake.screenLockOff"); if !screenLockOff { ScreenLock.forget() } } }
    @Published var toggleKey: Hotkey { didSet { save(toggleKey, "keepAwake.toggleKey"); applyHotkeys() } }
    @Published var displaysKey: Hotkey { didSet { save(displaysKey, "keepAwake.displaysKey"); applyHotkeys() } }

    /// ⌘⇧G and ⌘⇧D, as On The Go had them (settable, or off).
    static let defaultToggleKey = Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey), enabled: true)
    static let defaultDisplaysKey = Hotkey(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | shiftKey), enabled: true)

    var onStatus: (KeepAwakeStatus) -> Void = { _ in }
    private var timers: [Timer] = []
    private var approvalTimer: Timer?
    private var powerSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    init(log: DiagnosticLog) {
        self.log = log
        let dry = KeepAwakeMacSystem.dryRunDefault
        system = KeepAwakeMacSystem(log: log, dryRun: dry)
        let defaults = AppPaths.defaults
        autoDimMinutes = defaults.object(forKey: "keepAwake.autoDim") as? Int ?? 5
        turnOffExternals = defaults.object(forKey: "keepAwake.externals") as? Bool ?? true
        protectAudio = defaults.object(forKey: "keepAwake.protectAudio") as? Bool ?? true
        notifyOnDim = defaults.object(forKey: "keepAwake.notifyOnDim") as? Bool ?? true
        lowBatteryOffAt = defaults.object(forKey: "keepAwake.lowBatteryOff") as? Int ?? 10
        screenLockOff = defaults.bool(forKey: "keepAwake.screenLockOff")
        toggleKey = Self.load("keepAwake.toggleKey", defaults) ?? Self.defaultToggleKey
        displaysKey = Self.load("keepAwake.displaysKey", defaults) ?? Self.defaultDisplaysKey
        var prefsBox: () -> KeepAwakePrefs = { KeepAwakePrefs() }
        engine = KeepAwakeEngine(system: system, store: KeepAwakeFileStore(), prefs: { prefsBox() })
        prefsBox = { [weak self] in self?.prefs ?? KeepAwakePrefs() }
        engine.prefs = prefsBox
        #if DEBUG
        let printing = ProcessInfo.processInfo.environment["MACROPHONE_AWAKE_PRINT"] == "1"
        engine.log = { line in log.add(line); if printing { print("AWAKE: \(line)"); fflush(stdout) } }
        #else
        engine.log = { log.add($0) }
        #endif
        engine.onChange = { [weak self] in self?.refresh() }
        #if DEBUG
        if let m = ProcessInfo.processInfo.environment["MACROPHONE_AWAKE_MINUTE"].flatMap(Double.init) { engine.minute = m }
        #endif
        if dry { log.add("keep awake: dry run — nothing on this Mac is changed, every change is logged") }
    }

    private var prefs: KeepAwakePrefs {
        KeepAwakePrefs(autoDimMinutes: autoDimMinutes, turnOffExternals: turnOffExternals, screenLockOff: screenLockOff,
                       lowBatteryOffAt: lowBatteryOffAt, notifyOnDim: notifyOnDim)
    }

    var dryRun: Bool { system.dryRun }
    var machine: MachineKind { system.machine }

    // MARK: Start

    func start() {
        system.input.onPhysicalInput = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.engine.physicalInput()
                if self.engine.record.displaysOff { self.system.input.armed = true }
            }
        }
        applyHotkeys()
        Task { @MainActor in
            let decision = await engine.launch()
            if engine.isOn { system.audio.start() }
            // Resumed with the displays dark (a force-quit): the first touch still brings them back.
            if engine.isOn, engine.record.displaysOff { system.input.armed = true }
            if case .ask = decision { askAboutDisagreement() }
            if !dryRun { _ = await PowerHelperClient.shared.checkVersion() }
            await engine.helperMayHaveChanged()
            refresh()
            #if DEBUG
            await debugActions()
            #endif
        }
        // Every 30 s: the timer, the battery and heat, auto-dim. Every 5 minutes: the watchdog.
        let tick = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A shortcut another app held (SameerOS's ⌘⇧G until it quits) is tried again.
                if !self.hotkeyProblems.isEmpty { self.applyHotkeys() }
                Task { await self.engine.tick(); await self.engine.idleCheck(); self.refresh() }
            }
        }
        tick.tolerance = 5
        let watchdog = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; Task { await self.engine.watchdog() } }
        }
        watchdog.tolerance = 20
        timers = [tick, watchdog]
        timers.forEach { RunLoop.main.add($0, forMode: .common) }
        #if DEBUG
        // A proof with short minutes looks every second.
        if engine.minute < 60 {
            let fast = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; Task { await self.engine.tick(); await self.engine.idleCheck() } }
            }
            RunLoop.main.add(fast, forMode: .common)
            timers.append(fast)
        }
        #endif
        powerSource = MachinePower.observe { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { guard let self else { return }; Task { await self.engine.powerCheck() } } }
        }
        let nc = NotificationCenter.default
        let check: @Sendable (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { guard let self else { return }; Task { await self.engine.powerCheck() } } }
        }
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil, using: check))
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil, using: check))
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; Task { await self.engine.helperMayHaveChanged() } }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; Task { await self.engine.watchdog() } }
        })
    }

    // MARK: What everyone calls

    /// The switch, the menu, ⌘⇧G. On the Mac, the person is there: the password route is allowed
    /// only as a deliberate second step (the helper step offers it), never as the first thing.
    func toggle() { Task { await setOn(!engine.isOn, fromMac: true) } }

    func setOn(_ on: Bool, fromMac: Bool) async {
        if on {
            let r = await engine.turnOn(allowPassword: false, mayAsk: fromMac)
            if r == .on || r == .onWithoutLid { system.audio.start() }
        } else {
            // Turning off from the Mac may fall back to the password when the helper is gone;
            // from the phone or the API it never does (nobody may be there to answer).
            if await engine.turnOff(reason: .asked, allowPassword: fromMac) { system.audio.stop() }
        }
        refresh()
    }

    func setDisplays(off: Bool) { Task { await engine.setDisplays(off: off); refresh() } }
    func toggleDisplays() { Task { await engine.toggleDisplays(); refresh() } }
    func setTimer(minutes: Int?) { Task { await engine.setTimer(minutes: minutes); if engine.isOn { system.audio.start() }; refresh() } }
    func restoreNormalSleep() { Task { await engine.restoreNormalSleep(allowPassword: true); refresh() } }
    func keepAwakeAnyway() { Task { await engine.resolve(.keepAwake); refresh() } }
    func reconnectDisplays() { Task { await engine.reconnectDisplays(); refresh() } }

    /// "Turn On with Your Password Instead": for someone who'd rather not add the helper — the
    /// system's administrator dialog, this once.
    func turnOnWithPassword() {
        Task {
            if engine.isOn { await engine.turnOff(reason: .asked, allowPassword: true) }
            let r = await engine.turnOn(allowPassword: true, mayAsk: true)
            if r == .on || r == .onWithoutLid { system.audio.start() }
            refresh()
        }
    }

    /// The problem's button.
    func fix(_ p: KeepAwakeProblem) {
        switch p {
        case .needsHelper, .helperGone: allowHelper()
        case .helperOutdated:
            Task { await PowerHelperClient.shared.checkVersion(); await engine.helperMayHaveChanged(); await engine.watchdog(); refresh() }
        case .powerFailed: Task { await engine.watchdog(); refresh() }
        case .restoreFailed: restoreNormalSleep()
        case .lockNeedsPassword:
            Task { await engine.turnOff(reason: .asked, allowPassword: true); await engine.turnOn(mayAsk: true); refresh() }
        case .lockRefused:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")!)
        case .displaysStuck: reconnectDisplays()
        case .batteryTooLow, .tooHot: Task { await setOn(true, fromMac: true) }
        }
    }

    // MARK: The helper, as a guided step

    /// "Allow Macrophone to change sleep settings": registers the helper (macOS opens Login Items
    /// for the approval) and then looks every 2 s until it's on — the page turns green by itself.
    func allowHelper() {
        helperError = nil
        if dryRun {
            log.add("keep awake (dry run): would register the helper and open Login Items")
            return
        }
        helperError = PowerHelperClient.shared.register()
        log.add("keep awake: helper registered — \(PowerHelperClient.shared.state.rawValue)")
        watchApproval()
    }

    func openLoginItems() { SMAppServiceOpener.open() }

    private func watchApproval() {
        approvalTimer?.invalidate()
        awaitingApproval = PowerHelperClient.shared.state != .ready
        guard awaitingApproval else { Task { await engine.helperMayHaveChanged(); refresh() }; return }
        var ticks = 0
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                ticks += 1
                let s = PowerHelperClient.shared.state
                if s == .ready || ticks > 300 {
                    timer.invalidate()
                    self.awaitingApproval = false
                    Task { await PowerHelperClient.shared.checkVersion(); await self.engine.helperMayHaveChanged(); self.refresh() }
                }
                self.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        approvalTimer = t
    }

    /// Uninstall: normal sleep back, the screen lock as it was, the password forgotten, the helper
    /// unregistered. Then Macrophone can be dragged to the Trash with nothing left changed.
    func prepareForRemoval() {
        Task {
            let ok = await engine.prepareForRemoval()
            if ok { ScreenLock.forget(); screenLockOff = false; system.audio.stop() }
            refresh()
        }
    }

    // MARK: Status

    func refresh() {
        let s = engine.status()
        helper = engine.helper
        problem = engine.problem
        disagreement = engine.disagreement
        warnings = engine.warnings
        if s != status {
            status = s
            onStatus(s)
        }
        objectWillChange.send()
    }

    /// Seconds without a real key or click, while watching.
    var idleSeconds: TimeInterval? { engine.idleSeconds }
    var isOn: Bool { status.on }

    /// "Displays off · idle 3m" for the menu.
    var displaysLine: String {
        KeepAwakeWords.displaysLine(off: status.displaysOff, idle: idleSeconds, autoDimMinutes: autoDimMinutes)
    }

    var macLine: String { KeepAwakeWords.macLine(status, time: Self.time) }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: d)
    }

    // MARK: Hot keys

    private func applyHotkeys() {
        var problems: [UInt32: String] = [:]
        if let p = HotkeyCenter.shared.register(id: Self.toggleKeyID, toggleKey, action: { [weak self] in
            self?.log.add("keep awake: \(self?.toggleKey.display ?? "") pressed")
            self?.toggle()
        }) { problems[Self.toggleKeyID] = p }
        if let p = HotkeyCenter.shared.register(id: Self.displaysKeyID, displaysKey, action: { [weak self] in
            guard let self, self.engine.isOn else { return }
            self.toggleDisplays()
        }) { problems[Self.displaysKeyID] = p }
        hotkeyProblems = problems
    }

    private func save(_ k: Hotkey, _ key: String) { d.set(try? JSONEncoder().encode(k), forKey: key) }
    private static func load(_ key: String, _ d: UserDefaults) -> Hotkey? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
    }

    private func prefsChanged() {
        Task {
            if engine.isOn {
                if autoDimMinutes > 0 { system.startInputWatch() } else if !engine.record.displaysOff { system.stopInputWatch() }
            }
            refresh()
        }
    }

    // MARK: Questions

    /// At launch, when the record and the Mac disagree: the person decides (never silently).
    func askAboutDisagreement() {
        guard let d = disagreement ?? engine.disagreement else { return }
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let answer = env["MACROPHONE_AWAKE_RESOLVE"] {
            Task { await engine.resolve(answer == "keep" ? .keepAwake : .restoreSleep, allowPassword: false); refresh() }
            return
        }
        // A dry run never takes the screen with an alert unless asked (MACROPHONE_AWAKE_ALERT=1).
        if dryRun, env["MACROPHONE_AWAKE_ALERT"] != "1" { log.add("keep awake (dry run): would ask \(d.rawValue)"); return }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let alert = NSAlert()
                switch d {
                case .sleepCameBack:
                    alert.messageText = "Keep Awake was on before your Mac restarted"
                    alert.informativeText = "Turn it back on to keep using this Mac from your iPhone, or let your Mac sleep normally."
                    alert.addButton(withTitle: "Resume Keep Awake")
                    alert.addButton(withTitle: "Restore Normal Sleep")
                case .sleepOffWithoutUs:
                    alert.messageText = "Your Mac is set never to sleep"
                    alert.informativeText = "Keep Awake isn't on, but your Mac's sleep settings are still changed — probably left over from before Macrophone quit."
                    alert.addButton(withTitle: "Restore Normal Sleep")
                    alert.addButton(withTitle: "Resume Keep Awake")
                }
                NSApp.activate(ignoringOtherApps: true)
                let first = alert.runModal() == .alertFirstButtonReturn
                let keep = (d == .sleepCameBack) == first
                if keep { self.keepAwakeAnyway() } else { self.restoreNormalSleep() }
            }
        }
    }

    /// Quitting from the menu with sleep settings changed: they stay changed after Macrophone
    /// quits, so ask. True: go ahead and quit.
    func confirmQuit() -> Bool {
        guard engine.isOn, engine.record.powerApplied else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep Awake is on"
        alert.informativeText = "If you quit, your Mac keeps its Keep Awake sleep settings and won't sleep until you open Macrophone and turn Keep Awake off."
        alert.addButton(withTitle: "Turn Off and Quit")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                await engine.turnOff(reason: .asked, allowPassword: true)
                NSApp.terminate(nil)
            }
            return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
}

#if DEBUG
extension KeepAwakeService {
    /// MACROPHONE_AWAKE_ACTIONS=on,wait@3,displaysoff,input,displayson,timer@2,tick,watchdog,
    /// power,off,restore,remove,status — the same calls the switch, the menu, the phone and the
    /// timers make, one after another, each line to the log (and stdout with MACROPHONE_AWAKE_PRINT=1).
    func debugActions() async {
        guard let spec = ProcessInfo.processInfo.environment["MACROPHONE_AWAKE_ACTIONS"] else { return }
        for step in spec.split(separator: ",").map(String.init) {
            let parts = step.split(separator: "@").map(String.init)
            let arg = parts.dropFirst().first.flatMap(Double.init)
            switch parts[0] {
            case "on": await setOn(true, fromMac: true)
            case "phoneon": await setOn(true, fromMac: false)
            case "off": await setOn(false, fromMac: true)
            case "phoneoff": await setOn(false, fromMac: false)
            case "displaysoff": await engine.setDisplays(off: true)
            case "displayson": await engine.setDisplays(off: false)
            case "input": await engine.physicalInput()
            case "timer": await engine.setTimer(minutes: Int(arg ?? 1))
            case "tick": await engine.tick()
            case "idle": await engine.idleCheck()
            case "watchdog": await engine.watchdog()
            case "power": await engine.powerCheck()
            case "restore": await engine.restoreNormalSleep(allowPassword: false)
            case "keep": await engine.resolve(.keepAwake)
            case "remove": _ = await engine.prepareForRemoval()
            case "wait": try? await Task.sleep(nanoseconds: UInt64((arg ?? 1) * 1e9))
            case "status": break
            default: continue
            }
            refresh()
            let line = "after \(step): \(macLine)\(problem.map { " · problem: \($0.text)" } ?? "")\(status.warning.map { " · warning: \($0)" } ?? "")\(status.sleepStillOff ? " · sleep still off" : "")"
            log.add("keep awake: \(line)")
            if ProcessInfo.processInfo.environment["MACROPHONE_AWAKE_PRINT"] == "1" { print("AWAKE: \(line)"); fflush(stdout) }
        }
    }
}
#endif

/// System Settings › General › Login Items & Extensions.
enum SMAppServiceOpener {
    static func open() { SMAppService.openSystemSettingsLoginItems() }
}
