import Foundation
import MacrophoneKit

/// Keep Awake reaches the phones (feature `keepAwake`: the status after the welcome and on every
/// change; a phone's on / off / displays / timer) and the command line (`/v1/awake`).
extension AppModel: LinkServerKeepAwakeDelegate {
    func wireKeepAwake() {
        server.macFeatures.append(KeepAwakeStatus.feature)
        keepAwake.onStatus = { [weak self] s in self?.server.broadcastKeepAwake(s) }
        api.awake = { [weak self] action, reply in
            guard let self else { reply(503, Data("{}".utf8)); return }
            Task { @MainActor in
                let k = self.keepAwake!
                switch action {
                case "on": await k.setOn(true, fromMac: false)
                case "off": await k.setOn(false, fromMac: false)
                case "displays_on": await k.engine.setDisplays(off: false)
                case "displays_off": await k.engine.setDisplays(off: true)
                default: break
                }
                k.refresh()
                if let action { self.log.add("keep awake: \(action) from the command line") }
                reply(200, Self.awakeJSON(k))
            }
        }
    }

    func keepAwakeStatus(_ server: LinkServer) -> KeepAwakeStatus? { keepAwake.engine.status() }

    func linkServer(_ server: LinkServer, keepAwake request: KeepAwakeRequest, from peerID: UUID) {
        guard let action = request.known else { return }
        log.add("keep awake: \(action.rawValue) from the iPhone")
        let k = keepAwake!
        Task { @MainActor in
            switch action {
            case .on: await k.setOn(true, fromMac: false)
            case .off: await k.setOn(false, fromMac: false)
            case .displaysOn: await k.engine.setDisplays(off: false)
            case .displaysOff: await k.engine.setDisplays(off: true)
            case .timer: await k.engine.setTimer(minutes: request.minutes)
            // From the phone: only through the helper (nobody may be at the Mac for a password).
            case .restoreSleep: await k.engine.restoreNormalSleep(allowPassword: false)
            }
            k.refresh()
            // Always answer, even when nothing changed (a refused turn-on says why).
            await server.send(.keepAwake(k.engine.status()), to: peerID)
        }
    }

    /// The API's answer: snake_case, every key always present.
    static func awakeJSON(_ k: KeepAwakeService) -> Data {
        let s = k.status
        let iso = ISO8601DateFormatter()
        let body: [String: Any] = [
            "on": s.on,
            "line": k.macLine,
            "machine": s.machine.rawValue,
            "lid_can_close": s.lidCanClose,
            "displays_off": s.displaysOff,
            "back_at": s.backAt.map { iso.string(from: $0) } ?? NSNull(),
            "battery": s.battery.map { $0 as Any } ?? NSNull(),
            "charging": s.charging,
            "blocked": s.blocked ?? NSNull(),
            "problem": s.problem ?? NSNull(),
            "warning": s.warning ?? NSNull(),
            "sleep_still_off": s.sleepStillOff,
            "dry_run": k.dryRun,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
    }
}
