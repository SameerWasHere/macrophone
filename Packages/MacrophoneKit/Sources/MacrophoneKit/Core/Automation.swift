import Foundation

// The pure rules behind the pro automations. Both apps and the tests use these; the Mac
// app supplies the side effects (pasting, tmux, files, Notes, Reminders, the Claude API).
//
// Order on the Mac for one dictation:
//   1. pick the profile — voice prefix (phone) > chosen on the phone > per-app rule > default
//   2. snippets expand inside the text
//   3. the output format shapes it
//   4. the template wraps it, with context variables filled in
//   5. destination (clipboard / focused app / an app / a tmux pane / none) + actions

/// How the profile for a dictation was picked.
public enum ProfileSource: String, Codable, Sendable {
    /// The person picked it on the phone (or a Shortcut/Action Button did).
    case chosen
    /// A spoken lead-in picked it ("Claude, …").
    case prefix
    /// The phone was on "Automatic": the Mac picks by the app in front (per-app rules).
    case automatic
}

// MARK: - Voice prefixes

public enum VoicePrefix {
    /// If the transcript starts with one of a profile's prefixes followed by a pause mark
    /// ("Claude, refactor…", "note: buy milk", "Slack. Running late"), returns that profile and
    /// the transcript with the prefix removed. A prefix must be followed by punctuation (the
    /// recognizer's pause) or the words "colon"/"comma", so "note that the API…" never matches.
    public static func match(_ transcript: String, profiles: [ProfileSummary]) -> (profile: ProfileSummary, text: String)? {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Longest prefix first, so "claude code" wins over "claude".
        let candidates = profiles.flatMap { p in (p.voicePrefixes ?? []).map { (p, normalize($0)) } }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.count > $1.1.count }
        for (profile, prefix) in candidates {
            if let rest = strip(prefix, from: t) { return (profile, rest) }
        }
        return nil
    }

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }

    static func strip(_ prefix: String, from text: String) -> String? {
        let lower = text.lowercased()
        guard lower.hasPrefix(prefix) else { return nil }
        var rest = Substring(text.dropFirst(prefix.count))
        let separators: [String] = [",", ":", ".", ";", "!", "—", " -", " colon", " comma"]
        guard let sep = separators.first(where: { rest.lowercased().hasPrefix($0) }) else { return nil }
        rest = rest.dropFirst(sep.count)
        let lead = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;.-—"))
        let body = String(rest.drop { $0.unicodeScalars.allSatisfy { lead.contains($0) } })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return body.prefix(1).uppercased() + body.dropFirst()
    }
}

// MARK: - Output formats

public enum OutputFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case plain, singleLine, codeBlock, quote, shellQuoted, jsonString
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plain: return "Plain text"
        case .singleLine: return "Single line"
        case .codeBlock: return "Code block"
        case .quote: return "Markdown quote"
        case .shellQuoted: return "Shell-quoted"
        case .jsonString: return "JSON string"
        }
    }

    public var summary: String {
        switch self {
        case .plain: return "The text as cleaned up."
        case .singleLine: return "Line breaks become spaces — good for terminals and chat inputs that send on Return."
        case .codeBlock: return "Wrapped in a ``` fenced block."
        case .quote: return "Each line starts with “> ”."
        case .shellQuoted: return "One safely single-quoted argument, ready for a shell command."
        case .jsonString: return "A JSON string literal, quotes and escapes included."
        }
    }

    public func apply(_ text: String) -> String {
        switch self {
        case .plain:
            return text
        case .singleLine:
            return text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .codeBlock:
            let fence = text.contains("```") ? "````" : "```"
            return "\(fence)\n\(text)\n\(fence)"
        case .quote:
            return text.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
        case .shellQuoted:
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        case .jsonString:
            let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }
}

// MARK: - Actions

/// Something a profile does with every dictation besides delivering it.
public struct ProfileAction: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: Kind

    public enum Kind: Codable, Sendable, Hashable {
        /// Append to a Markdown note in an Obsidian vault (plain file write — Obsidian needn't run).
        /// `notePath` relative to the vault; nil = today's daily note (`dailyFolder/YYYY-MM-DD.md`).
        case obsidian(vaultPath: String, notePath: String?, dailyFolder: String?, heading: String?)
        /// A new Apple Note in `folder`, or appended to the note titled `appendTo`.
        case appleNote(folder: String?, appendTo: String?)
        /// A reminder in `list`; with `detectDates`, "tomorrow at 5pm" becomes the due date.
        case reminder(list: String?, detectDates: Bool)
        /// Send the text to Claude with the person's own API key; the reply is delivered
        /// (copied, shown in the popup, kept in history) when `deliverReply` is on.
        case claude(model: String, systemPrompt: String?, deliverReply: Bool)
    }

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// Only the Claude call leaves this Mac. (Notes and Reminders sync through iCloud if the
    /// person uses iCloud for them — the UI says so.)
    public var sendsOffDevice: Bool {
        if case .claude = kind { return true }
        return false
    }

    public var title: String {
        switch kind {
        case .obsidian: return "Save to Obsidian"
        case .appleNote: return "Save to Apple Notes"
        case .reminder: return "Add to Reminders"
        case .claude: return "Ask Claude"
        }
    }
}

// MARK: - Per-app rules

