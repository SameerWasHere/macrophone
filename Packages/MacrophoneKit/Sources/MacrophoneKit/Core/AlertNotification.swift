#if os(iOS)
import Foundation
import UniformTypeIdentifiers
import UserNotifications

/// One look for every alert on the phone (Nov 6 2026), whichever way it came — over the link while
/// the app is open (the app posts it), or through iCloud while it's closed (the notification
/// extension fills in the pushed one): the headline, the window's title under it, the line, and the
/// picture of the window. One per window: a newer one takes the older one's place.
public enum AlertNotification {
    public static let thread = "alerts"

    /// Fills `c` with the alert. The picture goes into a file the system moves into its own store.
    public static func fill(_ c: UNMutableNotificationContent, with a: MacAlert) {
        c.title = a.headline
        c.subtitle = a.title != a.appName && a.title != a.headline ? a.title : ""
        c.body = a.detail ?? AlertWords.body(a.knownKind)
        c.threadIdentifier = thread
        var info = c.userInfo
        if let ref = try? JSONEncoder().encode(a.ref) { info["ref"] = String(decoding: ref, as: UTF8.self) }
        info["window"] = MacAlert.windowKey(a.ref)
        c.userInfo = info
        if let jpeg = a.jpeg, let attachment = attachment(jpeg, id: a.id) { c.attachments = [attachment] }
    }

    static func attachment(_ jpeg: Data, id: UUID) -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alert-\(id.uuidString).jpg")
        guard (try? jpeg.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "picture", url: url,
                                             options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.jpeg.identifier])
    }

    /// The window's older alerts leave the Lock Screen (a pushed one can't replace them by its id).
    public static func removeOlder(window: String, except keep: String? = nil) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.deliveredNotifications()
            .filter { $0.request.content.userInfo["window"] as? String == window && $0.request.identifier != keep }
            .map(\.request.identifier)
        if !old.isEmpty { center.removeDeliveredNotifications(withIdentifiers: old) }
    }
}
#endif
