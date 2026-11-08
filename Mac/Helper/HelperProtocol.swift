import Foundation

// Keep Awake's root helper (Nov 7 2026), the part both sides compile: its name, who may talk to
// it, and what it answers. Compiled into the app and into the helper daemon; the helper also
// compiles MacrophoneKit's Core/KeepAwakePower.swift (the allowlist) and nothing else.
//
// The daemon is registered with SMAppService (macOS asks the person once, in System Settings ›
// General › Login Items & Extensions) and then changes `pmset` settings without a password.
// A debug build has its own label, so it never collides with an installed release.

enum PowerHelperIdentity {
    #if DEBUG
    static let label = "com.sameer.macrophone.mac.debug.helper"
    #else
    static let label = "com.sameer.macrophone.mac.helper"
    #endif
    static let plistName = label + ".plist"
    static let team = "8523EX5882"

    /// Who the helper takes calls from: Macrophone, signed by this team — Developer ID (a release)
    /// or Apple Development (a build from Xcode), both under Apple's anchor.
    static let clientRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (identifier \"com.sameer.macrophone.mac\" or identifier \"com.sameer.macrophone.mac.debug\")"

    /// Who the app talks to: the helper, signed the same way (a daemon swapped under the label is refused).
    static let helperRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (identifier \"com.sameer.macrophone.mac.helper\" or identifier \"com.sameer.macrophone.mac.debug.helper\")"
}

@objc protocol MacrophonePowerHelperProtocol {
    /// `PowerHelperVersion.current` of the daemon running (the handshake).
    func version(reply: @escaping (Int) -> Void)
    /// Each change is `PowerChange.wire` ("a sleep 0"). All are checked against the allowlist
    /// before any runs; one refused refuses them all.
    func apply(_ changes: [String], reply: @escaping (Bool, String) -> Void)
    /// `launchctl kickstart -k system/com.apple.audio.coreaudiod` (the audio guard's last resort).
    func restartCoreAudio(reply: @escaping (Bool, String) -> Void)
    /// Exits, so launchd starts the copy inside the current app the next time it's called (an
    /// update of Macrophone leaves the old daemon running until then).
    func stepDown(reply: @escaping () -> Void)
}
