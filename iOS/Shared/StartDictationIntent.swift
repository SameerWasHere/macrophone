import AppIntents
import Foundation

// Compiled into both the app and the Controls extension. The extension only needs the types
// to exist (its control button names the intent, its configuration lists the targets);
// `perform()` always runs in the app, because the intent opens the app — the microphone needs
// the app in the foreground.

/// The app group both targets read, so a Control Center control can list the Mac's targets.
enum SharedStore {
    static let groupID = "group.com.sameer.macrophone"
    static var defaults: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }
}

/// The Mac's profiles ("targets") as the phone last heard them. Kept so the Send-to picker,
/// voice prefixes, Shortcuts and controls all work while the Mac is away.
struct CachedProfile: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var isDefault: Bool
    /// `CleanupLevel.rawValue` (the extension doesn't link MacrophoneKit). Nil = the phone's own.
    var cleanupLevel: String?
    var voicePrefixes: [String]?

    static let key = "profiles.cache"

    static func load(_ defaults: UserDefaults = SharedStore.defaults) -> [CachedProfile] {
        // One-time move from the app's own defaults (v1 kept it there).
        if defaults.data(forKey: key) == nil, defaults !== UserDefaults.standard,
           let old = UserDefaults.standard.data(forKey: key) {
            defaults.set(old, forKey: key)
        }
        guard let d = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CachedProfile].self, from: d)) ?? []
    }

    static func save(_ list: [CachedProfile], _ defaults: UserDefaults = SharedStore.defaults) {
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
    }
}

/// A place a dictation can go: one of the Mac's targets, or Automatic (the Mac picks by the
/// app in front).
struct ProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Target") }
    static var defaultQuery: ProfileQuery { ProfileQuery() }

    /// Stands for "Automatic" wherever an entity is needed (Shortcuts, controls).
    static let automaticID = UUID(uuidString: "A0705E1E-C700-4000-8000-0000000A0700")!
    static var automatic: ProfileEntity { ProfileEntity(id: automaticID, name: "Automatic") }

    var id: UUID
    var name: String
    var hint: String? = nil

    var isAutomatic: Bool { id == Self.automaticID }

    var displayRepresentation: DisplayRepresentation {
        if isAutomatic {
            return DisplayRepresentation(title: "Automatic", subtitle: "Your Mac picks by the app in front",
                                         image: .init(systemName: "wand.and.sparkles"))
        }
        if let hint { return DisplayRepresentation(title: "\(name)", subtitle: "\(hint)") }
        return DisplayRepresentation(title: "\(name)")
    }

    init(id: UUID, name: String, hint: String? = nil) {
        self.id = id
        self.name = name
        self.hint = hint
    }

    init(_ p: CachedProfile) {
        self.init(id: p.id, name: p.name, hint: p.voicePrefixes?.first.map { "Say “\(spokenForm($0, name: p.name)), …”" })
    }
}

struct ProfileQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ProfileEntity] { all() }

    private func all() -> [ProfileEntity] {
        [ProfileEntity.automatic] + CachedProfile.load().map(ProfileEntity.init)
    }
}

/// Opens Macrophone already recording. Action Button, Back Tap, Siri, Shortcuts,
/// Control Center and the Lock Screen all run this one.
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource { "Start Dictation" }
    static var description: IntentDescription? {
        IntentDescription("Opens Macrophone and starts listening. Tap the button when you're done and the text goes to your Mac — to the target you pick here, or the one picked in the app.")
    }
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Send To", description: "Where on your Mac the text goes: one of your Mac's targets, or Automatic. Leave empty for the one picked in the app.")
    var profile: ProfileEntity?

    init() {}
    init(profile: ProfileEntity?) { self.profile = profile }

    static var parameterSummary: some ParameterSummary {
        Summary("Dictate to \(\.$profile)")
    }

    func perform() async throws -> some IntentResult {
        #if MACROPHONE_APP
        await IntentBridge.startRecording(profileID: profile?.id)
        #endif
        return .result()
    }
}

/// The Control Center / Lock Screen / Action Button control's settings: which target it sends to.
@available(iOS 18.0, *)
struct DictateControlConfiguration: ControlConfigurationIntent {
    static var title: LocalizedStringResource { "Dictate To" }
    static var description: IntentDescription? { IntentDescription("Choose where this control sends what you say.") }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Send To", description: "Leave empty to use the target picked in the app.")
    var profile: ProfileEntity?

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
