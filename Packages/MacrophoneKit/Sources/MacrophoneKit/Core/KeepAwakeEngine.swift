import Foundation

// Keep Awake's state machine (Nov 7 2026). Every decision On The Go made — what to back up, when
// to resume, what the watchdog fixes, when the displays go dark and come back — lives here, with
// the machine behind a protocol (`KeepAwakeSystem`) so the tests drive it with a fake and the
// Mac app with the real thing (or, in a DEBUG build, a dry run that only says what it would do).
//
// The rules that make it safe on a stranger's Mac:
//   - The record is written before anything changes (phase turningOn / turningOff), so a crash
//     or a force-quit mid-way is always recoverable at the next launch (`recover`).
//   - The Mac is never left unable to sleep without saying so: if Keep Awake isn't on but sleep
//     is off, `disagreement` is set — the menu bar, the page and the phone all show it with one
//     button that restores normal sleep.
//   - Nothing privileged runs from a timer with a password: the watchdog only uses the helper.
//   - Power settings are backed up per source (battery and charger) and put back exactly.
//   - Another app keeping the Mac awake (SameerOS's On The Go) is never fought.

public enum KeepAwakeHelperState: String, Equatable, Sendable {
    /// Installed, approved, answering at our version.
    case ready
    case notInstalled
    /// Registered; macOS waits for the person in System Settings › Login Items.
    case needsApproval
    /// Answering at an older version (an update of Macrophone, the old daemon still running).
    case outdated
}

public enum KeepAwakeApply: Equatable, Sendable {
    case done
    /// No helper to do it (and the password route wasn't allowed).
    case needsHelper
    /// The person cancelled the password dialog.
    case cancelled
    case failed(String)
}

public enum KeepAwakeLock: Equatable, Sendable {
    /// Turned off; the setting it had, to put back.
    case changed(before: String)
    case alreadyOff
    case noPassword
    case refused(String)
    case restored
}

public enum KeepAwakeTurnOn: Equatable, Sendable {
    case on
    /// On, but the lid will still sleep the laptop (no way to change sleep settings yet).
    case onWithoutLid
    case blocked(String)
    case cancelled
    case busy
}

public enum KeepAwakeOffReason: String, Sendable {
    case asked, timer, lowBattery, tooHot
    /// Finishing a turn-off the last run didn't (a crash, a force-quit): tears down even when the
    /// settings can't be put back, and says so as a sleep setting to restore.
    case finish
}

/// The record and the machine don't agree — only a person can say which is right.
public enum KeepAwakeDisagreement: String, Equatable, Sendable {
    /// Keep Awake was on, but sleep came back (a restart resets it, or a macOS update).
    case sleepCameBack
    /// Keep Awake is off, but the Mac is set never to sleep.
    case sleepOffWithoutUs
}

public enum KeepAwakeChoice: Sendable { case restoreSleep, keepAwake }

/// What `recover` decided at launch.
public enum KeepAwakeRecovery: Equatable, Sendable {
    case nothing
    /// Keep Awake was on and still is: hold on again, quietly.
    case resume
    /// It was turning off when the app stopped: finish.
    case finishOff
    /// Leftovers (a dimmed screen, an unplugged display) with nothing on: put them back.
    case cleanUp
    case ask(KeepAwakeDisagreement)
    /// Another app keeps the Mac awake now: let go of ours, touch nothing of theirs.
    case standDown
}

public enum KeepAwakeProblem: Equatable, Sendable {
    case needsHelper, helperGone, helperOutdated, powerFailed, restoreFailed
    case lockNeedsPassword, lockRefused, displaysStuck(Int)

    /// What's wrong, in a sentence.
    public var text: String {
        switch self {
        case .needsHelper: return "Keep the lid open for now — to let it close, allow Macrophone to change sleep settings."
        case .helperGone: return "Macrophone can't change sleep settings any more, so closing the lid would put your Mac to sleep."
        case .helperOutdated: return "Macrophone's sleep settings helper needs a quick update."
        case .powerFailed: return "macOS didn't accept the sleep settings, so keep the lid open."
        case .restoreFailed: return "Your Mac is still set never to sleep — Macrophone couldn't put the settings back."
        case .lockNeedsPassword: return "The screen will still lock — Macrophone needs your login password to turn the lock off."
        case .lockRefused: return "macOS wouldn't turn the screen lock off. Changing your login password once in System Settings › Users & Groups usually fixes it."
        case .displaysStuck(let n): return "\(n == 1 ? "A display" : "\(n) displays") didn't turn back on."
        }
    }

