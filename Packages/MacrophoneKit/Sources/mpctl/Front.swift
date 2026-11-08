import Foundation
import MacrophoneKit

// What's in front on the Mac (Nov 7 2026) in the protocol proof. `serve` tells a phone naming
// "frontWindow" a demo front window after the welcome and moves it along now and then, as a
// person switching apps would:
//
//   mpctl serve --front com.apple.Terminal#42   # the first front window (default: Terminal's codex window)
//   mpctl serve --front none                    # nothing safe to show (a password manager in front)
//   mpctl serve --front-every 12                # the next one in the list every 12 s (0: never; default 20)
//   mpctl serve --no-front                      # a Mac from before: never names the feature
//   mpctl listen --features frontWindow         # prints FRONT ‹bundle id›#‹key› · ‹app› — ‹title› (or FRONT none)
//
// A watch of `.frontApp` (Where I'm typing) is answered with the demo front window's app, as the
// Mac app adopts the app in front.

enum FrontDemo {
    /// The demo Mac's windows, in the order the front moves through them.
    static let cycle: [FrontWindow] = [
        FrontWindow(bundleID: "com.apple.Terminal", appName: "Terminal", window: 42, title: "codex — ~/api"),
        FrontWindow(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", window: nil, title: "Fix the login bug"),
        FrontWindow(bundleID: "com.apple.Terminal", appName: "Terminal", window: 41, title: "claude — ~/app"),
        FrontWindow(bundleID: "com.apple.MobileSMS", appName: "Messages", window: nil, title: nil),
    ]

    nonisolated(unsafe) static var current: FrontWindow? = first()

    static func first() -> FrontWindow? {
        guard let spec = flag("--front") else { return cycle[0] }
        if spec == "none" { return nil }
        let parts = spec.split(separator: "#", maxSplits: 1).map(String.init)
        if let known = cycle.first(where: { $0.bundleID == parts[0] && (parts.count < 2 || $0.windowKey == parts[1]) }) { return known }
        let name = parts[0].split(separator: ".").last.map(String.init) ?? parts[0]
        return FrontWindow(bundleID: parts[0], appName: name, window: parts.count > 1 ? UInt32(parts[1]) : nil, title: nil)
    }

    static func describe(_ w: FrontWindow?) -> String {
        guard let w else { return "none" }
        return "\(w.bundleID)#\(w.windowKey ?? "") · \(w.line)"
    }

    /// Moves the front along every `--front-every` s, telling every phone that shows it.
    static func start(_ server: LinkServer) {
        let every = Double(flag("--front-every") ?? "20") ?? 20
        guard every > 0 else { return }
        Task {
            var i = cycle.firstIndex { $0 == current } ?? -1
            while true {
                try? await Task.sleep(nanoseconds: UInt64(every * 1e9))
                i = (i + 1) % cycle.count
                current = cycle[i]
                server.broadcastFrontWindow(current)
                stdout("FRONT now \(describe(current))")
            }
        }
    }

    /// Where I'm typing on this demo Mac: the front window's app.
    static func resolve(_ target: TargetRef) -> TargetRef {
        guard target == .frontApp, let w = current else { return target }
        return .app(bundleID: w.bundleID, windowKey: w.windowKey, name: w.line)
    }
}

extension ServeDelegate: LinkServerFrontWindowDelegate {
    func frontWindow(_ server: LinkServer, for peerID: UUID) -> FrontWindow? {
        stdout("FRONT sent \(FrontDemo.describe(FrontDemo.current))")
        return FrontDemo.current
    }
}

extension PhoneDelegate: LinkClientFrontWindowDelegate {
    func linkClient(_ client: LinkClient, frontWindow: FrontWindow?, macID: UUID) {
        stdout("FRONT \(FrontDemo.describe(frontWindow))")
    }
}
