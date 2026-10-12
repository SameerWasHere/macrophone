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
let targets: [ProfileSummary] = [
    ProfileSummary(id: profileID(1), name: "Clipboard", cleanupLevel: nil, isDefault: true),
    ProfileSummary(id: profileID(2), name: "Claude", cleanupLevel: nil, isDefault: false, voicePrefixes: ["claude"]),
    ProfileSummary(id: profileID(3), name: "Claude Code (Terminal)", cleanupLevel: .light, isDefault: false, voicePrefixes: ["claude code", "terminal"]),
    ProfileSummary(id: profileID(4), name: "ChatGPT", cleanupLevel: nil, isDefault: false, voicePrefixes: ["chatgpt", "chat gpt"]),
]

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
        let name = targets.first { $0.id == d.profileID }?.name ?? "-"
        out("RECEIVED #\(n)\(delayed ? " (delayed)" : "") source=\(d.profileSource?.rawValue ?? "nil") profile=\(name) profileName=\(d.profileName ?? "nil") level=\(d.cleanupLevel.rawValue)")
        out("  raw:  \(d.raw)")
        out("  sent: \(d.text)")
        return (.delivered, name == "-" ? "Copied" : "Pasted into \(name)")
    }
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
    while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
}

await main()
