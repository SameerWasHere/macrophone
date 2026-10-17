import AppKit
import Foundation

/// Which key submits a message in an app.
enum SendKey: String, Codable, Sendable {
    case `return`, commandReturn, commandShiftD

    var title: String {
        switch self {
        case .return: return "Return"
        case .commandReturn: return "⌘ Return"
        case .commandShiftD: return "⌘⇧D"
        }
    }
}

/// The few things Macrophone needs to know about particular apps. Everything else is found by
/// looking (docs/TARGETS.md). Nothing here is a setting — it's an internal table.
enum AppQuirks {
    /// Never a target: nothing to dictate into, or only a lone search box.
    static let excluded: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.SystemPreferences", "com.apple.dock",
        "com.apple.loginwindow", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.ActivityMonitor", "com.apple.AppStore", "com.apple.Maps", "com.apple.Photos",
        "com.apple.Preview", "com.apple.QuickTimePlayerX", "com.apple.Music", "com.apple.TV",
        "com.apple.podcasts", "com.apple.calculator", "com.apple.FaceTime", "com.apple.weather",
        "com.apple.Passwords", "com.apple.keychainaccess", "com.apple.systeminfo",
    ]

    /// Terminals: the window is the input (a shell, Claude Code). Nothing to focus inside it,
    /// every window counts, and Return runs the line.
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "io.alacritty", "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.raphaelamorim.rio", "dev.commandline.waveterm",
    ]

    /// Where coding agents ask questions (besides terminals): their windows are watched for a
    /// question while a phone listens for alerts.
    static let agentApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode", "com.exafunction.windsurf", "dev.zed.Zed", "com.google.antigravity",
    ]

    /// Apps whose message box can't be seen through Accessibility at all (it isn't in their
    /// tree), but which keep the cursor in it: Macrophone brings the window forward and pastes
    /// where the cursor is. Found by looking at the app's tree (docs/TARGETS.md).
    static let hiddenComposer: Set<String> = [
        "com.meta.endo", // Muse
    ]

    /// Apps where Return makes a new line and another key sends.
    static let sendKeys: [String: SendKey] = [
        "com.apple.mail": .commandShiftD,
        "com.microsoft.Outlook": .commandReturn,
        "com.readdle.SparkDesktop": .commandReturn,
        "com.readdle.smartemail-Mac": .commandReturn,
        "com.superhuman.electron": .commandReturn,
        "com.linear": .commandReturn,
        "com.github.GitHubClient": .commandReturn,
    ]

    static func sendKey(for bundleID: String?) -> SendKey {
        bundleID.flatMap { sendKeys[$0] } ?? .return
    }

    static func isTerminal(_ bundleID: String?) -> Bool { bundleID.map(terminals.contains) ?? false }

    /// Settle times: a freshly activated window needs a moment to take keyboard focus, and a
    /// pasted message a moment to land before the send key (ms).
    static func activationSettle(_ bundleID: String?) -> UInt64 { isTerminal(bundleID) ? 160 : 260 }
    static func pasteSettle(_ bundleID: String?) -> UInt64 { isTerminal(bundleID) ? 260 : 380 }

    // MARK: Chromium / Electron

    private static var chromiumCache: [String: Bool] = [:]
    private static let lock = NSLock()

    /// Electron apps and Chromium browsers build their accessibility tree only when asked
    /// (`AXManualAccessibility`). Known browsers, plus any app shipping an Electron or Chromium
    /// framework.
    static func isChromium(bundleID: String, url: URL?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let v = chromiumCache[bundleID] { return v }
        var v = ["com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.dia", "company.thebrowser.Browser",
                 "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
                 "org.chromium.Chromium"].contains(bundleID)
        if !v, let url {
            let fw = url.appendingPathComponent("Contents/Frameworks")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: fw.path)) ?? []
            v = names.contains { $0.hasPrefix("Electron Framework") || $0.contains("Chromium") || $0.hasSuffix("Chrome Framework.framework") }
        }
        chromiumCache[bundleID] = v
        return v
    }
}
