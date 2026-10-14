import Foundation
import MacrophoneKit

// mpctl — the protocol proof. Two terminals (or two machines on a network under test):
//
//   mpctl serve --name "Test Mac"            # the Mac side: prints a pairing URL + accepts dictations
//   mpctl pair 'macrophone://pair?...'       # the phone side, by QR URL
//   mpctl pair-code [--mac <name>]           # the phone side, by confirmation code
//   mpctl send "hello world" [--count 5] [--resend]
//   mpctl serve --commands                    # …and type "select com.apple.MobileSMS send" to change the choice on the "Mac"
//   mpctl serve --land failed|copied|cancelled  # report that result for every dictation (default: what the target implies)
//   mpctl targets / mpctl select <bundleID|clipboard|front> [--send]
//   mpctl browse
//   mpctl watch [--target <bundleID|front>] [--window <key>] [--seconds 6] [--save DIR] [--action returnKey]
//   mpctl serve --watch-state permission|unavailable   # answer every watch with that state instead of the demo window
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
        let route = dictation.target.map { " → \($0.displayName)\(dictation.send == true ? " + send" : "")\(dictation.targetSpoken == true ? " (said)" : "")" } ?? ""
        stdout("RECEIVED #\(received)\(delayed ? " (delayed)" : "")\(route) [\(dictation.cleanupLevel.rawValue)]: \(dictation.text)")
        // Then, like the Mac after its countdown and paste: where it landed (--land <result> forces one).
        let forced = flag("--land").flatMap(LandingResult.init(rawValue:))
        let name = dictation.target?.displayName ?? "Clipboard"
        let result: LandingResult = forced ?? {
            switch dictation.target {
            case .app?, .frontApp?: return dictation.send == true && !delayed ? .sent : .pasted
            default: return .copied
            }
        }()
        let detail: String
        switch result {
        case .sent: detail = "Sent to \(name)"
        case .pasted: detail = "Pasted into \(name)"
        case .copied: detail = dictation.target.map { if case .clipboard = $0 { return "Copied to clipboard" } else { return "\(name) isn't open — copied to your Mac's clipboard instead" } } ?? "Copied to clipboard"
        case .cancelled: detail = "Cancelled on the Mac"
        case .failed: detail = "The message box in \(name) wasn't found"
        }
        let id = dictation.id, phone = peer.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            server.reportLanding(id, result: result, detail: detail, to: phone)
            stdout("LANDED \(result.rawValue): \(detail)")
        }
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

    // Watching: the drawn demo window, a frame each time it changes.
    var watches: [UUID: Task<Void, Never>] = [:]
    let demo = DemoWindow()

    func linkServer(_ server: LinkServer, watch target: TargetRef?, from peerID: UUID) {
        watches[peerID]?.cancel()
        watches[peerID] = nil
        guard let target else { stdout("WATCH stopped"); return }
        stdout("WATCH \(target.displayName)")
        let demo = self.demo
        let forced = flag("--watch-state")
        watches[peerID] = Task {
            if forced == "permission" { await server.send(.watchState(.needsPermission), to: peerID); return }
            if forced == "unavailable" {
                await server.send(.watchState(.unavailable("\(target.displayName)'s window is minimized", canReveal: true)), to: peerID)
                return
            }
            await server.send(.watchState(.live(appName: target.displayName)), to: peerID)
            var seq = 0, n = 0
            var last: Data?
            while !Task.isCancelled {
                n += 1
                if n % 2 == 0 { demo.tick() }
                if let jpeg = demo.jpeg(), jpeg != last {
                    last = jpeg
                    seq += 1
                    let frame = WatchFrame(seq: seq, jpeg: jpeg, width: demo.width, height: demo.height,
                                           appName: target.displayName, bundleID: target.bundleID, focus: demo.focus)
                    await server.send(.watchFrame(frame), to: peerID)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func linkServer(_ server: LinkServer, watchAction action: WatchAction, from peerID: UUID) {
        stdout("WATCH ACTION \(action.rawValue)")
        demo.apply(action)
    }

    func linkServer(_ server: LinkServer, watchClick point: CGPoint, from peerID: UUID) {
        stdout("WATCH CLICK \(String(format: "%.3f, %.3f", point.x, point.y))")
        demo.click(point)
    }
}

// MARK: phone

@MainActor
final class PhoneDelegate: LinkClientDelegate {
    func linkClient(_ client: LinkClient, stateChanged state: LinkClient.State) { stdout("STATE \(state)") }
    func linkClient(_ client: LinkClient, discovered macs: [DiscoveredMac]) {
        for m in macs { stdout("FOUND \(m.name) id=\(m.macID?.uuidString ?? "?")\(m.isPeerToPeer ? " (peer-to-peer)" : "")") }
    }
    func linkClient(_ client: LinkClient, unpairedBy macID: UUID) { stdout("UNPAIRED by Mac") }
    func linkClient(_ client: LinkClient, landed id: UUID, result: LandingResult, detail: String) {
        stdout("LANDED on Mac: \(result.rawValue) — \(detail)")
    }
    func linkClient(_ client: LinkClient, targets: [LiveTarget], macID: UUID) {
        stdout("TARGETS \(targets.map(\.title).joined(separator: " | "))")
    }
    func linkClient(_ client: LinkClient, selectionChanged selection: SendSelection, macID: UUID) {
        stdout("SELECTION from Mac: \(selection.target.displayName)\(selection.send ? " + send" : "")")
    }
    var frames = 0
    func linkClient(_ client: LinkClient, watchState: WatchState) { stdout("WATCH STATE \(watchState)") }
    func linkClient(_ client: LinkClient, watchFrame: WatchFrame) {
        frames += 1
        stdout("WATCH FRAME #\(watchFrame.seq) \(watchFrame.width)x\(watchFrame.height) \(watchFrame.jpeg.count / 1024) KB\(watchFrame.focus.map { " focus \($0)" } ?? "")")
        if let dir = flag("--save") {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("frame-\(watchFrame.seq).jpg")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? watchFrame.jpeg.write(to: url)
        }
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
                    let live = await MainActor.run { d.liveTargets(server) }
                    let name = live.first { $0.bundleID == parts[1] }?.title ?? parts[1]
                    let target: TargetRef = parts[1] == "clipboard" ? .clipboard : parts[1] == "front" ? .frontApp
                        : .app(bundleID: parts[1], windowKey: nil, name: name)
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
        // --target <bundleID|clipboard|front> [--send] [--window <key>]: route like the phone does.
        func routed(_ d: Dictation) -> Dictation {
            guard let t = flag("--target") else { return d }
            var d = d
            switch t {
            case "clipboard": d.target = .clipboard
            case "front": d.target = .frontApp
            default: d.target = .app(bundleID: t, windowKey: flag("--window"), name: t)
            }
            d.send = has("--send")
            return d
        }
        var d = routed(Dictation(raw: args[1], sourceDevice: "mpctl"))
        for i in 0..<count {
            if !has("--resend") || i == 0 { if i > 0 { d = routed(Dictation(raw: "\(args[1]) #\(i + 1)", sourceDevice: "mpctl")) } }
            let t0 = Date()
            do {
                let ack = try await client.send(d, delayed: has("--delayed"))
                stdout("ACK \(ack.outcome.rawValue) \(ack.detail ?? "") in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            } catch {
                failures += 1
                stdout("SEND FAILED: \(error)")
            }
        }
        // --landing: stay connected long enough to hear where it landed.
        if has("--landing") { try? await Task.sleep(nanoseconds: 3_000_000_000) }
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

    case "watch":
        let (client, d) = makeClient()
        client.start()
        do { try await client.connect() } catch { stdout("CONNECT FAILED: \(error)"); return 1 }
        let target: TargetRef
        switch flag("--target") ?? "front" {
        case "front": target = .frontApp
        case "clipboard": target = .clipboard
        case let bid: target = .app(bundleID: bid, windowKey: flag("--window"), name: bid)
        }
        client.watch(target)
        let seconds = Double(flag("--seconds") ?? "6") ?? 6
        if let a = flag("--action").flatMap(WatchAction.init(rawValue:)) {
            try? await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
            stdout("ACTION \(a.rawValue)")
            client.watchAction(a)
            try? await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
        } else {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        }
        client.watch(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        client.stop()
        stdout("FRAMES \(d.frames)")
        return d.frames > 0 ? 0 : 1

    case "unpair":
        let (client, _) = makeClient()
        client.start()
        guard let mac = client.activeMac else { stdout("not paired"); return 1 }
        await client.unpair(mac.id)
        stdout("unpaired")
        return 0

    case "clean":
        // mpctl clean "<text>" [--level light|medium|heavy|custom] [--instructions "<custom prompt>"]
        guard args.count > 1 else { stdout("usage: mpctl clean <text> [--level …] [--instructions …]"); return 2 }
        let level = flag("--level").flatMap(CleanupLevel.init(rawValue:)) ?? .medium
        CleanupPrompts.setCustomInstructions(flag("--instructions"))
        let r = await Cleaner.clean(args[1], level: level, dictionary: [], language: "en-US")
        stdout(r.cleaned ?? "(kept as spoken\(r.skipped.map { ": " + $0 } ?? ""))")
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
