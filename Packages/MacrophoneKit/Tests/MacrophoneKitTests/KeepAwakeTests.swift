import Foundation
import XCTest
@testable import MacrophoneKit

/// Keep Awake (Nov 7 2026): the helper's allowlist, pmset read and put back, the words, the
/// warnings, the wire — and the state machine driven through every path a stranger's Mac can take
/// (a laptop and a desktop, no helper, a crash mid-way, a restart while on, the battery, the heat,
/// a display that won't come back), with a fake machine that records what it was asked to do.
final class KeepAwakeTests: XCTestCase {

    // MARK: - The helper's allowlist (the same file runs in the root daemon)

    func testTheHelperRunsOnlyAllowedChanges() {
        XCTAssertEqual(PowerChange(wire: "a sleep 0"), PowerChange(.all, "sleep", 0))
        XCTAssertEqual(PowerChange(wire: "b displaysleep 2"), PowerChange(.battery, "displaysleep", 2))
        XCTAssertEqual(PowerChange(wire: "c hibernatemode 3"), PowerChange(.charger, "hibernatemode", 3))
        XCTAssertEqual(PowerChange(wire: "a disablesleep 1")?.arguments, ["-a", "disablesleep", "1"])
        for bad in ["a sleep -1", "a sleep 1441", "a hibernatemode 7", "b disablesleep 1", "a womp 1", "a sleep 0; rm -rf /",
                    "x sleep 0", "a  sleep 0", "a sleep", "a sleep 0 extra", "", "a sleep 0x1", "a autopoweroff 0", "a sleep 99999"] {
            XCTAssertNil(PowerChange(wire: bad), bad)
        }
        let all = PMSet.enableChanges(machine: .laptop) + PMSet.restoreChanges(backup: nil, machine: .laptop)
            + PMSet.restoreChanges(backup: nil, machine: .desktop)
        for c in all { XCTAssertEqual(PowerChange(wire: c.wire), c, "every change Keep Awake makes passes the helper") }
    }

    // MARK: - pmset

    static let custom = """
    Battery Power:
     Sleep On Power Button 1
     standby              1
     hibernatemode        3
     displaysleep         2
     sleep                1
    AC Power:
     Sleep On Power Button 1
     hibernatemode        3
     displaysleep         10
     womp                 1
     sleep                1
    """

    func testItReadsEachPowerSourceAndPutsEachBack() {
        let p = PMSet.parseCustom(Self.custom)
        XCTAssertEqual(p.sources["Battery Power"], ["hibernatemode": 3, "displaysleep": 2, "sleep": 1])
        XCTAssertEqual(p.sources["AC Power"], ["hibernatemode": 3, "displaysleep": 10, "sleep": 1])
        let back = PMSet.restoreChanges(backup: p, machine: .laptop)
        XCTAssertTrue(back.contains(PowerChange(.battery, "displaysleep", 2)))
        XCTAssertTrue(back.contains(PowerChange(.charger, "displaysleep", 10)))
        XCTAssertEqual(back.last, PowerChange(.all, "disablesleep", 0))
        XCTAssertFalse(back.contains { $0.source == .all && $0.key == "displaysleep" }, "never flattened into -a")
    }

    func testADesktopHasOneSourceAndKeepsItsHibernation() {
        let p = PMSet.parseCustom("AC Power:\n sleep                 1\n displaysleep          10\n hibernatemode         0\n")
        XCTAssertEqual(p.sources.count, 1)
        XCTAssertFalse(PMSet.enableChanges(machine: .desktop).contains { $0.key == "hibernatemode" })
        XCTAssertTrue(PMSet.enableChanges(machine: .laptop).contains(PowerChange(.all, "hibernatemode", 0)))
        let fallback = PMSet.restoreChanges(backup: nil, machine: .desktop)
        XCTAssertFalse(fallback.contains { $0.key == "hibernatemode" }, "a desktop is never given a laptop's hibernation")
        XCTAssertEqual(PMSet.restoreChanges(backup: nil, machine: .laptop).filter { $0.key == "hibernatemode" }.first?.value, 3)
    }

