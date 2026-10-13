import Foundation

/// How much the on-device model edits a transcript. Default is `.medium`.
public enum CleanupLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, light, medium, heavy, custom
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .medium: return "Medium"
        case .heavy: return "Heavy"
        case .custom: return "Custom"
        }
    }

    /// One line, shown under the slider.
    public var summary: String {
        switch self {
        case .off: return "Exactly what the recognizer heard."
        case .light: return "Removes filler and repeats, fixes punctuation."
        case .medium: return "Also fixes grammar and false starts."
        case .heavy: return "Rewrites rambling speech into tidy text."
        case .custom: return "Follows your own instructions."
        }
    }
}

/// One finished dictation. Only text is ever stored — never audio.
public struct Dictation: Codable, Sendable, Identifiable, Hashable {
    /// Stable across resends and queued retries, so the Mac can de-duplicate.
    public var id: UUID
    public var createdAt: Date
    public var raw: String
    /// Nil when cleanup was off or unavailable.
    public var cleaned: String?
    public var cleanupLevel: CleanupLevel
    /// BCP-47, e.g. "en-US".
    public var language: String
    public var profileID: UUID?
    public var profileName: String?
    /// How the profile was picked. Nil (older phones) = chosen on the phone.
    public var profileSource: ProfileSource?
    /// Where this dictation goes (the shared selection, or a spoken app name, at the time it
    /// was made). Each dictation carries it so a sync race can't misroute one. Nil = older phone.
    public var target: TargetRef?
    /// Press the send key after pasting (only for `.app` / `.frontApp`, never when delayed).
    public var send: Bool?
    /// True when `target` came from saying the app's name first ("Messages, …").
    public var targetSpoken: Bool?
    /// Interrupted (call, lock, permission) — what was captured was still processed and sent.
    public var stoppedEarly: Bool
    public var duration: TimeInterval
    public var sourceDevice: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), raw: String, cleaned: String? = nil,
                cleanupLevel: CleanupLevel = .off, language: String = "en-US", profileID: UUID? = nil,
                profileName: String? = nil, profileSource: ProfileSource? = nil, target: TargetRef? = nil,
                send: Bool? = nil, targetSpoken: Bool? = nil, stoppedEarly: Bool = false,
                duration: TimeInterval = 0, sourceDevice: String = "") {
        self.id = id
        self.createdAt = createdAt
        self.raw = raw
        self.cleaned = cleaned
        self.cleanupLevel = cleanupLevel
        self.language = language
        self.profileID = profileID
        self.profileName = profileName
        self.profileSource = profileSource
        self.target = target
        self.send = send
        self.targetSpoken = targetSpoken
        self.stoppedEarly = stoppedEarly
        self.duration = duration
        self.sourceDevice = sourceDevice
    }

    /// What gets delivered: the cleaned text when there is one, else the raw transcript.
    public var text: String {
        if let cleaned, !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return cleaned }
        return raw
    }
}

/// Where a profile's text goes on the Mac.
public enum Destination: Codable, Sendable, Hashable {
    /// Copy only (the delivery mode decides whether a notification shows).
    case clipboard
    /// Paste into whatever app is focused.
    case focusedApp
    /// Bring this app to the front and paste there.
    case app(bundleID: String, name: String)
    /// Type into a tmux pane (`session:window.pane`), whatever app is in front.
    case tmux(target: String)
    /// Don't copy or paste — only the profile's actions run (e.g. a note, a reminder, Claude).
    case none
}

/// A named bundle of cleanup level, destination and post-actions. Lives on the Mac;
/// the phone receives a summary so it can offer the choice and run the right cleanup.
public struct Profile: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// Nil = use the phone's own cleanup setting.
    public var cleanupLevel: CleanupLevel?
    public var destination: Destination
    /// Press Return after pasting. Only fires in allowlisted apps, never for delayed items.
    public var pressEnter: Bool
    /// "{{text}}" is replaced with the dictation. Nil/empty = no template.
    public var template: String?
    /// Shell command run with the text on stdin.
    public var script: String?
    /// POSTed a JSON body for every dictation.
    public var webhookURL: URL?
    public var isDefault: Bool
    /// How the text is shaped before the template (nil = plain).
    public var outputFormat: OutputFormat?
    /// Spoken lead-ins that pick this profile for one dictation: "Claude, …", "Note, …".
    public var voicePrefixes: [String]?
    /// With an `.app` destination: raise the window whose title contains this before pasting
    /// (e.g. "Claude Code" to hit the terminal tab running it). Nil = the app's front window.
    public var windowMatch: String?
    /// Extra things done with every dictation: save to Obsidian / Notes / Reminders, ask Claude.
    public var actions: [ProfileAction]?

    public init(id: UUID = UUID(), name: String, cleanupLevel: CleanupLevel? = nil,
                destination: Destination = .clipboard, pressEnter: Bool = false, template: String? = nil,
                script: String? = nil, webhookURL: URL? = nil, isDefault: Bool = false,
                outputFormat: OutputFormat? = nil, voicePrefixes: [String]? = nil, actions: [ProfileAction]? = nil) {
        self.id = id
        self.name = name
        self.cleanupLevel = cleanupLevel
        self.destination = destination
        self.pressEnter = pressEnter
        self.template = template
        self.script = script
        self.webhookURL = webhookURL
        self.isDefault = isDefault
        self.outputFormat = outputFormat
        self.voicePrefixes = voicePrefixes
        self.actions = actions
    }

    /// True when this profile can send text off the device.
    public var sendsOffDevice: Bool {
        webhookURL != nil || !(script ?? "").isEmpty || (actions ?? []).contains { $0.sendsOffDevice }
    }

    public var summary: ProfileSummary {
        var s = ProfileSummary(id: id, name: name, cleanupLevel: cleanupLevel, isDefault: isDefault, voicePrefixes: voicePrefixes)
        switch destination {
        case .clipboard: s.targetKind = .clipboard
        case .focusedApp: s.targetKind = .focusedApp
        case let .app(bundleID, appName): s.targetKind = .app; s.targetBundleID = bundleID; s.targetApp = appName
        case .tmux: s.targetKind = .tmux
        case .none: s.targetKind = ProfileSummary.TargetKind.none
        }
        return s
    }

    /// Applies the template, if any.
    public func render(_ text: String) -> String {
        guard let template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        if template.contains("{{text}}") { return template.replacingOccurrences(of: "{{text}}", with: text) }
        return template + "\n\n" + text
    }
}

/// What the phone needs to know about a Mac profile.
public struct ProfileSummary: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var cleanupLevel: CleanupLevel?
    public var isDefault: Bool
    /// The phone matches these at the start of a transcript (see `VoicePrefix`).
    public var voicePrefixes: [String]?
    /// What kind of place the text goes — for the phone's icon. Nil from older Macs.
    public var targetKind: TargetKind?
    /// With `.app`: which app ("Claude", "com.anthropic.claudefordesktop").
    public var targetApp: String?
    public var targetBundleID: String?

    public enum TargetKind: String, Codable, Sendable { case clipboard, focusedApp, app, tmux, none }
    public init(id: UUID, name: String, cleanupLevel: CleanupLevel?, isDefault: Bool, voicePrefixes: [String]? = nil) {
        self.id = id
        self.name = name
        self.cleanupLevel = cleanupLevel
        self.isDefault = isDefault
        self.voicePrefixes = voicePrefixes
    }
}

/// A paired device as each side remembers it.
public struct PairedPeer: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var pairedAt: Date
    public var lastSeen: Date?
    public init(id: UUID, name: String, pairedAt: Date = Date(), lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
    }
}
