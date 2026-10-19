import Foundation
import MacrophoneKit
import Network

// The lossy-link proof (Oct 19 2026): `mpctl relay` stands between the phone and the Mac's away
// door and behaves like a cellular link that loses packets; `mpctl probe` is the phone, watching a
// busy window while it times a ping's round trip the whole while.
//
// Why a model and not real packet loss: dropping real TCP segments needs the firewall's packet
// shaper (pfctl / dnctl, root) — which this proof must never touch. The relay keeps the two
// things a lost segment costs over TCP: that segment arrives one round trip late (its resend after
// the duplicate acks), and everything behind it on the same connection waits for it (TCP hands
// bytes over in order). That's exactly head-of-line blocking — the thing the video lane is about —
// and it treats the old single connection and the lane's two connections by the same rule.

enum LossyRelay {
    static func run() async -> Int32 {
        guard let listen = flag("--listen").flatMap(UInt16.init), let to = flag("--to").flatMap({ RemoteAddressRule.parse($0) }) else {
            stdout("usage: mpctl relay --listen <port> --to <host:port> [--loss 0.02] [--rtt 80] [--seed 1]")
            return 2
        }
        let model = LinkModel(loss: Double(flag("--loss") ?? "0") ?? 0, rtt: (Double(flag("--rtt") ?? "80") ?? 80) / 1000,
                              seed: UInt64(flag("--seed") ?? "1") ?? 1)
        let queue = DispatchQueue(label: "mpctl.relay")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        guard let port = NWEndpoint.Port(rawValue: listen), let l = try? NWListener(using: NWParameters(tls: nil, tcp: tcp), on: port) else {
            stdout("relay couldn't listen on \(listen)")
            return 1
        }
        var pairs: [RelayPair] = []
        l.newConnectionHandler = { inbound in
            let outbound = NWConnection(to: to.endpoint, using: NWParameters(tls: nil, tcp: tcp))
            let pair = RelayPair(a: inbound, b: outbound, model: model, queue: queue)
            pairs.append(pair)
            pair.start()
            stdout("RELAY connection \(pairs.count)")
        }
        l.stateUpdateHandler = { s in if case .ready = s { stdout("RELAY on \(listen) → \(to.display) · loss \(model.loss * 100)% · round trip \(Int(model.rtt * 1000)) ms") } }
        l.start(queue: queue)
        while true {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let (s, lost) = queue.sync { (model.segments, model.lost) }
            if has("--verbose") { stdout("RELAY \(s) segments, \(lost) lost") }
        }
    }
}

/// The link both directions share: half the round trip each way, and a lost segment late by one
/// round trip (a seeded generator, so a run can be repeated).
final class LinkModel: @unchecked Sendable {
    let loss: Double
    let rtt: TimeInterval
    private var rng: UInt64
    var segments = 0
    var lost = 0

    init(loss: Double, rtt: TimeInterval, seed: UInt64) {
        self.loss = loss
        self.rtt = rtt
        self.rng = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    /// How late this segment arrives past its one-way trip (0, or a round trip if it's lost).
    func extraDelay() -> TimeInterval {
        segments += 1
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        guard Double(rng % 1_000_000) / 1_000_000 < loss else { return 0 }
        lost += 1
        return rtt
    }
}

/// One relayed connection: two pumps, each holding its segments to their arrival time, in order.
final class RelayPair: @unchecked Sendable {
    static let segment = 1448
    let a: NWConnection, b: NWConnection
    let model: LinkModel
    let queue: DispatchQueue

    init(a: NWConnection, b: NWConnection, model: LinkModel, queue: DispatchQueue) {
        self.a = a; self.b = b; self.model = model; self.queue = queue
    }

    func start() {
        a.start(queue: queue)
        b.start(queue: queue)
        let up = Pump(from: a, to: b, model: model, queue: queue)
        let down = Pump(from: b, to: a, model: model, queue: queue)
        up.other = down; down.other = up
        up.read(); down.read()
        pumps = [up, down]
    }
    private var pumps: [Pump] = []

    final class Pump: @unchecked Sendable {
        let from: NWConnection, to: NWConnection
        let model: LinkModel
        let queue: DispatchQueue
        weak var other: Pump?
        /// Segments waiting for their arrival time, oldest first; each no earlier than the one before.
        private var waiting: [(due: DispatchTime, data: Data)] = []
        private var lastDue = DispatchTime.now()
        /// One timer, set to the oldest segment's arrival with no slack (a plain asyncAfter may
        /// fire milliseconds late, which would show up as link delay).
        private lazy var timer: DispatchSourceTimer = {
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.setEventHandler { [weak self] in self?.deliver() }
            t.schedule(deadline: .distantFuture, leeway: .nanoseconds(0))
            t.activate()
            return t
        }()

        init(from: NWConnection, to: NWConnection, model: LinkModel, queue: DispatchQueue) {
            self.from = from; self.to = to; self.model = model; self.queue = queue
        }

