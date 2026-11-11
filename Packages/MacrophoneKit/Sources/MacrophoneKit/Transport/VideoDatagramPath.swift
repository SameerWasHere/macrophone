import Foundation
import Network

// The network side of video datagrams (VideoDatagrams.swift has the rules and the wire).
//
// Set-up: the phone, connected from away to a Mac whose welcome named `VideoDatagrams.feature`,
// sends a hello datagram to the away door's port (UDP — the same number as its TCP port) every
// 150 ms for at most 1.2 s. The hello names the phone and is sealed under the session's datagram
// key (derived from the pair key and that session's nonces), so only the phone of that open session
// can make one. The Mac answers `ready`, takes the address the hello came from as the path's, and
// from then on sends the window's video there. Nothing answered in 1.2 s (a firewall that drops
// UDP): the phone stops; the video stays on the TCP lane, as before.
//
// Staying up: the phone reports every 100 ms (400 ms with nothing coming); the Mac answers each.
// No report for 1.5 s, or reports saying nothing it sent arrived for 1.5 s: the Mac gives the path
// up and the video goes back to the lane (then the session). The phone gives up after 3 s of
// silence. Neither comes back for that session.

/// What a session holds for its datagram path (either end).
protocol VideoDatagramLink: AnyObject, Sendable {
    /// Sends a message on the path; false when the path is gone (the caller uses the lane).
    func send(_ message: Message) async -> Bool
    func close()
    var stats: VideoDatagramStats { get }
}

/// Counts for the log and the proof (`mpctl probe`): numbers only.
public struct VideoDatagramStats: Sendable, Equatable {
    public var datagramsIn = 0
    public var datagramsOut = 0
    public var bytesIn = 0
    public var bytesOut = 0
    /// Message bytes handed on (the phone) or handed in (the Mac).
    public var payload = 0
    public var framesDelivered = 0
    public var framesSkipped = 0
    public var recoveredByParity = 0
    public var nacks = 0
    public var resends = 0
    public var parityPieces = 0
    public var refused = 0
    public var rttMillis = 0
    public init() {}
}

final class DatagramSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var link: VideoDatagramLink?
    private var closed = false

    func get() -> VideoDatagramLink? { lock.sync { link } }

    func attach(_ l: VideoDatagramLink) -> Bool {
        lock.sync {
            guard link == nil, !closed else { return false }
            link = l
            return true
        }
    }

    @discardableResult
    func detach(_ l: VideoDatagramLink) -> Bool {
        lock.sync {
            guard link === l else { return false }
            link = nil
            return true
        }
    }

    func closeAll() {
        let l = lock.sync { () -> VideoDatagramLink? in closed = true; let v = link; link = nil; return v }
        l?.close()
    }
}

extension SecureSession {
    /// The session's video goes in datagrams now.
    public var hasDatagrams: Bool { datagramSlot.get() != nil }
}

private func dgClock() -> TimeInterval { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1e9 }

private func udpParameters() -> NWParameters {
    let p = NWParameters.udp
    p.includePeerToPeer = false
    p.serviceClass = .interactiveVideo
    return p
}

// MARK: The Mac's side

/// The away door's UDP twin: a listener on the same port number.
final class DatagramDoor: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?

    func start(port: UInt16, server: LinkServer) {
        stop()
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: udpParameters(), on: p) else {
            server.log?.add("video datagrams: couldn't listen on the away port")
            return
        }
        l.newConnectionHandler = { [weak server] conn in
            guard let server else { conn.cancel(); return }
            server.acceptDatagrams(conn)
        }
        l.stateUpdateHandler = { [weak server] state in
            if case .failed = state { server?.log?.add("video datagrams: the listener failed") }
        }
        lock.sync { listener = l }
        l.start(queue: DispatchQueue(label: "macrophone.datagram.door"))
    }

    func stop() {
        let l = lock.sync { () -> NWListener? in let v = listener; listener = nil; return v }
        l?.cancel()
    }
}

