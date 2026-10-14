import Foundation

// Live targets (Oct 13 2026, Sameer's simplification): instead of configured app targets, the
// Mac finds every open app/window that has somewhere to type, tells the phone, and the phone
// picks one — "paste" or "paste & send". The pick is ONE shared selection: change it on either
// device and the other follows; when they reconnect and disagree, the phone's wins.

/// An app (or one of its windows) open on the Mac that has a text field to paste into.
public struct LiveTarget: Codable, Sendable, Identifiable, Hashable {
    /// Stable while the window lives: "<bundleID>" for the app, "<bundleID>#<windowKey>" for a window.
    public var id: String
    public var bundleID: String
    public var appName: String
    /// Set when the app has more than one window with a text field (e.g. two Terminal windows).
    public var windowTitle: String?
    /// The window's key inside its app, when `windowTitle` is set.
    public var windowKey: String?
    /// PNG app icon, small (≤ 128 px). The same for every window of an app.
    public var icon: Data?
    /// When the person last used it on the Mac — the list is newest first.
    public var lastActive: Date?

    public init(bundleID: String, appName: String, windowTitle: String? = nil, windowKey: String? = nil,
                icon: Data? = nil, lastActive: Date? = nil) {
        self.id = windowKey.map { "\(bundleID)#\($0)" } ?? bundleID
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.windowKey = windowKey
        self.icon = icon
        self.lastActive = lastActive
    }

    /// "Terminal — claude ~/app" for a window, "Claude" for an app.
    public var title: String {
        guard let w = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty else { return appName }
        return "\(appName) — \(w)"
    }

    public var ref: TargetRef { .app(bundleID: bundleID, windowKey: windowKey, name: title) }
}

/// Where the text goes.
public enum TargetRef: Codable, Sendable, Hashable {
    /// Copy to the Mac's clipboard only.
    case clipboard
    /// Paste into whatever app is in front on the Mac ("Where I'm typing").
    case frontApp
    /// A live app or window. `name` is for display when the target isn't open right now.
    case app(bundleID: String, windowKey: String?, name: String)

    public var displayName: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .frontApp: return "Where I'm typing"
        case let .app(_, _, name): return name
        }
    }

    /// Whether "send" makes sense for it (pressing the send key after pasting).
    public var canSend: Bool {
        switch self {
        case .clipboard: return false
        case .frontApp, .app: return true
        }
    }

    public var bundleID: String? {
        if case let .app(bid, _, _) = self { return bid }
        return nil
    }

    /// True when a live target is this ref (same app, and the same window if one was picked).
    public func matches(_ t: LiveTarget) -> Bool {
        guard case let .app(bid, key, _) = self, bid == t.bundleID else { return false }
        return key == nil ? t.windowKey == nil : key == t.windowKey
    }
}

/// The one shared choice: where dictations go, and whether to press send after pasting.
public struct SendSelection: Codable, Sendable, Hashable {
    public var target: TargetRef
    /// Paste, then press the app's send key — after the Mac's 2.5-second countdown.
    public var send: Bool

    public init(target: TargetRef, send: Bool = false) {
        self.target = target
        self.send = send && target.canSend
    }

    public static let `default` = SendSelection(target: .clipboard)
}

public enum SpokenTarget {
    /// "Messages, tell Sam I'm late" → the open Messages target and "Tell Sam I'm late".
    /// Matches an open app's name (or "<app> <window words>" for a window) at the start of the
    /// transcript, followed by a pause mark — the same rule as voice prefixes. Longest name wins.
    public static func match(_ transcript: String, targets: [LiveTarget]) -> (target: LiveTarget, text: String)? {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // App-level entries first so "Claude, …" picks the app, not one of its windows.
        let ordered = targets.sorted { a, b in
            if a.appName.count != b.appName.count { return a.appName.count > b.appName.count }
            return (a.windowKey == nil) && (b.windowKey != nil)
        }
        for target in ordered {
            let name = VoicePrefix.normalize(target.appName)
            guard !name.isEmpty else { continue }
            if let rest = VoicePrefix.strip(name, from: t) { return (target, rest) }
            // Speech often splits names: "Chat GPT" for ChatGPT.
            let spaced = name.replacingOccurrences(of: "gpt", with: " gpt")
            if spaced != name, let rest = VoicePrefix.strip(spaced, from: t) { return (target, rest) }
        }
        return nil
    }
}
