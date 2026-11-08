import CoreAudio
import Foundation

/// Keeps sound on a living output while displays come and go (Keep Awake, Nov 7 2026, from On
/// The Go's audio guard). A display's speakers vanish when it's unplugged or sleeps and come back
/// when it wakes; coreaudiod sometimes lands on the dead device, or crackles. So:
///   1. Around every display change, sound on a display moves to the built-in speakers first and
///      goes back once that display's endpoint is alive again (devices by UID — an object id
///      changes when a display re-registers).
///   2. Inside the 15 s after a change, a switch nobody chose is undone; outside it, a switch is
///      the person's choice and is followed.
///   3. Every 30 s while Keep Awake is on: is the output alive, with channels and a sane rate?
///      Once wrong → back to the preferred device; twice → restart coreaudiod (10-min cooldown).
/// Runs only while Keep Awake is on. In a dry run it decides and logs, and changes nothing.
@MainActor
final class AudioGuard {
    private let log: (String) -> Void
    private let dryRun: Bool
    var restartViaHelper: (() async -> Bool)?

    private var preferredUID: String?
    private var preferredSystemUID: String?
    private var savedUID: String?
    private var savedSystemUID: String?
    private var transitionUntil = Date.distantPast
    private var selfChangeUntil = Date.distantPast
    private var healthTimer: Timer?
    private var failures = 0
    private var lastRestart = Date.distantPast
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(dryRun: Bool, log: @escaping (String) -> Void) {
        self.dryRun = dryRun
        self.log = log
    }

    var running: Bool { healthTimer != nil }

