import AppKit
import Foundation
import IOKit.pwr_mgt
import MacrophoneKit

/// The Mac behind Keep Awake's state machine (Nov 7 2026). Reads are always real. Every change —
/// sleep settings, assertions, brightness, displays, the screen lock, the helper, coreaudiod,
/// notifications — goes through here, and in a dry run (`MACROPHONE_AWAKE_DRYRUN=1`, the default
/// in every DEBUG build; `=0` to really act) each is a log line ("would run pmset -a sleep 0")
/// instead. A dry run keeps a simulated SleepDisabled so the record and "the machine" agree the
/// way they would, and survives a relaunch (`MACROPHONE_AWAKE_SIM_RESTART=1` plays a restart).
@MainActor
final class KeepAwakeMacSystem: KeepAwakeSystem {
    let dryRun: Bool
    let machine: MachineKind = MachinePower.machine
    private let log: DiagnosticLog
    let input: InputMonitor
    let audio: AudioGuard
    private let helperClient = PowerHelperClient.shared
    private var assertions: [IOPMAssertionID] = []
    private let env = ProcessInfo.processInfo.environment

    static var dryRunDefault: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["MACROPHONE_AWAKE_DRYRUN"] != "0"
        #else
        return false
        #endif
    }

    init(log: DiagnosticLog, dryRun: Bool) {
        self.log = log
        self.dryRun = dryRun
        let l = log
        input = InputMonitor { l.add($0) }
        audio = AudioGuard(dryRun: dryRun) { l.add($0) }
        audio.restartViaHelper = { await PowerHelperClient.shared.restartCoreAudio() }
        #if DEBUG
        if dryRun, env["MACROPHONE_AWAKE_SIM_RESTART"] == "1" {
            simDisabled = false
            say("simulated a restart: sleep settings back to normal")
        }
        #endif
    }

    private func say(_ s: String) {
        log.add("keep awake (dry run): \(s)")
        #if DEBUG
        if env["MACROPHONE_AWAKE_PRINT"] == "1" { print("AWAKE DRY RUN: \(s)"); fflush(stdout) }
        #endif
    }

    // MARK: Simulated sleep settings (dry run)

    private var simDisabled: Bool {
        get { AppPaths.defaults.bool(forKey: "keepAwake.dryRun.sleepDisabled") }
        set { AppPaths.defaults.set(newValue, forKey: "keepAwake.dryRun.sleepDisabled") }
    }

    // MARK: pmset

    func pmsetSummary() -> String {
        let real = Shell.run("/usr/bin/pmset", ["-g"]).output
        guard dryRun else { return real }
        // The real summary with the simulated values Keep Awake reads.
        var lines = real.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.contains("SleepDisabled") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("displaysleep") }
        lines.insert(" SleepDisabled\t\t\(simDisabled ? 1 : 0)", at: min(1, lines.count))
        lines.append(" displaysleep         \(simDisabled ? 0 : 10)")
        return lines.joined(separator: "\n")
    }

    func pmsetCustom() -> String { Shell.run("/usr/bin/pmset", ["-g", "custom"]).output }

    func power() -> PowerSnapshot { MachinePower.snapshot() }

    func helperState() -> KeepAwakeHelperState {
        #if DEBUG
        if dryRun {
            switch env["MACROPHONE_AWAKE_HELPER"] ?? "ready" {
            case "missing": return .notInstalled
            case "approval": return .needsApproval
            case "outdated": return .outdated
            default: return .ready
            }
        }
        #endif
        return helperClient.state
    }

    func apply(_ changes: [PowerChange], allowPassword: Bool) async -> KeepAwakeApply {
        let state = helperState()
        if dryRun {
            guard state == .ready || allowPassword else {
                say("no helper (\(state.rawValue)) and no password allowed — would leave sleep settings as they are")
                return .needsHelper
            }
            for c in changes { say("would run pmset \(c.arguments.joined(separator: " "))\(state == .ready ? " (through the helper)" : " (with the administrator dialog)")") }
            if let d = changes.first(where: { $0.key == "disablesleep" }) { simDisabled = d.value == 1 }
            return .done
        }
        if state == .ready || state == .outdated {
            let r = await helperClient.apply(changes)
            if r.ok { log.add("keep awake: \(changes.count) sleep settings changed through the helper"); return .done }
            log.add("keep awake: the helper didn't apply them (\(r.detail))")
            if !allowPassword { return state == .outdated || r.detail.contains("outdated") ? .needsHelper : .failed(r.detail) }
        } else if !allowPassword {
            return .needsHelper
        }
        return applyWithAdministrator(changes)
    }

    /// The system's own administrator dialog — only after the person clicked, never from a timer
    /// or the phone (nobody may be at the Mac to answer it).
    private func applyWithAdministrator(_ changes: [PowerChange]) -> KeepAwakeApply {
        let cmd = changes.filter(\.isAllowed).map { "/usr/bin/pmset " + $0.arguments.joined(separator: " ") }.joined(separator: " && ")
        let script = "do shell script \"\(cmd)\" with administrator privileges with prompt \"Macrophone wants to change your Mac's sleep settings for Keep Awake.\""
        var error: NSDictionary?
        NSApp.activate(ignoringOtherApps: true)
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            log.add("keep awake: administrator dialog — \(code == -128 ? "cancelled" : "failed (\(code))")")
            return code == -128 ? .cancelled : .failed("administrator \(code)")
        }
        log.add("keep awake: \(changes.count) sleep settings changed with the administrator dialog")
        return .done
    }

    func removeHelper() -> Bool {
        if dryRun { say("would unregister the helper"); return true }
        return helperClient.unregister()
    }

    // MARK: Assertions (what caffeinate -s -i -d takes, held by this process)

    var assertionsHeld: Bool { dryRun ? simAssertions : !assertions.isEmpty }
    private var simAssertions = false

    func holdAssertions() {
        if dryRun {
            if !simAssertions { say("would hold the no-system-sleep, no-idle-sleep and no-display-sleep assertions") }
            simAssertions = true
            return
        }
        guard assertions.isEmpty else { return }
        // They end with the process: a force-quit never leaves an orphaned caffeinate behind.
        // caffeinate's -s, -i and -d, by their IOKit names.
        for type in ["PreventSystemSleep", kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertPreventUserIdleDisplaySleep] {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Macrophone: Keep Awake — so you can use this Mac from your iPhone" as CFString, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
    }

    func releaseAssertions() {
        if dryRun { if simAssertions { say("would release the assertions") }; simAssertions = false; return }
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions = []
    }

    // MARK: Displays

    var hasBuiltInDisplay: Bool { DisplayControl.builtIn != nil && DisplayControl.canDim }
    var hasDisplays: Bool { !DisplayControl.onlineDisplays().isEmpty }
    func builtInBrightness() -> Float? { DisplayControl.brightness() }

    func setBuiltInBrightness(_ level: Float) {
        if dryRun { say("would set the built-in display's brightness to \(Int((level * 100).rounded()))%"); return }
        DisplayControl.setBrightness(level)
    }

    var betterDisplayInstalled: Bool { DisplayControl.betterDisplayInstalled }

    func displaysOff(unplugExternals: Bool) async -> [String] {
        input.ignoreUntil = Date().addingTimeInterval(KeepAwakeEngine.ignoreAfterDim)
        input.armed = true
        if dryRun {
            if unplugExternals {
                let ids = DisplayControl.externals.map { "display-\($0)" }
                say(ids.isEmpty ? "no external displays to turn off" : "would turn off \(ids.count) external display(s) with BetterDisplay")
                return ids
            }
            say("would put every display to sleep (pmset displaysleepnow)")
            return []
        }
        // A beat for the menu or the key to be let go.
        try? await Task.sleep(nanoseconds: 800_000_000)
        if unplugExternals {
            let tags = await Task.detached { DisplayControl.unplugExternals() }.value
            // The unplug can bring the built-in back to its old level.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            DisplayControl.setBrightness(0)
            if !tags.isEmpty || DisplayControl.externals.isEmpty { return tags }
        }
        await Task.detached { DisplayControl.sleepAll() }.value
        return []
    }

    func displaysOn(reconnect: [String]) async -> [String] {
        input.armed = false
        if dryRun {
            if !reconnect.isEmpty { say("would turn \(reconnect.count) external display(s) back on with BetterDisplay") }
            return []
        }
        let real = reconnect.filter { !$0.hasPrefix("display-") }
        guard !real.isEmpty, DisplayControl.betterDisplayInstalled else { return [] }
        return await Task.detached { DisplayControl.plugIn(real) }.value
    }

    func wakeDisplays() {
        if dryRun { say("would wake the displays"); return }
        DisplayControl.wake()
    }

    func protectAudio(_ on: Bool) {
        guard AppPaths.defaults.object(forKey: "keepAwake.protectAudio") as? Bool ?? true else { return }
        if on { audio.protect() } else { audio.restore() }
    }

    // MARK: Screen lock

    func screenLockIsOff() -> Bool? { ScreenLock.current().map { $0 == "off" } }

    func screenLockOff(mayAsk: Bool) async -> KeepAwakeLock {
        let before = await Task.detached { ScreenLock.current() }.value
        if before == "off" { return .alreadyOff }
        if dryRun {
            say("would turn the screen lock off with the login password from the Keychain (sysadminctl -screenLock off)")
            return .changed(before: before ?? "immediate")
        }
        var password = await Task.detached { ScreenLock.storedPassword }.value
        if let pw = password, !(await Task.detached { ScreenLock.verify(pw) }.value) {
            log.add("keep awake: the kept login password no longer works — forgotten")
            ScreenLock.forget()
            password = nil
        }
        if password == nil {
            guard mayAsk, let pw = ScreenLock.ask() else { return .noPassword }
            ScreenLock.store(pw)
            password = pw
        }
        guard let pw = password else { return .noPassword }
        let arg = before ?? "immediate"
        if let err = await Task.detached(operation: { ScreenLock.set("off", password: pw) }).value { return .refused(err) }
        return .changed(before: arg)
    }

    func screenLockRestore(to before: String) async -> KeepAwakeLock {
        if dryRun { say("would put the screen lock back (\(before == "immediate" ? "immediately" : before))"); return .restored }
        guard let pw = await Task.detached(operation: { ScreenLock.storedPassword }).value else { return .noPassword }
        if let err = await Task.detached(operation: { ScreenLock.set(before, password: pw) }).value { return .refused(err) }
        return .restored
    }

    // MARK: Input

    func startInputWatch() -> Bool { input.start() }
    func stopInputWatch() { input.stop(); input.armed = false }
    var inputWatching: Bool { input.isRunning }
    var lastPhysicalInput: Date? { input.lastPhysicalInput }
    func ignoreInput(until: Date) { input.ignoreUntil = until }

    // MARK: Telling him

    func notify(_ title: String, _ body: String) {
        if dryRun { say("would notify: \(title)"); return }
        Notifier.shared.post(title: title, body: body, id: "keepAwake.\(title)")
    }

    // MARK: SameerOS's On The Go

    private var sameerOSChecked = Date.distantPast
    private var sameerOSHelper = false

    func otherKeeper() -> String? {
        #if DEBUG
        if env["MACROPHONE_AWAKE_IGNORE_SAMEEROS"] == "1" { return nil }
        #endif
        let active = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.onthego-active")
        // A read (launchctl print), at most once a minute.
        if Date().timeIntervalSince(sameerOSChecked) > 60 {
            sameerOSChecked = Date()
            sameerOSHelper = Shell.run("/bin/launchctl", ["print", "system/com.sameer.sameeros-mac.helper"]).status == 0
        }
        return OtherKeeper.words(onTheGoActive: active, sameerOSHelperLoaded: sameerOSHelper)
    }
}

/// The record, as a file in Macrophone's own folder (atomic writes: a crash mid-save never
/// leaves half a record).
@MainActor
final class KeepAwakeFileStore: KeepAwakeStore {
    private let url = AppPaths.supportDirectory.appendingPathComponent("keep-awake.json")

    func load() -> KeepAwakeRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(KeepAwakeRecord.self, from: data)
    }

    func save(_ record: KeepAwakeRecord) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        try? e.encode(record).write(to: url, options: .atomic)
    }
}
