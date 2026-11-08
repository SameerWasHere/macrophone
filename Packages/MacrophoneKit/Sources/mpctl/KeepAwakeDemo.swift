import Foundation
import MacrophoneKit

// Keep Awake in the protocol proof (Nov 7 2026). The demo Mac changes nothing: it keeps a made-up
// state, prints AWAKE on / AWAKE off / AWAKE displays off / AWAKE timer 60m for what a phone asks,
// and tells every phone that shows it. A laptop at 84% by default; `--awake-desktop` is an iMac
// (no lid, no battery), `--awake-blocked` has SameerOS's On The Go in the way, `--awake-no-helper`
// turns on without the lid, `--awake-battery N` sets the level, `--no-awake` is a Mac from before.

enum KeepAwakeDemo {
    nonisolated(unsafe) static var status: KeepAwakeStatus = {
        var s = KeepAwakeStatus(machine: has("--awake-desktop") ? .desktop : .laptop)
        if s.machine == .laptop { s.battery = flag("--awake-battery").flatMap(Int.init) ?? 84; s.onPower = false }
        if has("--awake-blocked") { s.blocked = OtherKeeper.words(onTheGoActive: true, sameerOSHelperLoaded: true) }
        return s
    }()
}

extension ServeDelegate: LinkServerKeepAwakeDelegate {
    func keepAwakeStatus(_ server: LinkServer) -> KeepAwakeStatus? {
        stdout("AWAKE sent \(KeepAwakeDemo.status.phoneLine)")
        return KeepAwakeDemo.status
    }

    func linkServer(_ server: LinkServer, keepAwake request: KeepAwakeRequest, from peerID: UUID) {
        guard let action = request.known else { return }
        var s = KeepAwakeDemo.status
        switch action {
        case .on:
            if s.blocked == nil {
                s.on = true
                s.since = Date()
                s.lidCanClose = s.machine == .laptop && !has("--awake-no-helper")
                s.problem = s.machine == .laptop && has("--awake-no-helper") ? KeepAwakeProblem.needsHelper.text : nil
            }
            stdout(s.blocked == nil ? "AWAKE on" : "AWAKE on refused — \(s.blocked!)")
        case .off:
            s.on = false; s.lidCanClose = false; s.displaysOff = false; s.displaysOffSince = nil; s.backAt = nil; s.since = nil; s.problem = nil
            stdout("AWAKE off")
        case .displaysOff where s.on:
            s.displaysOff = true; s.displaysOffSince = Date()
            stdout("AWAKE displays off")
        case .displaysOn where s.on:
            s.displaysOff = false; s.displaysOffSince = nil
            stdout("AWAKE displays on")
        case .timer:
            let m = request.minutes ?? 0
            s.backAt = m > 0 ? Date().addingTimeInterval(TimeInterval(m * 60)) : nil
            if m > 0, s.blocked == nil { s.on = true; s.lidCanClose = s.machine == .laptop && !has("--awake-no-helper") }
            stdout(m > 0 ? "AWAKE timer \(m)m" : "AWAKE timer off")
        case .restoreSleep:
            s.sleepStillOff = false
            stdout("AWAKE restore sleep")
        default:
            stdout("AWAKE \(action.rawValue) ignored (off)")
        }
        KeepAwakeDemo.status = s
        // As the Mac does: the asking phone always hears back, and every phone that shows it.
        server.broadcastKeepAwake(s)
    }
}

extension PhoneDelegate: LinkClientKeepAwakeDelegate {
    func linkClient(_ client: LinkClient, keepAwake k: KeepAwakeStatus, macID: UUID) {
        var line = "KEEP AWAKE \(k.on ? "on" : "off") · \(k.phoneLine)"
        if k.displaysOff { line += " · displays off" }
        if let p = k.problem { line += " · problem: \(p)" }
        stdout(line)
    }
}