    /// The button that fixes it on the Mac.
    public var fix: String {
        switch self {
        case .needsHelper: return "Allow…"
        case .helperGone: return "Allow Again…"
        case .helperOutdated: return "Update"
        case .powerFailed: return "Try Again"
        case .restoreFailed: return "Restore Normal Sleep"
        case .lockNeedsPassword: return "Enter Password…"
        case .lockRefused: return "Open Users & Groups"
        case .displaysStuck: return "Turn Displays On"
        }
    }
}

public struct KeepAwakePrefs: Equatable, Sendable {
    /// Displays go off after this long without a key or click (0 = off: they go off at once).
    public var autoDimMinutes: Int
    /// Turn external displays off with BetterDisplay when it's installed (else they sleep).
    public var turnOffExternals: Bool
    /// Turn the screen lock off while on (needs the login password; opt-in).
    public var screenLockOff: Bool
    /// Turn itself off on battery at this level (0 = never).
    public var lowBatteryOffAt: Int
    public var notifyOnDim: Bool

    public init(autoDimMinutes: Int = 5, turnOffExternals: Bool = true, screenLockOff: Bool = false,
                lowBatteryOffAt: Int = 10, notifyOnDim: Bool = true) {
        self.autoDimMinutes = autoDimMinutes
        self.turnOffExternals = turnOffExternals
        self.screenLockOff = screenLockOff
        self.lowBatteryOffAt = lowBatteryOffAt
        self.notifyOnDim = notifyOnDim
    }
}

/// What survives a quit, a crash and a restart.
public struct KeepAwakeRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case off, turningOn, on, turningOff }

    public var phase: Phase = .off
    public var since: Date?
    /// Sleep settings were changed by Keep Awake (and must be put back).
    public var powerApplied = false
    /// The settings before the change, per source.
    public var powerBackup: PowerProfile?
    /// The built-in display's brightness before it was dimmed.
    public var brightness: Float?
    /// External displays turned off (BetterDisplay ids) and not yet back.
    public var disconnected: [String] = []
    public var displaysOff = false
    public var displaysOffSince: Date?
    public var autoDimmed = false
    public var backAt: Date?
    /// The screen lock was turned off by Keep Awake, and what it was.
    public var lockChanged = false
    public var lockBefore: String?
    public var onBatterySince: Date?
    /// Warnings already told this time on (each once).
    public var told: [String] = []
    public var reconnectTries = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case phase, since, powerApplied, powerBackup, brightness, disconnected, displaysOff, displaysOffSince
        case autoDimmed, backAt, lockChanged, lockBefore, onBatterySince, told, reconnectTries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = (try? c.decodeIfPresent(Phase.self, forKey: .phase)) ?? .off
        since = try? c.decodeIfPresent(Date.self, forKey: .since)
        powerApplied = (try? c.decodeIfPresent(Bool.self, forKey: .powerApplied)) ?? false
        powerBackup = try? c.decodeIfPresent(PowerProfile.self, forKey: .powerBackup)
        brightness = try? c.decodeIfPresent(Float.self, forKey: .brightness)
        disconnected = (try? c.decodeIfPresent([String].self, forKey: .disconnected)) ?? []
        displaysOff = (try? c.decodeIfPresent(Bool.self, forKey: .displaysOff)) ?? false
        displaysOffSince = try? c.decodeIfPresent(Date.self, forKey: .displaysOffSince)
        autoDimmed = (try? c.decodeIfPresent(Bool.self, forKey: .autoDimmed)) ?? false
        backAt = try? c.decodeIfPresent(Date.self, forKey: .backAt)
        lockChanged = (try? c.decodeIfPresent(Bool.self, forKey: .lockChanged)) ?? false
        lockBefore = try? c.decodeIfPresent(String.self, forKey: .lockBefore)
        onBatterySince = try? c.decodeIfPresent(Date.self, forKey: .onBatterySince)
        told = (try? c.decodeIfPresent([String].self, forKey: .told)) ?? []
        reconnectTries = (try? c.decodeIfPresent(Int.self, forKey: .reconnectTries)) ?? 0
    }

    /// Something of Keep Awake's is still changed on the machine.
    var hasLeftovers: Bool { brightness != nil || !disconnected.isEmpty || displaysOff || lockChanged }
}

