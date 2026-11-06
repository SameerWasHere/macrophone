import AppIntents
import Foundation
import Security

// Compiled into both the app and the Controls extension. The extension only needs the types
// to exist (its control button names the intent, its configuration lists the targets);
// `perform()` always runs in the app, because the intent opens the app — the microphone needs
// the app in the foreground.

/// The Mac's open apps as the phone last heard them, shared with the Controls extension through
/// a keychain access group (an App Group would need an explicit provisioning profile). Only
/// target names live there — never text or keys.
enum SharedStore {
    static var keychainGroup: String? { Bundle.main.object(forInfoDictionaryKey: "MacrophoneSharedKeychainGroup") as? String }
    private static let service = "com.sameer.macrophone.shared"

    private static func query(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let g = keychainGroup, !g.hasPrefix("$(") { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    static func read(account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func write(_ data: Data, account: String) {
        let q = query(account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// The Mac's open apps as the phone last heard them — only what Shortcuts and the control need
/// to offer them (id, name). Written by the app; never text or keys.
struct CachedTarget: Codable, Hashable, Sendable {
    /// `TargetEntity` id: "app:<bundleID>#<windowKey>".
    var id: String
    var name: String

    static let key = "targets.cache"

    static func load() -> [CachedTarget] {
        guard let d = UserDefaults.standard.data(forKey: key) ?? SharedStore.read(account: key) else { return [] }
        return (try? JSONDecoder().decode([CachedTarget].self, from: d)) ?? []
    }

    static func save(_ list: [CachedTarget]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
        SharedStore.write(data, account: key)
    }
}

/// A place a dictation can go, for Shortcuts, Siri and the controls: Clipboard, Where I'm
/// typing, or an app open on the Mac (as last heard).
struct TargetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Send To") }
    static var defaultQuery: TargetQuery { TargetQuery() }

    static let clipboardID = "clipboard"
    static let frontID = "front"
    /// Only for Watch: the Mac's whole screen (the Clipboard and Where I'm typing watch it too).
    static let screenID = "screen"
    static var clipboard: TargetEntity { TargetEntity(id: clipboardID, name: "Clipboard", hint: "Copies it on your Mac") }
    static var front: TargetEntity { TargetEntity(id: frontID, name: "Where I'm typing", hint: "Pastes into the app in front on your Mac") }
    static var wholeScreen: TargetEntity { TargetEntity(id: screenID, name: "Whole Screen", hint: "Your Mac's whole screen, live") }

    /// "clipboard", "front", "screen" or "app:<bundleID>#<windowKey>" (an empty window key: the
    /// app itself, whichever of its windows is in front).
    var id: String
    var name: String
    var hint: String? = nil

    var displayRepresentation: DisplayRepresentation {
        let symbol: String
        switch id {
        case Self.clipboardID: symbol = "doc.on.clipboard"
        case Self.frontID: symbol = "text.cursor"
        case Self.screenID: symbol = "display"
        default: symbol = "macwindow"
        }
        if let hint { return DisplayRepresentation(title: "\(name)", subtitle: "\(hint)", image: .init(systemName: symbol)) }
        return DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }

    init(id: String, name: String, hint: String? = nil) {
        self.id = id
        self.name = name
        self.hint = hint
    }
}

struct TargetQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TargetEntity] {
        let known = all() + [TargetEntity.wholeScreen]
        // A target that has since closed on the Mac still resolves (the Mac copies instead).
        return identifiers.map { id in known.first { $0.id == id } ?? TargetEntity(id: id, name: Self.fallbackName(id)) }
    }

    func suggestedEntities() async throws -> [TargetEntity] { all() }

    /// Typed in Shortcuts' picker, or said to Siri ("Claude", "terminal").
    func entities(matching string: String) async throws -> [TargetEntity] {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return all() }
        return (all() + [TargetEntity.wholeScreen]).filter { $0.name.localizedStandardContains(s) }
    }

    /// Clipboard, Where I'm typing and the Mac's open apps as last heard. An app with several
    /// windows is offered by its own name too ("Terminal"), so Siri has a short name to match —
    /// it sends to whichever of its windows is in front.
    func all() -> [TargetEntity] {
        let cached = CachedTarget.load()
        var apps: [TargetEntity] = []
        var named = Set<String>()
        for t in cached {
            let (bid, key) = Self.parts(t.id)
            guard !key.isEmpty, let app = t.name.components(separatedBy: " — ").first, !app.isEmpty else { continue }
            // Its own entry when the app has no window-less one in the list already.
            let appID = "app:\(bid)#"
            guard !cached.contains(where: { $0.id == appID }), named.insert(appID).inserted else { continue }
            apps.append(TargetEntity(id: appID, name: app, hint: "Open on your Mac"))
        }
        return [TargetEntity.clipboard, TargetEntity.front]
            + cached.map { TargetEntity(id: $0.id, name: $0.name, hint: "Open on your Mac") }
            + apps
    }

    /// "app:<bundleID>#<windowKey>" → (bundleID, windowKey).
    static func parts(_ id: String) -> (String, String) {
        let p = id.dropFirst(4).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (p.first ?? "", p.count > 1 ? p[1] : "")
    }

    private static func fallbackName(_ id: String) -> String {
        if id == TargetEntity.screenID { return "Whole Screen" }
        guard id.hasPrefix("app:") else { return "Send To" }
        let bid = id.dropFirst(4).split(separator: "#").first.map(String.init) ?? ""
        return bid.split(separator: ".").last.map { $0.capitalized } ?? "App"
    }
}

/// Watch's choices: the Mac's open apps and its whole screen (nowhere to look at for the
/// Clipboard or Where I'm typing).
struct WatchPlaceOptions: DynamicOptionsProvider {
    func results() async throws -> [TargetEntity] {
        [TargetEntity.wholeScreen] + TargetQuery().all().filter { $0.id.hasPrefix("app:") }
    }
}

/// Opens Macrophone already recording. Action Button, Back Tap, Siri, Shortcuts,
/// Control Center and the Lock Screen all run this one.
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource { "Start Dictation" }
    static var description: IntentDescription? {
        // No "Mac" or the app's name in intent text: App Store processing rejects it (ITMS-90626, Oct 14 2026).
        IntentDescription("Starts listening right away. Tap the button when you're done and the text goes to the place you pick here (Clipboard, where you're typing, or an open app on your computer), or the one picked in the app.")
    }
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Send To", description: "Clipboard, Where I'm typing, or an open app on your computer. Leave empty for the one picked in the app.")
    var target: TargetEntity?

    init() {}
    init(target: TargetEntity?) { self.target = target }

    static var parameterSummary: some ParameterSummary {
        Summary("Dictate to \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        #if MACROPHONE_APP
        await IntentBridge.startRecording(targetID: target?.id, name: target?.name)
        #endif
        return .result()
    }
}

/// The Control Center / Lock Screen / Action Button control's settings: where it sends.
@available(iOS 18.0, *)
struct DictateControlConfiguration: ControlConfigurationIntent {
    static var title: LocalizedStringResource { "Dictate To" }
    static var description: IntentDescription? { IntentDescription("Choose where this control sends what you say.") }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Send To", description: "Leave empty to use the place picked in the app.")
    var target: TargetEntity?

    init() {}

    func perform() async throws -> some IntentResult { .result() }
}
