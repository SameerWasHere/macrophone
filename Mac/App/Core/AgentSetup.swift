import Foundation

/// Connecting Claude Code and Codex to Macrophone (Oct 17 2026): the one click that makes them
/// run `mp hook` on their own events. Claude Code: a hook per event in ~/.claude/settings.json,
/// kept beside his own hooks (the file is backed up once first). Codex: its `notify` program in
/// ~/.codex/config.toml — Codex has one, so one he set himself is never replaced.
/// Disconnecting takes out exactly what this added.
enum AgentSetup {
    enum Status: Equatable {
        case connected
        case notConnected
        /// Not installed here (no ~/.claude or ~/.codex).
        case missing
        /// Codex already runs another program when a turn ends.
        case taken
    }

    /// The helper inside this app, as an agent runs it.
    static var helper: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/macrophone").path
    }

    private static func command(_ agent: String) -> String {
        let h = helper
        return (h.contains(" ") ? "\"\(h)\"" : h) + " hook \(agent)"
    }

    /// Ours, wherever the app lived when it was added.
    private static func isOurs(_ command: String, agent: String) -> Bool {
        command.contains("Helpers/macrophone") && command.hasSuffix("hook \(agent)")
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Claude Code

    static let claudeFile = home.appendingPathComponent(".claude/settings.json")
    /// The events that tell where a session is; a tool's run only after it ran (the answer to a
    /// permission), never before, so a busy turn costs few trips.
    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification",
                               "PostToolUse", "Stop", "SessionEnd"]
    private static let toolEvents: Set<String> = ["PermissionRequest", "PostToolUse"]

    static var claude: Status {
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) else { return .missing }
        guard let hooks = readClaude()?["hooks"] as? [String: Any] else { return .notConnected }
        let ours = claudeEvents.filter { e in
            ((hooks[e] as? [[String: Any]]) ?? []).contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains { isOurs($0["command"] as? String ?? "", agent: "claude") }
            }
        }
        return ours.count == claudeEvents.count ? .connected : .notConnected
    }

    private static func readClaude() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeFile) else { return [:] }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Adds the hooks (or, `on: false`, takes ours out). Returns a line to show when it can't.
    static func setClaude(_ on: Bool) -> String? {
        guard var settings = readClaude() else {
            return "Couldn't read ~/.claude/settings.json — it isn't plain JSON. Nothing was changed."
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for e in claudeEvents {
            var groups = (hooks[e] as? [[String: Any]]) ?? []
            // Ours out first (an older path, or turning off).
            groups = groups.compactMap { g in
                var g = g
                let inner = ((g["hooks"] as? [[String: Any]]) ?? []).filter { !isOurs($0["command"] as? String ?? "", agent: "claude") }
                if inner.isEmpty, g["hooks"] != nil { return nil }
                g["hooks"] = inner
                return g
            }
            if on {
                var g: [String: Any] = ["hooks": [["type": "command", "command": command("claude"), "timeout": 5]]]
                if toolEvents.contains(e) { g["matcher"] = "*" }
                groups.append(g)
            }
            hooks[e] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return write(settings, to: claudeFile)
    }

    private static func write(_ obj: [String: Any], to url: URL) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let backup = url.appendingPathExtension("macrophone-backup")
            if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
            return nil
        } catch {
            return "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Codex

    static let codexFile = home.appendingPathComponent(".codex/config.toml")

    private static func codexNotifyLine(_ text: String) -> String? {
        text.components(separatedBy: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") }
    }

    static var codex: Status {
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) else { return .missing }
        let text = (try? String(contentsOf: codexFile, encoding: .utf8)) ?? ""
        guard let line = codexNotifyLine(text) else { return .notConnected }
        return line.contains("Helpers/macrophone") ? .connected : .taken
    }

    static func setCodex(_ on: Bool) -> String? {
        var text = (try? String(contentsOf: codexFile, encoding: .utf8)) ?? ""
        let existing = codexNotifyLine(text)
        if let existing, !existing.contains("Helpers/macrophone") {
            return "Codex already runs another program when a turn ends — Macrophone left it as it is."
        }
        if let existing { text = text.replacingOccurrences(of: existing + "\n", with: "").replacingOccurrences(of: existing, with: "") }
        if on {
            // A top-level key: before any [table].
            text = "notify = [\"\(helper)\", \"hook\", \"codex\"]\n" + text
        }
        do {
            try FileManager.default.createDirectory(at: codexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let backup = codexFile.appendingPathExtension("macrophone-backup")
            if FileManager.default.fileExists(atPath: codexFile.path), !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: codexFile, to: backup)
            }
            try text.write(to: codexFile, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "Couldn't save config.toml: \(error.localizedDescription)"
        }
    }
}
