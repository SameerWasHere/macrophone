import CloudKit
import MacrophoneKit
import UserNotifications

/// The alert that came through iCloud while Macrophone was closed (Nov 6 2026). Apple's push
/// carries only the headline and the window's title; this fetches the record the Mac wrote — the
/// line under the headline and a picture of the window (`CloudAlertRecord`) — fills the
/// notification in the same way the app does while it's open (`AlertNotification`), takes the
/// window's older alert off the Lock Screen, and deletes the record, so nothing stays in iCloud.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    static let container = "iCloud.com.sameer.macrophone"

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content
        let note = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo)
        guard note is CKRecordZoneNotification || note is CKQueryNotification else {
            contentHandler(content)
            return
        }
        work = Task {
            let db = CKContainer(identifier: Self.container).privateCloudDatabase
            // The push says only that the Alerts zone changed: take what's in it (one record per
            // window, a handful at most) and show the newest.
            let zoneID = CKRecordZone.ID(zoneName: AlertAnswers.zone, ownerName: CKCurrentUserDefaultName)
            var alerts: [(CKRecord.ID, MacAlert)] = []
            if let changes = try? await db.recordZoneChanges(inZoneWith: zoneID, since: nil) {
                for (id, result) in changes.modificationResultsByID {
                    guard id.recordName.hasPrefix(CloudAlertRecord.namePrefix), let record = try? result.get().record,
                          let alert = CloudAlertRecord.alert(line: record["line"] as? String, window: record["window"] as? String,
                                                             ref: record["ref"] as? String, payload: record["promptID"] as? String) else { continue }
                    alerts.append((id, alert))
                }
            }
            // One push per record written: this one shows the newest and takes only that one, so
            // the next push still finds its own.
            if let (id, alert) = alerts.max(by: { $0.1.at < $1.1.at }) {
                await AlertNotification.prepare(content, with: alert)
                await AlertNotification.removeOlder(window: MacAlert.windowKey(alert.ref))
                _ = try? await db.modifyRecords(saving: [], deleting: [id])
            } else {
                content.title = "Your Mac"
            }
            self.finish()
        }
    }

    /// Out of time: what's there goes (the headline and the window's title, at least).
    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        finish()
    }

    private func finish() {
        guard let handler, let content else { return }
        self.handler = nil
        handler(content)
    }
}
