import Foundation
import MacrophoneKit

// `mpctl serve` keeps windows on watch as the Mac does (Watch/WindowAlerts.swift) and, a few
// seconds after one is put on watch (--alert-after, 6 s), says it finished — with the demo
// window's picture: "ALERT WATCH on …", "ALERT sent …".
extension ServeDelegate: LinkServerAlertsDelegate {
    func alertWatches(_ server: LinkServer) -> [AlertWatch] { alertWatchList }

    func linkServer(_ server: LinkServer, alertWatch request: AlertWatchRequest, from peerID: UUID) {
        guard case let .app(bundleID, key, name) = request.ref else { return }
        alertWatchList.removeAll { $0.ref == request.ref }
        if request.on {
            let title = key == "42" ? "codex — ~/api" : name
            alertWatchList.insert(AlertWatch(ref: request.ref, bundleID: bundleID, windowKey: key, appName: name, title: title, since: Date()), at: 0)
        }
        server.broadcastAlertWatches(alertWatchList)
        stdout("ALERT WATCH \(request.on ? "on" : "off") \(name) (\(alertWatchList.count) on watch)")
        guard request.on else { return }
        let demo = self.demo(for: request.ref)
        Task {
            try? await Task.sleep(nanoseconds: UInt64((Double(flag("--alert-after") ?? "6") ?? 6) * 1e9))
            guard self.alertWatchList.contains(where: { $0.ref == request.ref }) else { return }
            let a = MacAlert(ref: request.ref, appName: name, title: self.alertWatchList.first { $0.ref == request.ref }?.title ?? name,
                             kind: .finished, headline: "\(name) finished", detail: "Done in 4.2s · 0 errors",
                             jpeg: demo.image().flatMap(MacAlerts.jpeg))
            for p in server.phones(with: MacAlerts.feature) { await server.send(.macAlert(a), to: p) }
            stdout("ALERT sent: \(a.headline) · picture \((a.jpeg?.count ?? 0) / 1024) KB")
        }
    }
}
