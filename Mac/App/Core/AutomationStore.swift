import Foundation
import MacrophoneKit

/// The Mac's automations: named things the iPhone can pick under Send to › Automations — save to
/// Obsidian / Apple Notes / Reminders, type into a tmux pane, ask Claude, run a script, post to a
/// webhook — each with its own template, output format and voice prefixes. Stored as the shared
/// `Profile` shape (automations.json); the phone gets their summaries (`broadcastProfiles`).
@MainActor
final class AutomationStore: ObservableObject {
    @Published private(set) var automations: [Profile] = []
    /// Called after any change, with the summaries for the phones.
    var onChange: ([ProfileSummary]) -> Void = { _ in }
    private let url: URL

    init(url: URL, legacyProfiles: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Profile].self, from: data) {
            automations = list
        } else if let data = try? Data(contentsOf: legacyProfiles), let list = try? JSONDecoder().decode([Profile].self, from: data) {
            automations = Self.migrate(list)
            save()
        } else {
            save()
        }
    }

    /// Profiles from before live targets. One that only sent text to an app (or the clipboard,
    /// or the app in front) becomes nothing — that app shows up under Send to by itself now.
    /// One that did more — a tmux pane, a note, a reminder, Claude, a script, a webhook, a
    /// template — becomes an automation. An app profile's extra actions keep running, with the
    /// text copied.
    static func migrate(_ profiles: [Profile]) -> [Profile] {
        profiles.compactMap { p in
            var a = p
            a.isDefault = false
            a.pressEnter = p.pressEnter
            a.windowMatch = nil
            let shapes = !(p.template ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (p.outputFormat ?? .plain) != .plain
            switch p.destination {
            case .tmux, .none:
                return a
            case .clipboard, .focusedApp:
                return p.hasActions || shapes ? a : nil
            case .app:
                guard p.hasActions else { return nil }
                a.destination = .clipboard
                a.pressEnter = false
                return a
            }
        }
    }

    var summaries: [ProfileSummary] { automations.map(\.summary) }

    func automation(_ id: UUID?) -> Profile? {
        guard let id else { return nil }
        return automations.first { $0.id == id }
    }

    func automation(named name: String?) -> Profile? {
        guard let n = name?.lowercased() else { return nil }
        return automations.first { $0.name.lowercased() == n }
    }

    func upsert(_ p: Profile) {
        var p = p
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.name.isEmpty { p.name = "Untitled" }
        p.isDefault = false
        if let i = automations.firstIndex(where: { $0.id == p.id }) { automations[i] = p } else { automations.append(p) }
        save()
    }

    func delete(_ id: UUID) {
        automations.removeAll { $0.id == id }
        save()
    }

    func move(from: IndexSet, to: Int) {
        automations.move(fromOffsets: from, toOffset: to)
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(automations) { try? d.write(to: url, options: .atomic) }
        onChange(summaries)
    }
}

extension Profile {
    var hasActions: Bool {
        !(actions ?? []).isEmpty || webhookURL != nil || !(script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One plain line for a list row: "Types into tmux pane work:1.0 · saves to Obsidian".
    var describe: String {
        var parts: [String] = []
        switch destination {
        case .clipboard: parts.append("Copies it")
        case .focusedApp: parts.append("Pastes where you're typing")
        case .app(_, let name): parts.append("Pastes into \(name)")
        case .tmux(let target): parts.append("Types into tmux pane \(target)")
        case .none: parts.append("Doesn't paste or copy")
        }
        if pressEnter, destination != .clipboard, destination != .none { parts[0] += " and presses Return" }
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
}
