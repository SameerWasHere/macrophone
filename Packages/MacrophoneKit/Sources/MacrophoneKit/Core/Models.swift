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
    public var profileName: String?
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
                cleanupLevel: CleanupLevel = .off, language: String = "en-US",
                profileName: String? = nil, target: TargetRef? = nil,
                send: Bool? = nil, targetSpoken: Bool? = nil, stoppedEarly: Bool = false,
                duration: TimeInterval = 0, sourceDevice: String = "") {
        self.id = id
        self.createdAt = createdAt
        self.raw = raw
        self.cleaned = cleaned
        self.cleanupLevel = cleanupLevel
        self.language = language
        self.profileName = profileName
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
