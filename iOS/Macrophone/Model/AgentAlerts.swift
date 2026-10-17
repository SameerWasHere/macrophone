import CloudKit
import MacrophoneKit
import UIKit
import UserNotifications

/// "Your agent needs you" on the phone (Oct 16 2026): the Mac says a window is asking something
/// nobody is looking at, and this posts a notification — "Codex is asking you something" with the
/// question. A tap opens that window, where its answers wait as buttons. Permission is asked the
/// first time a window is watched, when it makes sense.
///
/// While the app is closed nothing reaches it over the network, so a build signed for iCloud also
/// subscribes to the person's own private iCloud database: the Mac writes a small record there
/// ("Claude is asking you something", the window) and Apple pushes it. No server of ours.
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
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await subscribeInCloud()
    }

    // MARK: Through iCloud, for when the app is closed

    static let container = "iCloud.com.sameer.macrophone"
    static let subscriptionID = "ask"
    /// Only a build signed with the iCloud entitlement may touch CloudKit; that build sets this.
    static var cloudAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "MacrophoneCloudAlerts") as? String == "YES" }
    /// The subscription is in place: the hello tells the Mac to keep looking while the app is closed.
    static var cloudReady: Bool { UserDefaults.standard.bool(forKey: "alerts.cloud") }

    /// Subscribes once (saving it again is harmless). Needs notifications allowed and iCloud.
    func subscribeInCloud() async {
        guard Self.cloudAvailable, model?.settings.agentAlerts == true,
              await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized else { return }
        UIApplication.shared.registerForRemoteNotifications()
        let sub = CKQuerySubscription(recordType: "Ask", predicate: NSPredicate(value: true), subscriptionID: Self.subscriptionID,
                                      options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = ["line"]
        info.subtitleLocalizationKey = "%1$@"
        info.subtitleLocalizationArgs = ["window"]
        info.alertBody = "Tap to see it and answer."
        info.soundName = "default"
        info.desiredKeys = ["ref"]
        sub.notificationInfo = info
        // A new container (or a busy iCloud) asks for patience: wait as long as it says, a few times.
        for attempt in 1...4 {
            do {
                _ = try await CKContainer(identifier: Self.container).privateCloudDatabase.save(sub)
                if !Self.cloudReady { model?.log.add("alerts: set up through iCloud") }
                UserDefaults.standard.set(true, forKey: "alerts.cloud")
                model?.alertsReadyInCloud()
                return
            } catch let e as CKError where [.requestRateLimited, .serviceUnavailable, .zoneBusy].contains(e.code) && attempt < 4 {
                let wait = e.retryAfterSeconds ?? Double(attempt * 20)
                model?.log.add("alerts: iCloud asked to wait \(Int(wait)) s")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            } catch {
                model?.log.add("alerts: iCloud didn't take the subscription (\((error as? CKError)?.code.rawValue ?? -1)): \(error.localizedDescription)")
                return
            }
        }
    }

    #if DEBUG
    /// Saves one sample record so the Development schema gets the type and its fields (the Mac
    /// writes them; the type is then deployed to Production in the CloudKit Console).
    func debugCreateSchema() async {
        let r = CKRecord(recordType: "Ask", recordID: CKRecord.ID(recordName: "ask-schema"))
        r["line"] = "Claude is asking you something" as CKRecordValue
        r["window"] = "Claude" as CKRecordValue
        r["ref"] = "{}" as CKRecordValue
        r["promptID"] = "0" as CKRecordValue
        do {
            _ = try await CKContainer(identifier: Self.container).privateCloudDatabase.save(r)
            model?.log.add("alerts: schema record saved")
            await subscribeInCloud()
        } catch {
            model?.log.add("alerts: schema record failed: \(error.localizedDescription)")
        }
    }
    #endif

    /// Alerts turned off: the subscription goes, so nothing arrives while the app is closed.
    func unsubscribeInCloud() async {
        guard Self.cloudAvailable else { return }
        _ = try? await CKContainer(identifier: Self.container).privateCloudDatabase.deleteSubscription(withID: Self.subscriptionID)
        UserDefaults.standard.set(false, forKey: "alerts.cloud")
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
        let info = response.notification.request.content.userInfo
        // From the Mac over the network, or from iCloud (the window rides in the record).
        let s = info["ref"] as? String
            ?? (CKNotification(fromRemoteNotificationDictionary: info) as? CKQueryNotification)?.recordFields?["ref"] as? String
        guard let s, let ref = try? JSONDecoder().decode(TargetRef.self, from: Data(s.utf8)) else { return }
        await MainActor.run { self.model?.openAttention(ref) }
    }
}
