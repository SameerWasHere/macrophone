import Foundation

/// How much the on-device model edits a transcript. Default is `.medium`.
public enum CleanupLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, light, medium, heavy
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .medium: return "Medium"
        case .heavy: return "Heavy"
        }
    }

    /// One line, shown under the slider.
    public var summary: String {
        switch self {
        case .off: return "Exactly what the recognizer heard."
        case .light: return "Removes filler and repeats, fixes punctuation."
        case .medium: return "Also fixes grammar and false starts."
        case .heavy: return "Rewrites rambling speech into tidy text."
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
    /// Interrupted (call, lock, permission) — what was captured was still processed and sent.
    public var stoppedEarly: Bool
    public var duration: TimeInterval
    public var sourceDevice: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), raw: String, cleaned: String? = nil,
                cleanupLevel: CleanupLevel = .off, language: String = "en-US", profileID: UUID? = nil,
                profileName: String? = nil, stoppedEarly: Bool = false, duration: TimeInterval = 0,
                sourceDevice: String = "") {
        self.id = id
        self.createdAt = createdAt
        self.raw = raw
        self.cleaned = cleaned
        self.cleanupLevel = cleanupLevel
        self.language = language
        self.profileID = profileID
        self.profileName = profileName
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

    public init(id: UUID = UUID(), name: String, cleanupLevel: CleanupLevel? = nil,
                destination: Destination = .clipboard, pressEnter: Bool = false, template: String? = nil,
                script: String? = nil, webhookURL: URL? = nil, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.cleanupLevel = cleanupLevel
        self.destination = destination
        self.pressEnter = pressEnter
        self.template = template
        self.script = script
        self.webhookURL = webhookURL
        self.isDefault = isDefault
    }

    /// True when this profile can send text off the device.
    public var sendsOffDevice: Bool { webhookURL != nil || !(script ?? "").isEmpty }

    public var summary: ProfileSummary {
        ProfileSummary(id: id, name: name, cleanupLevel: cleanupLevel, isDefault: isDefault)
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
    public init(id: UUID, name: String, cleanupLevel: CleanupLevel?, isDefault: Bool) {
        self.id = id
        self.name = name
        self.cleanupLevel = cleanupLevel
        self.isDefault = isDefault
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
