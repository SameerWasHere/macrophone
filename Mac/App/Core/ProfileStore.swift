import Foundation
import MacrophoneKit

/// The Mac's profiles, persisted as JSON. The phone gets summaries (`broadcastProfiles`)
/// so it can offer the choice and run the profile's cleanup level.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    /// Mac-only settings per profile (send key, go back), stored next to each profile.
    @Published private(set) var options: [UUID: ProfileOptions] = [:]
    /// Called after any change, with the summaries for the phones.
    var onChange: ([ProfileSummary]) -> Void = { _ in }
    private let url: URL

    static let claudeBundleID = "com.anthropic.claudefordesktop"
    /// Bumped when the ready-made set changes; older installs are brought up to it once.
    static let readyMadeVersion = 2

    /// First run: the clipboard default, the ready-made targets whose apps are installed
    /// (Claude Code in Terminal always), and a quick note.
    static func defaults() -> [Profile] {
        var list = [Profile(name: "Clipboard", destination: .clipboard, isDefault: true)]
        for item in ReadyMade.items where item.spec.isInstalled {
            list.append(ReadyMade.profile(for: item))
        }
        list.append(Profile(name: "Quick note", cleanupLevel: .light, destination: .clipboard))
        return list
    }

    init(url: URL) {
        self.url = url
        let d = UserDefaults.standard
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Profile].self, from: data), !list.isEmpty {
            profiles = list
            struct Extra: Decodable { var id: UUID; var mac: ProfileOptions? }
            for e in (try? JSONDecoder().decode([Extra].self, from: data)) ?? [] { if let m = e.mac { options[e.id] = m } }
            if d.integer(forKey: "readyMadeVersion") < Self.readyMadeVersion {
                upgradeReadyMade()
                d.set(Self.readyMadeVersion, forKey: "readyMadeVersion")
                ensureOneDefault()
                save()
            }
        } else {
            profiles = Self.defaults()
            d.set(Self.readyMadeVersion, forKey: "readyMadeVersion")
            save()
        }
        ensureOneDefault()
    }

    /// An install from before the target catalog: the untouched "Claude prompt" becomes the
    /// ready-made Claude (same id, so a phone that had it picked keeps it), and the other
    /// ready-made targets whose apps are installed are added once.
    private func upgradeReadyMade() {
        if let i = profiles.firstIndex(where: { p in
            if case .app(Self.claudeBundleID, _) = p.destination, p.name == "Claude prompt", !p.pressEnter,
               (p.template ?? "").isEmpty, (p.script ?? "").isEmpty, p.webhookURL == nil { return true }
            return false
        }) {
            var p = ReadyMade.profile(for: ReadyMade.items[0])
            p.id = profiles[i].id
            p.isDefault = profiles[i].isDefault
            p.cleanupLevel = profiles[i].cleanupLevel
            profiles[i] = p
        }
        for item in ReadyMade.items where item.spec.isInstalled && !hasTarget(item) {
            profiles.append(ReadyMade.profile(for: item))
        }
    }

    /// A profile already sends to this ready-made's app (and window).
    func hasTarget(_ item: ReadyMade.Item) -> Bool {
        profiles.contains { p in
            if case .app(let id, _) = p.destination, item.spec.bundleIDs.contains(id),
               (p.windowMatch ?? "").lowercased() == (item.windowMatch ?? "").lowercased() { return true }
            return p.name.lowercased() == item.name.lowercased()
        }
    }

    var summaries: [ProfileSummary] { profiles.map(\.summary) }
    var defaultProfile: Profile { profiles.first(where: \.isDefault) ?? profiles.first ?? Self.defaults()[0] }

    func options(for id: UUID) -> ProfileOptions { options[id] ?? .none }

    /// The profile for a dictation: a voice prefix or the phone's pick wins (by id, then by
    /// name); on Automatic, the rule for the app in front; else the default.
    func resolve(_ d: Dictation, frontmostBundleID: String? = nil, rules: [AppRule] = []) -> Profile {
        if d.profileSource == .automatic {
            return AppRule.resolve(dictation: d, frontmostBundleID: frontmostBundleID, rules: rules, profiles: profiles) ?? defaultProfile
        }
        if let id = d.profileID, let p = profiles.first(where: { $0.id == id }) { return p }
        if let name = d.profileName?.lowercased(), let p = profiles.first(where: { $0.name.lowercased() == name }) { return p }
        return defaultProfile
    }

    func upsert(_ p: Profile, options o: ProfileOptions? = nil) {
        var p = p
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.name.isEmpty { p.name = "Untitled" }
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        if p.isDefault { for i in profiles.indices where profiles[i].id != p.id { profiles[i].isDefault = false } }
        if let o { options[p.id] = o == .none ? nil : o }
        ensureOneDefault()
        save()
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        options[id] = nil
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

    /// profiles.json: the shared `Profile` fields, plus "mac" for this Mac's own options.
    private func save() {
        let enc = JSONEncoder()
        var out: [Any] = []
        for p in profiles {
            guard let d = try? enc.encode(p), var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            if let o = options[p.id], let od = try? enc.encode(o), let oo = try? JSONSerialization.jsonObject(with: od) {
                obj["mac"] = oo
            }
            out.append(obj)
        }
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url, options: .atomic)
        }
        onChange(summaries)
    }
}

extension Profile {
    /// One plain line for a list row: "Pastes into Claude and sends it · saves to Obsidian".
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
        case .app(_, let name):
            var s = "Pastes into \(name)"
            if let w = windowMatch, !w.isEmpty { s += " (“\(w)”)" }
            parts.append(s)
        case .tmux(let target): parts.append("Types into tmux pane \(target)")
        case .none: parts.append("Doesn't paste or copy")
        }
        if pressEnter && pastes(mode: mode) { parts[0] += " and sends it" }
        if let f = outputFormat, f != .plain { parts.append(f.title.lowercased()) }
        if let t = template, !t.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("wrapped in a template") }
        for a in actions ?? [] {
            switch a.kind {
            case .obsidian: parts.append("saves to Obsidian")
            case .appleNote: parts.append("saves to Notes")
            case .reminder: parts.append("adds a reminder")
            case .claude: parts.append("asks Claude")
            }
        }
        if let s = script, !s.isEmpty { parts.append("runs a script") }
        if webhookURL != nil { parts.append("posts to a webhook") }
        var line = parts.joined(separator: " · ")
        if let c = cleanupLevel { line += " · cleanup \(c.title)" }
        return line
    }

    func pastes(mode: DeliveryMode) -> Bool {
        switch destination {
        case .clipboard: return mode == .autoPaste
        case .focusedApp, .app, .tmux: return true
        case .none: return false
        }
    }

    /// The app this profile sends to, if it names one.
    var targetBundleID: String? {
        if case .app(let id, _) = destination { return id }
        return nil
    }
}