@MainActor
public protocol KeepAwakeStore: AnyObject {
    func load() -> KeepAwakeRecord?
    func save(_ record: KeepAwakeRecord)
}

/// The machine, as Keep Awake needs it. Reads are always real; the Mac app's dry run logs every
/// change instead of making it.
@MainActor
public protocol KeepAwakeSystem: AnyObject {
    var machine: MachineKind { get }
    /// `pmset -g`.
    func pmsetSummary() -> String
    /// `pmset -g custom`.
    func pmsetCustom() -> String
    func power() -> PowerSnapshot
    func helperState() -> KeepAwakeHelperState
    /// Changes sleep settings through the helper; with `allowPassword`, through the system's
    /// administrator dialog when there's no helper (only ever when the person just clicked).
    func apply(_ changes: [PowerChange], allowPassword: Bool) async -> KeepAwakeApply
    /// The power assertions caffeinate -s -i -d would take, held by this process (they end with it).
    func holdAssertions()
    func releaseAssertions()
    var assertionsHeld: Bool { get }
    var hasBuiltInDisplay: Bool { get }
    /// Any display at all (a headless mini has none).
    var hasDisplays: Bool { get }
    func builtInBrightness() -> Float?
    func setBuiltInBrightness(_ level: Float)
    var betterDisplayInstalled: Bool { get }
    /// Turns the displays off (the built-in is already dark): externals unplugged virtually when
    /// asked and possible, else every display asleep. Returns the ids unplugged.
    func displaysOff(unplugExternals: Bool) async -> [String]
    /// Plugs those back in; returns the ids still off.
    func displaysOn(reconnect: [String]) async -> [String]
    func wakeDisplays()
    /// Keeps sound on a living output while displays come and go.
    func protectAudio(_ on: Bool)
    /// nil when it can't be read.
    func screenLockIsOff() -> Bool?
    func screenLockOff(mayAsk: Bool) async -> KeepAwakeLock
    func screenLockRestore(to before: String) async -> KeepAwakeLock
    @discardableResult func startInputWatch() -> Bool
    func stopInputWatch()
    var inputWatching: Bool { get }
    var lastPhysicalInput: Date? { get }
    func ignoreInput(until: Date)
    func notify(_ title: String, _ body: String)
    /// Words when another app keeps the Mac awake (SameerOS's On The Go).
    func otherKeeper() -> String?
    /// Unregisters the helper (uninstall).
    func removeHelper() -> Bool
}

@MainActor
public final class KeepAwakeEngine {
    public let system: KeepAwakeSystem
    private let store: KeepAwakeStore
    public var prefs: () -> KeepAwakePrefs
    private let now: () -> Date
    public var log: (String) -> Void = { _ in }
    public var onChange: () -> Void = {}

    public private(set) var record: KeepAwakeRecord
    public private(set) var busy = false
    public private(set) var disagreement: KeepAwakeDisagreement?
    public private(set) var problem: KeepAwakeProblem?
    public private(set) var warnings: [KeepAwakeWarning] = []
    public private(set) var power = PowerSnapshot()
    public private(set) var blockedBy: String?
    public private(set) var helper: KeepAwakeHelperState = .notInstalled

    /// Input within this long after the displays go dark isn't him (the hot key's release, the
    /// cursor shuffle a display unplug causes).
    public static let ignoreAfterDim: TimeInterval = 6
    /// Tries to plug a display back in before telling him.
    public static let reconnectTries = 3

    public init(system: KeepAwakeSystem, store: KeepAwakeStore, prefs: @escaping () -> KeepAwakePrefs,
                now: @escaping () -> Date = Date.init) {
        self.system = system
        self.store = store
        self.prefs = prefs
        self.now = now
        self.record = store.load() ?? KeepAwakeRecord()
    }

