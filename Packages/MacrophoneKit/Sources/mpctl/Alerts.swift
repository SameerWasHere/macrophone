import Foundation
import MacrophoneKit

// `mpctl serve` keeps windows on watch as the Mac does (Watch/WindowAlerts.swift) and, a few
// seconds after one is put on watch (--alert-after, 6 s), says it finished — with the demo
// window's picture: "ALERT WATCH on …", "ALERT sent …".
extension ServeDelegate: LinkServerAlertsDelegate {
    func alertWatches(_ server: LinkServer) -> [AlertWatch] { alertWatchList }

    func linkServer(_ server: LinkServer, chatAnswers on: Bool, from peerID: UUID) {
        chatAnswers = on
        stdout("CHAT ANSWERS \(on ? "on" : "off")")
    }

    /// The answer finds you (Nov 8 2026): with --answer-after <s>, a dictation sent to an app
    /// "answers" that many seconds after it landed — "‹App› answered you", a reply's last lines and
    /// the demo window's picture, as the Mac's ReplyWatcher sends for a chat the phone wrote to.
    /// Only while the phone's switch is on; with no phone connected the Mac would use iCloud.
    func answerLater(bundleID: String, key: String?, name: String, server: LinkServer) {
        guard let after = flag("--answer-after").flatMap(Double.init), server.macFeatures.contains(ChatAnswers.feature) else { return }
        let ref = TargetRef.app(bundleID: bundleID, windowKey: key, name: name)
        let demo = self.demo(for: ref)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(after * 1e9))
            guard self.chatAnswers == true else {
                stdout("ANSWER held: the phone's switch is \(self.chatAnswers == false ? "off" : "unknown (a phone from before)")")
                return
            }
            let reply = ["Here's the change: the token now refreshes a minute", "before it expires, and the login test passes again."]
            let a = MacAlert(ref: ref, appName: name, title: name, kind: .answered,
                             headline: AlertWords.headline(.answered, app: name, newLines: reply),
                             detail: AlertWords.reply(reply), jpeg: demo.image().flatMap(MacAlerts.jpeg), chat: true)
            let phones = server.phones(with: MacAlerts.feature)
            guard !phones.isEmpty else { stdout("ANSWER no phone connected (the Mac would send it through iCloud)"); return }
            for p in phones { await server.send(.macAlert(a), to: p) }
            stdout("ANSWER sent: \(a.headline) · \(a.detail ?? "-") · picture \((a.jpeg?.count ?? 0) / 1024) KB")
        }
    }

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
