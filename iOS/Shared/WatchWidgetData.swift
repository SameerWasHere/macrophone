import Foundation

/// The Watch widget's apps (Oct 18 2026, Sameer: "a small widget ... that allows the user to quickly
/// jump into watch mode for up to 4 apps that are open on their Mac"): the four apps used most
/// recently on the Mac, one per app (its newest window), with their icons and whether a chat there
/// answered you. Written by the app whenever they change, through the same keychain group as the
/// controls' list (no App Group); only names and icons — never text.
struct WidgetApp: Codable, Hashable, Sendable {
    /// `TargetEntity` id: "app:<bundleID>#<windowKey>".
    var id: String
    var name: String
    /// A small PNG.
    var icon: Data?
    /// A chat there answered you (the ember mark).
    var needsYou: Bool

    static let kind = "com.sameer.macrophone.watch"
    static let key = "widget.apps"
    static let limit = 4

    static func load() -> [WidgetApp] {
        guard let d = SharedStore.read(account: key) else { return [] }
        return (try? JSONDecoder().decode([WidgetApp].self, from: d)) ?? []
    }

    /// Saves the list; false when it's what was there already.
    @discardableResult
    static func save(_ list: [WidgetApp]) -> Bool {
        guard let data = try? JSONEncoder().encode(list) else { return false }
        if SharedStore.read(account: key) == data { return false }
        SharedStore.write(data, account: key)
        return true
    }

    /// What a tap opens: the app, watching this one.
    var url: URL {
        var c = URLComponents()
        c.scheme = "macrophone"
        c.host = "watch"
        c.queryItems = [URLQueryItem(name: "target", value: id)]
        return c.url ?? URL(string: "macrophone://watch")!
    }
}