    public var isOn: Bool { record.phase == .on }
    private var machine: MachineKind { system.machine }

    private func save() { store.save(record) }
    private func changed() { onChange() }

    // MARK: - Launch

    /// What the record and the machine say together at launch.
    public nonisolated static func recover(_ r: KeepAwakeRecord, sleepDisabled: Bool?, other: String?) -> KeepAwakeRecovery {
        if other != nil {
            return r.phase == .off && !r.hasLeftovers && !r.powerApplied ? .nothing : .standDown
        }
        switch r.phase {
        case .on:
            return r.powerApplied && sleepDisabled == false ? .ask(.sleepCameBack) : .resume
        case .turningOn:
            return sleepDisabled == true ? .resume : .cleanUp
        case .turningOff:
            return r.powerApplied && sleepDisabled == true ? .finishOff : .cleanUp
        case .off:
            if sleepDisabled == true { return .ask(.sleepOffWithoutUs) }
            return r.hasLeftovers || r.powerApplied ? .cleanUp : .nothing
        }
    }

    /// Once, at launch: picks up where the last run left off.
    @discardableResult
    public func launch() async -> KeepAwakeRecovery {
        power = system.power()
        helper = system.helperState()
        blockedBy = system.otherKeeper()
        let disabled = PMSet.sleepDisabled(system.pmsetSummary())
        let decision = Self.recover(record, sleepDisabled: disabled, other: blockedBy)
        log("keep awake: launch — was \(record.phase.rawValue), sleep \(disabled.map { $0 ? "off" : "normal" } ?? "unknown"), \(machine.rawValue), helper \(helper.rawValue) → \(decision)")
        switch decision {
        case .nothing:
            break
        case .resume:
            if record.phase == .turningOn { record.powerApplied = true }
            record.phase = .on
            if record.since == nil { record.since = now() }
            await startProtections(mayAsk: false)
            if helper != .ready, machine == .laptop, !record.powerApplied { problem = .needsHelper }
            save()
        case .finishOff:
            record.phase = .on
            await turnOff(reason: .finish, allowPassword: false)
        case .cleanUp:
            await putDisplaysBack()
            if record.lockChanged, let before = record.lockBefore { _ = await system.screenLockRestore(to: before) }
            let stuck = record.disconnected
            record = KeepAwakeRecord()
            record.disconnected = stuck
            save()
        case .ask(let d):
            disagreement = d
            // Hold nothing while asking: the person decides.
            record.phase = .off
            save()
        case .standDown:
            await putDisplaysBack()
            record = KeepAwakeRecord()
            save()
        }
        changed()
        return decision
    }

    // MARK: - On

    @discardableResult
    public func turnOn(allowPassword: Bool = false, mayAsk: Bool = true) async -> KeepAwakeTurnOn {
        guard !busy else { return .busy }
        guard !isOn else { return record.powerApplied || machine == .desktop ? .on : .onWithoutLid }
        blockedBy = system.otherKeeper()
        if let b = blockedBy {
            log("keep awake: not turned on — another app keeps the Mac awake")
            changed()
            return .blocked(b)
        }
        busy = true
        disagreement = nil
        problem = nil
        changed()
        let disabledNow = PMSet.sleepDisabled(system.pmsetSummary()) == true
        if record.powerBackup == nil, !disabledNow {
            let profile = PMSet.parseCustom(system.pmsetCustom())
            if !profile.isEmpty { record.powerBackup = profile }
        }
        record.phase = .turningOn
        save()
        helper = system.helperState()
        let result = await system.apply(PMSet.enableChanges(machine: machine), allowPassword: allowPassword)
        switch result {
        case .done:
            record.powerApplied = true
        case .needsHelper:
            // Still useful: the Mac won't idle-sleep while it's open (and a desktop needs no more).
            if machine == .laptop { problem = helper == .outdated ? .helperOutdated : .needsHelper }
        case .cancelled:
            record.phase = .off
            if !record.powerApplied { record.powerBackup = nil }
            save()
            busy = false
            log("keep awake: turning on cancelled")
            changed()
            return .cancelled
        case .failed:
            if machine == .laptop { problem = .powerFailed }
        }
        power = system.power()
        record.phase = .on
        record.since = now()
        record.told = []
        record.onBatterySince = power.onBattery ? now() : nil
        record.reconnectTries = 0
        await startProtections(mayAsk: mayAsk)
        save()
        busy = false
        log("keep awake: on — sleep settings \(record.powerApplied ? "changed" : "unchanged (\(result))"), auto-dim \(prefs().autoDimMinutes)m")
        if prefs().autoDimMinutes == 0, system.hasDisplays {
            await displaysOff(auto: false)
        }
        refreshWarnings()
        changed()
        return record.powerApplied || machine == .desktop ? .on : .onWithoutLid
    }

