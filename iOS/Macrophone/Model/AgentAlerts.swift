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
///
/// **Sturdier (Nov 8 2026, "the answer finds you").** Read again with fresh eyes, it could fail
/// without a word in four ways, each fixed here: (1) a "ready" remembered from an earlier launch
/// (or an earlier build, another iCloud environment) was trusted — `retryIfNeeded` returned at
/// `.ready`, so with the agents switch off and the watch list not yet arrived at launch, the
/// subscription was never saved again; now it's confirmed once per launch (`confirmed`). (2) The
/// push registration's answer was never heard — the app delegate had no
/// `didRegisterForRemoteNotifications…` / `didFail…`, so a build whose `aps-environment` didn't
/// match its profile (or no network to Apple's push service) failed silently; now a failure is
/// `.pushOff` and logged. (3) Every iCloud account status but "available" read as "no account":
/// iCloud turned off for Macrophone, a restricted account and a sign-in that expired each have
/// their own words and their own fix. (4) The subscription was only tried while the agents switch
/// was on or a window was on watch; a chat answering is the usual reason now, so the first send of
/// a dictation into a chat asks for notifications (once) and subscribes (`sentToChat`).
/// The push environment the build is signed for rides the hello beside the state
/// (`alertPush-development|production|simulator`), so the Mac's log says which build is asking.
@MainActor
final class AgentAlerts: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    static let shared = AgentAlerts()
    private weak var model: AppModel?
    private var bag: Set<AnyCancellable> = []
    /// The subscription was saved in this launch (a remembered "ready" isn't proof).
    private var confirmed = false
    private var tryingSince: Date?

    /// Where alerts with the app closed stand.
    enum CloudState: Equatable {
        /// Nothing wants alerts yet, or nothing has been tried.
        case idle
        /// This build can't (not signed for iCloud).
        case unavailable
        /// Notifications are off for Macrophone in Settings.
        case notificationsOff
        /// No iCloud account on this iPhone.
        case noAccount
        /// iCloud is off for Macrophone, or restricted on this iPhone.
        case iCloudOff
        /// The iCloud account needs its password again (Settings asks).
        case signInAgain
        /// Apple's push service didn't take this iPhone (its words): nothing can be pushed.
        case pushOff(String)
        /// iCloud refused the subscription: the code and its words.
        case failed(String)
        case trying
        case ready
    }

    @Published private(set) var cloudState: CloudState = AgentAlerts.cloudReady ? .ready : .idle {
        didSet { if cloudState != oldValue { model?.noteAlertState(cloudState.word) } }
    }

    func install(_ model: AppModel) {
        self.model = model
        model.noteAlertState(cloudState.word)
        model.noteAlertPush(Self.pushEnvironment)
        UNUserNotificationCenter.current().delegate = self
        // Back in front: Settings may have changed (notifications allowed, iCloud signed in), or
        // the network is here now — try again where it failed.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { await self?.retryIfNeeded() } }
            .store(in: &bag)
    }

    /// `force`: a window was just put on watch, or a chat written to (alerts are wanted whatever
    /// the switches said a moment ago).
    func askIfNeeded(force: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            model?.log.add("alerts: notifications \(allowed ? "allowed" : "not allowed") when asked")
        }
        await subscribeInCloud(force: force)
    }

    /// A dictation was just sent into a chat (Nov 8 2026): its answer comes as a notification, so
    /// this is when to ask for them (iOS asks once) and make sure they reach a closed app.
    func sentToChat() async {
        guard model?.settings.chatAnswers == true else { return }
        if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined {
            await askIfNeeded(force: true)
        } else {
            await retryIfNeeded()
        }
    }

    /// Something wants alerts: the agents switch, a chat's answers, or a window on watch.
    var wanted: Bool {
        model?.settings.agentAlerts == true || model?.settings.chatAnswers == true || model?.alertWatches.isEmpty == false
    }

    /// Tries again when it isn't set up in this launch (the app came to the front, a watch
    /// arrived, a chat was written to).
    func retryIfNeeded() async {
        guard wanted, !confirmed else { return }
        if cloudState == .unavailable { return }
        await subscribeInCloud()
    }

    // MARK: Through iCloud, for when the app is closed

    static let container = "iCloud.com.sameer.macrophone"
    static let subscriptionID = "alerts-zone"
    /// The query subscription from before (never accepted; removed if one ever was).
    static let oldSubscriptionID = "ask"
    /// Only a build signed with the iCloud entitlement may touch CloudKit; that build sets this.
    static var cloudAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "MacrophoneCloudAlerts") as? String == "YES" }
    /// The subscription is in place: the hello tells the Mac to keep looking while the app is closed.
    static var cloudReady: Bool { UserDefaults.standard.bool(forKey: "alerts.cloud") }

    /// Which push service this build is signed for: a development build installed straight from
    /// the Mac carries its profile (and says), a TestFlight or App Store build carries none and is
    /// production. For the logs: a push from iCloud's Production environment to a development
    /// build is the first thing to suspect when everything else says ready.
    static let pushEnvironment: String = {
        #if targetEnvironment(simulator)
        return "simulator"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return "production" }
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "<key>aps-environment</key>") else { return "none" }
        let next = text[r.upperBound...].prefix(80)
        return next.contains("development") ? "development" : next.contains("production") ? "production" : "unknown"
        #endif
    }()

    /// Subscribes once a launch (saving it again is harmless). Needs notifications allowed, iCloud
    /// and Apple's push service.
    func subscribeInCloud(force: Bool = false) async {
        guard force || wanted else { return }
        // One at a time (the launch, the app coming to the front and a send can all ask at once);
        // a try that never answered gives way after two minutes.
        if cloudState == .trying, let since = tryingSince, Date().timeIntervalSince(since) < 120 { return }
        guard Self.cloudAvailable else {
            cloudState = .unavailable
            model?.log.add("alerts: this build can't get alerts while closed (not signed for iCloud)")
            return
        }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            cloudState = .notificationsOff
            model?.log.add("alerts: notifications aren't allowed (\(status.rawValue)), so none while the app is closed")
            return
        }
        // Not available: iCloud would refuse after a round trip; say which way plainly.
        switch try? await CKContainer(identifier: Self.container).accountStatus() {
        case .available?: break
        case .noAccount?:
            cloudState = .noAccount
            model?.log.add("alerts: no iCloud account on this iPhone, so none while the app is closed")
            return
        case .restricted?:
            cloudState = .iCloudOff
            model?.log.add("alerts: iCloud is restricted or off for Macrophone, so none while the app is closed")
            return
        case .temporarilyUnavailable?:
            cloudState = .signInAgain
            model?.log.add("alerts: the iCloud account needs signing in again, so none while the app is closed")
            return
        default:
            // Couldn't tell (no network, iCloud busy): try anyway — the save says what's wrong.
            model?.log.add("alerts: iCloud's account status unknown; trying anyway")
        }
        cloudState = .trying
        tryingSince = Date()
        UIApplication.shared.registerForRemoteNotifications()
        // A zone subscription (Nov 9 2026). The query subscription this used was refused by the
        // Production container every time ("attempting to create a subscription in a production
        // container": its type has to be made in Development and deployed first) — the reason no
        // alert ever reached a closed app. A zone subscription needs nothing deployed (proven
        // from the Mac, same container and account). Its push can't carry the record's own words,
        // so it says a plain line and the notification extension fills in the rest — the
        // headline, the line under it, the picture, the answers' buttons.
        let db = CKContainer(identifier: Self.container).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: AlertAnswers.zone, ownerName: CKCurrentUserDefaultName)
        _ = try? await db.save(CKRecordZone(zoneID: zoneID))
        let sub = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Something on your Mac needs you. Tap to see it."
        info.soundName = "default"
        info.shouldSendMutableContent = true
        sub.notificationInfo = info
        // A new container (or a busy iCloud) asks for patience: wait as long as it says, a few times.
        for attempt in 1...4 {
            do {
                _ = try await db.save(sub)
                _ = try? await db.deleteSubscription(withID: Self.oldSubscriptionID)
                if !Self.cloudReady { model?.log.add("alerts: set up through iCloud") }
                UserDefaults.standard.set(true, forKey: "alerts.cloud")
                confirmed = true
                tryingSince = nil
                // The push registration may have answered "no" meanwhile: that stands.
                if case .pushOff = cloudState { return }
                cloudState = .ready
                model?.alertsReadyInCloud()
                return
            } catch let e as CKError where [.requestRateLimited, .serviceUnavailable, .zoneBusy, .networkUnavailable, .networkFailure].contains(e.code) && attempt < 4 {
                let wait = e.retryAfterSeconds ?? Double(attempt * 20)
                model?.log.add("alerts: iCloud asked to wait \(Int(wait)) s")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            } catch {
                tryingSince = nil
                let e = error as? CKError
                if e?.code == .notAuthenticated {
                    cloudState = .noAccount
                    model?.log.add("alerts: iCloud says this iPhone isn't signed in")
                    return
                }
                let code = e?.code.rawValue ?? -1
                cloudState = .failed("\(code)")
                model?.log.add("alerts: iCloud didn't take the subscription (\(code)): \(error.localizedDescription)" + Self.hint(error))
                return
            }
        }
        tryingSince = nil
        cloudState = .failed("busy")
    }

    /// What to do about a refusal that names the container's schema (the Production schema needs
    /// the "Ask" type, and a query subscription may want its record name indexed).
    private static func hint(_ error: Error) -> String {
        let words = error.localizedDescription.lowercased()
        if words.contains("queryable") || words.contains("indexable") || words.contains("index") {
            return " — CloudKit Console › iCloud.com.sameer.macrophone › Production › Indexes: make Ask's recordName Queryable (in Development, then Deploy Schema Changes)"
        }
        if words.contains("record type") || words.contains("did not find") {
            return " — the Production schema has no \"Ask\" type: deploy it from Development in the CloudKit Console"
        }
        return ""
    }

    /// Apple's push service took this iPhone: what it pushes can arrive.
    func pushRegistered() {
        model?.log.add("alerts: push registration answered (\(Self.pushEnvironment))")
        if case .pushOff = cloudState { cloudState = confirmed ? .ready : .idle }
    }

    /// Apple's push service didn't take this iPhone: nothing from iCloud can arrive. Its words go
    /// to the log, never anything personal.
    func pushFailed(_ error: Error) {
        let ns = error as NSError
        model?.log.add("alerts: push registration failed (\(ns.domain) \(ns.code)): \(error.localizedDescription)")
        cloudState = .pushOff("\(ns.code)")
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
        confirmed = false
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
        Task {
            let c = UNMutableNotificationContent()
            // Its buttons too (the answers, Reply), registered before it shows.
            await AlertNotification.prepare(c, with: a)
            c.sound = .default
            let request = UNNotificationRequest(identifier: a.notificationID, content: c, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            await AlertNotification.removeOlder(window: MacAlert.windowKey(a.ref), except: a.notificationID)
            #if DEBUG
            // MACROPHONE_ALERT_ANSWER=<index> / MACROPHONE_ALERT_REPLY=<words>: what the system has
            // for this notification's buttons, then what a tap on one does (the simulator's long
            // press on a notification can't be driven from a test).
            let env = DebugHooks.env
            guard env["MACROPHONE_ALERT_ANSWER"] != nil || env["MACROPHONE_ALERT_REPLY"] != nil else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let center = UNUserNotificationCenter.current()
            let shown = await center.deliveredNotifications().first { $0.request.identifier == a.notificationID }
            let category = await center.notificationCategories().first { $0.identifier == shown?.request.content.categoryIdentifier }
            model?.log.add("alert buttons: \(category?.actions.map(\.title).joined(separator: " | ") ?? "none")")
            if let i = env["MACROPHONE_ALERT_ANSWER"].flatMap(Int.init), let id = shown?.request.content.userInfo["promptID"] as? String {
                await model?.answerFromNotification(ref: a.ref, promptID: id, index: i)
            }
            if let words = env["MACROPHONE_ALERT_REPLY"] { await model?.replyFromNotification(ref: a.ref, text: words) }
            #endif
        }
    }

    /// A line of our own (an answer that couldn't be given): tapping it opens that window.
    func say(_ title: String, body: String, ref: TargetRef) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.threadIdentifier = AlertNotification.thread
        if let data = try? JSONEncoder().encode(ref) { c.userInfo = ["ref": String(decoding: data, as: UTF8.self)] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "answer-\(UUID().uuidString)", content: c, trigger: nil))
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
        // A button on the notification (Nov 9 2026): answered or replied without opening the app.
        let action = response.actionIdentifier
        if action.hasPrefix(AlertNotification.answerPrefix), let index = Int(action.dropFirst(AlertNotification.answerPrefix.count)),
           let promptID = info["promptID"] as? String {
            await self.model?.answerFromNotification(ref: ref, promptID: promptID, index: index)
            return
        }
        if action == AlertNotification.replyAction, let typed = (response as? UNTextInputNotificationResponse)?.userText {
            await self.model?.replyFromNotification(ref: ref, text: typed)
            return
        }
        guard action == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { self.model?.openAttention(ref) }
    }
}

