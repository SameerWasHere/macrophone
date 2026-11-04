import Foundation

/// Undo the last paste (Nov 3 2026, Sameer chose it from the polish ideas: "for a few seconds after
/// the words land on the Mac, an Undo chip by the mic sends ⌘Z"). The phone asks by the
/// dictation's id; the Mac undoes only its own last paste — one it pasted and didn't send, made a
/// moment ago — by bringing that app forward and pressing ⌘Z, and says what happened.
public enum UndoPaste {
    /// Named in hello / welcome: a Mac that doesn't name it never gets the message.
    public static let feature = "undo"
    /// How long after a paste the Mac still undoes it.
    public static let window: TimeInterval = 30
}

/// Mac → phone: what the undo did, in a plain line ("Undid the paste in Claude").
public struct UndoResult: Codable, Sendable, Equatable {
    public var id: UUID
    public var ok: Bool
    public var detail: String

    public init(id: UUID, ok: Bool, detail: String) {
        self.id = id
        self.ok = ok
        self.detail = detail
    }
}