/// "When <app> is in front, use <profile>." Applies only to dictations sent on Automatic.
public struct AppRule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    public var profileID: UUID
    public init(id: UUID = UUID(), bundleID: String, appName: String, profileID: UUID) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.profileID = profileID
    }

    /// Picks the profile for a dictation: prefix/chosen win, then the frontmost app's rule,
    /// then the default profile.
    public static func resolve(dictation: Dictation, frontmostBundleID: String?, rules: [AppRule], profiles: [Profile]) -> Profile? {
        let byID = { (id: UUID?) in profiles.first { $0.id == id } }
        let source = dictation.profileSource ?? .chosen
        if source != .automatic, let p = byID(dictation.profileID) { return p }
        if let bid = frontmostBundleID, let rule = rules.first(where: { $0.bundleID == bid }), let p = byID(rule.profileID) { return p }
        return profiles.first { $0.isDefault } ?? profiles.first
    }
}

// MARK: - Snippets

/// Say the trigger, get the expansion: "my email" → "sameer@example.com". Matches whole
/// phrases, ignoring case and the punctuation the recognizer adds around them.
public struct Snippet: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

public enum SnippetExpander {
    /// The expansion may use template variables ({{date}}, {{clipboard}}…); pass `context`
    /// to fill them.
    public static func expand(_ text: String, snippets: [Snippet], context: [String: String] = [:]) -> String {
        var out = text
        for s in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let trigger = s.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { continue }
            // Words of the trigger, separated by spaces or recognizer punctuation.
            let words = trigger.split(whereSeparator: { $0 == " " }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "[\\s,]+") + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let replacement = TemplateRenderer.fill(s.expansion, context: context)
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return out
    }
}

// MARK: - Templates and context injection

/// Fills `{{name}}` variables. The Mac gathers only the variables a template uses
/// (`variables(in:)`) — reading the selection or the browser URL costs a permission.
public enum TemplateRenderer {
    /// Every variable the apps know, with a one-line description for the editor.
    public static let known: [(name: String, summary: String)] = [
        ("text", "What you dictated, after snippets and the output format"),
        ("raw", "The raw transcript, before cleanup"),
        ("clipboard", "What was on the Mac clipboard before this dictation"),
        ("selection", "The text selected in the app in front (needs Accessibility)"),
        ("app", "The name of the app in front"),
        ("window", "The title of the front window (needs Accessibility)"),
        ("url", "The front tab's URL in Safari, Chrome, Arc, Brave or Edge (asks once per browser)"),
        ("tmux_cwd", "The working directory of the target tmux pane"),
        ("date", "Today's date, e.g. 2026-10-12"),
        ("time", "The time, e.g. 14:05"),
        ("datetime", "Date and time, ISO 8601"),
        ("profile", "The profile's name"),
        ("device", "The iPhone it came from"),
    ]

    public static func variables(in template: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: "\\{\\{\\s*([a-z_]+)\\s*\\}\\}") else { return [] }
        return Set(re.matches(in: template, range: NSRange(template.startIndex..., in: template)).compactMap {
            Range($0.range(at: 1), in: template).map { String(template[$0]) }
        })
    }

    /// Replaces known variables present in `context`; unknown ones are left as typed so a
    /// typo is visible rather than silently empty.
    public static func fill(_ template: String, context: [String: String]) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\{\\{\\s*([a-z_]+)\\s*\\}\\}") else { return template }
        var out = ""
        var last = template.startIndex
        for m in re.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let whole = Range(m.range, in: template), let name = Range(m.range(at: 1), in: template) else { continue }
            out += template[last..<whole.lowerBound]
            out += context[String(template[name])] ?? String(template[whole])
            last = whole.upperBound
        }
        out += template[last...]
        return out
    }

    /// The final text for a profile: template (if any) around `text`, context filled in.
    /// A template without {{text}} gets the text appended after a blank line.
    public static func render(template: String?, text: String, context: [String: String]) -> String {
        guard let template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        var ctx = context
        ctx["text"] = text
        let t = variables(in: template).contains("text") ? template : template + "\n\n{{text}}"
        return fill(t, context: ctx)
    }

    /// Date/time variables, always available.
    public static func clockContext(_ now: Date = Date(), timeZone: TimeZone = .current) -> [String: String] {
        let d = DateFormatter(); d.timeZone = timeZone; d.locale = Locale(identifier: "en_US_POSIX")
        d.dateFormat = "yyyy-MM-dd"; let date = d.string(from: now)
        d.dateFormat = "HH:mm"; let time = d.string(from: now)
        let iso = ISO8601DateFormatter(); iso.timeZone = timeZone
        return ["date": date, "time": time, "datetime": iso.string(from: now)]
    }
}

// MARK: - Reminder dates

public enum ReminderParsing {
    /// Finds a date in the text ("tomorrow at 5pm", "on Friday") and returns it with the
    /// title left over ("Call the dentist"). Nil date = no due date.
    public static func parse(_ text: String, now: Date = Date()) -> (title: String, due: Date?) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = m.date, let r = Range(m.range, in: text) else {
            return (text, nil)
        }
        var title = text.replacingCharacters(in: r, with: "")
        title = title.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:")))
        for lead in ["remind me to ", "remind me ", "reminder to ", "reminder: "] where title.lowercased().hasPrefix(lead) {
            title = String(title.dropFirst(lead.count))
        }
        if title.lowercased().hasSuffix(" by") || title.lowercased().hasSuffix(" on") || title.lowercased().hasSuffix(" at") {
            title = String(title.dropLast(3))
        }
        title = title.prefix(1).uppercased() + title.dropFirst()
        return (title.isEmpty ? text : title, date)
    }
}
