import CloudKit
import CryptoKit
import Foundation
import MacrophoneKit

/// Alerts that reach a closed iPhone app (Oct 16 2026): the Mac writes one small record per window
/// into the person's own private iCloud database, and the phone's subscription has Apple push it.
/// No server of ours, nothing collected; the record names the app and the window, never the
/// question or anything else on screen. One record per window, overwritten, so they don't pile up.
enum CloudAlerts {
    static let container = "iCloud.com.sameer.macrophone"
    static let recordType = "Ask"

    /// Only a build signed with the iCloud entitlement may touch CloudKit (it stops the app
    /// otherwise); that build sets this key.
    static var available: Bool { Bundle.main.object(forInfoDictionaryKey: "MacrophoneCloudAlerts") as? String == "YES" }

    static func post(_ a: Attention) async -> Bool {
        guard available, let refData = try? JSONEncoder().encode(a.ref), let ref = String(data: refData, encoding: .utf8) else { return false }
        // Named by the window (a stable hash of its ref), so its record is overwritten, not added.
        let key = SHA256.hash(data: refData).prefix(8).map { String(format: "%02x", $0) }.joined()
        let id = CKRecord.ID(recordName: "ask-" + key)
        let r = CKRecord(recordType: recordType, recordID: id)
        r["line"] = "\(a.appName) is asking you something" as CKRecordValue
        r["window"] = a.title as CKRecordValue
        r["ref"] = ref as CKRecordValue
        r["promptID"] = a.promptID as CKRecordValue
        let op = CKModifyRecordsOperation(recordsToSave: [r])
        op.savePolicy = .allKeys   // overwrite: each window keeps one record
        op.qualityOfService = .userInitiated
        return await withCheckedContinuation { c in
            op.modifyRecordsResultBlock = { c.resume(returning: (try? $0.get()) != nil) }
            CKContainer(identifier: container).privateCloudDatabase.add(op)
        }
    }
}
