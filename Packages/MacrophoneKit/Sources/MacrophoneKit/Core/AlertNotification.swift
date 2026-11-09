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
        if let category = category(for: a) {
            c.categoryIdentifier = category.identifier
            info["promptID"] = a.promptID
            c.userInfo = info
        }
    }

    // MARK: Answering from the notification (Nov 9 2026)

    public static let replyAction = "reply"
    public static let answerPrefix = "answer-"

    /// The buttons this alert carries: a question's answers as the window words them (three at
    /// most), and Reply — a line typed or dictated into that window and sent — for a question or a
    /// chat's answer. Nil for anything else (a build finishing has nothing to answer).
    public static func category(for a: MacAlert) -> UNNotificationCategory? {
        let kind = a.knownKind
        guard kind == .asking || kind == .answered || a.chat == true else { return nil }
        guard a.ref != .clipboard else { return nil }
        var actions: [UNNotificationAction] = []
        var key = "reply"
        if kind == .asking, a.promptID != nil, let answers = a.answers, answers.count >= 2 {
            for (i, words) in answers.prefix(AlertAnswers.most).enumerated() {
                let title = words.count > 36 ? String(words.prefix(34)).trimmingCharacters(in: .whitespaces) + "…" : words
                actions.append(UNNotificationAction(identifier: "\(answerPrefix)\(i)", title: "\(i + 1). \(title)", options: []))
                key += "|" + title
            }
        }
        actions.append(UNTextInputNotificationAction(identifier: replyAction, title: "Reply…", options: [],
                                                     textInputButtonTitle: "Send", textInputPlaceholder: "Reply to \(a.appName)"))
        key += "|" + a.appName
        // A stable id per set of buttons (the system keeps categories by id).
        var h: UInt64 = 5381
        for b in key.utf8 { h = (h &* 33) ^ UInt64(b) }
        return UNNotificationCategory(identifier: "mac-\(String(h, radix: 16))", actions: actions, intentIdentifiers: [], options: [])
    }

    /// Fills `c` and makes sure the system knows its buttons before it's shown.
    public static func prepare(_ c: UNMutableNotificationContent, with a: MacAlert) async {
        fill(c, with: a)
        guard let category = category(for: a) else { return }
        let center = UNUserNotificationCenter.current()
        var all = await center.notificationCategories()
        guard !all.contains(where: { $0.identifier == category.identifier }) else { return }
        // (Old ones go once there are many: each alert's set is registered again when it comes.)
        if all.count > 40 { all = [] }
        all.insert(category)
        center.setNotificationCategories(all)
        // The registry is written on another queue; a beat so the notification finds its buttons.
        try? await Task.sleep(nanoseconds: 60_000_000)
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