        func read() {
            from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data, !data.isEmpty { self.carry(data) }
                if done || error != nil {
                    self.queue.asyncAfter(deadline: self.lastDue + .milliseconds(5)) { self.from.cancel(); self.to.cancel() }
                    return
                }
                self.read()
            }
        }

        private func carry(_ data: Data) {
            var i = data.startIndex
            while i < data.endIndex {
                let j = min(i + RelayPair.segment, data.endIndex)
                let arrive = DispatchTime.now() + model.rtt / 2 + model.extraDelay()
                // In order: nothing overtakes a segment still on its way (TCP's head-of-line wait).
                let due = max(arrive, lastDue)
                lastDue = due
                waiting.append((due, data.subdata(in: i..<j)))
                if waiting.count == 1 { timer.schedule(deadline: due, leeway: .nanoseconds(0)) }
                i = j
            }
        }

        private func deliver() {
            let now = DispatchTime.now()
            var out = Data()
            while let first = waiting.first, first.due <= now {
                out.append(first.data)
                waiting.removeFirst()
            }
            if !out.isEmpty { to.send(content: out, completion: .idempotent) }
            timer.schedule(deadline: waiting.first?.due ?? .distantFuture, leeway: .nanoseconds(0))
        }
    }
}

enum Probe {
    /// Connects (away, through whatever `--dial` names), watches the busy window, and times a
    /// ping's round trip every `--every` seconds for `--seconds`.
    @MainActor
    static func run() async -> Int32 {
        let (client, d) = makeClient()
        quietFrames = true
        let t0 = Date()
        client.start()
        do { try await client.connect() } catch { stdout("CONNECT FAILED: \(error)"); return 1 }
        stdout("CONNECTED \(client.isRemote ? "remote" : "local") in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        client.watch(.app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude"))
        if client.macFeatures.contains(WatchVideo.feature) { client.watchKeyframe() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        stdout("VIDEO LANE \(client.hasVideoLane ? "yes" : "no")")
        let seconds = Double(flag("--seconds") ?? "20") ?? 20
        let every = Double(flag("--every") ?? "0.1") ?? 0.1
        let framesBefore = d.frames, bytesBefore = d.bytes
        var times: [Double] = []
        var missed = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let started = Date()
            if let rtt = await client.roundTrip(timeout: 3) { times.append(rtt * 1000) } else { missed += 1 }
            let left = every - Date().timeIntervalSince(started)
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1e9)) }
        }
        let frames = d.frames - framesBefore, kb = (d.bytes - bytesBefore) / 1024
        let lane = client.hasVideoLane
        client.watch(nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        client.stop()
        times.sort()
        func pct(_ p: Double) -> Int { times.isEmpty ? -1 : Int(times[min(times.count - 1, Int(Double(times.count) * p))].rounded()) }
        // --slow N: the share of round trips that took longer than N ms (a tap that felt late).
        let slow = Double(flag("--slow") ?? "120") ?? 120
        let late = times.isEmpty ? 0 : Double(times.filter { $0 > slow }.count) / Double(times.count) * 100
        let mean = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
        stdout("PROBE \(times.count) round trips (\(missed) unanswered) · lane \(lane ? "yes" : "no") · "
               + "mean \(Int(mean.rounded())) ms · over \(Int(slow)) ms \(String(format: "%.1f", late))% · median \(pct(0.5)) ms · p95 \(pct(0.95)) ms · p99 \(pct(0.99)) ms · max \(Int(times.last ?? -1)) ms · "
               + "video \(frames) frames, \(kb) KB (\(String(format: "%.1f", Double(frames) / seconds)) a second)")
        return times.isEmpty ? 1 : 0
    }
}

/// The probe's video comes thirty a second: don't print a line for each.
nonisolated(unsafe) var quietFrames = false

extension ServeDelegate: LinkServerPermissionsDelegate {
    /// `--permissions accessibility=off,screen=off`: what this "Mac" says it's allowed to do.
    func macPermissions(_ server: LinkServer) -> MacPermissions? {
        let spec = flag("--permissions") ?? ""
        return MacPermissions(accessibility: !spec.contains("accessibility=off"), screenRecording: !spec.contains("screen=off"))
    }

    func linkServerShowPermissions(_ server: LinkServer, from peerID: UUID) {
        stdout("SHOW PERMISSIONS asked by the phone")
    }
}

extension PhoneDelegate: LinkClientPermissionsDelegate {
    func linkClient(_ client: LinkClient, macPermissions: MacPermissions) {
        stdout("MAC PERMISSIONS accessibility \(macPermissions.accessibility ? "on" : "off") · screen recording \(macPermissions.screenRecording ? "on" : "off")"
               + (macPermissions.missingLine.map { " — \($0)" } ?? ""))
        if has("--show-permissions") { stdout("SHOW PERMISSIONS sent: \(client.showPermissionsOnMac())") }
    }
}
