import Foundation

// What's in front on your Mac (Nov 7 2026, Sameer: "pick up where the Mac is" — whatever window
// is in front on the Mac, a tap on the phone and you're watching it). Handoff was tried first and
// dropped: macOS advertises only the active app's activity, and a menu bar app is almost never
// the active one (CLAUDE.md).
//
// The wire: `.frontWindow(FrontWindow?)` Mac → phone — after the welcome and on each change
// (paced by `FrontWindowPacer`: a change waits half a second to stay put, never more than two a
// second), nil when there's nothing safe to offer (a password manager in front, a window kept out
// of screen capture, a password field, a locked screen). Only to a phone whose hello named
// `FrontWindow.feature`; an older phone never gets it, and an older Mac never sends it (the phone
// then watches `.frontApp`, which every Mac understands).

public struct FrontWindow: Codable, Sendable, Equatable {
    public static let feature = "frontWindow"

    /// The app in front on the Mac.
    public var bundleID: String
    public var appName: String
    /// Its front window's number (the window server's id) — a `LiveTarget`'s `windowKey`. Nil
    /// when the app showed no window the Mac could see.
    public var window: UInt32?
    /// The window's title, one line, trimmed (`trimmed`); nil when it has none or it's the app's name.
    public var title: String?

    public init(bundleID: String, appName: String, window: UInt32?, title: String?) {
        self.bundleID = bundleID
        self.appName = appName
        self.window = window
        let t = title.map(Self.trimmed) ?? ""
        self.title = t.isEmpty || t == appName ? nil : t
    }

    /// The longest title sent (the phone shows one line).
    public static let titleLimit = 90

    /// One line, at most `titleLimit` characters, cut on a word when one is near — with no "…"
    /// (Nov 10 2026: nothing in the app ends in dots; the phone fades a line that runs long).
    public static func trimmed(_ s: String) -> String {
        let one = s.components(separatedBy: .newlines).joined(separator: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        guard one.count > titleLimit else { return one }
        var cut = String(one.prefix(titleLimit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > titleLimit * 2 / 3 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " —-–·,:;"))
    }

    /// "Claude — Fix the login bug", or "Claude".
    public var line: String { title.map { "\(appName) — \($0)" } ?? appName }

    /// The window's key for a `TargetRef`.
    public var windowKey: String? { window.map(String.init) }

    /// The phone watches this.
    public var target: TargetRef { .app(bundleID: bundleID, windowKey: windowKey, name: line) }

    /// Whether this is the place `ref` already names: the same app and window, or the app with no
    /// window named (the Mac shows its front one).
    public func isSame(as ref: TargetRef) -> Bool {
        guard case let .app(bid, key, _) = ref, bid == bundleID else { return false }
        return key == nil || windowKey == nil || key == windowKey
    }

    /// Apps whose windows are never offered: what they show is private (password managers, the
    /// keychain), or they're the system's own surfaces (the login window, the lock screen, the
    /// Dock) — nothing to watch.
    public static let neverShown: Set<String> = [
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.ScreenSaver.Engine",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.systempreferences.Passwords",
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "com.dashlane.Dashlane", "org.keepassxc.keepassxc", "in.sinew.Enpass-Desktop",
        "com.nordpass.macos.NordPass", "me.proton.pass.electron", "com.keepersecurity.keeper",
        "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Spotlight",
        "com.apple.WindowManager", "com.apple.systemuiserver",
    ]

    /// An app the Mac may offer (never Macrophone's own copies — the Mac keeps the last real app then).
    public static func mayShow(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && !neverShown.contains(bundleID) && !isMacrophone(bundleID)
    }

    /// Macrophone itself (any copy: Release, Debug, an instance).
    public static func isMacrophone(_ bundleID: String) -> Bool { bundleID.hasPrefix("com.sameer.macrophone") }
}

/// When the Mac tells the phones what's in front: a change waits `settle` to stay put (switching
/// through three apps with ⌘Tab sends one), and never sooner than `gap` after the last (at most
/// two a second). The same value twice is never sent. Pure: the Mac's timer asks `due` and `take`.
public struct FrontWindowPacer: Sendable {
    public static let settle: TimeInterval = 0.5
    public static let gap: TimeInterval = 0.5

    private var hasSent = false
    private var sent: FrontWindow?
    private var sentAt = Date.distantPast
    private var latest: FrontWindow?
    /// Since when `latest` has stood; nil when nothing waits.
    private var since: Date?

    public init() {}

    /// What's in front now.
    public mutating func saw(_ w: FrontWindow?, at now: Date) {
        if hasSent, w == sent { since = nil; latest = w; return }
        if since == nil || w != latest { latest = w; since = now }
    }

    /// When the waiting value may go; nil when nothing waits.
    public var due: Date? {
        guard let since else { return nil }
        return max(since.addingTimeInterval(Self.settle), sentAt.addingTimeInterval(Self.gap))
    }

    /// The value to send now (`.some(nil)`: say there's nothing), or nil when nothing is due.
    public mutating func take(at now: Date) -> FrontWindow?? {
        guard let due, now >= due else { return nil }
        hasSent = true
        sent = latest
        sentAt = now
        since = nil
        return .some(latest)
    }
}
