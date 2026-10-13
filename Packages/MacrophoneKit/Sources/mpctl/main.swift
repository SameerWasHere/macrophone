import Foundation
import MacrophoneKit

// mpctl — the protocol proof. Two terminals (or two machines on a network under test):
//
//   mpctl serve --name "Test Mac"            # the Mac side: prints a pairing URL + accepts dictations
//   mpctl pair 'macrophone://pair?...'       # the phone side, by QR URL
//   mpctl pair-code [--mac <name>]           # the phone side, by confirmation code
//   mpctl send "hello world" [--count 5] [--resend]
//   mpctl serve --commands                    # …and type "select com.apple.MobileSMS send" to change the choice on the "Mac"
//   mpctl targets / mpctl select <bundleID|clipboard|front> [--send]
//   mpctl browse
//   mpctl cleanup-eval [--file samples.json] [--level medium]
//
// State lives in ~/.mpctl/<role> (or --state DIR) so a serve and a phone can coexist.

let args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func has(_ name: String) -> Bool { args.contains(name) }

func stateDir(_ role: String) -> URL {
    if let s = flag("--state") { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mpctl/\(role)")
}

func identity(_ role: String, name: String) -> DeviceIdentity {
    let url = stateDir(role).appendingPathComponent("identity.json")
    if let d = try? Data(contentsOf: url), var id = try? JSONDecoder().decode(DeviceIdentity.self, from: d) {
        id.name = name
        return id
    }
    let id = DeviceIdentity(id: UUID(), name: name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(id).write(to: url)
    return id
}

func stdout(_ s: String) { print(s); fflush(Foundation.stdout) }

// MARK: serve

@MainActor
final class ServeDelegate: LinkServerDelegate {
    var received = 0
    func linkServer(_ server: LinkServer, approveCode code: String, phoneName: String) async -> Bool {
        stdout("\n“\(phoneName)” wants to pair. Code on the Mac: \(code)")
        if has("--auto-approve") { stdout("(auto-approved)"); return true }
        stdout("Does it match the phone? [y/N] ")
        let answer = await Task.detached { readLine() }.value
        return answer?.lowercased().hasPrefix("y") == true
    }
    func linkServer(_ server: LinkServer, didPair peer: PairedPeer) { stdout("PAIRED with \(peer.name)") }
    func linkServer(_ server: LinkServer, didUnpair peerID: UUID) { stdout("UNPAIRED by phone") }
    func linkServer(_ server: LinkServer, peerConnected peer: PairedPeer, appVersion: String, os: String) {
        stdout("CONNECTED \(peer.name) (\(os), v\(appVersion))")
    }
    func linkServer(_ server: LinkServer, peerDisconnected peerID: UUID) { stdout("DISCONNECTED") }
    func linkServer(_ server: LinkServer, deliver dictation: Dictation, delayed: Bool, from peer: PairedPeer) async -> (DeliveryOutcome, String?) {
        received += 1
        stdout("RECEIVED #\(received)\(delayed ? " (delayed)" : ""): \(dictation.text)")
        return (.delivered, "Printed by mpctl")
    }
    func linkServer(_ server: LinkServer, listenerChanged state: LinkServer.ListenerState) {
        stdout("LISTENER \(state)")
    }
    func linkServer(_ server: LinkServer, selectionChanged selection: SendSelection, from peer: PairedPeer) {
        stdout("SELECTION \(selection.target.displayName)\(selection.send ? " + send" : "") from \(peer.name)")
    }
    func linkServerRefreshTargets(_ server: LinkServer) {
        stdout("REFRESH requested")
        server.broadcastTargets(liveTargets(server))
    }
    func liveTargets(_ server: LinkServer) -> [LiveTarget] {
        [LiveTarget(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", lastActive: Date()),
         LiveTarget(bundleID: "com.apple.MobileSMS", appName: "Messages"),
         LiveTarget(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "claude — ~/app", windowKey: "41")]
    }
    func profilesForPhones(_ server: LinkServer) -> [ProfileSummary] {
        [ProfileSummary(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Default", cleanupLevel: nil, isDefault: true)]
    }
}

// MARK: phone

@MainActor
final class PhoneDelegate: LinkClientDelegate {
    func linkClient(_ client: LinkClient, stateChanged state: LinkClient.State) { stdout("STATE \(state)") }
    func linkClient(_ client: LinkClient, discovered macs: [DiscoveredMac]) {
        for m in macs { stdout("FOUND \(m.name) id=\(m.macID?.uuidString ?? "?")\(m.isPeerToPeer ? " (peer-to-peer)" : "")") }
    }
    func linkClient(_ client: LinkClient, profiles: [ProfileSummary], macID: UUID) {
        stdout("PROFILES \(profiles.map(\.name).joined(separator: ", "))")
    }
    func linkClient(_ client: LinkClient, unpairedBy macID: UUID) { stdout("UNPAIRED by Mac") }
    func linkClient(_ client: LinkClient, targets: [LiveTarget], macID: UUID) {
        stdout("TARGETS \(targets.map(\.title).joined(separator: " | "))")
    }
    func linkClient(_ client: LinkClient, selectionChanged selection: SendSelection, macID: UUID) {
        stdout("SELECTION from Mac: \(selection.target.displayName)\(selection.send ? " + send" : "")")
    }
}

/// The client's delegate is weak; keep ours alive for the whole run.
nonisolated(unsafe) var keepDelegate: PhoneDelegate?

@MainActor
func makeClient() -> (LinkClient, PhoneDelegate) {
    let dir = stateDir("phone")
    let client = LinkClient(identity: identity("phone", name: flag("--name") ?? "mpctl phone"),
                            store: FilePairingStore(url: dir.appendingPathComponent("pairings.json")),
                            appVersion: "0.0-mpctl", osDescription: ProcessInfo.processInfo.operatingSystemVersionString)
    let d = PhoneDelegate()
    keepDelegate = d
    client.delegate = d
    if has("--verbose") { client.log = DiagnosticLog(url: nil) }
    return (client, d)
}

@MainActor
func run() async -> Int32 {
    guard let command = args.first else {
        stdout("usage: mpctl serve|pair <url>|pair-code|send <text>|browse|unpair|cleanup-eval")
        return 2
    }
    switch command {
    case "serve":
        let dir = stateDir("mac")
        let server = LinkServer(identity: identity("mac", name: flag("--name") ?? Host.current().localizedName ?? "mpctl Mac"),
                                store: FilePairingStore(url: dir.appendingPathComponent("pairings.json")),
                                appVersion: "0.0-mpctl", seenIDsURL: dir.appendingPathComponent("seen.json"))
        let d = ServeDelegate()
        server.delegate = d
        if has("--verbose") { server.log = DiagnosticLog(url: nil) }
        server.start()
        let invite = server.makeInvite()
        stdout("PAIR URL \(invite.url.absoluteString)")
        stdout("Paired phones: \(server.store.peers().map(\.name))")
        if has("--commands") {
            // Type "select <bundleID|clipboard|front> [send]" to change the choice "on the Mac".
            Task.detached {
                while let line = readLine() {
                    let parts = line.split(separator: " ").map(String.init)
                    guard parts.first == "select", parts.count > 1 else { continue }
                    let send = parts.contains("send")
                    let target: TargetRef = parts[1] == "clipboard" ? .clipboard : parts[1] == "front" ? .frontApp
                        : .app(bundleID: parts[1], windowKey: nil, name: parts[1])
                    server.broadcastSelection(SendSelection(target: target, send: send))
                    stdout("SENT SELECTION \(target.displayName)\(send ? " + send" : "")")
                }
            }
        }
        while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }

    case "browse":
        let (client, _) = makeClient()
        client.start()
        try? await Task.sleep(nanoseconds: UInt64((Double(flag("--seconds") ?? "4") ?? 4) * 1e9))
        if client.discoveredMacs.isEmpty { stdout("No Macs found"); return 1 }
        return 0

    case "pair":
        guard args.count > 1, let invite = PairingInvite(string: args[1]) else { stdout("bad pairing URL"); return 2 }
        let (client, _) = makeClient()
        do {
            let t0 = Date()
            let peer = try await client.pair(invite: invite)
            stdout("PAIRED with \(peer.name) in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            return 0
        } catch {
            stdout("PAIR FAILED: \(error)")
            return 1
        }

    case "pair-code":
        let (client, _) = makeClient()
        client.start()
        var mac: DiscoveredMac?
        for _ in 0..<40 where mac == nil {
            mac = client.discoveredMacs.first { m in flag("--mac").map { m.name == $0 } ?? true }
            if mac == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
        }
        guard let mac else { stdout("No Mac found"); return 1 }
        do {
            let peer = try await client.pairWithCode(mac) { code in stdout("CODE ON PHONE: \(code) — approve it on the Mac") }
            stdout("PAIRED with \(peer.name)")
            return 0
        } catch {
            stdout("PAIR FAILED: \(error)")
            return 1
        }

    case "send":
        guard args.count > 1 else { stdout("usage: mpctl send <text>"); return 2 }
        let (client, _) = makeClient()
        client.start()
        let count = Int(flag("--count") ?? "1") ?? 1
        var failures = 0
        var d = Dictation(raw: args[1], sourceDevice: "mpctl")
        for i in 0..<count {
            if !has("--resend") || i == 0 { if i > 0 { d = Dictation(raw: "\(args[1]) #\(i + 1)", sourceDevice: "mpctl") } }
            let t0 = Date()
            do {
                let ack = try await client.send(d, delayed: has("--delayed"))
                stdout("ACK \(ack.outcome.rawValue) \(ack.detail ?? "") in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            } catch {
                failures += 1
                stdout("SEND FAILED: \(error)")
            }
        }
        client.stop()
        return failures == 0 ? 0 : 1

    case "targets", "select":
        // mpctl targets            — print the Mac's open apps
        // mpctl select <bundleID|clipboard|front> [--send]  — set the shared choice (sent on connect)
        let (client, _) = makeClient()
        var sel: SendSelection?
        if command == "select", args.count > 1 {
            switch args[1] {
            case "clipboard": sel = SendSelection(target: .clipboard)
            case "front": sel = SendSelection(target: .frontApp, send: has("--send"))
            default: sel = SendSelection(target: .app(bundleID: args[1], windowKey: flag("--window"), name: args[1]), send: has("--send"))
            }
            let chosen = sel
            client.selectionProvider = { chosen }
        }
        client.start()
        do { try await client.connect() } catch { stdout("CONNECT FAILED: \(error)"); return 1 }
        if command == "targets" { client.refreshTargets() }
        try? await Task.sleep(nanoseconds: UInt64((Double(flag("--seconds") ?? "1.5") ?? 1.5) * 1e9))
        client.stop()
        return 0

    case "unpair":
        let (client, _) = makeClient()
        client.start()
        guard let mac = client.activeMac else { stdout("not paired"); return 1 }
        await client.unpair(mac.id)
        stdout("unpaired")
        return 0

    case "cleanup-eval":
        return await CleanupEval.run(file: flag("--file"), level: flag("--level"), only: flag("--only"))

    default:
        stdout("unknown command \(command)")
        return 2
    }
}

let code = await run()
exit(code)
