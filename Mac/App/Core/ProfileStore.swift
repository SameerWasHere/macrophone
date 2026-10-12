import Foundation
import MacrophoneKit

/// The Mac's profiles, persisted as JSON. The phone gets summaries (`broadcastProfiles`)
/// so it can offer the choice and run the profile's cleanup level.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    /// Called after any change, with the summaries for the phones.
    var onChange: ([ProfileSummary]) -> Void = { _ in }
    private let url: URL

    static let claudeBundleID = "com.anthropic.claudefordesktop"

    static func defaults() -> [Profile] {
        [
            Profile(name: "Clipboard", destination: .clipboard, isDefault: true),
            Profile(name: "Claude prompt", destination: .app(bundleID: claudeBundleID, name: "Claude"), pressEnter: false),
            Profile(name: "Quick note", cleanupLevel: .light, destination: .clipboard),
        ]
    }

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Profile].self, from: d), !list.isEmpty {
            profiles = list
        } else {
            profiles = Self.defaults()
            save()
        }
        ensureOneDefault()
    }

    var summaries: [ProfileSummary] { profiles.map(\.summary) }
    var defaultProfile: Profile { profiles.first(where: \.isDefault) ?? profiles.first ?? Self.defaults()[0] }

    /// The profile a dictation asked for (by id, then by name), else the default.
    func resolve(_ d: Dictation) -> Profile {
        if let id = d.profileID, let p = profiles.first(where: { $0.id == id }) { return p }
        if let name = d.profileName?.lowercased(), let p = profiles.first(where: { $0.name.lowercased() == name }) { return p }
        return defaultProfile
    }

    func upsert(_ p: Profile) {
        var p = p
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.name.isEmpty { p.name = "Untitled" }
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        if p.isDefault { for i in profiles.indices where profiles[i].id != p.id { profiles[i].isDefault = false } }
        ensureOneDefault()
        save()
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if profiles.isEmpty { profiles = Self.defaults() }
        ensureOneDefault()
        save()
    }

    func makeDefault(_ id: UUID) {
        for i in profiles.indices { profiles[i].isDefault = profiles[i].id == id }
        save()
    }

    func move(from: IndexSet, to: Int) {
        profiles.move(fromOffsets: from, toOffset: to)
        save()
    }

    private func ensureOneDefault() {
        if !profiles.contains(where: \.isDefault), !profiles.isEmpty { profiles[0].isDefault = true }
        if profiles.filter(\.isDefault).count > 1 {
            var seen = false
            for i in profiles.indices where profiles[i].isDefault {
                if seen { profiles[i].isDefault = false } else { seen = true }
            }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(profiles) { try? d.write(to: url, options: .atomic) }
        onChange(summaries)
    }
}

extension Profile {
    /// One plain line for a list row: "Pastes into Claude, then presses Return".
    func describe(mode: DeliveryMode) -> String {
        var parts: [String] = []
        switch destination {
        case .clipboard:
            switch mode {
            case .clipboardNotify: parts.append("Copies it and shows a notification")
            case .clipboardOnly: parts.append("Copies it silently")
            case .autoPaste: parts.append("Pastes into the app you're using")
            }
        case .focusedApp: parts.append("Pastes into the app you're using")
        case .app(_, let name): parts.append("Pastes into \(name)")
        }
        if pressEnter && pastes(mode: mode) { parts[0] += ", then presses Return" }
        if let t = template, !t.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("wrapped in a template") }
        if let s = script, !s.isEmpty { parts.append("runs a script") }
        if webhookURL != nil { parts.append("posts to a webhook") }
        var line = parts.joined(separator: " · ")
        if let c = cleanupLevel { line += " · cleanup \(c.title)" }
        return line
    }

    func pastes(mode: DeliveryMode) -> Bool {
        switch destination {
        case .clipboard: return mode == .autoPaste
        case .focusedApp, .app: return true
        }
    }
}
