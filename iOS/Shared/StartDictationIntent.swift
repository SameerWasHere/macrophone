import AppIntents
import Foundation
import Security

// Compiled into both the app and the Controls extension. The extension only needs the types
// to exist (its control button names the intent, its configuration lists the targets);
// `perform()` always runs in the app, because the intent opens the app — the microphone needs
// the app in the foreground.

/// The Mac's automations and open apps as the phone last heard them, shared with the Controls extension through
/// a keychain access group (an App Group would need an explicit provisioning profile). Only
/// target names, cleanup levels and voice prefixes live there — never text or keys.
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

    static func read(account: String = CachedProfile.key) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func write(_ data: Data, account: String = CachedProfile.key) {
        let q = query(account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil)
        }
    }
}

/// The Mac's automations as the phone last heard them. Kept so the Send-to picker,
/// voice prefixes, Shortcuts and controls all work while the Mac is away.
struct CachedProfile: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var isDefault: Bool
    /// `CleanupLevel.rawValue` (the extension doesn't link MacrophoneKit). Nil = the phone's own.
    var cleanupLevel: String?
    var voicePrefixes: [String]?

    static let key = "profiles.cache"

    /// The app reads its own defaults; the extension (which has none) reads the shared keychain item.
    static func load() -> [CachedProfile] {
        guard let d = UserDefaults.standard.data(forKey: key) ?? SharedStore.read() else { return [] }
        return (try? JSONDecoder().decode([CachedProfile].self, from: d)) ?? []
    }

    static func save(_ list: [CachedProfile]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
        SharedStore.write(data)
    }
}

/// The Mac's open apps as the phone last heard them — only what Shortcuts and the control need
/// to offer them (id, name). Written by the app next to `CachedProfile`; never text or keys.
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
/// typing, an app open on the Mac (as last heard), or one of the Mac's automations.
struct TargetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Send To") }
    static var defaultQuery: TargetQuery { TargetQuery() }

    static let clipboardID = "clipboard"
    static let frontID = "front"
    static var clipboard: TargetEntity { TargetEntity(id: clipboardID, name: "Clipboard", hint: "Copies it on your Mac") }
    static var front: TargetEntity { TargetEntity(id: frontID, name: "Where I'm typing", hint: "Pastes into the app in front on your Mac") }

    /// "clipboard", "front", "app:<bundleID>#<windowKey>" or "auto:<UUID>".
    var id: String
    var name: String
    var hint: String? = nil

    var displayRepresentation: DisplayRepresentation {
        let symbol: String
        switch id {
        case Self.clipboardID: symbol = "doc.on.clipboard"
        case Self.frontID: symbol = "cursorarrow.rays"
        default: symbol = id.hasPrefix("auto:") ? "gearshape.2" : "macwindow"
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

struct TargetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [TargetEntity] {
        let known = all()
        // A target that has since closed on the Mac still resolves (the Mac copies instead).
        return identifiers.map { id in known.first { $0.id == id } ?? TargetEntity(id: id, name: Self.fallbackName(id)) }
    }

    func suggestedEntities() async throws -> [TargetEntity] { all() }

    private func all() -> [TargetEntity] {
        [TargetEntity.clipboard, TargetEntity.front]
            + CachedTarget.load().map { TargetEntity(id: $0.id, name: $0.name, hint: "Open on your Mac") }
            + CachedProfile.load().map { p in
                TargetEntity(id: "auto:\(p.id.uuidString)", name: p.name,
                             hint: p.voicePrefixes?.first.map { "Automation · say “\(spokenForm($0, name: p.name)), …”" } ?? "Automation")
            }
    }

    private static func fallbackName(_ id: String) -> String {
        guard id.hasPrefix("app:") else { return "Send To" }
        let bid = id.dropFirst(4).split(separator: "#").first.map(String.init) ?? ""
        return bid.split(separator: ".").last.map { $0.capitalized } ?? "App"
    }
}

/// Opens Macrophone already recording. Action Button, Back Tap, Siri, Shortcuts,
/// Control Center and the Lock Screen all run this one.
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource { "Start Dictation" }
    static var description: IntentDescription? {
        IntentDescription("Opens Macrophone and starts listening. Tap the button when you're done and the text goes to your Mac — to the place you pick here (Clipboard, where you're typing, an app open on your Mac, or an automation), or the one picked in the app.")
    }
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Send To", description: "Clipboard, Where I'm typing, an app open on your Mac, or one of its automations. Leave empty for the one picked in the app.")
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

/// A lead-in as people would write it: "chatgpt" for "ChatGPT" reads "ChatGPT", "claude code"
/// for "Claude Code (Terminal)" reads "Claude Code"; anything else gets a capital first letter.
func spokenForm(_ prefix: String, name: String) -> String {
    let p = prefix.trimmingCharacters(in: .whitespaces)
    if name.lowercased().hasPrefix(p.lowercased()) { return String(name.prefix(p.count)) }
    return p.capitalizedFirst
}

extension String {
    /// "claude" → "Claude" (only the first letter; "chatGPT" stays "ChatGPT").
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