    private func startProtections(mayAsk: Bool) async {
        system.holdAssertions()
        if prefs().screenLockOff { await lockOff(mayAsk: mayAsk) }
        if prefs().autoDimMinutes > 0 { system.startInputWatch() }
    }

    private func lockOff(mayAsk: Bool) async {
        switch await system.screenLockOff(mayAsk: mayAsk) {
        case .changed(let before):
            if !record.lockChanged { record.lockBefore = before }
            record.lockChanged = true
            if problem == .lockNeedsPassword || problem == .lockRefused { problem = nil }
            log("keep awake: screen lock off")
        case .alreadyOff, .restored:
            break
        case .noPassword:
            if problem == nil { problem = .lockNeedsPassword }
        case .refused:
            if problem == nil { problem = .lockRefused }
            log("keep awake: macOS refused to turn the screen lock off")
        }
    }

    // MARK: - Off

    /// Turns Keep Awake off. When asked and the settings can't be put back, it stays on (a
    /// consistent state, with the problem shown). When it turns itself off (a timer, the
    /// battery, the heat) everything else goes, and a sleep setting that couldn't be put back
    /// is shown as one to restore.
    @discardableResult
    public func turnOff(reason: KeepAwakeOffReason = .asked, allowPassword: Bool = false) async -> Bool {
        guard !busy, isOn else { return !isOn }
        busy = true
        record.phase = .turningOff
        save()
        changed()
        var restored = true
        if record.powerApplied {
            let r = await system.apply(PMSet.restoreChanges(backup: record.powerBackup, machine: machine), allowPassword: allowPassword)
            restored = r == .done
            if !restored { log("keep awake: sleep settings not put back (\(r))") }
        }
        if !restored && reason == .asked {
            record.phase = .on
            problem = .restoreFailed
            save()
            busy = false
            changed()
            return false
        }
        system.releaseAssertions()
        system.stopInputWatch()
        if record.lockChanged, let before = record.lockBefore {
            if case .refused = await system.screenLockRestore(to: before) { log("keep awake: screen lock not restored") }
        }
        await putDisplaysBack()
        let backup = record.powerBackup
        let stuck = record.disconnected
        record = KeepAwakeRecord()
        record.disconnected = stuck
        problem = stuck.isEmpty ? nil : .displaysStuck(stuck.count)
        if !restored {
            record.powerApplied = true
            record.powerBackup = backup
            disagreement = .sleepOffWithoutUs
            problem = .restoreFailed
        }
        warnings = []
        save()
        busy = false
        log("keep awake: off (\(reason.rawValue))\(restored ? "" : " — sleep still off")")
        switch reason {
        case .asked, .finish: break
        case .timer: system.notify("Keep Awake is off", "Welcome back — your Mac can sleep again.")
        case .lowBattery:
            system.notify("Keep Awake turned off", "Your battery reached \(power.battery ?? prefs().lowBatteryOffAt)%, so your Mac can sleep. Plug it in to keep it awake.")
        case .tooHot: system.notify("Keep Awake turned off", "Your Mac got too hot, so it can sleep and cool down.")
        }
        changed()
        return restored
    }

    public func toggle(allowPassword: Bool = false) async {
        if isOn { await turnOff(reason: .asked, allowPassword: allowPassword) } else { await turnOn(allowPassword: allowPassword) }
    }

