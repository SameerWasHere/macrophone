import CloudKit
import Combine
import MacrophoneKit
import SwiftUI
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
///
/// **Whether that will work is on the screen (Nov 7 2026).** Sameer put a window on watch, left,
/// and the Mac's log said "the phone hasn't said it subscribed" — the phone had never managed to,
/// and nothing told him. `cloudState` now says where the subscription stands — notifications off,
/// no iCloud account, iCloud refusing, set up — and Settings › Alerts shows the one line and the
/// one button that fixes it. The subscription is tried again each time the app comes to the
/// front while something wants alerts, so a one-time refusal (no network on the first try, iCloud
/// signed in later) doesn't last.
@MainActor
final class AgentAlerts: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    static let shared = AgentAlerts()
    private weak var model: AppModel?
    private var bag: Set<AnyCancellable> = []

    /// Where alerts with the app closed stand.
    enum CloudState: Equatable {
        /// Nothing wants alerts yet, or nothing has been tried.
        case idle
        /// This build can't (not signed for iCloud).
        case unavailable
        /// Notifications are off for Macrophone in Settings.
        case notificationsOff
        /// No iCloud account on this iPhone (or iCloud Drive restricted).
        case noAccount
        /// iCloud refused the subscription: the code and its words.
        case failed(String)
        case trying
        case ready
    }

    @Published private(set) var cloudState: CloudState = AgentAlerts.cloudReady ? .ready : .idle

    func install(_ model: AppModel) {
        self.model = model
        UNUserNotificationCenter.current().delegate = self
        // Back in front: Settings may have changed (notifications allowed, iCloud signed in), or
        // the network is here now — try again where it failed.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { await self?.retryIfNeeded() } }
            .store(in: &bag)
    }

    /// `force`: a window was just put on watch (alerts are wanted whatever the agents switch says).
    func askIfNeeded(force: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await subscribeInCloud(force: force)
    }

    /// Something wants alerts: the agents switch, or a window on watch.
    var wanted: Bool { model?.settings.agentAlerts == true || model?.alertWatches.isEmpty == false }

    /// Tries again when the last try didn't take (the app came to the front, a watch arrived).
    func retryIfNeeded() async {
        guard wanted else { return }
        switch cloudState {
        case .ready, .trying, .unavailable: return
        case .idle, .notificationsOff, .noAccount, .failed: await subscribeInCloud()
        }
    }

    // MARK: Through iCloud, for when the app is closed

    static let container = "iCloud.com.sameer.macrophone"
    static let subscriptionID = "ask"
    /// Only a build signed with the iCloud entitlement may touch CloudKit; that build sets this.
    static var cloudAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "MacrophoneCloudAlerts") as? String == "YES" }
    /// The subscription is in place: the hello tells the Mac to keep looking while the app is closed.
    static var cloudReady: Bool { UserDefaults.standard.bool(forKey: "alerts.cloud") }

    /// Subscribes once (saving it again is harmless). Needs notifications allowed and iCloud.
    func subscribeInCloud(force: Bool = false) async {
        guard force || wanted else { return }
        guard Self.cloudAvailable else {
            cloudState = .unavailable
            model?.log.add("alerts: this build can't get alerts while closed (not signed for iCloud)")
            return
        }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            cloudState = .notificationsOff
            model?.log.add("alerts: notifications aren't allowed (\(status.rawValue)), so none while the app is closed")
            return
        }
        // No account: iCloud would refuse with "not authenticated" after a round trip; say it plainly.
        if let account = try? await CKContainer(identifier: Self.container).accountStatus(), account != .available {
            cloudState = .noAccount
            model?.log.add("alerts: no iCloud account for alerts while the app is closed (\(account.rawValue))")
            return
        }
        cloudState = .trying
        UIApplication.shared.registerForRemoteNotifications()
        let sub = CKQuerySubscription(recordType: "Ask", predicate: NSPredicate(value: true), subscriptionID: Self.subscriptionID,
                                      options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = ["line"]
        info.subtitleLocalizationKey = "%1$@"
        info.subtitleLocalizationArgs = ["window"]
        info.alertBody = "Tap to see it."
        info.soundName = "default"
        info.desiredKeys = ["ref"]
        // The notification extension (MacrophoneAlerts) fills in the line under it and the picture
        // of the window, and deletes the record (Nov 6 2026).
        info.shouldSendMutableContent = true
        info.category = "macAlert"
        sub.notificationInfo = info
        // A new container (or a busy iCloud) asks for patience: wait as long as it says, a few times.
        for attempt in 1...4 {
            do {
                _ = try await CKContainer(identifier: Self.container).privateCloudDatabase.save(sub)
                if !Self.cloudReady { model?.log.add("alerts: set up through iCloud") }
                UserDefaults.standard.set(true, forKey: "alerts.cloud")
                cloudState = .ready
                model?.alertsReadyInCloud()
                return
            } catch let e as CKError where [.requestRateLimited, .serviceUnavailable, .zoneBusy, .networkUnavailable, .networkFailure].contains(e.code) && attempt < 4 {
                let wait = e.retryAfterSeconds ?? Double(attempt * 20)
                model?.log.add("alerts: iCloud asked to wait \(Int(wait)) s")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            } catch {
                let code = (error as? CKError)?.code.rawValue ?? -1
                cloudState = .failed("\(code)")
                model?.log.add("alerts: iCloud didn't take the subscription (\(code)): \(error.localizedDescription)")
                return
            }
        }
        cloudState = .failed("busy")
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
        cloudState = .idle
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

    /// Every alert from the Mac, one look (AlertNotification): the headline, the window's title,
    /// the line, and the picture of the window. One per window: a newer one replaces it.
    func post(_ a: MacAlert) {
        let c = UNMutableNotificationContent()
        AlertNotification.fill(c, with: a)
        c.sound = .default
        let request = UNNotificationRequest(identifier: a.notificationID, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        Task { await AlertNotification.removeOlder(window: MacAlert.windowKey(a.ref), except: a.notificationID) }
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

/// Settings › Alerts: one line and one button when alerts can't reach this iPhone with Macrophone
/// closed (Nov 7 2026). Nothing while they can, or while nothing wants them.
struct CloudAlertsStatusRow: View {
    @ObservedObject private var alerts = AgentAlerts.shared

    var body: some View {
        switch alerts.cloudState {
        case .idle, .ready, .trying:
            EmptyView()
        case .unavailable:
            row("This build can't get alerts while Macrophone is closed", symbol: "icloud.slash", button: nil) {}
        case .notificationsOff:
            row("Notifications are off, so alerts can't reach you", symbol: "bell.slash", button: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        case .noAccount:
            row("Sign in to iCloud to get alerts while Macrophone is closed", symbol: "icloud.slash", button: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        case .failed:
            row("Alerts while Macrophone is closed aren't set up yet", symbol: "exclamationmark.icloud", button: "Try Again") {
                Task { await AgentAlerts.shared.subscribeInCloud(force: true) }
            }
        }
    }

    private func row(_ words: String, symbol: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: Light.ochre)
            Text(words)
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let button {
                Spacer(minLength: 8)
                Button(button, action: action)
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.medium))
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("alerts-cloud-status")
    }
}
