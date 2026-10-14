import Foundation

// Open an app (Oct 14 2026, Sameer: "what if Claude is closed and I want to open it?"): the phone
// asks the Mac for the apps installed on it, and opening one launches it on the Mac, brings it
// forward and makes it the Send-to choice.

/// An app installed on the Mac.
public struct MacApp: Codable, Sendable, Identifiable, Hashable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    /// PNG, 64 px.
    public var icon: Data?
    /// Open on the Mac right now.
    public var running: Bool

    public init(bundleID: String, name: String, icon: Data? = nil, running: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
        self.running = running
    }
}