    func start() {
        guard healthTimer == nil else { return }
        install()
        if let id = defaultDevice(system: false) {
            preferredUID = uid(id)
            preferredSystemUID = defaultDevice(system: true).flatMap(uid)
        }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.healthCheck() } }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        healthTimer = t
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        for (address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, block)
        }
        listeners = []
    }

    private var inTransition: Bool { Date() < transitionUntil }

    /// Right before displays go off.
    func protect() {
        transitionUntil = Date().addingTimeInterval(15)
        guard let out = defaultDevice(system: false) else { return }
        if !isDisplay(out), let u = uid(out) { preferredUID = u }
        if let sys = defaultDevice(system: true), isDisplay(sys) {
            savedSystemUID = uid(sys)
            if let b = builtInOutput() { setDefault(b, system: true, why: "alerts off a display") }
        }
        guard isDisplay(out) else { return }
        savedUID = uid(out)
        if let b = builtInOutput() { setDefault(b, system: false, why: "sound off a display before it goes") }
    }

    /// After displays come back: waits (≤10 s) for the saved endpoint to be alive.
    func restore() {
        transitionUntil = Date().addingTimeInterval(15)
        let want = [(savedUID, false), (savedSystemUID, true)].compactMap { u, s in u.map { ($0, s) } }
        savedUID = nil
        savedSystemUID = nil
        guard !want.isEmpty else { return }
        let deadline = Date().addingTimeInterval(10)
        func attempt() {
            let ready = want.allSatisfy { device($0.0).map(isAlive) ?? false }
            if ready || Date() > deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        for (u, system) in want {
                            if let id = self.device(u), self.isAlive(id) {
                                self.setDefault(id, system: system, why: "sound back on the display")
                                if !system { self.preferredUID = u }
                            } else {
                                self.log("keep awake: audio — a display's speakers didn't come back in 10 s, staying put")
                            }
                        }
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { attempt() } }
        }
        attempt()
    }

    private func install() {
        guard listeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed(selector) }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    private func changed(_ selector: AudioObjectPropertySelector) {
        if selector == kAudioHardwarePropertyDevices {
            if let out = defaultDevice(system: false), !isAlive(out) { reset(system: false, why: "the output died") }
            return
        }
        let system = selector == kAudioHardwarePropertyDefaultSystemOutputDevice
        guard Date() >= selfChangeUntil else { return }
        guard let now = defaultDevice(system: system) else { reset(system: system, why: "no output"); return }
        let preferred = system ? preferredSystemUID : preferredUID
        if !isAlive(now) {
            reset(system: system, why: "moved to a dead device")
        } else if inTransition, let p = preferred, p != uid(now), device(p).map(isAlive) == true {
            reset(system: system, why: "moved by a display change")
        } else if !inTransition {
            if system { preferredSystemUID = uid(now) } else { preferredUID = uid(now) }
        }
    }

    private func reset(system: Bool, why: String) {
        let p = system ? preferredSystemUID : preferredUID
        if let p, let id = device(p), isAlive(id) { setDefault(id, system: system, why: why) }
        else if let b = builtInOutput() { setDefault(b, system: system, why: "\(why) (built-in)") }
    }

    private func healthCheck() {
        guard !inTransition else { return }
        guard let problem = diagnose() else { failures = 0; return }
        failures += 1
        log("keep awake: audio health — \(problem) (\(failures)×)")
        if failures == 1 { reset(system: false, why: "health check") } else { restartCoreAudio() }
    }

    func diagnose() -> String? {
        guard let out = defaultDevice(system: false) else { return "no output device" }
        guard isAlive(out) else { return "the output isn't alive" }
        guard channels(out) > 0 else { return "the output has no channels" }
        let rate = sampleRate(out)
        guard rate >= 8000 && rate <= 384_000 else { return "the output's rate is \(Int(rate))" }
        return nil
    }

    private func restartCoreAudio() {
        guard Date().timeIntervalSince(lastRestart) > 600 else { return }
        lastRestart = Date()
        failures = 0
        if dryRun { log("keep awake (dry run): would restart coreaudiod"); return }
        log("keep awake: audio — restarting coreaudiod")
        Task.detached {
            let ok = Shell.run("/bin/launchctl", ["kickstart", "-k", "system/com.apple.audio.coreaudiod"]).status == 0
            if !ok { _ = await self.restartViaHelper?() }
        }
    }

    // MARK: CoreAudio

    private func setDefault(_ device: AudioObjectID, system: Bool, why: String) {
        let kind = describe(device)
        if dryRun { log("keep awake (dry run): would set the \(system ? "alert" : "sound") output to the \(kind) device — \(why)"); return }
        var dev = device
        var address = AudioObjectPropertyAddress(
            mSelector: system ? kAudioHardwarePropertyDefaultSystemOutputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        selfChangeUntil = Date().addingTimeInterval(1.5)
        let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &dev)
        log("keep awake: audio — \(system ? "alert" : "sound") output to the \(kind) device (\(st == noErr ? "ok" : "\(st)")) — \(why)")
    }

    private func defaultDevice(system: Bool) -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        let ok = get(AudioObjectID(kAudioObjectSystemObject), system ? kAudioHardwarePropertyDefaultSystemOutputDevice : kAudioHardwarePropertyDefaultOutputDevice, &id)
        return ok && id != kAudioObjectUnknown ? id : nil
    }

    private func devices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private func builtInOutput() -> AudioObjectID? { devices().first { transport($0) == kAudioDeviceTransportTypeBuiltIn && channels($0) > 0 } }
    private func device(_ uid: String) -> AudioObjectID? { devices().first { self.uid($0) == uid } }
    private func uid(_ d: AudioObjectID) -> String? { string(d, kAudioDevicePropertyDeviceUID) }
    private func transport(_ d: AudioObjectID) -> UInt32 { var t: UInt32 = 0; _ = get(d, kAudioDevicePropertyTransportType, &t); return t }
    private func isDisplay(_ d: AudioObjectID) -> Bool { [kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort].contains(transport(d)) }
    private func isAlive(_ d: AudioObjectID) -> Bool { var a: UInt32 = 0; return get(d, kAudioDevicePropertyDeviceIsAlive, &a) && a != 0 }
    private func sampleRate(_ d: AudioObjectID) -> Double { var r: Float64 = 0; _ = get(d, kAudioDevicePropertyNominalSampleRate, &r); return r }

    private func channels(_ d: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(d, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(d, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// A device by its kind only — the log keeps no device names.
    private func describe(_ d: AudioObjectID) -> String {
        switch transport(d) {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        default: return "other"
        }
    }

    private func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) } == noErr
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }
}