    /// The disagreement's two buttons: restore normal sleep, or keep the Mac awake.
    public func resolve(_ choice: KeepAwakeChoice, allowPassword: Bool = true) async {
        switch choice {
        case .keepAwake:
            disagreement = nil
            await turnOn(allowPassword: false, mayAsk: false)
        case .restoreSleep:
            await restoreNormalSleep(allowPassword: allowPassword)
        }
    }

    /// Puts sleep back to normal whatever the record says (the "your Mac is set never to sleep"
    /// fix, and the first half of uninstalling).
    @discardableResult
    public func restoreNormalSleep(allowPassword: Bool) async -> Bool {
        guard !busy else { return false }
        if isOn { return await turnOff(reason: .asked, allowPassword: allowPassword) }
        busy = true
        changed()
        let r = await system.apply(PMSet.restoreChanges(backup: record.powerBackup, machine: machine), allowPassword: allowPassword)
        busy = false
        guard r == .done else {
            if r != .cancelled { problem = .restoreFailed }
            log("keep awake: restore normal sleep — \(r)")
            changed()
            return false
        }
        await putDisplaysBack()
        let stuck = record.disconnected
        record = KeepAwakeRecord()
        record.disconnected = stuck
        disagreement = nil
        problem = nil
        save()
        log("keep awake: normal sleep restored")
        changed()
        return true
    }

    /// Uninstall: normal sleep back, the screen lock as it was, the helper unregistered.
    @discardableResult
    public func prepareForRemoval() async -> Bool {
        var ok = true
        if isOn || disagreement != nil || record.powerApplied || (PMSet.sleepDisabled(system.pmsetSummary()) == true && blockedBy == nil) {
            ok = await restoreNormalSleep(allowPassword: true)
        }
        if ok { ok = system.removeHelper() }
        helper = system.helperState()
        log("keep awake: prepared for removal — \(ok ? "done" : "not done")")
        changed()
        return ok
    }

    // MARK: - Displays

    public func setDisplays(off: Bool) async {
        guard isOn, !busy else { return }
        if off { await displaysOff(auto: false) } else { await displaysOn() }
    }

    public func toggleDisplays() async { await setDisplays(off: !record.displaysOff) }

    private func displaysOff(auto: Bool) async {
        guard isOn, system.hasDisplays, !record.displaysOff else { return }
        let t = now()
        system.ignoreInput(until: t.addingTimeInterval(Self.ignoreAfterDim))
        system.protectAudio(true)
        if system.hasBuiltInDisplay {
            if record.brightness == nil, let current = system.builtInBrightness() {
                // Already dark when dimmed: bring it back to a level you can see.
                record.brightness = current > 0.05 ? current : 0.6
            }
            system.setBuiltInBrightness(0)
        }
        record.displaysOff = true
        record.displaysOffSince = t
        record.autoDimmed = auto
        save()
        changed()
        let unplugged = await system.displaysOff(unplugExternals: prefs().turnOffExternals && system.betterDisplayInstalled)
        record.disconnected = Array(Set(record.disconnected).union(unplugged)).sorted()
        save()
        log("keep awake: displays off (\(auto ? "idle" : "asked"), \(unplugged.count) unplugged)")
        if auto, prefs().notifyOnDim {
            system.notify("Displays off", "Move the mouse or press a key to turn them back on.")
        }
        changed()
    }

    private func displaysOn() async {
        guard record.displaysOff || !record.disconnected.isEmpty || record.brightness != nil else { return }
        await putDisplaysBack()
        if !record.disconnected.isEmpty { problem = .displaysStuck(record.disconnected.count) }
        else if case .displaysStuck = problem { problem = nil }
        save()
        changed()
    }

    /// The built-in's brightness back first (instant), then the externals.
    private func putDisplaysBack() async {
        guard record.displaysOff || !record.disconnected.isEmpty || record.brightness != nil else { return }
        if let b = record.brightness, system.hasBuiltInDisplay { system.setBuiltInBrightness(b) }
        record.brightness = nil
        system.wakeDisplays()
        record.displaysOff = false
        record.displaysOffSince = nil
        record.autoDimmed = false
        if !record.disconnected.isEmpty {
            let asked = record.disconnected.count
            record.disconnected = await system.displaysOn(reconnect: record.disconnected)
            log("keep awake: displays reconnected \(asked - record.disconnected.count) of \(asked)")
        }
        system.protectAudio(false)
        save()
    }

