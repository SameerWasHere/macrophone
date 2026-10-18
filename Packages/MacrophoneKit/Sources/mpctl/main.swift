import AppKit
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
//   mpctl apps / mpctl open <bundleID>        # the Mac's installed apps; open one there
//   mpctl watch [--target <bundleID|front>] [--window <key>] [--seconds 6] [--save DIR] [--action returnKey]
//              prints the connect time, when each picture came (after asking, after the last, after the action);
//              with --features video the frames come as HEVC, are decoded here (decode time printed, --save
//              writes them as PNG); --fit larger|largest|normal asks for readable text; --keyframe asks for
//              a keyframe halfway
//   --features attention,attention-cloud,video   what this "phone" says it understands (any phone-side command)
//   mpctl serve --watch-state permission|unavailable   # answer every watch with that state instead of the demo window
//   mpctl serve --remote [--port 47821]       # remote access on: a fixed port, connections from away, the addresses told to phones
//   --dial <host[:port]>                      # phone side: keep this typed address with the pairing (as the phone's Settings does)
//   --no-bonjour                              # phone side: never look with Bonjour — stands in for a network where it finds nothing
//   mpctl roam [--no-bonjour] [--dial …] [--bonjour-after 4] [--seconds 10] [--expect remote|local|home]
//              connects (away or at home), prints PATH changes, sends one dictation; --bonjour-after N turns
//              Bonjour on after N s so a remote link moves home; --expect fails the run if that never happens
//   mpctl serve --jpeg                        # pictures to every phone, even one that named video (a Mac from before)
//   mpctl serve --software                    # encode in software from the start (the hardware encoder is busy elsewhere)
//   mpctl watch --swipe 0.3 [--flick 1500]    # a swipe as the phone sends it: a gesture, then the coast after a flick
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
        // Alerts: a phone that understands them hears, after a while, that the codex window (one it
        // isn't watching) is asking — read off that window's picture like the Mac app does.
        if server.phones(with: Attention.feature).contains(peer.id), flag("--no-attention") == nil {
            let codex = LiveTarget(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "codex — ~/api", windowKey: "42")
            let demo = self.demo(for: codex.ref)
            demo.finish()
            Task {
                try? await Task.sleep(nanoseconds: UInt64((Double(flag("--attention-after") ?? "8") ?? 8) * 1e9))
                guard let image = demo.image(), let p = await PromptVision.read(image) else { stdout("ATTENTION none read"); return }
                let a = Attention(ref: codex.ref, appName: "Terminal", title: codex.title, question: p.question, promptID: p.id)
                await server.send(.attention(a), to: peer.id)
                stdout("ATTENTION sent: \(codex.title) — \(p.question ?? "-")")
            }
        }
        stdout("CONNECTED \(peer.name) (\(os), v\(appVersion))\(server.isRemote(peer.id) ? " from away" : "")")
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
        if case .ready = state, server.remoteConfig != nil {
            // Like the Mac app: the list it would tell a phone, sent to any already connected.
            Task { @MainActor in
                let list = await self.refreshRemoteAddresses(server)
                stdout("REMOTE on port \(server.remoteConfig?.port ?? 0): " + (list.isEmpty ? "no addresses" : list.map(\.display).joined(separator: ", ")))
            }
        }
    }
    var remoteList: [RemoteAddress] = []
    func refreshRemoteAddresses(_ server: LinkServer) async -> [RemoteAddress] {
        guard let config = server.remoteConfig else { remoteList = []; return [] }
        let own = NetworkAddresses.current()
        var name: String?
        if let ts = own.first(where: \.isTailscale) { name = await NetworkAddresses.tailscaleName(for: ts.host) }
        remoteList = NetworkAddresses.remoteAddresses(port: config.port, tailscaleName: name)
        server.broadcastRemoteAddresses(remoteList)
        return remoteList
    }
    func remoteAddresses(_ server: LinkServer) -> [RemoteAddress] { remoteList }
    func linkServer(_ server: LinkServer, selectionChanged selection: SendSelection, from peer: PairedPeer) {
        stdout("SELECTION \(selection.target.displayName)\(selection.send ? " + send" : "") from \(peer.name)")
    }
    func linkServerRefreshTargets(_ server: LinkServer) {
        stdout("REFRESH requested")
        server.broadcastTargets(liveTargets(server))
    }
    func liveTargets(_ server: LinkServer) -> [LiveTarget] {
        [LiveTarget(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", icon: demoIcon("com.anthropic.claudefordesktop", 128), lastActive: Date()),
         LiveTarget(bundleID: "com.apple.MobileSMS", appName: "Messages", icon: demoIcon("com.apple.MobileSMS", 128)),
         LiveTarget(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "claude — ~/app", windowKey: "41", icon: demoIcon("com.apple.Terminal", 128)),
         LiveTarget(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "codex — ~/api", windowKey: "42", icon: demoIcon("com.apple.Terminal", 128)),
         LiveTarget(bundleID: "com.apple.Notes", appName: "Notes", icon: demoIcon("com.apple.Notes", 128))]
    }

    // Watching: a drawn demo window per place, a frame each time it changes, with the question
    // it's asking read off the picture by the same on-device reader the Mac app uses.
    var watches: [UUID: Task<Void, Never>] = [:]
    var demos: [String: DemoWindow] = [:]
    var watched: [UUID: DemoWindow] = [:]
    var prompts: [UUID: WatchPrompt] = [:]
    /// A phone that named "video" gets HEVC: its encoder, and whether it asked for a keyframe.
    var encoders: [UUID: VideoEncoder] = [:]
    var keyframeWanted: Set<UUID> = []
    let lock = NSLock()

    func demo(for target: TargetRef) -> DemoWindow {
        lock.sync {
            let key: String
            if case let .app(bid, wk, _) = target { key = bid + "#" + (wk ?? "") } else { key = "front" }
            if let d = demos[key] { return d }
            let d = DemoWindow()
            let name = target.displayName.components(separatedBy: " — ")
            d.app = name.first ?? "Claude"
            if name.count > 1 { d.title = name[1] } else { d.title = d.app }
            if d.title.hasPrefix("codex") { d.app = "Codex" }
            demos[key] = d
            return d
        }
    }

    func linkServer(_ server: LinkServer, watch target: TargetRef?, from peerID: UUID) {
        watches[peerID]?.cancel()
        watches[peerID] = nil
        guard let target else { stdout("WATCH stopped"); return }
        stdout("WATCH \(target.displayName)")
        let demo = self.demo(for: target)
        lock.sync { watched[peerID] = demo }
        // The app's own name, as the Mac sends it ("Terminal", not "Terminal — claude ~/app").
        let appName = target.displayName.components(separatedBy: " — ").first ?? target.displayName
        let forced = flag("--watch-state")
        watches[peerID] = Task {
            if forced == "permission" { await server.send(.watchState(.needsPermission), to: peerID); return }
            if forced == "unavailable" {
                await server.send(.watchState(.unavailable("\(target.displayName)'s window is minimized", canReveal: true)), to: peerID)
                return
            }
            await server.send(.watchState(.live(appName: appName)), to: peerID)
            // Video to a phone that named it (unless --jpeg: a Mac from before video).
            let video = server.phones(with: WatchVideo.feature).contains(peerID) && !has("--jpeg")
            self.lock.sync { self.encoders[peerID] = nil; self.keyframeWanted.remove(peerID) }
            var n = 0
            var drawn = -1, read = -1
            var prompt: WatchPrompt?
            /// One count for pictures and frames, given out as each goes; the task sending frames.
            let seqs = Counter()
            var sender: Task<Void, Never>?
            defer { sender?.cancel() }
            while !Task.isCancelled {
                n += 1
                // A line of the answer every second; the window is looked at thirty times a second
                // and a frame goes whenever it changed (a swipe moves it at display rate).
                if n % 30 == 0 { demo.tick() }
                let keyframe = self.lock.sync { self.keyframeWanted.remove(peerID) != nil }
                if demo.version != drawn || keyframe, let jpeg = demo.jpeg() {
                    drawn = demo.version
                    let image = demo.image()
                    // The question is read again only when the words changed (a tenth of a second
                    // a read; a swipe at display rate would starve the frames).
                    if let image, demo.wordsVersion != read {
                        read = demo.wordsVersion
                        prompt = await PromptVision.read(image)
                        self.lock.sync { self.prompts[peerID] = prompt }
                        if let prompt { stdout("WATCH PROMPT \(prompt.question ?? "-") → \(prompt.choices.map(\.label).joined(separator: " | ")) (on \(prompt.highlighted.map(String.init) ?? "-"))") }
                    }
                    if video, let image, let pixels = VideoEncoder.pixelBuffer(from: image) {
                        // The encoder is handed the frame and never waited on, as on the Mac: its
                        // bytes come back in order and go out in order (`sender`).
                        var encoder = self.lock.sync { self.encoders[peerID] }
                        if encoder == nil || encoder!.width != image.width & ~1 || encoder!.height != image.height & ~1 {
                            sender?.cancel()
                            encoder = try? VideoEncoder(width: image.width, height: image.height, software: has("--software"))
                            self.lock.sync { self.encoders[peerID] = encoder }
                            let (stream, continuation) = AsyncStream.makeStream(of: (VideoEncoder.Encoded, TimeInterval).self, bufferingPolicy: .unbounded)
                            encoder?.onEncoded = { e, took in continuation.yield((e, took)) }
                            let (w, h) = (encoder?.width ?? 0, encoder?.height ?? 0)
                            sender = Task {
                                for await (e, took) in stream {
                                    guard !Task.isCancelled else { return }
                                    let frame = WatchVideoFrame(seq: seqs.next(), data: e.data, parameterSets: e.parameterSets, keyframe: e.keyframe,
                                                                width: w, height: h, appName: appName, bundleID: target.bundleID,
                                                                focus: demo.focus, prompt: self.lock.sync { self.prompts[peerID] })
                                    stdout("WATCH VIDEO #\(frame.seq) \(e.data.count / 1024) KB\(e.keyframe ? " key" : "") encoded in \(Int(took * 1000)) ms")
                                    await server.send(.watchVideo(frame), to: peerID)
                                }
                            }
                        }
                        guard let encoder else { stdout("WATCH VIDEO: no encoder"); continue }
                        if keyframe { encoder.requestKeyframe() }
                        if case .dropped = encoder.submit(pixels) { stdout("WATCH VIDEO: the encoder gave up") }
                    } else {
                        let frame = WatchFrame(seq: seqs.next(), jpeg: jpeg, width: demo.width, height: demo.height,
                                               appName: appName, bundleID: target.bundleID, focus: demo.focus, prompt: prompt)
                        await server.send(.watchFrame(frame), to: peerID)
                    }
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    func linkServer(_ server: LinkServer, watchKeyframeFrom peerID: UUID) {
        stdout("WATCH KEYFRAME asked")
        lock.sync { _ = keyframeWanted.insert(peerID) }
    }

    func linkServer(_ server: LinkServer, watchFit fit: WatchFit, from peerID: UUID) {
        stdout("WATCH FIT \(fit.rawValue)")
        lock.sync { watched[peerID] }?.fit(fit)
    }

    func linkServer(_ server: LinkServer, watchAction action: WatchAction, from peerID: UUID) {
        stdout("WATCH ACTION \(action.rawValue)")
        lock.sync { watched[peerID] }?.apply(action)
    }

    func linkServer(_ server: LinkServer, watchChoose promptID: String, index: Int, from peerID: UUID) {
        let (demo, prompt) = lock.sync { (watched[peerID], prompts[peerID]) }
        guard let demo, let prompt, prompt.id == promptID, let keys = prompt.keys(for: index) else {
            stdout("WATCH CHOOSE \(index) skipped: the window moved on")
            return
        }
        stdout("WATCH CHOOSE \(index) → \(keys)")
        for k in keys {
            switch k {
            case .up: demo.apply(.arrowUp)
            case .down: demo.apply(.arrowDown)
            case .returnKey: demo.apply(.returnKey)
            case .character: break
            }
        }
    }

    func installedApps(_ server: LinkServer) async -> [MacApp] {
        stdout("LIST APPS")
        // Real bundle ids, with this Mac's icons where the app is installed (screenshots look real).
        let apps: [(String, String)] = [("Calendar", "com.apple.iCal"), ("ChatGPT", "com.openai.chat"), ("Claude", "com.anthropic.claudefordesktop"),
                                        ("Cursor", "com.todesktop.230313mzl4w4u92"), ("Ghostty", "com.mitchellh.ghostty"), ("Mail", "com.apple.mail"),
                                        ("Messages", "com.apple.MobileSMS"), ("Notes", "com.apple.Notes"), ("Reminders", "com.apple.reminders"),
                                        ("Safari", "com.apple.Safari"), ("Slack", "com.tinyspeck.slackmacgap"), ("Terminal", "com.apple.Terminal"),
                                        ("TextEdit", "com.apple.TextEdit"), ("Xcode", "com.apple.dt.Xcode")]
        // Only the ones installed here, like the real Mac app.
        return apps.compactMap { app in
            demoIcon(app.1, 64).map { MacApp(bundleID: app.1, name: app.0, icon: $0, running: ["Claude", "Messages", "Terminal", "Notes"].contains(app.0)) }
        }
    }

    func linkServer(_ server: LinkServer, openApp bundleID: String, from peerID: UUID) async -> (Bool, String) {
        stdout("OPEN APP \(bundleID)")
        let name = await installedApps(server).first { $0.bundleID == bundleID }?.name ?? bundleID
        return (true, "\(name) is open on your Mac")
    }

    func linkServer(_ server: LinkServer, watchScroll point: CGPoint, delta: CGVector, from peerID: UUID) {
        scrollSteps += 1
        if has("--verbose") { stdout("WATCH SCROLL at \(String(format: "%.2f, %.2f", point.x, point.y)) by \(String(format: "%.3f", delta.dy))") }
        lock.sync { watched[peerID] }?.scrollBy(delta.dy)
    }

    /// Steps since the last phase, for the line each phase prints (a swipe at display rate is
    /// too many lines to read one by one).
    var scrollSteps = 0
    func linkServer(_ server: LinkServer, watchScrollPhase phase: WatchScrollPhase, at point: CGPoint, from peerID: UUID) {
        stdout("WATCH SCROLL \(phase.rawValue) at \(String(format: "%.2f, %.2f", point.x, point.y)) after \(scrollSteps) steps")
        scrollSteps = 0
    }

    func linkServer(_ server: LinkServer, watchClick point: CGPoint, from peerID: UUID) {
        stdout("WATCH CLICK \(String(format: "%.3f, %.3f", point.x, point.y))")
        lock.sync { watched[peerID] }?.click(point)
    }
}

/// A count given out in order from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// An installed app's icon as PNG (nil when it isn't installed here).
func demoIcon(_ bundleID: String, _ px: Int) -> Data? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    let image = NSWorkspace.shared.icon(forFile: url.path)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
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
    var appsHeard = 0
    func linkClient(_ client: LinkClient, installedApps: [MacApp]) {
        appsHeard = installedApps.count
        let kb = installedApps.compactMap(\.icon).reduce(0) { $0 + $1.count } / 1024
        stdout("APPS \(installedApps.count) (\(kb) KB of icons): " + installedApps.prefix(12).map { $0.name + ($0.running ? "*" : "") }.joined(separator: ", "))
    }
    func linkClient(_ client: LinkClient, appOpened bundleID: String, ok: Bool, detail: String) {
        stdout("OPENED \(ok ? "ok" : "failed"): \(detail)")
    }
    func linkClient(_ client: LinkClient, remoteAddresses: [RemoteAddress], macID: UUID) {
        stdout("REMOTE ADDRESSES \(remoteAddresses.count): " + remoteAddresses.map { "\($0.display) (\($0.source.rawValue))" }.joined(separator: ", "))
    }
    var paths: [String] = []
    func linkClient(_ client: LinkClient, pathChanged remote: Bool) {
        paths.append(remote ? "remote" : "local")
        stdout("PATH \(remote ? "remote (away from home)" : "local (back home)")")
    }
    var frames = 0
    /// Bytes of pictures or frames received (bandwidth, printed at the end).
    var bytes = 0
    /// When each picture or frame came, for the peak frames-a-second at the end.
    var frameTimes: [Date] = []
    var peakPerSecond: Int {
        var best = 0
        for (i, t) in frameTimes.enumerated() {
            let n = frameTimes[i...].prefix { $0.timeIntervalSince(t) < 1 }.count
            best = max(best, n)
        }
        return best
    }
    /// Timing (numbers only): when the watch was asked for, the last picture, and the last action.
    var watchAsked: Date?
    var lastFrame: Date?
    var lastAction: Date?
    func linkClient(_ client: LinkClient, watchState: WatchState) { stdout("WATCH STATE \(watchState)") }

    private func timing() -> String {
        let now = Date()
        var timing = ""
        if let a = lastAction { timing += " \(Int(now.timeIntervalSince(a) * 1000)) ms after the action"; lastAction = nil }
        else if let l = lastFrame { timing += " +\(Int(now.timeIntervalSince(l) * 1000)) ms" }
        else if let w = watchAsked { timing += " \(Int(now.timeIntervalSince(w) * 1000)) ms after asking" }
        lastFrame = now
        return timing
    }

    func linkClient(_ client: LinkClient, watchFrame: WatchFrame) {
        frames += 1
        bytes += watchFrame.jpeg.count
        frameTimes.append(Date())
        stdout("WATCH FRAME #\(watchFrame.seq) \(watchFrame.width)x\(watchFrame.height) \(watchFrame.jpeg.count / 1024) KB\(watchFrame.focus.map { " focus \($0)" } ?? "")\(timing())")
        if let dir = flag("--save") {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("frame-\(watchFrame.seq).jpg")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? watchFrame.jpeg.write(to: url)
        }
    }

    /// Video, decoded here like the phone does (the same decoder); a frame that can't be decoded
    /// asks for a keyframe and the ones until it comes are dropped.
    let decoder = VideoDecoder()
    var newestVideo = 0
    var waitingForKeyframe = true
    func linkClient(_ client: LinkClient, watchVideo f: WatchVideoFrame) {
        frames += 1
        bytes += f.data.count
        if !f.isWordsOnly { frameTimes.append(Date()) }
        let t = timing()
        if f.isWordsOnly {
            stdout("WATCH VIDEO #\(f.seq) words only\(f.prompt.map { " prompt \($0.choices.count) answers" } ?? "")\(t)")
            return
        }
        guard WatchVideoFrame.canDecode(seq: f.seq, keyframe: f.keyframe, newest: newestVideo, waitingForKeyframe: waitingForKeyframe) else {
            stdout("WATCH VIDEO #\(f.seq) dropped (waiting for a keyframe)")
            if !waitingForKeyframe { waitingForKeyframe = true; client.watchKeyframe() }
            return
        }
        let t0 = Date()
        do {
            let pixels = try decoder.decode(f)
            newestVideo = f.seq
            waitingForKeyframe = false
            stdout("WATCH VIDEO #\(f.seq) \(f.width)x\(f.height) \(f.data.count / 1024) KB\(f.keyframe ? " key" : "") decoded in \(Int(Date().timeIntervalSince(t0) * 1000)) ms\(f.focus.map { " focus \($0)" } ?? "")\(t)")
            if let dir = flag("--save"), let image = VideoDecoder.image(pixels) {
                let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("frame-\(f.seq).png")
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        } catch {
            stdout("WATCH VIDEO #\(f.seq) failed to decode (\(error)) — asking for a keyframe")
            waitingForKeyframe = true
            client.watchKeyframe()
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
    // --features attention,attention-cloud: what this "phone" says it understands in its hello.
    if let f = flag("--features") { client.features = f.split(separator: ",").map(String.init) }
    // A phone that keeps the Mac's remote addresses says so; --no-bonjour stands in for a network
    // where Bonjour finds nothing; --dial keeps a typed address with the pairing, as Settings does.
    if !client.features.contains(RemoteAccess.feature) { client.features.append(RemoteAccess.feature) }
    if has("--no-bonjour") { client.browsesBonjour = false }
    if let a = flag("--away-after").flatMap(Double.init) { client.awayAfter = a }
    if let text = flag("--dial") {
        guard let addr = RemoteAddressRule.parse(text) else { stdout("bad --dial address: \(text)"); exit(2) }
        guard let mac = client.activeMac else { stdout("--dial needs a paired Mac (pair first)"); exit(2) }
        client.setTypedAddress(addr, for: mac.id)
        stdout("DIAL \(addr.display) kept for \(mac.name)")
    }
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
        if has("--remote") {
            let port = flag("--port").flatMap(UInt16.init) ?? RemoteAddressRule.defaultPort
            server.setRemote(RemoteConfig(port: port))
        }
        // What this "Mac" can do beyond the first version (the welcome names it). --jpeg: a Mac from before.
        server.macFeatures = has("--jpeg") ? [] : [WatchVideo.feature, WatchVideo.fitFeature, WatchScroll.feature, WatchRightClick.feature, WatchKey.feature, WatchShape.feature, WatchWindowCommand.feature]
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

    case "demo-window":
        // mpctl demo-window <out.png>: the drawn Claude Code window, finished, as a PNG.
        guard args.count > 1 else { stdout("usage: mpctl demo-window <out.png>"); return 2 }
        let demo = DemoWindow()
        demo.finish()
        guard let data = demo.png() else { return 1 }
        try? data.write(to: URL(fileURLWithPath: args[1]))
        stdout("wrote \(args[1])")
        return 0

    case "apps", "open":
        let (client, d) = makeClient()
        client.start()
        do { try await client.connect() } catch { stdout("CONNECT FAILED: \(error)"); return 1 }
        if command == "apps" { client.listApps() } else if args.count > 1 { client.openApp(args[1]) }
        try? await Task.sleep(nanoseconds: UInt64((Double(flag("--seconds") ?? "4") ?? 4) * 1e9))
        client.stop()
        return command == "apps" ? (d.appsHeard > 0 ? 0 : 1) : 0

    case "watch":
        let (client, d) = makeClient()
        let t0 = Date()
        client.start()
        do { try await client.connect() } catch { stdout("CONNECT FAILED: \(error)"); return 1 }
        stdout("CONNECTED in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        let target: TargetRef
        switch flag("--target") ?? "front" {
        case "front": target = .frontApp
        case "clipboard": target = .clipboard
        case let bid: target = .app(bundleID: bid, windowKey: flag("--window"), name: bid)
        }
        d.watchAsked = Date()
        client.watch(target)
        if client.macFeatures.contains(WatchVideo.feature) { client.watchKeyframe() }
        let seconds = Double(flag("--seconds") ?? "6") ?? 6
        if let fit = flag("--fit").flatMap(WatchFit.init(rawValue:)) {
            try? await Task.sleep(nanoseconds: UInt64(seconds / 3 * 1e9))
            stdout("FIT \(fit.rawValue) sent: \(client.watchFit(fit))")
            d.lastAction = Date()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 2 / 3 * 1e9))
        } else if has("--keyframe") {
            try? await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
            stdout("KEYFRAME asked: \(client.watchKeyframe())")
            d.lastAction = Date()
            try? await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
        } else if let dy = flag("--swipe").flatMap(Double.init) {
            // A swipe in the middle of the window as the phone sends it: the finger lands, ten
            // steps a display frame apart (dy: content dragged down, as a fraction of the window),
            // lifts, then the coast after a flick (--flick, points a second; 0 = none) — to a Mac
            // that takes the phases; to one from before, the steps alone.
            try? await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
            let at = CGPoint(x: 0.5, y: 0.5)
            let phased = client.macFeatures.contains(WatchScroll.feature)
            stdout("SWIPE \(dy)\(phased ? " as a gesture" : " as bare steps")")
            d.lastAction = Date()
            if phased { client.watchScrollPhase(.began, at: at) }
            for _ in 0..<10 { client.watchScroll(at: at, by: CGVector(dx: 0, dy: dy / 10)); try? await Task.sleep(nanoseconds: 16_000_000) }
            if phased {
                client.watchScrollPhase(.ended, at: at)
                // A picture about 800 points tall, as the phone shows it.
                if var m = ScrollMomentum(velocity: CGVector(dx: 0, dy: (Double(flag("--flick") ?? "1500") ?? 1500) * (dy < 0 ? -1 : 1))) {
                    client.watchScrollPhase(.momentumBegan, at: at)
                    var steps = 0
                    while let step = m.step(dt: 1 / ScrollMomentum.tickRate) {
                        client.watchScroll(at: at, by: CGVector(dx: 0, dy: step.dy / 800))
                        steps += 1
                        try? await Task.sleep(nanoseconds: 16_000_000)
                    }
                    client.watchScrollPhase(.momentumEnded, at: at)
                    stdout("COAST \(steps) steps")
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
        } else if let a = flag("--action").flatMap(WatchAction.init(rawValue:)) {
            try? await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
            stdout("ACTION \(a.rawValue)")
            d.lastAction = Date()
            client.watchAction(a)
            try? await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
        } else {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        }
        client.watch(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        client.stop()
        stdout("FRAMES \(d.frames) · \(d.bytes / 1024) KB in \(Int(seconds)) s · peak \(d.peakPerSecond) a second")
        return d.frames > 0 ? 0 : 1

    case "roam":
        // The away-and-back proof. With --no-bonjour the phone can only reach the Mac by the
        // addresses it keeps (--dial, or what the Mac told it earlier); --bonjour-after N then lets
        // Bonjour look again, and a remote link should move to the local path by itself.
        let (client, d) = makeClient()
        let t0 = Date()
        client.start()
        do { try await client.connect() } catch { stdout("CONNECT FAILED: \(error)"); return 1 }
        stdout("CONNECTED \(client.isRemote ? "remote (away from home)" : "local (at home)") in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        let seconds = Double(flag("--seconds") ?? "8") ?? 8
        let deadline = Date().addingTimeInterval(seconds)
        if let after = flag("--bonjour-after").flatMap(Double.init) {
            try? await Task.sleep(nanoseconds: UInt64(after * 1e9))
            stdout("BONJOUR on")
            client.setBrowsesBonjour(true)
        }
        // The link stays usable through it all: one dictation, whichever path it's on.
        while Date() < deadline, !(flag("--expect") == "home" && d.paths.contains("local")) {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        do {
            let ack = try await client.send(Dictation(raw: "roam check", sourceDevice: "mpctl"), delayed: false)
            stdout("ACK \(ack.outcome.rawValue) \(client.isRemote ? "from away" : "at home")")
        } catch { stdout("SEND FAILED: \(error)") }
        stdout("PATHS \(d.paths.isEmpty ? "none" : d.paths.joined(separator: " → ")) · now \(client.isRemote ? "remote" : "local")")
        client.stop()
        switch flag("--expect") {
        case "remote": return d.paths.first == "remote" ? 0 : 1
        case "local": return !client.remoteAddresses.isEmpty || d.paths.isEmpty ? (d.paths.contains("remote") ? 1 : 0) : 0
        case "home": return d.paths.first == "remote" && d.paths.last == "local" ? 0 : 1
        default: return 0
        }

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
