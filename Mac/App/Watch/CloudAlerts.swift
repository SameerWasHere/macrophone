import CloudKit
import Foundation
import MacrophoneKit

/// Alerts that reach a closed iPhone app (Oct 16 2026; every alert since Nov 6 2026): the Mac
/// writes one record per window into the person's own private iCloud database, and the phone's
/// subscription has Apple push it. No server of ours, nothing collected. The record carries the
/// alert's headline, the window's title, the line under it and a picture of the window
/// (`CloudAlertRecord`); the phone's notification extension takes the picture and deletes the
/// record. One record per window, overwritten, and any the phone never picked up (it was off) are
/// deleted here after a day — so nothing stays in iCloud.
enum CloudAlerts {
    static let container = "iCloud.com.sameer.macrophone"
    /// The records written and when, so the ones the phone never took can be cleared.
    private static let writtenKey = "alerts.cloud.written"
    static let keepFor: TimeInterval = 24 * 3600

    /// Only a build signed with the iCloud entitlement may touch CloudKit (it stops the app
    /// otherwise); that build sets this key.
    static var available: Bool { Bundle.main.object(forInfoDictionaryKey: "MacrophoneCloudAlerts") as? String == "YES" }

    private static var database: CKDatabase { CKContainer(identifier: container).privateCloudDatabase }
    /// Alerts live in their own zone (Nov 9 2026): the phone's zone subscription is what Apple
    /// pushes for — the query subscription it used before is refused in a Production container.
    static let zoneID = CKRecordZone.ID(zoneName: AlertAnswers.zone, ownerName: CKCurrentUserDefaultName)
    private static var zoneMade = false
    private static func makeZone() async {
        guard !zoneMade else { return }
        if (try? await database.save(CKRecordZone(zoneID: zoneID))) != nil { zoneMade = true }
    }

    /// Writes the alert's record. Returns nil when iCloud took it, else why not (for the log).
    static func post(_ a: MacAlert) async -> String? {
        guard available else { return "this build isn't signed for iCloud" }
        guard let fields = CloudAlertRecord.fields(a) else { return "the alert couldn't be written as a record" }
        let name = CloudAlertRecord.name(a)
        await makeZone()
        let r = CKRecord(recordType: CloudAlertRecord.recordType, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        for (k, v) in fields { r[k] = v as CKRecordValue }
        let op = CKModifyRecordsOperation(recordsToSave: [r])
        op.savePolicy = .allKeys   // overwrite: each window keeps one record
        op.qualityOfService = .userInitiated
        let failure: String? = await withCheckedContinuation { c in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: c.resume(returning: nil)
                case .failure(let e): c.resume(returning: "\((e as? CKError)?.code.rawValue ?? -1): \(e.localizedDescription)")
                }
            }
            database.add(op)
        }
        if failure == nil {
            var written = UserDefaults.standard.dictionary(forKey: writtenKey) as? [String: Date] ?? [:]
            written[name] = Date()
            UserDefaults.standard.set(written, forKey: writtenKey)
        }
        await sweep()
        return failure
    }

    /// Deletes the records older than a day (deleting one the phone already took does nothing).
    static func sweep() async {
        guard available else { return }
        let written = UserDefaults.standard.dictionary(forKey: writtenKey) as? [String: Date] ?? [:]
        let old = written.filter { Date().timeIntervalSince($0.value) > keepFor }.map(\.key)
        guard !old.isEmpty else { return }
        let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: old.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })
        op.qualityOfService = .utility
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            op.modifyRecordsResultBlock = { _ in c.resume() }
            database.add(op)
        }
        var left = UserDefaults.standard.dictionary(forKey: writtenKey) as? [String: Date] ?? [:]
        for k in old { left.removeValue(forKey: k) }
        UserDefaults.standard.set(left, forKey: writtenKey)
    }

    // MARK: Probe (Nov 9 2026)

    /// What iCloud's Production database takes as a subscription, tried once from this Mac (same
    /// container, same account as the phone) when `defaults write … cloud.probe -bool YES` is set:
    /// each shape is saved under a probe id, the full answer logged, and the probe removed. The
    /// phone's own subscription was being refused (12) and its log can't be read from here.
    static func probeIfAsked(log: DiagnosticLog) async {
        guard available, UserDefaults.standard.bool(forKey: "cloud.probe") else { return }
        UserDefaults.standard.removeObject(forKey: "cloud.probe")
        func info(args: Bool, mutable: Bool = true) -> CKSubscription.NotificationInfo {
            let i = CKSubscription.NotificationInfo()
            if args {
                i.titleLocalizationKey = "%1$@"; i.titleLocalizationArgs = ["line"]
                i.subtitleLocalizationKey = "%1$@"; i.subtitleLocalizationArgs = ["window"]
                i.desiredKeys = ["ref"]
            }
            i.alertBody = "Tap to see it."
            i.soundName = "default"
            i.shouldSendMutableContent = mutable
            i.category = "macAlert"
            return i
        }
        let zoneID = CKRecordZone.ID(zoneName: "Alerts", ownerName: CKCurrentUserDefaultName)
        var subs: [(String, CKSubscription)] = []
        let q1 = CKQuerySubscription(recordType: CloudAlertRecord.recordType, predicate: NSPredicate(value: true), subscriptionID: "probe-query-args",
                                     options: [.firesOnRecordCreation, .firesOnRecordUpdate]); q1.notificationInfo = info(args: true)
        let q2 = CKQuerySubscription(recordType: CloudAlertRecord.recordType, predicate: NSPredicate(value: true), subscriptionID: "probe-query-plain",
                                     options: [.firesOnRecordCreation, .firesOnRecordUpdate]); q2.notificationInfo = info(args: false)
        let q3 = CKQuerySubscription(recordType: CloudAlertRecord.recordType, predicate: NSPredicate(value: true), subscriptionID: "probe-query-zone",
                                     options: [.firesOnRecordCreation, .firesOnRecordUpdate]); q3.zoneID = zoneID; q3.notificationInfo = info(args: true)
        let z = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: "probe-zone"); z.notificationInfo = info(args: false)
        let d = CKDatabaseSubscription(subscriptionID: "probe-database"); d.notificationInfo = info(args: false)
        subs = [("query, fields in the title", q1), ("query, plain alert", q2), ("query in a zone, fields in the title", q3), ("zone, plain alert", z), ("database, plain alert", d)]
        do { _ = try await database.save(CKRecordZone(zoneID: zoneID)); log.add("cloud probe: zone ready") }
        catch { log.add("cloud probe: zone failed: \((error as? CKError)?.code.rawValue ?? -1) \(error.localizedDescription)") }
        for (name, sub) in subs {
            do {
                _ = try await database.save(sub)
                log.add("cloud probe: \(name) — taken")
                _ = try? await database.deleteSubscription(withID: sub.subscriptionID)
            } catch {
                let e = error as NSError
                let server = (e.userInfo["ServerErrorDescription"] as? String) ?? (e.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? ""
                log.add("cloud probe: \(name) — refused \((error as? CKError)?.code.rawValue ?? -1): \(error.localizedDescription) \(server)")
            }
        }
    }
}