extension LinkServer {
    /// A new address sent a datagram: it must be a hello for an open session whose phone named
    /// datagrams; then it's that session's path. Anything else is dropped without an answer.
    func acceptDatagrams(_ conn: NWConnection) {
        let queue = DispatchQueue(label: "macrophone.datagram.mac")
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            // Nothing valid came: let it go (the path, once made, owns the connection).
            if self?.datagramOwner(conn) == nil { conn.cancel() }
        }
        conn.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data else { conn.cancel(); return }
            guard self.datagramsEnabled, let phoneID = datagramHelloPhone(data), let s = self.openSession(phoneID),
                  self.phoneFeatures(phoneID).contains(VideoDatagrams.feature), let keys = s.laneSecrets?.datagram else {
                conn.cancel(); return
            }
            var opener = DatagramOpener(key: keys.phoneToMac)
            guard let (plain, hello) = try? opener.open(data), hello, DatagramMessage.decode(plain) == .hello else {
                conn.cancel(); return
            }
            let path = MacDatagramPath(connection: conn, queue: queue, keys: keys, opener: opener, session: s, log: self.log)
            guard s.datagramSlot.attach(path) else { conn.cancel(); return }
            self.log?.add("video datagrams open: the video goes in datagrams")
            path.begin()
        }
    }

    private func datagramOwner(_ conn: NWConnection) -> MacDatagramPath? {
        connectedPeerIDs.lazy.compactMap { self.openSession($0)?.datagramSlot.get() as? MacDatagramPath }.first { $0.connection === conn }
    }
}

final class MacDatagramPath: VideoDatagramLink, @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var sealer: DatagramSealer
    private var opener: DatagramOpener
    private var sender = DatagramSender()
    private weak var session: SecureSession?
    private let log: DiagnosticLog?
    private var closed = false
    private var timer: DispatchSourceTimer?
    private var lastHeard = dgClock()
    private var phoneReceived: UInt32 = 0
    private var unansweredSince: TimeInterval?
    private var pending: [(message: Data, keyframe: Bool, since: TimeInterval, done: CheckedContinuation<Bool, Never>)] = []
    private var _stats = VideoDatagramStats()

    static let quietLimit: TimeInterval = 1.5
    /// How long a send may wait for the window before it goes anyway.
    static let windowWait: TimeInterval = 0.5

    init(connection: NWConnection, queue: DispatchQueue, keys: DatagramKeys, opener: DatagramOpener, session: SecureSession, log: DiagnosticLog?) {
        self.connection = connection
        self.queue = queue
        self.sealer = DatagramSealer(key: keys.macToPhone)
        self.opener = opener
        self.session = session
        self.log = log
    }

    var stats: VideoDatagramStats { queue.sync { _stats } }

    func begin() {
        queue.async { [self] in
            emit([.ready])
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.queue.async { self?.fail("its connection ended") }
                default: break
                }
            }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.1, repeating: 0.1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.activate()
            timer = t
            read()
        }
    }

    func send(_ message: Message) async -> Bool {
        guard let plain = try? WireCoding.encoder.encode(message) else { return false }
        var keyframe = false
        if case let .watchVideo(f) = message { keyframe = f.keyframe }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                guard !closed else { c.resume(returning: false); return }
                pending.append((plain, keyframe, dgClock(), c))
                pump()
            }
        }
    }

    /// Sends what's waiting while the window allows (or a send has waited long enough).
    private func pump() {
        let now = dgClock()
        while let first = pending.first, sender.inFlight(now: now) < DatagramSender.window || now - first.since > Self.windowWait {
            pending.removeFirst()
            let pieces = sender.frame(first.message, keyframe: first.keyframe, now: now)
            _stats.payload += first.message.count
            _stats.parityPieces += pieces.filter(\.parity).count
            emit(pieces.map { .piece($0) })
            first.done.resume(returning: true)
        }
    }

    private func emit(_ messages: [DatagramMessage]) {
        guard !closed, !messages.isEmpty else { return }
        connection.batch {
            for m in messages {
                let d = sealer.seal(m.encoded())
                _stats.datagramsOut += 1
                _stats.bytesOut += d.count
                connection.send(content: d, completion: .idempotent)
            }
        }
        if unansweredSince == nil, messages.contains(where: { if case .piece = $0 { return true }; return false }) { unansweredSince = dgClock() }
    }

    private func read() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if let data { self.handle(data) }
                if error == nil { self.read() }
            }
        }
    }

    private func handle(_ data: Data) {
        _stats.datagramsIn += 1
        _stats.bytesIn += data.count
        guard let (plain, _) = try? opener.open(data), let m = DatagramMessage.decode(plain) else { _stats.refused += 1; return }
        let now = dgClock()
        lastHeard = now
        switch m {
        case .hello:
            emit([.ready])
        case let .report(r):
            if r.received > phoneReceived { phoneReceived = r.received; unansweredSince = nil }
            _stats.rttMillis = Int(r.rttMillis)
            let again = sender.report(r, now: now)
            _stats.resends += again.count
            emit([.reportAck(echo: r.time)] + again.map { .piece($0) })
            pump()
        case let .nack(list):
            let again = sender.nack(list)
            _stats.nacks += list.count
            _stats.resends += again.count
            emit(again.map { .piece($0) })
        default: break
        }
    }

    private func tick() {
        guard !closed else { return }
        let now = dgClock()
        if now - lastHeard > Self.quietLimit { fail("went quiet"); return }
        if let since = unansweredSince, now - since > Self.quietLimit { fail("nothing sent reached the phone"); return }
        pump()
    }

    private func fail(_ why: String) {
        guard !closed else { return }
        emit([.closing])
        closed = true
        timer?.cancel()
        let waiting = pending
        pending = []
        waiting.forEach { $0.done.resume(returning: false) }
        if let session { session.datagramSlot.detach(self) }
        let s = _stats
        log?.add("video datagrams closed (\(why)) after \(s.datagramsOut) datagrams, \(s.resends) resent, \(s.parityPieces) parity: the video goes back on the lane")
        connection.cancel()
    }

    func close() { queue.async { [self] in fail("the session closed") } }
}

