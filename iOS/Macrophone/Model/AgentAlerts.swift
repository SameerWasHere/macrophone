import MacrophoneKit
import UserNotifications

/// "Your agent needs you" on the phone (Oct 16 2026): the Mac says a window is asking something
/// nobody is looking at, and this posts a notification — "Codex is asking you something" with the
/// question. A tap opens that window, where its answers wait as buttons. Permission is asked the
/// first time a window is watched, when it makes sense.
@MainActor
final class AgentAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentAlerts()
    private weak var model: AppModel?

    func install(_ model: AppModel) {
        self.model = model
        UNUserNotificationCenter.current().delegate = self
    }

    func askIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(_ a: Attention) {
        let c = UNMutableNotificationContent()
        c.title = "\(a.appName) is asking you something"
        if a.title != a.appName { c.subtitle = a.title }
        c.body = a.question ?? "Tap to see it and answer."
        c.sound = .default
        c.threadIdentifier = "attention"
        if let data = try? JSONEncoder().encode(a.ref), let ref = String(data: data, encoding: .utf8) { c.userInfo = ["ref": ref] }
        // One per window: a newer question replaces the older one.
        let request = UNNotificationRequest(identifier: "attention-\(a.title)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["ref"] as? String,
              let ref = try? JSONDecoder().decode(TargetRef.self, from: Data(s.utf8)) else { return }
        await MainActor.run { self.model?.openAttention(ref) }
    }
}
