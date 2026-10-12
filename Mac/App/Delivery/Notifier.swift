import AppKit
import CoreGraphics
import UserNotifications

/// Notification Center, for "Clipboard + notification". The popup is what you see while
/// you're at the Mac; a notification is left in Notification Center when the popup can't be
/// seen (the screen is locked or asleep), so nothing that arrived while you were away is a
/// surprise. Permission is asked the first time it's needed.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    func setUp() {
        center.delegate = self
        refresh()
    }

    func refresh() {
        center.getNotificationSettings { s in
            let st = s.authorizationStatus
            Task { @MainActor in self.status = st }
        }
    }

    /// Ask once, at first need.
    func requestIfNeeded() {
        guard status == .notDetermined else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refresh() }
        }
    }

    /// The popup won't be seen right now.
    static var personIsAway: Bool {
        if let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if (d["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
            if (d["CGSSessionScreenIsLocked"] as? Int) == 1 { return true }
        }
        return CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "dictations"
        content.interruptionLevel = .passive
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // While the Mac is in use the popup already showed it; keep it in the list only.
        completionHandler([.list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in AppDelegate.shared?.openMainWindow(pane: .history) }
        completionHandler()
    }
}