    /// Displays that didn't come back: try again now (the problem's button).
    public func reconnectDisplays() async {
        record.reconnectTries = 0
        if record.displaysOff, isOn { await displaysOn(); return }
        guard !record.disconnected.isEmpty else { return }
        await putDisplaysBack()
        problem = record.disconnected.isEmpty ? nil : .displaysStuck(record.disconnected.count)
        save()
        changed()
    }

    // MARK: - Auto-dim

    /// Every 30 s: the displays go off once he's been away long enough.
    public func idleCheck() async {
        let minutes = prefs().autoDimMinutes
        guard isOn, !busy, minutes > 0, !record.displaysOff, system.inputWatching, system.hasDisplays else { return }
        let last = system.lastPhysicalInput ?? record.since ?? now()
        guard now().timeIntervalSince(last) >= TimeInterval(minutes * 60) else { return }
        await displaysOff(auto: true)
    }

    /// A key, click or move from a real hand (never a posted event).
    public func physicalInput() async {
        guard isOn, !busy, record.displaysOff else { return }
        if let since = record.displaysOffSince, now().timeIntervalSince(since) < Self.ignoreAfterDim { return }
        log("keep awake: displays on (a key or the mouse)")
        await displaysOn()
    }

    /// Seconds since a real key or click, while watching.
    public var idleSeconds: TimeInterval? {
        guard system.inputWatching, let last = system.lastPhysicalInput else { return nil }
        return max(0, now().timeIntervalSince(last))
    }

    // MARK: - Timer ("Back at desk in…")

    public func setTimer(minutes: Int?) async {
        if let m = minutes, m > 0 {
            record.backAt = now().addingTimeInterval(TimeInterval(m * 60))
            save()
            log("keep awake: back at desk in \(m)m")
            if !isOn { await turnOn() } else { changed() }
        } else {
            record.backAt = nil
            save()
            changed()
        }
    }

    // MARK: - Every 30 s: the timer, the battery, the heat

    public func tick() async {
        if isOn, !busy, let at = record.backAt, now() >= at {
            await turnOff(reason: .timer)
            return
        }
        await powerCheck()
    }

    public func powerCheck() async {
        let before = (power, warnings, blockedBy)
        power = system.power()
        blockedBy = system.otherKeeper()
        guard isOn, !busy else {
            warnings = []
            if before.0 != power || before.2 != blockedBy || !before.1.isEmpty { changed() }
            return
        }
        if power.onBattery { if record.onBatterySince == nil { record.onBatterySince = now(); save() } }
        else if record.onBatterySince != nil { record.onBatterySince = nil; save() }
        if KeepAwakeRules.tooHot(power) {
            log("keep awake: critically hot — turning off")
            await turnOff(reason: .tooHot)
            return
        }
        if KeepAwakeRules.batteryTooLow(power, offAt: prefs().lowBatteryOffAt) {
            log("keep awake: battery \(power.battery ?? -1)% ≤ \(prefs().lowBatteryOffAt)% — turning off")
            await turnOff(reason: .lowBattery)
            return
        }
        refreshWarnings()
        for w in warnings where w != .lowPowerMode && !record.told.contains(w.key) {
            record.told.append(w.key)
            save()
            system.notify(w == .hot ? "Your Mac is hot" : "Keep Awake", w.text)
            log("keep awake: told \(w.key)")
        }
        if before.0 != power || before.1 != warnings { changed() }
    }

    private func refreshWarnings() {
        warnings = isOn ? KeepAwakeRules.warnings(power, onBatterySince: record.onBatterySince, now: now()) : []
    }

    // MARK: - Every 5 minutes: is everything still holding?

