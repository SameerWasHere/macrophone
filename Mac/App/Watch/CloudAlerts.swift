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

    static func post(_ a: MacAlert) async -> Bool {
        guard available, let fields = CloudAlertRecord.fields(a) else { return false }
        let name = CloudAlertRecord.name(a)
        let r = CKRecord(recordType: CloudAlertRecord.recordType, recordID: CKRecord.ID(recordName: name))
        for (k, v) in fields { r[k] = v as CKRecordValue }
        let op = CKModifyRecordsOperation(recordsToSave: [r])
        op.savePolicy = .allKeys   // overwrite: each window keeps one record
        op.qualityOfService = .userInitiated
        let ok = await withCheckedContinuation { c in
            op.modifyRecordsResultBlock = { c.resume(returning: (try? $0.get()) != nil) }
            database.add(op)
        }
        if ok {
            var written = UserDefaults.standard.dictionary(forKey: writtenKey) as? [String: Date] ?? [:]
            written[name] = Date()
            UserDefaults.standard.set(written, forKey: writtenKey)
        }
        await sweep()
        return ok
    }

    /// Deletes the records older than a day (deleting one the phone already took does nothing).
    static func sweep() async {
        guard available else { return }
        let written = UserDefaults.standard.dictionary(forKey: writtenKey) as? [String: Date] ?? [:]
        let old = written.filter { Date().timeIntervalSince($0.value) > keepFor }.map(\.key)
        guard !old.isEmpty else { return }
        let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: old.map { CKRecord.ID(recordName: $0) })
        op.qualityOfService = .utility
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            op.modifyRecordsResultBlock = { _ in c.resume() }
            database.add(op)
        }
        var left = UserDefaults.standard.dictionary(forKey: writtenKey) as? [String: Date] ?? [:]
        for k in old { left.removeValue(forKey: k) }
        UserDefaults.standard.set(left, forKey: writtenKey)
    }
}
