import AppKit
import MacrophoneKit

/// What the menu bar menu says — pure words from a snapshot of the app's state, so the header
/// and every row read the same way whatever the state came from (the live model or a staged
/// one).
enum MenuWords {
    /// The header's meaning colour: cyan is a connected phone, grey is waiting, orange is a
    /// fix-it.
    enum Tone { case connected, waiting, warning }

    struct Phone {
        var name: String
        var connected: Bool
        var route: LinkRoute?
        var lastSeen: Date?
    }

    struct Header {
        var title: String
        var detail: String?
        var tone: Tone
        var symbol: String
    }

    /// How a connected phone reaches this Mac, in the words the status line and the phone use
    /// ("Tailscale · away from home", "Nearby", "Home network").
    static func via(_ route: LinkRoute?) -> String? {
        guard let route else { return nil }
        return route.isAway ? "\(route.short) · away from home" : route.short
    }

    /// The first row: who's connected and how, or what's missing and what to do.
    static func header(phones: [Phone], listenerFailed: Bool) -> Header {
        if listenerFailed {
            return Header(title: "Your iPhone can't reach this Mac",
                          detail: "Allow Macrophone in System Settings › Privacy & Security › Local Network.",
                          tone: .warning, symbol: "exclamationmark.triangle.fill")
        }
        let on = phones.filter(\.connected)
        if on.count == 1, let p = on.first {
            let how = ["Connected", via(p.route)].compactMap { $0 }.joined(separator: " · ")
            return Header(title: p.name, detail: how, tone: .connected, symbol: "iphone")
        }
        if on.count == 2 {
            let routes = Set(on.compactMap(\.route))
            let how = routes.count == 1 ? ["Both connected", via(routes.first)].compactMap { $0 }.joined(separator: " · ") : "Both connected"
            return Header(title: "\(on[0].name) and \(on[1].name)", detail: how, tone: .connected, symbol: "iphone")
        }
        if on.count > 2 {
            return Header(title: "\(on.count) iPhones", detail: "All connected", tone: .connected, symbol: "iphone")
        }
        if phones.isEmpty {
            return Header(title: "No iPhone paired yet", detail: "Pair your iPhone to dictate into this Mac.",
                          tone: .waiting, symbol: "iphone.slash")
        }
        // Paired, none connected: which phones, and when one was last here.
        var detail = phones.prefix(3).map(\.name).joined(separator: ", ")
        if phones.count > 3 { detail += " and \(phones.count - 3) more" }
        if let seen = phones.compactMap(\.lastSeen).max() { detail += " · last seen \(seen.relativeShort)" }
        return Header(title: "Waiting for your iPhone", detail: detail, tone: .waiting, symbol: "iphone")
    }

    /// The row that ends a watch: "Stop Showing Claude" / "Sameer's iPhone is watching its window."
    static func stopWatching(app: String, phone: String) -> (title: String, detail: String) {
        ("Stop Showing \(app)", "\(phone) is watching its window.")
    }

    /// Under Send after pasting: why it's off, or what it does.
    static func sendAfterPastingDetail(canSend: Bool, terminal: Bool) -> String {
        if !canSend { return "Pick an app or Where I'm typing first." }
        return terminal ? "Presses Return after a 2.5-second countdown you can cancel."
            : "Presses the app's send key after a 2.5-second countdown you can cancel."
    }

    /// "3 min ago · Claude" under a recent dictation.
    static func recentMeta(_ item: HistoryItem) -> String {
        var meta = item.receivedAt.relativeShort
        if item.delayed { meta += " · delayed" }
        return meta + " · " + item.profileName
    }

    /// The number of apps Send to lists in the menu itself; the rest wait under More Apps.
    static let inlineApps = 6
}
