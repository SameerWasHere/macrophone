import AppIntents
import Foundation

// Compiled into both the app and the Controls extension. The extension only needs the type
// to exist (its control button names it); `perform()` always runs in the app, because the
// intent opens the app — the microphone needs the app in the foreground.

/// The Mac's profiles as the phone last heard them, kept so Shortcuts can offer them.
struct CachedProfile: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var isDefault: Bool

    static let key = "profiles.cache"

    static func load(_ defaults: UserDefaults = .standard) -> [CachedProfile] {
        guard let d = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CachedProfile].self, from: d)) ?? []
    }

    static func save(_ list: [CachedProfile], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
    }
}

struct ProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Profile") }
    static var defaultQuery: ProfileQuery { ProfileQuery() }

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ProfileQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
        CachedProfile.load().filter { identifiers.contains($0.id) }.map { ProfileEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [ProfileEntity] {
        CachedProfile.load().map { ProfileEntity(id: $0.id, name: $0.name) }
    }
}

/// Opens Macrophone already recording. Action Button, Back Tap, Siri, Shortcuts,
/// Control Center and the Lock Screen all run this one.
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource { "Start Dictation" }
    static var description: IntentDescription? {
        IntentDescription("Opens Macrophone and starts listening. Tap the button when you're done and the text goes to your Mac.")
    }
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Profile", description: "Which of your Mac's profiles to use. Leave empty for the one picked in the app.")
    var profile: ProfileEntity?

    init() {}
    init(profile: ProfileEntity?) { self.profile = profile }

    static var parameterSummary: some ParameterSummary {
        Summary("Start dictation with \(\.$profile)")
    }

    func perform() async throws -> some IntentResult {
        #if MACROPHONE_APP
        await IntentBridge.startRecording(profileID: profile?.id)
        #endif
        return .result()
    }
}
