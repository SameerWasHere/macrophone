import CoreGraphics
import Foundation

// Watching (Oct 14 2026): after a dictation lands, the phone can show the picked app's window,
// live, with a few one-tap actions (scroll, Return, Esc). Only that one window, never the whole
// screen; frames go over the same encrypted link and only while the phone is looking.

/// One picture of the watched window. Sent only when it changed.
public struct WatchFrame: Codable, Sendable {
    public var seq: Int
    /// JPEG, at most ~1500 px wide.
    public var jpeg: Data
    public var width: Int
    public var height: Int
    public var appName: String
    /// The app's bundle id (the phone names its buttons by it — "Approve" in a terminal).
    public var bundleID: String?
    /// Where the place to type is, as a fraction of the window (0…1, top-left origin) — the
    /// phone centres its view on that column (Cursor's chat on the right, Claude's in the middle).
    public var focus: CGRect?

    public init(seq: Int, jpeg: Data, width: Int, height: Int, appName: String, bundleID: String?, focus: CGRect?) {
        self.seq = seq
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.appName = appName
        self.bundleID = bundleID
        self.focus = focus
    }
}

/// How watching is going, from the Mac's side.
public enum WatchState: Codable, Sendable, Equatable {
    /// Frames are coming.
    case live(appName: String)
    /// Screen Recording is off for Macrophone on the Mac.
    case needsPermission
    /// Nothing to show right now, in one plain sentence ("Claude isn't open on your Mac",
    /// "Claude's window is minimized").
    case unavailable(String, canReveal: Bool)
    /// The Mac stopped (asked to, or the phone went away).
    case stopped
}

/// A one-tap action on the watched window. Each brings the window forward first.
public enum WatchAction: String, Codable, Sendable, CaseIterable {
    case scrollUp
    case scrollDown
    /// Return — approves a prompt in Claude Code, sends in most chat apps.
    case returnKey
    /// Esc — stops Claude Code.
    case escape
    /// Bring the window forward (it was minimized or on another desktop).
    case reveal
    /// Open Privacy & Security › Screen Recording on the Mac.
    case openScreenRecordingSettings
}

public enum WatchApps {
    /// Terminals, where Claude Code and other agents run: Return approves, Esc stops.
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "dev.warp.Warp", "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm",
        "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio",
    ]

    /// Agent apps whose permission prompts take Return / Esc.
    public static let agents: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.codex", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode", "com.exafunction.windsurf",
    ]

    public static func isAgentLike(_ bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        return terminals.contains(b) || agents.contains(b)
    }
}
