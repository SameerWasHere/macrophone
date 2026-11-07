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
        guard let note = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo) as? CKQueryNotification,
              let id = note.recordID, id.recordName.hasPrefix(CloudAlertRecord.namePrefix) else {
            // A question from a Mac from before: as it came.
            contentHandler(content)
            return
        }
        work = Task {
            let db = CKContainer(identifier: Self.container).privateCloudDatabase
            if let record = try? await db.record(for: id),
               let alert = CloudAlertRecord.alert(line: record["line"] as? String, window: record["window"] as? String,
                                                  ref: record["ref"] as? String, payload: record["promptID"] as? String) {
                AlertNotification.fill(content, with: alert)
                await AlertNotification.removeOlder(window: MacAlert.windowKey(alert.ref))
                // The phone has it now: the record (and its picture) goes.
                _ = try? await db.deleteRecord(withID: id)
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
