import Foundation

// Answering from the notification (Nov 9 2026). Sameer's loop is dictate → pocket the phone →
// come back for the answer; when the answer is a question ("Do you want to make this edit?
// 1. Yes 2. No") he had to open the app, wait for the link and tap. Now the notification carries
// the answers as buttons and a Reply field; a tap sends this to the Mac, which answers the
// window only if it still asks that question.

public enum AlertAnswers {
    /// In the Mac's welcome: it answers a window's question for a phone that isn't watching it.
    public static let feature = "alertAnswer"
    /// The private iCloud zone alerts are written to. A zone subscription needs no schema in the
    /// Production container (a query subscription does: "attempting to create a subscription in
    /// a production container" — why no alert ever reached a closed app before).
    public static let zone = "Alerts"
    /// Most answers a notification offers as buttons (iOS shows four actions; one is Reply).
    public static let most = 3
}

/// Phone → Mac: give the window at `ref` the answer at `index`, if it still asks `promptID`.
public struct AlertAnswer: Codable, Sendable, Equatable {
    public var ref: TargetRef
    public var promptID: String
    public var index: Int
    public init(ref: TargetRef, promptID: String, index: Int) {
        self.ref = ref
        self.promptID = promptID
        self.index = index
    }
}

/// Mac → phone: how that went, in words for the person.
public struct AlertAnswerResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var detail: String
    public init(ok: Bool, detail: String) {
        self.ok = ok
        self.detail = detail
    }
}