/// Settings › Alerts: one line and one button when alerts can't reach this iPhone with Macrophone
/// closed (Nov 7 2026), saying plainly what's in the way (Nov 8 2026). Nothing while they can, or
/// while nothing wants them.
struct CloudAlertsStatusRow: View {
    @ObservedObject private var alerts = AgentAlerts.shared

    var body: some View {
        switch alerts.cloudState {
        case .idle, .ready, .trying:
            EmptyView()
        case .unavailable:
            row("This build can't get alerts while Macrophone is closed", symbol: "icloud.slash", button: nil) {}
        case .notificationsOff:
            row("Notifications are off for Macrophone, so alerts can't reach you", symbol: "bell.slash", button: "Open Settings", action: openSettings)
        case .noAccount:
            row("Sign in to iCloud on this iPhone to get alerts while Macrophone is closed", symbol: "icloud.slash", button: "Open Settings", action: openSettings)
        case .iCloudOff:
            row("iCloud is off for Macrophone. Turn it on in Settings › your name › iCloud to get alerts while it's closed", symbol: "icloud.slash", button: "Open Settings", action: openSettings)
        case .signInAgain:
            row("iCloud needs your password again (Settings › your name) before alerts can reach you closed", symbol: "person.crop.circle.badge.exclamationmark", button: "Open Settings", action: openSettings)
        case .pushOff:
            row("Apple's notification service didn't take this iPhone, so alerts can't reach it while Macrophone is closed", symbol: "bell.slash", button: "Try Again") {
                Task { await AgentAlerts.shared.subscribeInCloud(force: true) }
            }
        case let .failed(code):
            row("iCloud didn't set up alerts while Macrophone is closed (\(code))", symbol: "exclamationmark.icloud", button: "Try Again") {
                Task { await AgentAlerts.shared.subscribeInCloud(force: true) }
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
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

extension AgentAlerts.CloudState {
    /// One word for the Mac's log (Nov 7 2026): the phone's hello carries it as
    /// "alertState-<word>", so "the phone hasn't said it subscribed" comes with the reason.
    var word: String {
        switch self {
        case .idle: "idle"
        case .unavailable: "unavailable"
        case .notificationsOff: "notificationsOff"
        case .noAccount: "noAccount"
        case .iCloudOff: "iCloudOff"
        case .signInAgain: "signInAgain"
        case .pushOff(let code): "pushOff\(code)"
        case .failed(let code): "failed\(code)"
        case .trying: "trying"
        case .ready: "ready"
        }
    }
}

/// The push registration's answer (Nov 8 2026): heard, so a refusal isn't silent.
extension AppDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { AgentAlerts.shared.pushRegistered() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { AgentAlerts.shared.pushFailed(error) }
    }
}
