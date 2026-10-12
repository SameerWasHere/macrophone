import Foundation
import MacrophoneKit

/// One dictation as the Mac remembers it: the phone's dictation (raw + cleaned), when it
/// arrived, whether it came from the phone's offline queue, which profile ran and what
/// happened. Never audio.
struct HistoryItem: Codable, Identifiable, Sendable, Hashable {
    enum Outcome: String, Codable, Sendable {
        case copied, pasted, cancelled, failed, pending
    }

    var dictation: Dictation
    var receivedAt: Date
    var delayed: Bool
    var profileName: String
    var outcome: Outcome
    /// One plain line: "Pasted into Claude", "Copied — delayed items are never pasted".
    var detail: String

    var id: UUID { dictation.id }

    var pulled: PulledDictation {
        PulledDictation(dictation, receivedAt: receivedAt, delayed: delayed)
    }

    /// True when cleanup changed the words (the raw/cleaned toggle only shows then).
    var hasCleanedVersion: Bool {
        guard let c = dictation.cleaned?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return false }
        return c != dictation.raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
