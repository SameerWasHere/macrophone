import Foundation
import MacrophoneKit

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func out(_ s: String) { print(s); fflush(stdout) }

let dir = URL(fileURLWithPath: flag("--state") ?? "/tmp/mp-route-sink")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

func profileID(_ n: Int) -> UUID { UUID(uuidString: String(format: "5155C0DE-0000-4000-8000-%012X", n))! }
/// The Mac's automations.
let targets: [ProfileSummary] = [
    ProfileSummary(id: profileID(1), name: "Quick note", cleanupLevel: .light, isDefault: false, voicePrefixes: ["note"]),
    ProfileSummary(id: profileID(2), name: "Remind me", cleanupLevel: nil, isDefault: false, voicePrefixes: ["remind me"]),
]
/// The Mac's open apps.
let apps: [LiveTarget] = [
    LiveTarget(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", lastActive: Date()),
    LiveTarget(bundleID: "com.apple.MobileSMS", appName: "Messages"),
    LiveTarget(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "claude", windowKey: "41"),
]

func describe(_ t: TargetRef?) -> String {
    switch t {
    case .clipboard?: return "clipboard"
    case .frontApp?: return "front"
    case let .app(bid, key, name)?: return "app(\(bid)\(key.map { "#\($0)" } ?? ""), \(name))"
    case let .automation(id, name)?: return "automation(\(id.uuidString.prefix(8)), \(name))"
    case nil: return "nil"
    }
}

@MainActor
final class Sink: LinkServerDelegate {
    var n = 0
    func linkServer(_ server: LinkServer, approveCode code: String, phoneName: String) async -> Bool { true }
    func linkServer(_ server: LinkServer, didPair peer: PairedPeer) { out("PAIRED with \(peer.name)") }
    func linkServer(_ server: LinkServer, didUnpair peerID: UUID) { out("UNPAIRED by phone") }
    func linkServer(_ server: LinkServer, peerConnected peer: PairedPeer, appVersion: String, os: String) { out("CONNECTED \(peer.name)") }
    func linkServer(_ server: LinkServer, peerDisconnected peerID: UUID) { out("DISCONNECTED") }
    func linkServer(_ server: LinkServer, deliver d: Dictation, delayed: Bool, from peer: PairedPeer) async -> (DeliveryOutcome, String?) {
        n += 1
        out("RECEIVED #\(n)\(delayed ? " (delayed)" : "") target=\(describe(d.target)) send=\(d.send.map { "\($0)" } ?? "nil") said=\(d.targetSpoken == true) source=\(d.profileSource?.rawValue ?? "nil") profileName=\(d.profileName ?? "nil") level=\(d.cleanupLevel.rawValue)")
        out("  raw:  \(d.raw)")
        out("  sent: \(d.text)")
        switch d.target {
        case let .app(bid, _, name)?:
            if !apps.contains(where: { $0.bundleID == bid }) { return (.delivered, "\(name) isn't open on your Mac — copied instead") }
            return (.delivered, d.send == true ? "Sent to \(name)" : "Pasted into \(name)")
        case .frontApp?: return (.delivered, d.send == true ? "Sent to Slack" : "Pasted into Slack")
        case let .automation(_, name)?: return (.delivered, "Ran \(name)")
        default: return (.delivered, "Copied to clipboard")
        }
    }
    func linkServer(_ server: LinkServer, selectionChanged selection: SendSelection, from peer: PairedPeer) {
        out("SELECTION \(describe(selection.target))\(selection.send ? " + send" : "") from \(peer.name)")
    }
    func linkServerRefreshTargets(_ server: LinkServer) {
        out("REFRESH requested")
        server.broadcastTargets(apps)
    }
    func liveTargets(_ server: LinkServer) -> [LiveTarget] { apps }
    func linkServer(_ server: LinkServer, listenerChanged state: LinkServer.ListenerState) { out("LISTENER \(state)") }
    func profilesForPhones(_ server: LinkServer) -> [ProfileSummary] { targets }
}

@MainActor
func main() async {
    let idURL = dir.appendingPathComponent("identity.json")
    var identity = (try? Data(contentsOf: idURL)).flatMap { try? JSONDecoder().decode(DeviceIdentity.self, from: $0) }
        ?? DeviceIdentity(id: UUID(), name: "Route Sink")
    identity.name = flag("--name") ?? "Route Sink"
    try? JSONEncoder().encode(identity).write(to: idURL)
    let server = LinkServer(identity: identity, store: FilePairingStore(url: dir.appendingPathComponent("pairings.json")),
                            appVersion: "0.0-sink", seenIDsURL: dir.appendingPathComponent("seen.json"))
    let sink = Sink()
    server.delegate = sink
    server.start()
    out("PAIR URL \(server.makeInvite().url.absoluteString)")
    // Type "select <bundleID|clipboard|front> [send]" to change the choice "on the Mac".
    Task.detached {
        while let line = readLine() {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.first == "select", parts.count > 1 else { continue }
            let target: TargetRef = parts[1] == "clipboard" ? .clipboard : parts[1] == "front" ? .frontApp
                : (apps.first { $0.bundleID == parts[1] }?.ref ?? .app(bundleID: parts[1], windowKey: nil, name: parts[1]))
            let sel = SendSelection(target: target, send: parts.contains("send"))
            await MainActor.run { server.broadcastSelection(sel) }
            out("SENT SELECTION \(describe(target))\(sel.send ? " + send" : "")")
        }
    }
    while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
}

await main()