    func testItReadsTheSummaryAsPrintedWithReasons() {
        let summary = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         Sleep On Power Button 1
         sleep                0 (sleep prevented by SameerOS, caffeinate)
         displaysleep         0 (display sleep prevented by caffeinate)
        """
        XCTAssertEqual(PMSet.sleepDisabled(summary), true)
        XCTAssertEqual(PMSet.value("sleep", in: summary), 0)
        XCTAssertFalse(PMSet.drifted(summary))
        XCTAssertTrue(PMSet.drifted(" SleepDisabled 0\n displaysleep 0"))
        XCTAssertTrue(PMSet.drifted(" SleepDisabled 1\n displaysleep 10"))
        XCTAssertNil(PMSet.sleepDisabled("nothing here"))
    }

    // MARK: - Another app keeping the Mac awake

    func testSameerOSIsNeverFought() {
        XCTAssertEqual(OtherKeeper.words(onTheGoActive: true, sameerOSHelperLoaded: true), "SameerOS's On The Go is on — turn it off there first.")
        XCTAssertNotNil(OtherKeeper.words(onTheGoActive: false, sameerOSHelperLoaded: true))
        XCTAssertNil(OtherKeeper.words(onTheGoActive: false, sameerOSHelperLoaded: false))
    }

    // MARK: - The wire

    func testTheStatusRoundTripsAndAnOlderShapeStillReads() throws {
        let s = KeepAwakeStatus(on: true, machine: .laptop, lidCanClose: true, since: Date(timeIntervalSince1970: 1_000),
                                displaysOff: true, battery: 84, onPower: false, warning: "w")
        let data = try WireCoding.encoder.encode(Message.keepAwake(s))
        guard case let .keepAwake(back) = try WireCoding.decoder.decode(Message.self, from: data) else { return XCTFail("not keep awake") }
        XCTAssertEqual(back, s)
        // A Mac from before some field: defaults, never a failed decode.
        let old = try WireCoding.decoder.decode(KeepAwakeStatus.self, from: Data(#"{"on":true}"#.utf8))
        XCTAssertTrue(old.on)
        XCTAssertTrue(old.hasDisplays)
        XCTAssertNil(old.battery)
        // A newer Mac's kind of machine this phone doesn't know reads as a laptop.
        let newer = try WireCoding.decoder.decode(KeepAwakeStatus.self, from: Data(#"{"on":false,"machine":"tablet","extra":1}"#.utf8))
        XCTAssertEqual(newer.machine, .laptop)
    }

    func testARequestFromANewerPhoneIsIgnoredNotFatal() throws {
        XCTAssertTrue(KeepAwakeRequest(.on).isValid)
        XCTAssertTrue(KeepAwakeRequest(.timer, minutes: 60).isValid)
        XCTAssertFalse(KeepAwakeRequest(.timer).isValid)
        XCTAssertFalse(KeepAwakeRequest(.timer, minutes: 5000).isValid)
        let unknown = try WireCoding.decoder.decode(KeepAwakeRequest.self, from: Data(#"{"action":"teleport"}"#.utf8))
        XCTAssertNil(unknown.known)
        XCTAssertFalse(unknown.isValid)
    }

    // MARK: - Words

    func testThePhoneLineForEveryMac() {
        XCTAssertEqual(KeepAwakeStatus(on: true, machine: .laptop, lidCanClose: true, battery: 84, onPower: false).phoneLine, "Lid can close · 84%")
        XCTAssertEqual(KeepAwakeStatus(on: true, machine: .laptop, lidCanClose: false, battery: 50, charging: true).phoneLine, "Keep the lid open · 50% · charging")
        XCTAssertEqual(KeepAwakeStatus(on: true, machine: .desktop).phoneLine, "Stays awake")
        XCTAssertEqual(KeepAwakeStatus(on: false, machine: .desktop).phoneLine, "Off")
        XCTAssertEqual(KeepAwakeStatus(on: false, blocked: "SameerOS's On The Go is on — turn it off there first.").phoneLine,
                       "SameerOS's On The Go is on — turn it off there first.")
        XCTAssertEqual(KeepAwakeStatus(on: false, sleepStillOff: true).phoneLine, "Your Mac is set never to sleep")
        XCTAssertEqual(KeepAwakeStatus(on: false, busy: true).phoneLine, "Turning on…")
    }

    func testTheMacLine() {
        let t0 = Date(timeIntervalSince1970: 0)
        let time: (Date) -> String = { d in d == t0 ? "3:12" : "5:00" }
        let s = KeepAwakeStatus(on: true, machine: .laptop, lidCanClose: true, displaysOff: true, displaysOffSince: t0, backAt: t0.addingTimeInterval(60))
        XCTAssertEqual(KeepAwakeWords.macLine(s, time: time), "On · lid can close · displays off since 3:12 · back at desk at 5:00")
        XCTAssertEqual(KeepAwakeWords.macLine(KeepAwakeStatus(on: true, machine: .desktop), time: time), "On · stays awake")
        XCTAssertEqual(KeepAwakeWords.macLine(KeepAwakeStatus(on: false), time: time), "Off")
        XCTAssertEqual(KeepAwakeWords.displaysLine(off: true, idle: 200, autoDimMinutes: 5), "Displays off · idle 3m")
        XCTAssertEqual(KeepAwakeWords.displaysLine(off: false, idle: 5, autoDimMinutes: 5), "Displays on · active")
        XCTAssertEqual(KeepAwakeWords.countdown(to: t0.addingTimeInterval(4800), now: t0), "Back at desk in 1h 20m")
        XCTAssertTrue(KeepAwakeWords.explainer(.desktop).contains("awake and reachable"))
        XCTAssertFalse(KeepAwakeWords.explainer(.desktop).contains("lid"))
    }

    // MARK: - Warnings

    func testWarningsForTheBatteryAndTheHeat() {
        let now = Date()
        XCTAssertEqual(KeepAwakeRules.warnings(PowerSnapshot(hasBattery: true, battery: 18, onPower: false), onBatterySince: now, now: now), [.lowBattery(18)])
        XCTAssertEqual(KeepAwakeRules.warnings(PowerSnapshot(hasBattery: true, battery: 18, onPower: true), onBatterySince: nil, now: now), [], "plugged in: no battery warning")
        XCTAssertEqual(KeepAwakeRules.warnings(PowerSnapshot(hasBattery: true, battery: 80, onPower: false), onBatterySince: now.addingTimeInterval(-3 * 3600), now: now), [.longOnBattery(hours: 3)])
        XCTAssertEqual(KeepAwakeRules.warnings(PowerSnapshot(thermal: .serious), onBatterySince: nil, now: now), [.hot])
        XCTAssertEqual(KeepAwakeRules.warnings(PowerSnapshot(lowPowerMode: true), onBatterySince: nil, now: now), [.lowPowerMode])
        XCTAssertEqual(KeepAwakeRules.warnings(PowerSnapshot(), onBatterySince: nil, now: now), [], "a desktop: nothing")
        XCTAssertTrue(KeepAwakeRules.batteryTooLow(PowerSnapshot(hasBattery: true, battery: 10, onPower: false), offAt: 10))
        XCTAssertFalse(KeepAwakeRules.batteryTooLow(PowerSnapshot(hasBattery: true, battery: 10, onPower: true), offAt: 10))
        XCTAssertFalse(KeepAwakeRules.batteryTooLow(PowerSnapshot(hasBattery: true, battery: 3, onPower: false), offAt: 0), "Never")
        XCTAssertFalse(KeepAwakeRules.batteryTooLow(PowerSnapshot(), offAt: 10), "no battery")
        XCTAssertTrue(KeepAwakeRules.tooHot(PowerSnapshot(thermal: .critical)))
        XCTAssertFalse(KeepAwakeRules.tooHot(PowerSnapshot(thermal: .serious)))
    }

    // MARK: - Recovery at launch (every case)

    func testRecoveryMatrix() {
        func r(_ phase: KeepAwakeRecord.Phase, applied: Bool = true, leftovers: Bool = false) -> KeepAwakeRecord {
            var x = KeepAwakeRecord(); x.phase = phase; x.powerApplied = applied
            if leftovers { x.brightness = 0.5 }
            return x
        }
        typealias E = KeepAwakeEngine
        XCTAssertEqual(E.recover(r(.on), sleepDisabled: true, other: nil), .resume)
        XCTAssertEqual(E.recover(r(.on), sleepDisabled: false, other: nil), .ask(.sleepCameBack), "a restart reset sleep")
        XCTAssertEqual(E.recover(r(.on, applied: false), sleepDisabled: false, other: nil), .resume, "on without the lid: nothing to disagree about")
        XCTAssertEqual(E.recover(r(.on), sleepDisabled: nil, other: nil), .resume)
        XCTAssertEqual(E.recover(r(.turningOn, applied: false), sleepDisabled: true, other: nil), .resume, "crashed after applying")
        XCTAssertEqual(E.recover(r(.turningOn, applied: false), sleepDisabled: false, other: nil), .cleanUp, "crashed before applying")
        XCTAssertEqual(E.recover(r(.turningOff), sleepDisabled: true, other: nil), .finishOff)
        XCTAssertEqual(E.recover(r(.turningOff), sleepDisabled: false, other: nil), .cleanUp)
        XCTAssertEqual(E.recover(r(.off, applied: false), sleepDisabled: true, other: nil), .ask(.sleepOffWithoutUs), "never a Mac that can't sleep, unsaid")
        XCTAssertEqual(E.recover(r(.off, applied: false), sleepDisabled: false, other: nil), .nothing)
        XCTAssertEqual(E.recover(r(.off, applied: false, leftovers: true), sleepDisabled: false, other: nil), .cleanUp)
        XCTAssertEqual(E.recover(r(.off, applied: false), sleepDisabled: true, other: "SameerOS"), .nothing, "theirs, not ours")
        XCTAssertEqual(E.recover(r(.on), sleepDisabled: true, other: "SameerOS"), .standDown)
    }

    // MARK: - The engine

    @MainActor func testTurningOnWithTheHelperBacksUpAndChangesSleep() async {
        let rig = EngineRig()
        let result = await rig.engine.turnOn()
        XCTAssertEqual(result, .on)
        XCTAssertTrue(rig.engine.isOn)
        XCTAssertTrue(rig.sys.assertionsHeld)
        XCTAssertEqual(rig.sys.applied.last, PMSet.enableChanges(machine: .laptop))
        XCTAssertEqual(rig.store.record?.powerBackup?.sources["AC Power"]?["displaysleep"], 10)
        XCTAssertTrue(rig.sys.inputWatching, "auto-dim on by default")
        XCTAssertEqual(rig.sys.lockCalls, 0, "the screen lock is opt-in: never touched by default")
        XCTAssertFalse(rig.engine.record.displaysOff, "auto-dim leaves the displays on until he walks away")
        let s = rig.engine.status()
        XCTAssertTrue(s.lidCanClose)
        XCTAssertEqual(s.phoneLine, "Lid can close · 84%")
        XCTAssertFalse(rig.sys.passwordAsked)
    }

    @MainActor func testWithoutTheHelperALaptopStaysOpenAndSaysWhy() async {
        let rig = EngineRig()
        rig.sys.helper = .notInstalled
        let result = await rig.engine.turnOn()
        XCTAssertEqual(result, .onWithoutLid)
        XCTAssertTrue(rig.engine.isOn)
        XCTAssertTrue(rig.sys.assertionsHeld, "still awake while open")
        XCTAssertFalse(rig.sys.passwordAsked, "never a raw password prompt first")
        XCTAssertEqual(rig.engine.problem, .needsHelper)
        XCTAssertEqual(rig.engine.status().phoneLine, "Keep the lid open · 84%")
        // Approved later: the lid can close at once, no toggle needed.
        rig.sys.helper = .ready
        await rig.engine.helperMayHaveChanged()
        XCTAssertTrue(rig.engine.record.powerApplied)
        XCTAssertNil(rig.engine.problem)
        XCTAssertTrue(rig.engine.status().lidCanClose)
    }

    @MainActor func testADesktopNeedsNoHelperAndHasNoLidOrBattery() async {
        let rig = EngineRig(machine: .desktop)
        rig.sys.helper = .notInstalled
        rig.sys.snapshot = PowerSnapshot()
        rig.sys.builtIn = false
        let result = await rig.engine.turnOn()
        XCTAssertEqual(result, .on)
        XCTAssertNil(rig.engine.problem)
        let s = rig.engine.status()
        XCTAssertEqual(s.machine, .desktop)
        XCTAssertNil(s.battery)
        XCTAssertEqual(s.phoneLine, "Stays awake")
        await rig.engine.setDisplays(off: true)
        XCTAssertTrue(rig.sys.brightnessSets.isEmpty, "no built-in display: brightness is never touched")
        XCTAssertTrue(rig.engine.record.displaysOff)
    }

    @MainActor func testAnOutdatedHelperIsNamed() async {
        let rig = EngineRig()
        rig.sys.helper = .outdated
        _ = await rig.engine.turnOn()
        XCTAssertEqual(rig.engine.problem, .helperOutdated)
    }

    @MainActor func testCancellingThePasswordLeavesEverythingAsItWas() async {
        let rig = EngineRig()
        rig.sys.helper = .notInstalled
        rig.sys.passwordAnswer = .cancelled
        let result = await rig.engine.turnOn(allowPassword: true)
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(rig.engine.isOn)
        XCTAssertFalse(rig.sys.assertionsHeld)
        XCTAssertEqual(rig.store.record?.phase, .off)
    }

    @MainActor func testSameerOSBlocksTurningOn() async {
        let rig = EngineRig()
        rig.sys.other = "SameerOS's On The Go is on — turn it off there first."
        let result = await rig.engine.turnOn()
        XCTAssertEqual(result, .blocked("SameerOS's On The Go is on — turn it off there first."))
        XCTAssertFalse(rig.engine.isOn)
        XCTAssertTrue(rig.sys.applied.isEmpty, "nothing of SameerOS's touched")
        XCTAssertEqual(rig.engine.status().blocked, "SameerOS's On The Go is on — turn it off there first.")
    }

    @MainActor func testTurningOffPutsTheExactSettingsBack() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        await rig.engine.setDisplays(off: true)
        let ok = await rig.engine.turnOff()
        XCTAssertTrue(ok)
        XCTAssertFalse(rig.engine.isOn)
        XCTAssertEqual(rig.sys.applied.last, PMSet.restoreChanges(backup: PMSet.parseCustom(Self.custom), machine: .laptop))
        XCTAssertFalse(rig.sys.assertionsHeld)
        XCTAssertFalse(rig.sys.inputWatching)
        XCTAssertEqual(rig.sys.brightnessSets.last, 0.7, "the built-in back where it was")
        XCTAssertTrue(rig.sys.reconnected.contains(["ext-1"]))
        XCTAssertEqual(rig.store.record, KeepAwakeRecord(), "a clean record")
    }

    @MainActor func testAFailedRestoreWhenAskedStaysOnConsistently() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        rig.sys.applyAnswer = .failed("refused")
        let ok = await rig.engine.turnOff()
        XCTAssertFalse(ok)
        XCTAssertTrue(rig.engine.isOn)
        XCTAssertTrue(rig.sys.assertionsHeld)
        XCTAssertEqual(rig.engine.problem, .restoreFailed)
    }

    @MainActor func testAFailedRestoreOnItsOwnIsShownAsSleepStillOff() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        await rig.engine.setTimer(minutes: 30)
        rig.sys.applyAnswer = .needsHelper
        rig.clock = rig.clock.addingTimeInterval(31 * 60)
        await rig.engine.tick()
        XCTAssertFalse(rig.engine.isOn)
        XCTAssertFalse(rig.sys.assertionsHeld)
        XCTAssertEqual(rig.engine.disagreement, .sleepOffWithoutUs)
        XCTAssertTrue(rig.engine.status().sleepStillOff)
        // One click restores (the password route allowed: he clicked).
        rig.sys.applyAnswer = .done
        await rig.engine.resolve(.restoreSleep)
        XCTAssertNil(rig.engine.disagreement)
        XCTAssertFalse(rig.engine.status().sleepStillOff)
        XCTAssertEqual(rig.sys.applied.last?.last, PowerChange(.all, "disablesleep", 0))
    }

    @MainActor func testTheTimerTurnsItOffAndSaysWelcomeBack() async {
        let rig = EngineRig()
        await rig.engine.setTimer(minutes: 60)
        XCTAssertTrue(rig.engine.isOn, "setting the timer turns it on")
        XCTAssertNotNil(rig.engine.status().backAt)
        rig.clock = rig.clock.addingTimeInterval(59 * 60)
        await rig.engine.tick()
        XCTAssertTrue(rig.engine.isOn)
        rig.clock = rig.clock.addingTimeInterval(2 * 60)
        await rig.engine.tick()
        XCTAssertFalse(rig.engine.isOn)
        XCTAssertEqual(rig.sys.notes.last?.0, "Keep Awake is off")
    }

    // MARK: Crash, force-quit, restart

    @MainActor func testAForceQuitWhileOnResumesQuietly() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        rig.sys.sleepIsDisabled = true
        // The process died: its assertions with it.
        rig.sys.releaseAssertions()
        let next = rig.relaunch()
        let decision = await next.engine.launch()
        XCTAssertEqual(decision, .resume)
        XCTAssertTrue(next.engine.isOn)
        XCTAssertTrue(next.sys.assertionsHeld)
        XCTAssertFalse(next.sys.passwordAsked)
    }

    @MainActor func testARestartWhileOnAsksAndEitherAnswerWorks() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        rig.sys.sleepIsDisabled = false   // a restart reset it
        var next = rig.relaunch()
        let decision = await next.engine.launch()
        XCTAssertEqual(decision, .ask(.sleepCameBack))
        XCTAssertFalse(next.engine.isOn)
        XCTAssertNotNil(next.engine.status().problem)
        await next.engine.resolve(.keepAwake)
        XCTAssertTrue(next.engine.isOn)
        XCTAssertTrue(next.engine.record.powerApplied)

        rig.sys.sleepIsDisabled = false
        next = rig.relaunch()
        _ = await next.engine.launch()
        await next.engine.resolve(.restoreSleep)
        XCTAssertFalse(next.engine.isOn)
        XCTAssertNil(next.engine.disagreement)
    }

    @MainActor func testARestartWithTheDisplaysOffBringsThemBackBeforeAsking() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        await rig.engine.setDisplays(off: true)
        rig.sys.sleepIsDisabled = false
        let next = rig.relaunch()
        _ = await next.engine.launch()
        XCTAssertFalse(next.engine.record.displaysOff)
        XCTAssertEqual(next.sys.brightnessSets.last, 0.7)
        XCTAssertTrue(next.sys.reconnected.last == ["ext-1"])
        await next.engine.resolve(.keepAwake)
        XCTAssertFalse(next.engine.status().displaysOff, "on again, displays on")
    }

    @MainActor func testACrashMidTurnOnLeavesNothingBehind() async {
        let rig = EngineRig()
        var rec = KeepAwakeRecord()
        rec.phase = .turningOn
        rec.brightness = 0.4
        rig.store.record = rec
        rig.sys.sleepIsDisabled = false
        let next = rig.relaunch()
        let decision = await next.engine.launch()
        XCTAssertEqual(decision, .cleanUp)
        XCTAssertEqual(next.sys.brightnessSets.last, 0.4, "the dimmed screen comes back")
        XCTAssertEqual(next.store.record?.phase, .off)
    }

    @MainActor func testACrashMidTurnOffFinishesIt() async {
        let rig = EngineRig()
        var rec = KeepAwakeRecord()
        rec.phase = .turningOff
        rec.powerApplied = true
        rec.powerBackup = PMSet.parseCustom(Self.custom)
        rig.store.record = rec
        rig.sys.sleepIsDisabled = true
        let next = rig.relaunch()
        let decision = await next.engine.launch()
        XCTAssertEqual(decision, .finishOff)
        XCTAssertFalse(next.engine.isOn)
        XCTAssertEqual(next.sys.applied.last?.last, PowerChange(.all, "disablesleep", 0))
        // And when it can't be finished (the helper was removed), it says so instead of hiding it.
        let rig2 = EngineRig()
        rig2.store.record = rec
        rig2.sys.sleepIsDisabled = true
        rig2.sys.helper = .notInstalled
        rig2.sys.applyAnswer = .needsHelper
        let next2 = rig2.relaunch()
        _ = await next2.engine.launch()
        XCTAssertFalse(next2.engine.isOn)
        XCTAssertTrue(next2.engine.status().sleepStillOff)
    }

    @MainActor func testSleepOffWithoutKeepAwakeIsNeverSilent() async {
        let rig = EngineRig()
        rig.sys.sleepIsDisabled = true
        let decision = await rig.engine.launch()
        XCTAssertEqual(decision, .ask(.sleepOffWithoutUs))
        XCTAssertTrue(rig.engine.status().sleepStillOff)
        await rig.engine.resolve(.restoreSleep)
        XCTAssertFalse(rig.engine.status().sleepStillOff)
        XCTAssertEqual(rig.sys.applied.last, PMSet.restoreChanges(backup: nil, machine: .laptop), "no backup: this kind of Mac's defaults")
    }

    // MARK: Displays and auto-dim

    @MainActor func testAutoDimTimingAndTheFirstTouchBringsThemBack() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        rig.sys.lastInput = rig.clock
        rig.clock = rig.clock.addingTimeInterval(4 * 60 + 50)
        await rig.engine.idleCheck()
        XCTAssertFalse(rig.engine.record.displaysOff, "not yet 5 minutes")
        rig.clock = rig.clock.addingTimeInterval(15)
        await rig.engine.idleCheck()
        XCTAssertTrue(rig.engine.record.displaysOff)
        XCTAssertEqual(rig.sys.brightnessSets.last, 0)
        XCTAssertEqual(rig.engine.record.brightness, 0.7)
        XCTAssertEqual(rig.engine.record.disconnected, ["ext-1"])
        XCTAssertEqual(rig.sys.notes.last?.0, "Displays off")
        XCTAssertEqual(rig.sys.ignoredUntil, rig.clock.addingTimeInterval(6))
        // The hot key's release a moment later isn't him.
        rig.clock = rig.clock.addingTimeInterval(2)
        await rig.engine.physicalInput()
        XCTAssertTrue(rig.engine.record.displaysOff)
        rig.clock = rig.clock.addingTimeInterval(60)
        await rig.engine.physicalInput()
        XCTAssertFalse(rig.engine.record.displaysOff)
        XCTAssertEqual(rig.sys.brightnessSets.last, 0.7)
        XCTAssertEqual(rig.sys.audio, [true, false], "sound guarded around both changes")
    }

    @MainActor func testAutoDimOffTurnsTheDisplaysOffAtOnce() async {
        let rig = EngineRig()
        rig.prefs.autoDimMinutes = 0
        await rig.engine.turnOn()
        XCTAssertTrue(rig.engine.record.displaysOff)
        XCTAssertFalse(rig.sys.inputWatching)
    }

    @MainActor func testAScreenAlreadyDarkComesBackToALevelYouCanSee() async {
        let rig = EngineRig()
        rig.sys.brightness = 0.01
        await rig.engine.turnOn()
        await rig.engine.setDisplays(off: true)
        await rig.engine.setDisplays(off: false)
        XCTAssertEqual(rig.sys.brightnessSets.last, 0.6)
    }

    @MainActor func testNoDisplaysAtAllNothingToTurnOff() async {
        let rig = EngineRig(machine: .desktop)
        rig.sys.displays = false
        rig.sys.builtIn = false
        rig.prefs.autoDimMinutes = 0
        await rig.engine.turnOn()
        XCTAssertFalse(rig.engine.record.displaysOff)
        XCTAssertFalse(rig.engine.status().hasDisplays)
    }

    @MainActor func testWithoutBetterDisplayTheDisplaysSleepInstead() async {
        let rig = EngineRig()
        rig.sys.betterDisplay = false
        await rig.engine.turnOn()
        await rig.engine.setDisplays(off: true)
        XCTAssertEqual(rig.sys.offCalls.last, false, "nothing unplugged: every display sleeps")
        XCTAssertTrue(rig.engine.record.disconnected.isEmpty)
    }

    @MainActor func testADisplayThatWontComeBackIsRetriedThenNamed() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        await rig.engine.setDisplays(off: true)
        rig.sys.reconnectFails = true
        await rig.engine.setDisplays(off: false)
        XCTAssertEqual(rig.engine.problem, .displaysStuck(1))
        XCTAssertEqual(rig.engine.record.disconnected, ["ext-1"], "kept, to try again")
        for _ in 0..<3 { await rig.engine.watchdog() }
        XCTAssertEqual(rig.sys.notes.last?.0, "A display didn't turn back on")
        rig.sys.reconnectFails = false
        await rig.engine.reconnectDisplays()
        XCTAssertNil(rig.engine.problem)
        XCTAssertTrue(rig.engine.record.disconnected.isEmpty)
    }

    // MARK: Watchdog

    @MainActor func testTheWatchdogFixesDriftThroughTheHelperOnlyNeverAPassword() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        rig.sys.summary = " SleepDisabled 0\n displaysleep 10"
        rig.sys.applied = []
        rig.sys.allowPasswordSeen = []
        rig.sys.releaseAssertions()
        await rig.engine.watchdog()
        XCTAssertEqual(rig.sys.applied, [PMSet.enableChanges(machine: .laptop)])
        XCTAssertEqual(rig.sys.allowPasswordSeen, [false])
        XCTAssertTrue(rig.sys.assertionsHeld)
        // The helper removed while on: said, not prompted.
        rig.sys.helper = .notInstalled
        rig.sys.applied = []
        rig.sys.summary = " SleepDisabled 0\n displaysleep 10"
        await rig.engine.watchdog()
        XCTAssertTrue(rig.sys.applied.isEmpty)
        XCTAssertEqual(rig.engine.problem, .helperGone)
        XCTAssertFalse(rig.sys.passwordAsked)
    }

    @MainActor func testTheWatchdogRestartsTheInputWatch() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        rig.sys.stopInputWatch()
        await rig.engine.watchdog()
        XCTAssertTrue(rig.sys.inputWatching)
    }

    // MARK: Battery and heat

    @MainActor func testItTurnsItselfOffAtTheBatteryFloorAndSaysSo() async {
        let rig = EngineRig()
        rig.sys.snapshot = PowerSnapshot(hasBattery: true, battery: 30, onPower: false)
        await rig.engine.turnOn()
        rig.sys.snapshot.battery = 19
        await rig.engine.powerCheck()
        XCTAssertTrue(rig.engine.isOn)
        XCTAssertEqual(rig.engine.warnings, [.lowBattery(19)])
        XCTAssertEqual(rig.sys.notes.count, 1, "told once")
        await rig.engine.powerCheck()
        XCTAssertEqual(rig.sys.notes.count, 1, "not twice")
        rig.sys.snapshot.battery = 10
        await rig.engine.powerCheck()
        XCTAssertFalse(rig.engine.isOn)
        XCTAssertEqual(rig.sys.notes.last?.0, "Keep Awake turned off")
        XCTAssertTrue(rig.sys.notes.last?.1.contains("10%") ?? false)
    }

    @MainActor func testItWontTurnOnAtTheFloorAndSaysWhy() async {
        let rig = EngineRig()
        rig.sys.snapshot = PowerSnapshot(hasBattery: true, battery: 9, onPower: false)
        let r = await rig.engine.turnOn()
        XCTAssertEqual(r, .blocked(KeepAwakeProblem.batteryTooLow(9).text))
        XCTAssertFalse(rig.engine.isOn)
        XCTAssertTrue(rig.sys.applied.isEmpty, "nothing changed only to be put back seconds later")
        XCTAssertEqual(rig.engine.problem, .batteryTooLow(9))
        rig.sys.snapshot.onPower = true
        let plugged = await rig.engine.turnOn()
        XCTAssertEqual(plugged, .on, "plugged in, 9% is fine")
    }

    @MainActor func testNeverMeansNever() async {
        let rig = EngineRig()
        rig.prefs.lowBatteryOffAt = 0
        rig.sys.snapshot = PowerSnapshot(hasBattery: true, battery: 4, onPower: false)
        await rig.engine.turnOn()
        await rig.engine.powerCheck()
        XCTAssertTrue(rig.engine.isOn)
    }

    @MainActor func testHotWarnsCriticalTurnsOff() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        rig.sys.snapshot.thermal = .serious
        await rig.engine.powerCheck()
        XCTAssertTrue(rig.engine.isOn)
        XCTAssertEqual(rig.sys.notes.last?.0, "Your Mac is hot")
        rig.sys.snapshot.thermal = .critical
        await rig.engine.powerCheck()
        XCTAssertFalse(rig.engine.isOn)
        XCTAssertTrue(rig.sys.notes.last?.1.contains("too hot") ?? false)
        // And it won't turn back on until it's cooler.
        let again = await rig.engine.turnOn()
        XCTAssertEqual(again, .blocked(KeepAwakeProblem.tooHot.text))
        rig.sys.snapshot.thermal = .fair
        let cooler = await rig.engine.turnOn()
        XCTAssertEqual(cooler, .on)
    }

    @MainActor func testLongOnBatteryAndLowPowerMode() async {
        let rig = EngineRig()
        rig.sys.snapshot = PowerSnapshot(hasBattery: true, battery: 90, onPower: false, lowPowerMode: true)
        await rig.engine.turnOn()
        await rig.engine.powerCheck()
        XCTAssertEqual(rig.engine.warnings, [.lowPowerMode])
        XCTAssertTrue(rig.sys.notes.isEmpty, "Low Power Mode is shown, never a notification")
        rig.clock = rig.clock.addingTimeInterval(2 * 3600 + 60)
        await rig.engine.powerCheck()
        XCTAssertEqual(rig.engine.warnings.first, .longOnBattery(hours: 2))
    }

    // MARK: Screen lock (opt-in)

    @MainActor func testTheScreenLockIsTurnedOffOnlyWhenChosenAndPutBack() async {
        let rig = EngineRig()
        rig.prefs.screenLockOff = true
        await rig.engine.turnOn()
        XCTAssertTrue(rig.engine.record.lockChanged)
        XCTAssertEqual(rig.engine.record.lockBefore, "immediate")
        XCTAssertEqual(rig.sys.lockAsks, [true], "asked when he turned it on")
        await rig.engine.turnOff()
        XCTAssertEqual(rig.sys.lockRestores, ["immediate"])
    }

    @MainActor func testTheWatchdogNeverAsksForThePassword() async {
        let rig = EngineRig()
        rig.prefs.screenLockOff = true
        rig.sys.lockAnswer = .noPassword
        await rig.engine.turnOn()
        XCTAssertEqual(rig.engine.problem, .lockNeedsPassword)
        rig.sys.lockIsOff = false
        await rig.engine.watchdog()
        XCTAssertEqual(rig.sys.lockAsks, [true, false])
    }

    @MainActor func testARefusedLockIsExplained() async {
        let rig = EngineRig()
        rig.prefs.screenLockOff = true
        rig.sys.lockAnswer = .refused("MKBDeviceSetGracePeriod error -14")
        await rig.engine.turnOn()
        XCTAssertEqual(rig.engine.problem, .lockRefused)
        XCTAssertTrue(KeepAwakeProblem.lockRefused.text.contains("Users & Groups"))
    }

    // MARK: Uninstall

    @MainActor func testRemovalRestoresSleepAndUnregistersTheHelper() async {
        let rig = EngineRig()
        await rig.engine.turnOn()
        let ok = await rig.engine.prepareForRemoval()
        XCTAssertTrue(ok)
        XCTAssertFalse(rig.engine.isOn)
        XCTAssertTrue(rig.sys.helperRemoved)
        XCTAssertEqual(rig.sys.applied.last?.last, PowerChange(.all, "disablesleep", 0))
    }

    // MARK: - Over a real connection

    func testAPhoneThatNamesItHearsKeepAwakeAndCanTurnItOn() async throws {
        let rig = try await Rig.make(port: 47941)
        defer { rig.stop() }
        rig.mac.keepAwake = KeepAwakeStatus(on: false, machine: .laptop, battery: 84)
        rig.server.macFeatures.append(KeepAwakeStatus.feature)
        rig.client.features.append(KeepAwakeStatus.feature)
        try await rig.connect()
        XCTAssertTrue(rig.client.macCanKeepAwake)
        try await rig.waitFor { rig.phone.keepAwakes.count == 1 }
        XCTAssertEqual(rig.phone.keepAwakes.first?.battery, 84)
        XCTAssertTrue(rig.client.keepAwake(KeepAwakeRequest(.on)))
        try await rig.waitFor { rig.mac.keepAwakeRequests.count == 1 }
        XCTAssertEqual(rig.mac.keepAwakeRequests.first?.known, .on)
        rig.server.broadcastKeepAwake(KeepAwakeStatus(on: true, machine: .laptop, lidCanClose: true, battery: 84))
        try await rig.waitFor { rig.phone.keepAwakes.count == 2 }
        XCTAssertEqual(rig.phone.keepAwakes.last?.phoneLine, "Lid can close · 84%")
    }

    func testAnOlderPhoneNeverHearsItAndAnOlderMacIsNeverAsked() async throws {
        let rig = try await Rig.make(port: 47942)
        defer { rig.stop() }
        rig.mac.keepAwake = KeepAwakeStatus(on: true)
        rig.server.macFeatures.append(KeepAwakeStatus.feature)
        try await rig.connect()
        rig.server.broadcastKeepAwake(KeepAwakeStatus(on: true))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(rig.phone.keepAwakes.isEmpty)
        let rtt = await rig.client.roundTrip(); XCTAssertNotNil(rtt)

        let rig2 = try await Rig.make(port: 47943)
        defer { rig2.stop() }
        rig2.client.features.append(KeepAwakeStatus.feature)
        try await rig2.connect()
        XCTAssertFalse(rig2.client.macCanKeepAwake)
        XCTAssertFalse(rig2.client.keepAwake(KeepAwakeRequest(.on)), "a Mac from before is never sent it")
    }
}

extension MacSide: LinkServerKeepAwakeDelegate {
    func keepAwakeStatus(_ server: LinkServer) -> KeepAwakeStatus? { keepAwake }
    func linkServer(_ server: LinkServer, keepAwake request: KeepAwakeRequest, from peerID: UUID) {
        keepAwakeRequests.append(request)
    }
}

extension PhoneSide: LinkClientKeepAwakeDelegate {
    func linkClient(_ client: LinkClient, keepAwake: KeepAwakeStatus, macID: UUID) {
        keepAwakes.append(keepAwake)
    }
}

// MARK: - The fake machine

@MainActor
final class FakeKeepAwakeStore: KeepAwakeStore {
    var record: KeepAwakeRecord?
    func load() -> KeepAwakeRecord? { record }
    func save(_ r: KeepAwakeRecord) { record = r }
}

@MainActor
final class FakeKeepAwakeSystem: KeepAwakeSystem {
    var machine: MachineKind
    var helper: KeepAwakeHelperState = .ready
    var sleepIsDisabled = false
    var summaryOverride: String?
    var summary: String {
        get { summaryOverride ?? " SleepDisabled \(sleepIsDisabled ? 1 : 0)\n displaysleep \(sleepIsDisabled ? 0 : 10)" }
        set { summaryOverride = newValue }
    }
    var snapshot = PowerSnapshot(hasBattery: true, battery: 84, onPower: false)
    var applied: [[PowerChange]] = []
    var allowPasswordSeen: [Bool] = []
    var applyAnswer: KeepAwakeApply = .done
    var passwordAnswer: KeepAwakeApply = .done
    var passwordAsked = false
    private(set) var assertionsHeld = false
    var builtIn = true
    var displays = true
    var brightness: Float = 0.7
    var brightnessSets: [Float] = []
    var betterDisplay = true
    var offCalls: [Bool] = []
    var reconnected: [[String]] = []
    var reconnectFails = false
    var audio: [Bool] = []
    var lockIsOff: Bool? = false
    var lockAnswer: KeepAwakeLock = .changed(before: "immediate")
    var lockAsks: [Bool] = []
    var lockRestores: [String] = []
    var lockCalls: Int { lockAsks.count + lockRestores.count }
    private(set) var inputWatching = false
    var lastInput: Date?
    var ignoredUntil: Date?
    var notes: [(String, String)] = []
    var other: String?
    var helperRemoved = false

    init(machine: MachineKind) { self.machine = machine }

    func pmsetSummary() -> String { summary }
    func pmsetCustom() -> String { KeepAwakeTests.custom }
    func power() -> PowerSnapshot { snapshot }
    func helperState() -> KeepAwakeHelperState { helper }
    func apply(_ changes: [PowerChange], allowPassword: Bool) async -> KeepAwakeApply {
        allowPasswordSeen.append(allowPassword)
        var answer = applyAnswer
        if helper != .ready {
            if allowPassword { passwordAsked = true; answer = passwordAnswer } else { answer = applyAnswer == .done ? .needsHelper : applyAnswer }
        }
        if answer == .done {
            applied.append(changes)
            if let d = changes.first(where: { $0.key == "disablesleep" }) { sleepIsDisabled = d.value == 1; summaryOverride = nil }
        }
        return answer
    }
    func holdAssertions() { assertionsHeld = true }
    func releaseAssertions() { assertionsHeld = false }
    var hasBuiltInDisplay: Bool { builtIn }
    var hasDisplays: Bool { displays }
    func builtInBrightness() -> Float? { builtIn ? brightness : nil }
    func setBuiltInBrightness(_ level: Float) { brightnessSets.append(level); brightness = level }
    var betterDisplayInstalled: Bool { betterDisplay }
    func displaysOff(unplugExternals: Bool) async -> [String] { offCalls.append(unplugExternals); return unplugExternals ? ["ext-1"] : [] }
    func displaysOn(reconnect: [String]) async -> [String] { reconnected.append(reconnect); return reconnectFails ? reconnect : [] }
    func wakeDisplays() {}
    func protectAudio(_ on: Bool) { audio.append(on) }
    func screenLockIsOff() -> Bool? { lockIsOff }
    func screenLockOff(mayAsk: Bool) async -> KeepAwakeLock {
        lockAsks.append(mayAsk)
        if case .changed = lockAnswer { lockIsOff = true }
        return lockAnswer
    }
    func screenLockRestore(to before: String) async -> KeepAwakeLock { lockRestores.append(before); lockIsOff = false; return .restored }
    func startInputWatch() -> Bool { inputWatching = true; return true }
    func stopInputWatch() { inputWatching = false }
    var lastPhysicalInput: Date? { lastInput }
    func ignoreInput(until: Date) { ignoredUntil = until }
    func notify(_ title: String, _ body: String) { notes.append((title, body)) }
    func otherKeeper() -> String? { other }
    func removeHelper() -> Bool { helperRemoved = true; helper = .notInstalled; return true }
}

@MainActor
final class EngineRig {
    let sys: FakeKeepAwakeSystem
    let store: FakeKeepAwakeStore
    var prefs = KeepAwakePrefs()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var engine: KeepAwakeEngine!

    init(machine: MachineKind = .laptop, store: FakeKeepAwakeStore? = nil, sys: FakeKeepAwakeSystem? = nil) {
        self.sys = sys ?? FakeKeepAwakeSystem(machine: machine)
        let store = store ?? FakeKeepAwakeStore()
        self.store = store
        engine = KeepAwakeEngine(system: self.sys, store: store, prefs: { [unowned self] in self.prefs }, now: { [unowned self] in self.clock })
    }

    /// A new run of the app on the same machine and the same saved record.
    func relaunch() -> EngineRig {
        let next = EngineRig(machine: sys.machine, store: store, sys: sys)
        next.prefs = prefs
        next.clock = clock
        sys.applied = []
        sys.brightnessSets = []
        return next
    }
}
