import Foundation
import MacrophoneKit

/// Where one dictation's text ended up.
enum DeliveryState: String, Codable, Sendable {
    /// Not paired: the text went to this iPhone's clipboard.
    case copiedOnPhone
    case cleaning
    case sending
    case delivered
    /// The Mac already had it (a resend).
    case duplicate
    /// The Mac wasn't reachable — waiting in the queue.
    case queued
    /// The Mac answered but couldn't deliver it.
    case failed
}

/// One dictation as the phone remembers it: the text, both versions, and its delivery.
struct HistoryItem: Codable, Identifiable, Sendable, Hashable {
    var dictation: Dictation
    var delivery: DeliveryState
    /// The Mac's own line, e.g. "Copied to clipboard".
    var detail: String?
    var macName: String?
    /// It went through the offline queue (sent later than it was spoken).
    var wasDelayed: Bool = false
    var deliveredAt: Date?
    /// Cleanup ran out of time partway: the start is cleaned, the rest went as spoken.
    var partialCleanup: Bool? = nil
    /// The name that picked the target, as said ("Messages", "Claude"), when saying it did.
    var spokenPrefix: String? = nil

    var id: UUID { dictation.id }

    /// "Messages", "Clipboard", "Where I'm typing", an automation's name — or nil for older
    /// dictations sent on Automatic.
    var targetName: String? {
        if let t = dictation.target { return t.displayName }
        return dictation.profileSource == .automatic ? nil : dictation.profileName
    }

    /// True when the cleaned version only differs because the prefix was taken off.
    var onlyPrefixRemoved: Bool { hasCleaned && dictation.cleanupLevel == .off }

    var hasCleaned: Bool {
        guard let c = dictation.cleaned?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !c.isEmpty && c != dictation.raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func text(cleaned: Bool) -> String { cleaned && hasCleaned ? (dictation.cleaned ?? dictation.raw) : dictation.raw }

    /// The short labels shown on a history row.
    var labels: [String] {
        var out: [String] = []
        switch delivery {
        case .copiedOnPhone: out.append("Copied on iPhone")
        case .cleaning, .sending: out.append("Sending")
        case .delivered: out.append("Delivered")
        case .duplicate: out.append("On your Mac")
        case .queued: out.append("Queued")
        case .failed: out.append("Not delivered")
        }
        if wasDelayed, delivery != .queued { out.append("Delayed") }
        if dictation.stoppedEarly { out.append("Stopped early") }
        return out
    }
}