    public func watchdog() async {
        guard isOn, !busy else { return }
        helper = system.helperState()
        var notes: [String] = []
        if !system.assertionsHeld { system.holdAssertions(); notes.append("assertions back") }
        if record.powerApplied {
            if PMSet.drifted(system.pmsetSummary()) {
                if helper == .ready {
                    let r = await system.apply(PMSet.enableChanges(machine: machine), allowPassword: false)
                    notes.append("sleep settings drifted, fixed: \(r == .done)")
                    if r == .done, problem == .helperGone { problem = nil }
                } else {
                    // Never a password from a timer: say so instead.
                    problem = helper == .outdated ? .helperOutdated : .helperGone
                    notes.append("sleep settings drifted, helper \(helper.rawValue)")
                }
            }
        } else if machine == .laptop, helper == .ready {
            await upgradeToLid()
            notes.append("helper ready — lid can close: \(record.powerApplied)")
        }
        if prefs().screenLockOff, system.screenLockIsOff() == false {
            await lockOff(mayAsk: false)
            notes.append("screen lock back on, off again: \(record.lockChanged)")
        }
        if prefs().autoDimMinutes > 0, !system.inputWatching { system.startInputWatch(); notes.append("input watch restarted") }
        if !record.displaysOff, !record.disconnected.isEmpty {
            if record.reconnectTries < Self.reconnectTries {
                record.reconnectTries += 1
                await putDisplaysBack()
                notes.append("display reconnect retry \(record.reconnectTries)")
                if record.disconnected.isEmpty {
                    if case .displaysStuck = problem { problem = nil }
                } else if record.reconnectTries == Self.reconnectTries {
                    problem = .displaysStuck(record.disconnected.count)
                    system.notify("A display didn't turn back on", "Open Macrophone › Keep Awake and choose Turn Displays On.")
                }
            }
        }
        save()
        log("keep awake: watchdog — \(notes.isEmpty ? "all holding" : notes.joined(separator: "; "))")
        changed()
    }

    /// The helper may have been approved (or removed) since: on without the lid becomes on with
    /// it, at once.
    public func helperMayHaveChanged() async {
        let was = helper
        helper = system.helperState()
        guard helper != was else { return }
        log("keep awake: helper \(was.rawValue) → \(helper.rawValue)")
        if isOn, !busy, !record.powerApplied, helper == .ready, machine == .laptop {
            await upgradeToLid()
        } else if isOn, record.powerApplied, helper != .ready {
            problem = helper == .outdated ? .helperOutdated : .helperGone
        } else if helper == .ready, [.helperGone, .helperOutdated, .needsHelper].contains(problem) {
            problem = nil
        }
        changed()
    }

    private func upgradeToLid() async {
        if record.powerBackup == nil, PMSet.sleepDisabled(system.pmsetSummary()) != true {
            let profile = PMSet.parseCustom(system.pmsetCustom())
            if !profile.isEmpty { record.powerBackup = profile }
        }
        if await system.apply(PMSet.enableChanges(machine: machine), allowPassword: false) == .done {
            record.powerApplied = true
            if [.needsHelper, .helperGone, .helperOutdated, .powerFailed].contains(problem) { problem = nil }
            save()
            log("keep awake: sleep settings changed — the lid can close now")
        }
    }

    // MARK: - What everyone reads

    public func status() -> KeepAwakeStatus {
        var problemText = problem?.text
        if disagreement == .sleepCameBack { problemText = "Keep Awake was on before your Mac restarted — turn it on again?" }
        return KeepAwakeStatus(
            on: isOn, busy: busy, machine: machine,
            lidCanClose: isOn && machine == .laptop && record.powerApplied,
            since: isOn ? record.since : nil,
            displaysOff: isOn && record.displaysOff, displaysOffSince: isOn ? record.displaysOffSince : nil,
            hasDisplays: system.hasDisplays,
            backAt: isOn ? record.backAt : nil,
            battery: power.hasBattery ? power.battery : nil, charging: power.charging, onPower: power.onPower,
            blocked: isOn ? nil : blockedBy,
            problem: problemText,
            warning: warnings.first?.text,
            sleepStillOff: !isOn && (disagreement == .sleepOffWithoutUs || record.powerApplied))
    }

    /// The problem's button was pressed: the engine's part of each fix (the Mac app opens
    /// System Settings or asks for a password for the others).
    public func clearProblem() { problem = nil; changed() }
}