// MARK: The phone's side

extension LinkClient {
    /// Opens the datagram path for a session that just opened from away (the same host and port
    /// it won on). Anything failing leaves the video on the lane.
    func openDatagrams(for s: SecureSession, endpoint: NWEndpoint, macID: UUID) {
        guard let keys = s.laneSecrets?.datagram, case let .hostPort(host, sessionPort) = endpoint else { return }
        let port = datagramPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? sessionPort
        let path = PhoneDatagramPath(host: host, port: port, keys: keys, session: s, client: self, macID: macID, phoneID: identity.id, log: log)
        guard s.datagramSlot.attach(path) else { return }
        path.begin()
    }

    /// The connected Mac's video comes in datagrams (away from home).
    public var hasVideoDatagrams: Bool { currentSession?.datagramSlot.get().map { ($0 as? PhoneDatagramPath)?.isReady ?? true } ?? false }
    /// The datagram path's counts (nil without one).
    public var videoDatagramStats: VideoDatagramStats? { currentSession?.datagramSlot.get()?.stats }
}

final class PhoneDatagramPath: VideoDatagramLink, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "macrophone.datagram.phone")
    private var sealer: DatagramSealer
    private var opener: DatagramOpener
    private var reassembler = FrameReassembler()
    private weak var session: SecureSession?
    private weak var client: LinkClient?
    private let macID: UUID
    private let phoneID: UUID
    private let log: DiagnosticLog?
    private var ready = false
    private var closed = false
    private var started = dgClock()
    private var lastHello: TimeInterval = 0
    private var lastHeard = dgClock()
    private var lastPiece: TimeInterval = 0
    private var lastReport: TimeInterval = 0
    private var srtt: TimeInterval?
    private var timer: DispatchSourceTimer?
    private var _stats = VideoDatagramStats()

    static let helloEvery: TimeInterval = 0.15
    static let helloFor: TimeInterval = 1.2
    static let quietLimit: TimeInterval = 3

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, keys: DatagramKeys, session: SecureSession, client: LinkClient, macID: UUID, phoneID: UUID, log: DiagnosticLog?) {
        connection = NWConnection(host: host, port: port, using: udpParameters())
        sealer = DatagramSealer(key: keys.phoneToMac)
        opener = DatagramOpener(key: keys.macToPhone)
        self.session = session
        self.client = client
        self.macID = macID
        self.phoneID = phoneID
        self.log = log
    }

    var isReady: Bool { queue.sync { ready && !closed } }
    var stats: VideoDatagramStats {
        queue.sync {
            var s = _stats
            let r = reassembler.stats
            s.framesDelivered = r.delivered; s.framesSkipped = r.skipped; s.recoveredByParity = r.recovered; s.nacks = r.nacked
            s.resends = r.resendsUseful; s.refused = opener.refused; s.rttMillis = Int((srtt ?? 0) * 1000)
            return s
        }
    }

    func begin() {
        queue.async { [self] in
            started = dgClock()
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.queue.async { self?.end("its connection failed") } }
            }
            connection.start(queue: queue)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 0.01, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.activate()
            timer = t
            read()
        }
    }

    /// The phone never sends video.
    func send(_ message: Message) async -> Bool { false }

    private func emit(_ m: DatagramMessage, hello: Bool = false) {
        guard !closed else { return }
        let d = sealer.seal(m.encoded(), hello: hello ? phoneID : nil)
        _stats.datagramsOut += 1
        _stats.bytesOut += d.count
        connection.send(content: d, completion: .idempotent)
    }

    private func read() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            // Already on the queue (the connection's).
            guard !self.closed else { return }
            if let data { self.handle(data) }
            if error == nil { self.read() }
        }
    }

    private func handle(_ data: Data) {
        _stats.datagramsIn += 1
        _stats.bytesIn += data.count
        guard let (plain, _) = try? opener.open(data), let m = DatagramMessage.decode(plain) else { return }
        let now = dgClock()
        lastHeard = now
        switch m {
        case .ready:
            becameReady(now)
        case let .piece(p):
            becameReady(now)
            lastPiece = now
            deliver(reassembler.receive(p, now: now))
        case let .reportAck(echo):
            let sample = now - TimeInterval(echo) / 1e9
            if sample >= 0, sample < 5 {
                srtt = srtt.map { $0 * 0.875 + sample * 0.125 } ?? sample
                reassembler.rtt = srtt!
            }
        case .closing:
            end("the Mac closed it")
        default: break
        }
    }

    private func becameReady(_ now: TimeInterval) {
        guard !ready else { return }
        ready = true
        log?.add("video datagrams open in \(Int((now - started) * 1000)) ms")
    }

    private func deliver(_ messages: [Data]) {
        guard let client, let session else { return }
        for d in messages {
            _stats.payload += d.count
            guard let m = try? WireCoding.decoder.decode(Message.self, from: d), VideoLane.rides(m) else { continue }
            client.handle(m, from: session, macID: macID)
        }
    }

    private func tick() {
        guard !closed else { return }
        let now = dgClock()
        if !ready {
            if now - started > Self.helloFor { end("no answer in \(Int(Self.helloFor * 1000)) ms"); return }
            if now - lastHello >= Self.helloEvery { lastHello = now; emit(.hello, hello: true) }
            return
        }
        if now - lastHeard > Self.quietLimit { end("the Mac went quiet"); return }
        let (out, nacks) = reassembler.tick(now: now)
        deliver(out)
        if !nacks.isEmpty { emit(.nack(nacks)) }
        let every = now - lastPiece < 1 || reassembler.incomplete ? 0.1 : 0.4
        if now - lastReport >= every {
            lastReport = now
            let r = DatagramReport(time: DispatchTime.now().uptimeNanoseconds, resolved: reassembler.next - 1, seen: reassembler.seen,
                                   received: UInt32(truncatingIfNeeded: _stats.datagramsIn), lossPermille: UInt16(reassembler.takeLoss()),
                                   rttMillis: UInt16(min(60_000, Int((srtt ?? 0) * 1000))))
            emit(.report(r))
        }
    }

    private func end(_ why: String) {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        connection.cancel()
        if let session { session.datagramSlot.detach(self) }
        let r = reassembler.stats
        if ready {
            log?.add("video datagrams closed (\(why)) after \(r.delivered) frames, \(r.skipped) given up, \(r.recovered) rebuilt from parity, \(r.nacked) asked again")
        } else {
            log?.add("video datagrams didn't open (\(why)): the video stays on the lane")
        }
    }

    func close() { queue.async { [self] in end("the session closed") } }
}
