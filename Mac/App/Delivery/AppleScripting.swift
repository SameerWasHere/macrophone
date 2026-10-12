import AppKit
import CoreServices
import Foundation

/// AppleScript for the few things only it can do: picking a Terminal/iTerm tab by what's
/// running in it, reading a browser's address, writing an Apple Note. Each target app asks
/// for Automation permission once (System Settings › Privacy & Security › Automation); we
/// ask only when a profile actually needs it.
enum Scripting {
    enum Permission: Equatable {
        case granted, denied, notAsked
        /// The app isn't running, so macOS can't say yet.
        case notRunning
    }

    private static let queue = DispatchQueue(label: "macrophone.applescript")

    /// Whether Macrophone may send Apple Events to `bundleID`. With `ask`, shows the system
    /// prompt when it hasn't been answered — that blocks until the person answers, so call it
    /// off the main thread.
    static func permission(_ bundleID: String, ask: Bool) -> Permission {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(procNotFound): return .notRunning
        default: return .notAsked
        }
    }

    static func permissionAsync(_ bundleID: String, ask: Bool) async -> Permission {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: permission(bundleID, ask: ask)) }
        }
    }

    /// Launches the app quietly if needed, then shows the permission prompt. For the "Allow…"
    /// buttons in the editor.
    static func requestPermission(_ bundleID: String) async -> Permission {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        return await permissionAsync(bundleID, ask: true)
    }

    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    struct Failure: Error { var message: String; var number: Int }

    /// Runs a script on a background queue. `timeout` is applied inside the script.
    static func run(_ source: String, timeout: Int = 6) async throws -> String {
        let wrapped = "with timeout of \(timeout) seconds\n\(source)\nend timeout"
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                var err: NSDictionary?
                let result = NSAppleScript(source: wrapped)?.executeAndReturnError(&err)
                if let err {
                    c.resume(throwing: Failure(message: err[NSAppleScript.errorMessage] as? String ?? "AppleScript error",
                                               number: err[NSAppleScript.errorNumber] as? Int ?? 0))
                } else {
                    c.resume(returning: result?.stringValue ?? "")
                }
            }
        }
    }

    /// A Swift string as an AppleScript string literal.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Terminal tabs

    /// Selects the Terminal tab whose custom title, window name or running processes contain
    /// `needle` (front-most window first) and brings its window to the top. Returns false when
    /// nothing matches.
    static func selectTerminalTab(matching needle: String) async throws -> Bool {
        let script = """
        set needle to \(quote(needle))
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    set hit to false
                    try
                        if (custom title of t) contains needle then set hit to true
                    end try
                    if not hit then
                        try
                            repeat with p in (processes of t)
                                if (p as text) contains needle then set hit to true
                            end repeat
                        end try
                    end if
                    if not hit and (selected of t) then
                        try
                            if (name of w) contains needle then set hit to true
                        end try
                    end if
                    if hit then
                        set selected of t to true
                        set index of w to 1
                        return "found"
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """
        return try await run(script) == "found"
    }

    /// Selects the iTerm2 session whose name contains `needle`.
    static func selectITermSession(matching needle: String) async throws -> Bool {
        let script = """
        set needle to \(quote(needle))
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (name of s) contains needle then
                            select w
                            tell t to select
                            tell s to select
                            return "found"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return ""
        """
        return try await run(script) == "found"
    }

    // MARK: Browsers

    struct Browser {
        let bundleID: String
        let name: String
        /// AppleScript that returns the front tab's URL.
        let script: String
    }

    static let browsers: [Browser] = [
        Browser(bundleID: "com.apple.Safari", name: "Safari",
                script: "tell application id \"com.apple.Safari\" to return URL of front document"),
        Browser(bundleID: "com.google.Chrome", name: "Chrome",
                script: "tell application id \"com.google.Chrome\" to return URL of active tab of front window"),
        Browser(bundleID: "company.thebrowser.Browser", name: "Arc",
                script: "tell application id \"company.thebrowser.Browser\" to return URL of active tab of front window"),
        Browser(bundleID: "com.brave.Browser", name: "Brave",
                script: "tell application id \"com.brave.Browser\" to return URL of active tab of front window"),
        Browser(bundleID: "com.microsoft.edgemac", name: "Edge",
                script: "tell application id \"com.microsoft.edgemac\" to return URL of active tab of front window"),
    ]

    /// The browser the person was most recently looking at: the front app if it's one, else the
    /// browser with the front-most window on screen.
    static func frontBrowser(frontmost: String?) -> Browser? {
        if let f = frontmost, let b = browsers.first(where: { $0.bundleID == f }) { return b }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                  let b = browsers.first(where: { $0.bundleID == bid }) else { continue }
            return b
        }
        return nil
    }

    /// The front tab's URL. Asks for Automation permission the first time (per browser).
    static func browserURL(frontmost: String?) async -> (url: String?, note: String?) {
        guard let b = frontBrowser(frontmost: frontmost) else { return (nil, nil) }
        switch await permissionAsync(b.bundleID, ask: true) {
        case .granted: break
        case .denied: return (nil, "{{url}} is empty — Macrophone isn't allowed to read \(b.name)'s address (System Settings › Privacy & Security › Automation).")
        default: return (nil, nil)
        }
        let url = try? await run(b.script, timeout: 3)
        return (url?.isEmpty == false ? url : nil, nil)
    }
}
