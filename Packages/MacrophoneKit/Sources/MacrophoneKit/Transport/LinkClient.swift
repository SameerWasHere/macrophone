import CryptoKit
import Foundation
import Network

/// A Mac running Macrophone, seen over Bonjour.
public struct DiscoveredMac: Identifiable, Hashable, Sendable {
    public var id: String { macID?.uuidString ?? name }
    public var macID: UUID?
    public var name: String
    public var endpoint: NWEndpoint
    public var isPeerToPeer: Bool

    public init(macID: UUID?, name: String, endpoint: NWEndpoint, isPeerToPeer: Bool = false) {
        self.macID = macID
        self.name = name
        self.endpoint = endpoint
        self.isPeerToPeer = isPeerToPeer
    }
}

@MainActor
public protocol LinkClientDelegate: AnyObject {
    func linkClient(_ client: LinkClient, stateChanged state: LinkClient.State)
    func linkClient(_ client: LinkClient, discovered macs: [DiscoveredMac])
    /// The Mac forgot this phone ("Forget this iPhone"). The key is already deleted.
    func linkClient(_ client: LinkClient, unpairedBy macID: UUID)
    /// iOS is blocking Bonjour because Local Network access is off for this app (true), or it
    /// came back (false). Tell the person where to turn it on.
    func linkClient(_ client: LinkClient, localNetworkDenied: Bool)
    /// The Mac's open apps/windows with a text field, newest first.
    func linkClient(_ client: LinkClient, targets: [LiveTarget], macID: UUID)
    /// The Send-to choice was changed on the Mac. Apply it (don't send it back).
    func linkClient(_ client: LinkClient, selectionChanged selection: SendSelection, macID: UUID)
    /// Where a dictation finally landed on the Mac (after the countdown and the paste).
    func linkClient(_ client: LinkClient, landed id: UUID, result: LandingResult, detail: String)
    /// Watching: how it's going on the Mac.
    func linkClient(_ client: LinkClient, watchState: WatchState)
    /// Watching: a new picture of the window.
    func linkClient(_ client: LinkClient, watchFrame: WatchFrame)
    /// Watching: a new frame of the window, as video (only when `features` names "video").
    func linkClient(_ client: LinkClient, watchVideo: WatchVideoFrame)
    /// A window on the Mac is asking something (only when `features` names "attention").
    func linkClient(_ client: LinkClient, attention: Attention)
    /// The apps installed on the Mac (answer to `listApps`).
    func linkClient(_ client: LinkClient, installedApps: [MacApp])
    /// An app asked for with `openApp` opened (or didn't).
    func linkClient(_ client: LinkClient, appOpened bundleID: String, ok: Bool, detail: String)
    /// The Mac said where it can be reached from away (already kept with the pairing).
    func linkClient(_ client: LinkClient, remoteAddresses: [RemoteAddress], macID: UUID)
    /// The link moved between the local path (Bonjour) and a remote one while staying connected
    /// — back home, it moves to the local path by itself.
    func linkClient(_ client: LinkClient, pathChanged remote: Bool)
}

public extension LinkClientDelegate {
    func linkClient(_ client: LinkClient, localNetworkDenied: Bool) {}
    func linkClient(_ client: LinkClient, targets: [LiveTarget], macID: UUID) {}
    func linkClient(_ client: LinkClient, selectionChanged selection: SendSelection, macID: UUID) {}
    func linkClient(_ client: LinkClient, landed id: UUID, result: LandingResult, detail: String) {}
    func linkClient(_ client: LinkClient, watchState: WatchState) {}
    func linkClient(_ client: LinkClient, watchFrame: WatchFrame) {}
    func linkClient(_ client: LinkClient, watchVideo: WatchVideoFrame) {}
    func linkClient(_ client: LinkClient, attention: Attention) {}
    func linkClient(_ client: LinkClient, installedApps: [MacApp]) {}
    func linkClient(_ client: LinkClient, appOpened bundleID: String, ok: Bool, detail: String) {}
    func linkClient(_ client: LinkClient, remoteAddresses: [RemoteAddress], macID: UUID) {}
    func linkClient(_ client: LinkClient, pathChanged remote: Bool) {}
}

/// The iPhone end of the link: browses for Macs, pairs, and keeps one encrypted session to
/// the active Mac while the app is in use.
public final class LinkClient: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case notPaired
        case searching            // paired, looking for the Mac
        case connecting(String)
        case connected(String)
        case unreachable(String)  // paired, Mac not found right now
    }

    public struct Ack: Sendable {
        public var outcome: DeliveryOutcome
        public var detail: String?
    }

    public let identity: DeviceIdentity
    public let store: PairingStore
    public let appVersion: String
    public let osDescription: String
    /// What this phone understands beyond the first version, told to the Mac in the hello.
    public var features: [String] = []
    /// What the connected Mac said it understands (its welcome's features): a newer message goes
    /// only to a Mac that named it.
    public private(set) var macFeatures: Set<String> = []
    @MainActor public weak var delegate: LinkClientDelegate?
    public var log: DiagnosticLog?
    /// Away from home: when Bonjour hasn't shown the Mac this long after looking began, the
    /// phone dials the addresses the Mac gave it (all at once; the first to answer wins).
    public var awayAfter: TimeInterval = 3
    /// Whether to look for the Mac with Bonjour at all. Off only in the protocol proof (mpctl),
    /// to stand in for a network where Bonjour finds nothing.
    public var browsesBonjour = true

    private let queue = DispatchQueue(label: "macrophone.client")
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var macs: [DiscoveredMac] = []
    private var session: SecureSession?
    private var sessionMacID: UUID?
    private var connectTask: Task<SecureSession, Error>?
    private var pending: [UUID: CheckedContinuation<Ack, Error>] = [:]
    private var pingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 1
    private var wantsConnection = false
    private var _state: State = .notPaired
    /// The session runs over a remote address, not Bonjour.
    private var _remote = false
    private var browserStartedAt: Date?
    private var movingHome = false

    /// The phone's current Send-to choice. Sent to the Mac right after every welcome, so the
    /// phone's choice wins when the two reconnect.
    public var selectionProvider: (@Sendable () -> SendSelection?)?

    public init(identity: DeviceIdentity, store: PairingStore, appVersion: String, osDescription: String) {
        self.identity = identity
        self.store = store
        self.appVersion = appVersion
        self.osDescription = osDescription
        _state = store.peers().isEmpty ? .notPaired : .searching
    }

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    /// Connected over a remote address (away from home) rather than Bonjour.
    public var isRemote: Bool { lock.sync { session != nil && _remote } }
    /// Where the active Mac can be reached from away, in the order they'd be dialled.
    public var remoteAddresses: [RemoteAddress] { RemoteAddressRule.ordered(activeMac?.remoteAddresses ?? []) }
    public var discoveredMacs: [DiscoveredMac] { lock.lock(); defer { lock.unlock() }; return macs }
    public var pairedMacs: [PairedPeer] { store.peers() }

    /// The Mac dictations go to — v1 uses the most recently paired one.
    public var activeMac: PairedPeer? {
        store.peers().sorted { $0.pairedAt > $1.pairedAt }.first
    }

    private func setState(_ s: State) {
        lock.lock()
        let changed = _state != s
        _state = s
        lock.unlock()
        guard changed else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.linkClient(self, stateChanged: s)
        }
    }

    // MARK: Browsing

    /// Start looking for Macs; also (re)connects to the paired Mac when it appears.
    /// Triggers the local network permission prompt the first time.
    public func start() {
        // Back in the foreground: a fresh start, with the first retry a second away, not thirty.
        let existing = lock.sync { () -> NWBrowser? in wantsConnection = true; retryDelay = 1; return browser }
        if existing == nil, browsesBonjour {
            let params = LinkServer.parameters()
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: Product.serviceType, domain: nil), using: params)
            b.browseResultsChangedHandler = { [weak self] results, _ in self?.updateResults(results) }
            b.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let e): self?.log?.add("browser failed: \(e)"); self?.restartBrowser()
                case .waiting(let e):
                    self?.log?.add("browser waiting: \(e)")
                    self?.setLocalNetworkDenied(Self.isPolicyDenied(e))
                case .ready:
                    self?.log?.add("browser ready")
                    self?.setLocalNetworkDenied(false)
                default: break
                }
            }
            lock.sync { browser = b; browserStartedAt = Date() }
            b.start(queue: queue)
        }
        if activeMac == nil { setState(.notPaired) } else { ensureConnected() }
    }

    /// The protocol proof's switch: stop or start looking with Bonjour while connected, to stand
    /// in for leaving home (nothing changes until the link drops) and coming back (the Mac shows
    /// up and the link moves to the local path).
    public func setBrowsesBonjour(_ on: Bool) {
        browsesBonjour = on
        if on {
            if lock.sync({ browser }) == nil, lock.sync({ wantsConnection }) { start() }
        } else {
            let b = lock.sync { () -> NWBrowser? in let v = browser; browser = nil; browserStartedAt = nil; return v }
            b?.cancel()
            lock.sync { macs = [] }
        }
    }

    /// Stop browsing and drop the session (app went to the background with nothing to send).
    public func stop() {
        lock.lock()
        wantsConnection = false
        let b = browser; browser = nil
        let s = session; session = nil; sessionMacID = nil; _remote = false; browserStartedAt = nil
        lock.unlock()
        b?.cancel()
        s?.close()
        retryTask?.cancel()
        pingTask?.cancel()
        failPending(LinkError.cancelled)
    }

    /// True while iOS refuses Bonjour for this app (Local Network permission off).
    public var isLocalNetworkDenied: Bool { lock.sync { localNetworkDenied } }
    private var localNetworkDenied = false

    static func isPolicyDenied(_ e: NWError) -> Bool {
        if case let .dns(code) = e { return code == -65570 }  // kDNSServiceErr_PolicyDenied
        return false
    }

    private func setLocalNetworkDenied(_ denied: Bool) {
        let changed = lock.sync { () -> Bool in
            guard localNetworkDenied != denied else { return false }
            localNetworkDenied = denied
            return true
        }
        guard changed else { return }
        log?.add(denied ? "local network access is off" : "local network access ok")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.linkClient(self, localNetworkDenied: denied)
        }
    }

    private func restartBrowser() {
        let (b, want) = lock.sync { () -> (NWBrowser?, Bool) in let v = browser; browser = nil; return (v, wantsConnection) }
        b?.cancel()
        guard want else { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }

    private func updateResults(_ results: Set<NWBrowser.Result>) {
        var found: [DiscoveredMac] = []
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            var macID: UUID?
            if case let .bonjour(txt) = r.metadata, let s = txt["id"] { macID = UUID(uuidString: s) }
            let p2p = r.interfaces.contains { $0.type == .other } && !r.interfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
            found.append(DiscoveredMac(macID: macID, name: name, endpoint: r.endpoint, isPeerToPeer: p2p))
        }
        found.sort { $0.name < $1.name }
        lock.sync { macs = found }
        log?.add("found \(found.count) Mac(s)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.linkClient(self, discovered: found)
        }
        if let active = activeMac, found.contains(where: { $0.macID == active.id }) {
            // Back home: the Mac is on this network again while the link still runs over a remote
            // address — move to the local path.
            if isRemote { moveHome(active) } else { ensureConnected() }
        }
    }

    /// How to reach the Mac right now: its Bonjour endpoint (verified = the TXT record says it IS
    /// that Mac by id; a dial by name may reach another Mac with the same name), or — once Bonjour
    /// has had `awayAfter` seconds and found nothing — the addresses it gave for away.
    private enum Route { case bonjour(NWEndpoint, verified: Bool), remote([RemoteAddress]) }

    private func route(for mac: PairedPeer) async -> Route {
        func local() -> NWEndpoint? { discoveredMacs.first(where: { $0.macID == mac.id })?.endpoint }
        if let e = local() { return .bonjour(e, verified: true) }
        let remotes = RemoteAddressRule.ordered(mac.remoteAddresses)
        if !remotes.isEmpty, browsesBonjour {
            // Give Bonjour its few seconds before dialling away.
            while let started = lock.sync({ browserStartedAt }), Date().timeIntervalSince(started) < awayAfter {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let e = local() { return .bonjour(e, verified: true) }
            }
        }
        if !remotes.isEmpty { return .remote(remotes) }
        // Not browsed yet — dial the service by name and let Bonjour resolve it.
        return .bonjour(.service(name: mac.name, type: Product.serviceType, domain: "local.", interface: nil), verified: false)
    }

    /// Dials every remote address at once and keeps the first whose connection opens; the
    /// others are closed before any handshake, so the Mac only ever sees one session.
    private func raceConnect(_ addresses: [RemoteAddress], timeout: TimeInterval) async throws -> FramedConnection {
        log?.add("dialling \(addresses.count) remote address(es)")
        let conns = addresses.map { FramedConnection(NWConnection(to: $0.endpoint, using: LinkServer.parameters()), queue: queue) }
        return try await withThrowingTaskGroup(of: FramedConnection.self) { g in
            for c in conns { g.addTask { try await c.start(timeout: timeout); return c } }
            var winner: FramedConnection?
            var lastError: Error = LinkError.macNotFound
            while winner == nil, let r = await g.nextResult() {
                switch r {
                case .success(let c): winner = c
                case .failure(let e): lastError = e
                }
            }
            g.cancelAll()
            for c in conns where c !== winner { c.cancel() }
            guard let winner else { throw lastError }
            return winner
        }
    }

    // MARK: Session

    public var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return session != nil }

    /// Connects if paired and not connected; retries with backoff while `start()` is in effect.
    public func ensureConnected() {
        guard activeMac != nil else { setState(.notPaired); return }
        let busy = lock.sync { session != nil || connectTask != nil }
        guard !busy else { return }
        Task { _ = try? await self.connect() }
    }

    /// Dials the active Mac and completes the session handshake.
    @discardableResult
    public func connect(timeout: TimeInterval = 8) async throws -> SecureSession {
        guard let mac = activeMac, let key = store.key(for: mac.id) else { setState(.notPaired); throw LinkError.notPaired }
        enum Start { case have(SecureSession), join(Task<SecureSession, Error>) }
        let start: Start = lock.sync {
            if let s = session { return .have(s) }
            if let t = connectTask { return .join(t) }
            let task = Task { try await self.dial(mac: mac, key: key, timeout: timeout) }
            connectTask = task
            return .join(task)
        }
        let task: Task<SecureSession, Error>
        switch start {
        case .have(let s): return s
        case .join(let t): task = t
        }
        do {
            let s = try await task.value
            lock.sync { connectTask = nil }
            return s
        } catch {
            lock.sync { connectTask = nil }
            throw error
        }
    }

    /// `replacing`: a move back home — the new session takes the place of the remote one and the
    /// state never leaves `.connected`.
    private func dial(mac: PairedPeer, key: SymmetricKey, timeout: TimeInterval, replacing: Bool = false) async throws -> SecureSession {
        if !replacing { setState(.connecting(mac.name)) }
        let route: Route = replacing
            ? .bonjour(discoveredMacs.first(where: { $0.macID == mac.id })?.endpoint ?? .service(name: mac.name, type: Product.serviceType, domain: "local.", interface: nil), verified: true)
            : await route(for: mac)
        let conn: FramedConnection
        let verified: Bool
        let remote: Bool
        do {
            switch route {
            case let .bonjour(endpoint, v):
                conn = FramedConnection(NWConnection(to: endpoint, using: LinkServer.parameters()), queue: queue)
                try await conn.start(timeout: timeout)
                verified = v
                remote = false
            case let .remote(list):
                conn = try await raceConnect(list, timeout: min(timeout, 6))
                verified = false
                remote = true
            }
        } catch {
            log?.add("connect failed: \(String(describing: error))")
            if !replacing { setState(.unreachable(mac.name)); scheduleRetry() }
            throw error
        }
        do {
            let phoneNonce = LinkCrypto.randomBytes(32)
            try await conn.sendHandshake(.clientHello(phoneID: identity.id, nonce: phoneNonce, version: Product.protocolVersion))
            let reply = try await conn.receiveHandshake(timeout: timeout)
            switch reply {
            case let .serverHello(macID, macNonce, proof):
                guard macID == mac.id,
                      LinkCrypto.verify(proof, LinkCrypto.sessionProof(key, role: "mac", phoneNonce: phoneNonce, macNonce: macNonce)) else {
                    throw LinkError.handshake(.badProof)
                }
                try await conn.sendHandshake(.clientFinish(proof: LinkCrypto.sessionProof(key, role: "phone", phoneNonce: phoneNonce, macNonce: macNonce)))
                let keys = LinkCrypto.sessionKeys(key, phoneNonce: phoneNonce, macNonce: macNonce)
                let s = SecureSession(connection: conn, peerID: mac.id, sendKey: keys.phoneToMac, receiveKey: keys.macToPhone, isRemote: remote)
                try await s.send(.hello(phoneName: identity.name, appVersion: appVersion, os: osDescription, features: features))
                guard case let .welcome(macName, _, macFeatures) = try await receive(s, timeout: timeout) else {
                    throw LinkError.protocolError("expected welcome")
                }
                let old = lock.sync { () -> SecureSession? in
                    let o = session
                    session = s; sessionMacID = mac.id; retryDelay = 1; _remote = remote; self.macFeatures = Set(macFeatures ?? [])
                    return o
                }
                old?.close()
                if let sel = selectionProvider?() { try? await s.send(.selection(sel)) }
                store.touch(mac.id)
                log?.add(remote ? "connected to Mac from away" : (replacing ? "back home: moved to the local path" : "connected to Mac"))
                setState(.connected(macName))
                if replacing || remote {
                    let r = remote
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.delegate?.linkClient(self, pathChanged: r)
                    }
                }
                conn.onState { [weak self, weak s] state in
                    if case .failed = state, let s { self?.sessionEnded(s, error: LinkError.connectionFailed("dropped")) }
                    if case .cancelled = state, let s { self?.sessionEnded(s, error: LinkError.cancelled) }
                }
                startLoops(s, macID: mac.id)
                return s
            case .failure(.unknownPeer) where !verified:
                // Dialled by name: this may be another Mac with the same name. Never forget the
                // pairing on its word — wait until Bonjour shows our Mac by id.
                log?.add("a Mac with this name doesn't know this phone; not ours, keeping the pairing")
                conn.cancel()
                throw LinkError.macNotFound
            case .failure(.unknownPeer):
                // Our Mac (matched by id) forgot us while we were away.
                log?.add("Mac no longer knows this phone")
                conn.cancel()
                store.remove(mac.id)
                setState(.notPaired)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.delegate?.linkClient(self, unpairedBy: mac.id)
                }
                throw LinkError.handshake(.unknownPeer)
            case let .failure(reason):
                throw LinkError.handshake(reason)
            default:
                throw LinkError.protocolError("unexpected reply")
            }
        } catch {
            conn.cancel()
            log?.add("connect failed: \(String(describing: error))")
            if replacing { throw error }
            if case LinkError.handshake(.unknownPeer) = error {} else {
                setState(.unreachable(mac.name))
                scheduleRetry()
            }
            throw error
        }
    }

    /// Back home while connected from away: open the local path and swap the remote session for
    /// it. If that fails, the remote one simply stays.
    private func moveHome(_ mac: PairedPeer) {
        guard let key = store.key(for: mac.id) else { return }
        let go = lock.sync { () -> Bool in
            guard _remote, session != nil, !movingHome else { return false }
            movingHome = true
            return true
        }
        guard go else { return }
        Task {
            let moved = (try? await dial(mac: mac, key: key, timeout: 6, replacing: true)) != nil
            let lost = lock.sync { () -> Bool in movingHome = false; return session == nil }
            if !moved, lost {
                // The remote session went while the local one failed: say so and try again.
                setState(.unreachable(mac.name))
                scheduleRetry()
            }
        }
    }

    /// Keep (or clear, with nil) the one address the person typed for the active Mac.
    public func setTypedAddress(_ address: RemoteAddress?, for macID: UUID) {
        guard var peer = store.peers().first(where: { $0.id == macID }) else { return }
        peer.remoteAddresses.removeAll { $0.source == .typed }
        if let address { peer.remoteAddresses.append(RemoteAddress(host: address.host, port: address.port, source: .typed)) }
        store.update(peer)
        log?.add(address == nil ? "typed address cleared" : "typed address kept")
    }

    private func receive(_ s: SecureSession, timeout: TimeInterval) async throws -> Message {
        try await withThrowingTaskGroup(of: Message.self) { g in
            g.addTask { try await s.receive() }
            g.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); throw LinkError.timedOut }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }

    private func startLoops(_ s: SecureSession, macID: UUID) {
        Task.detached { [weak self] in
            do {
                while true {
                    let m = try await s.receive()
                    self?.handle(m, from: s, macID: macID)
                }
            } catch {
                self?.sessionEnded(s, error: error)
            }
        }
        pingTask?.cancel()
        pingTask = Task { [weak self, weak s] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                guard let s else { return }
                do { try await s.send(.ping) } catch { self?.sessionEnded(s, error: error); return }
            }
        }
    }

    private func handle(_ m: Message, from s: SecureSession, macID: UUID) {
        switch m {
        case let .ack(id, outcome, detail):
            let c = lock.sync { pending.removeValue(forKey: id) }
            c?.resume(returning: Ack(outcome: outcome, detail: detail))
        case let .targets(list):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.linkClient(self, targets: list, macID: macID)
            }
        case let .landed(id, result, detail):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.linkClient(self, landed: id, result: result, detail: detail)
            }
        case let .selection(sel):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.linkClient(self, selectionChanged: sel, macID: macID)
            }
        case let .watchState(state):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.linkClient(self, watchState: state)
            }
        case let .apps(list):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.linkClient(self, installedApps: list)
            }
        case let .appOpened(bundleID, ok, detail):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.linkClient(self, appOpened: bundleID, ok: ok, detail: detail)
            }
        case let .watchFrame(frame):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.linkClient(self, watchFrame: frame)
            }
        case let .watchVideo(frame):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.linkClient(self, watchVideo: frame)
            }
        case let .attention(a):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.linkClient(self, attention: a)
            }
        case let .remoteAddresses(list):
            // Kept with the pairing: what the Mac says replaces what it said before; a typed
            // address stays.
            if var peer = store.peers().first(where: { $0.id == macID }) {
                let clean = list.prefix(12).filter { !$0.host.isEmpty && $0.port > 0 }
                peer.remoteAddresses = RemoteAddressRule.merge(told: clean, into: peer.remoteAddresses)
                store.update(peer)
                log?.add("Mac gave \(clean.count) remote address(es)")
                let kept = peer.remoteAddresses
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.delegate?.linkClient(self, remoteAddresses: kept, macID: macID)
                }
            }
        case .ping:
            Task { try? await s.send(.pong) }
        case .unpair:
            log?.add("Mac forgot this phone")
            store.remove(macID)
            sessionEnded(s, error: LinkError.notPaired)
            setState(.notPaired)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.linkClient(self, unpairedBy: macID)
            }
        case .pong, .welcome, .hello, .dictation, .refreshTargets, .watch, .watchAction, .watchClick, .watchScroll, .watchChoose, .watchKeyframe, .watchFit, .listApps, .openApp:
            break
        }
    }

    private func sessionEnded(_ s: SecureSession, error: Error) {
        lock.lock()
        guard session === s else { lock.unlock(); return }
        session = nil
        sessionMacID = nil
        _remote = false
        // Moving home: the Mac closes the remote session the moment the local one's handshake
        // lands, a beat before this side installs it — not a drop, so no "not found" in between.
        let moving = movingHome
        lock.unlock()
        s.close()
        pingTask?.cancel()
        failPending(error)
        log?.add(moving ? "remote session closed by the move home" : "session ended")
        guard !moving else { return }
        if let mac = activeMac {
            setState(.unreachable(mac.name))
            scheduleRetry()
        }
    }

    private func failPending(_ error: Error) {
        let all = lock.sync { () -> [UUID: CheckedContinuation<Ack, Error>] in let v = pending; pending.removeAll(); return v }
        all.values.forEach { $0.resume(throwing: error) }
    }

    private func scheduleRetry() {
        lock.lock()
        let want = wantsConnection
        let delay = retryDelay
        // Doubling, capped at ten seconds: a Mac that comes back is usually noticed by Bonjour
        // first, but when it isn't, ten seconds is the most a reconnect waits.
        retryDelay = min(retryDelay * 2, 10)
        lock.unlock()
        guard want else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard !Task.isCancelled else { return }
            self?.ensureConnected()
        }
    }

    /// Sends one dictation and waits for the Mac's ack. Throws if the Mac can't be reached —
    /// the caller queues it and calls again later with `delayed: true`.
    public func send(_ dictation: Dictation, delayed: Bool, timeout: TimeInterval = 10) async throws -> Ack {
        let s = try await connect(timeout: min(timeout, 6))
        return try await withThrowingTaskGroup(of: Ack.self) { g in
            g.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Ack, Error>) in
                    self.lock.lock(); self.pending[dictation.id] = c; self.lock.unlock()
                    Task {
                        do { try await s.send(.dictation(dictation, delayed: delayed)) } catch {
                            let c = self.lock.sync { self.pending.removeValue(forKey: dictation.id) }
                            c?.resume(throwing: error)
                        }
                    }
                }
            }
            g.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); throw LinkError.timedOut }
            defer { g.cancelAll() }
            do {
                return try await g.next()!
            } catch {
                let c = lock.sync { pending.removeValue(forKey: dictation.id) }
                c?.resume(throwing: error)
                throw error
            }
        }
    }

    /// Tell the Mac the Send-to choice changed on the phone. If not connected, it goes with
    /// the next welcome anyway (via `selectionProvider`).
    public func setSelection(_ selection: SendSelection) {
        guard let s = lock.sync({ session }) else { return }
        Task { try? await s.send(.selection(selection)) }
    }

    /// Ask the Mac to rescan its open apps now (the picker opened).
    public func refreshTargets() {
        guard let s = lock.sync({ session }) else { return }
        Task { try? await s.send(.refreshTargets) }
    }

    /// Start watching a place's window on the Mac (nil stops). Returns false when not connected.
    @discardableResult
    public func watch(_ target: TargetRef?) -> Bool {
        guard let s = lock.sync({ session }) else { return false }
        Task { try? await s.send(.watch(target)) }
        return true
    }

    /// A one-tap action on the watched window.
    public func watchAction(_ action: WatchAction) {
        guard let s = lock.sync({ session }) else { return }
        Task { try? await s.send(.watchAction(action)) }
    }

    /// Answer the prompt the watched window showed with the answer at `index`.
    public func watchChoose(_ prompt: WatchPrompt, index: Int) {
        guard let s = lock.sync({ session }) else { return }
        Task { try? await s.send(.watchChoose(promptID: prompt.id, index: index)) }
    }

    /// Ask the Mac for its installed apps (the answer comes to the delegate). False when not connected.
    @discardableResult
    public func listApps() -> Bool {
        guard let s = lock.sync({ session }) else { return false }
        Task { try? await s.send(.listApps) }
        return true
    }

    /// Open an app on the Mac and bring it forward. False when not connected.
    @discardableResult
    public func openApp(_ bundleID: String) -> Bool {
        guard let s = lock.sync({ session }) else { return false }
        Task { try? await s.send(.openApp(bundleID: bundleID)) }
        return true
    }

    /// Scroll the watched window at a point by a delta (fractions of the window).
    public func watchScroll(at p: CGPoint, by d: CGVector) {
        guard let s = lock.sync({ session }) else { return }
        Task { try? await s.send(.watchScroll(x: Double(p.x), y: Double(p.y), dx: Double(d.dx), dy: Double(d.dy))) }
    }

    /// Click the watched window at a fraction of its size (top-left origin).
    public func watchClick(_ p: CGPoint) {
        guard let s = lock.sync({ session }) else { return }
        Task { try? await s.send(.watchClick(x: Double(p.x), y: Double(p.y))) }
    }

    /// Ask for a video frame that stands on its own. Only a Mac that named "video" gets it
    /// (an unknown message would end an older Mac's session). False when it wasn't sent.
    @discardableResult
    public func watchKeyframe() -> Bool {
        guard let s = lock.sync({ macFeatures.contains(WatchVideo.feature) ? session : nil }) else { return false }
        Task { try? await s.send(.watchKeyframe) }
        return true
    }

    /// Size the watched window for readable text. Only a Mac that named "fit" gets it. False
    /// when it wasn't sent.
    @discardableResult
    public func watchFit(_ fit: WatchFit) -> Bool {
        guard let s = lock.sync({ macFeatures.contains(WatchVideo.fitFeature) ? session : nil }) else { return false }
        Task { try? await s.send(.watchFit(fit)) }
        return true
    }

    // MARK: Pairing

    /// Pairs using a scanned QR invite. Waits briefly for the Mac to show up on the network.
    public func pair(invite: PairingInvite) async throws -> PairedPeer {
        guard invite.version == Product.protocolVersion else { throw LinkError.rejected(.versionMismatch) }
        start()
        let endpoint = await waitForEndpoint(macID: invite.macID, fallbackName: invite.macName)
        let conn = FramedConnection(NWConnection(to: endpoint, using: LinkServer.parameters()), queue: queue)
        defer { conn.cancel() }
        try await conn.start(timeout: 10)
        let key = Curve25519.KeyAgreement.PrivateKey()
        let phonePub = key.publicKey.rawRepresentation
        let proof = LinkCrypto.qrProof(token: invite.token, phonePub: phonePub, macPub: invite.macPublicKey)
        try await conn.sendHandshake(.pairQR(phoneID: identity.id, phoneName: identity.name, phonePub: phonePub,
                                             inviteID: invite.inviteID, proof: proof, version: Product.protocolVersion))
        let macPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: invite.macPublicKey)
        let shared = try key.sharedSecretFromKeyAgreement(with: macPub)
        let pairKey = LinkCrypto.pairKey(shared: shared, salt: invite.token, macID: invite.macID, phoneID: identity.id)
        return try await finishPairing(conn, expectedMacID: invite.macID, key: pairKey)
    }

    /// Pairs by confirmation code with a Mac from `discoveredMacs`. `showCode` is called with
    /// the six digits; the person approves on the Mac.
    public func pairWithCode(_ mac: DiscoveredMac, showCode: @escaping @MainActor (String) -> Void) async throws -> PairedPeer {
        let conn = FramedConnection(NWConnection(to: mac.endpoint, using: LinkServer.parameters()), queue: queue)
        defer { conn.cancel() }
        try await conn.start(timeout: 10)
        let key = Curve25519.KeyAgreement.PrivateKey()
        let phonePub = key.publicKey.rawRepresentation
        let phoneNonce = LinkCrypto.randomBytes(32)
        try await conn.sendHandshake(.pairCodeCommit(phoneID: identity.id, phoneName: identity.name,
                                                     commitment: LinkCrypto.commitment(phonePub: phonePub, nonce: phoneNonce),
                                                     version: Product.protocolVersion))
        let reply = try await conn.receiveHandshake(timeout: 15)
        if case let .pairRejected(reason) = reply { throw LinkError.rejected(reason) }
        guard case let .pairCodeMacKey(macID, _, macPubData, macNonce) = reply else { throw LinkError.protocolError("expected key") }
        try await conn.sendHandshake(.pairCodeReveal(phonePub: phonePub, nonce: phoneNonce))
        let macPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: macPubData)
        let shared = try key.sharedSecretFromKeyAgreement(with: macPub)
        let code = LinkCrypto.confirmationCode(macPub: macPubData, phonePub: phonePub, macNonce: macNonce, phoneNonce: phoneNonce)
        let next = try await conn.receiveHandshake(timeout: 15)
        if case let .pairRejected(reason) = next { throw LinkError.rejected(reason) }
        guard case .pairCodeWaiting = next else { throw LinkError.protocolError("expected wait") }
        await MainActor.run { showCode(code) }
        let pairKey = LinkCrypto.pairKey(shared: shared, salt: macNonce + phoneNonce, macID: macID, phoneID: identity.id)
        return try await finishPairing(conn, expectedMacID: macID, key: pairKey, timeout: 130)
    }

    private func finishPairing(_ conn: FramedConnection, expectedMacID: UUID, key: SymmetricKey, timeout: TimeInterval = 15) async throws -> PairedPeer {
        let reply = try await conn.receiveHandshake(timeout: timeout)
        switch reply {
        case let .pairAccepted(macID, macName, confirm):
            guard macID == expectedMacID, LinkCrypto.verify(confirm, LinkCrypto.macConfirm(key)) else {
                throw LinkError.rejected(.badProof)
            }
            // One Mac at a time in v1: replace any older pairing's session.
            let peer = PairedPeer(id: macID, name: macName)
            store.save(peer, key: key)
            log?.add("paired with a Mac")
            let old = lock.sync { () -> SecureSession? in let v = session; session = nil; sessionMacID = nil; return v }
            old?.close()
            ensureConnected()
            return peer
        case let .pairRejected(reason):
            throw LinkError.rejected(reason)
        default:
            throw LinkError.protocolError("unexpected pairing reply")
        }
    }

    private func waitForEndpoint(macID: UUID, fallbackName: String) async -> NWEndpoint {
        for _ in 0..<40 {
            if let d = discoveredMacs.first(where: { $0.macID == macID }) { return d.endpoint }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return .service(name: fallbackName, type: Product.serviceType, domain: "local.", interface: nil)
    }

    /// Forget a Mac on this phone, telling it if connected.
    public func unpair(_ macID: UUID) async {
        // Best effort: reach the Mac so it forgets this phone too. If it's away, the Mac
        // learns on the next connection attempt (it gets no session) — or via its own menu.
        if activeMac?.id == macID { _ = try? await connect(timeout: 3) }
        let s = lock.sync { () -> SecureSession? in
            let s = sessionMacID == macID ? session : nil
            if s != nil { session = nil; sessionMacID = nil }
            return s
        }
        if let s { try? await s.send(.unpair); s.close() }
        store.remove(macID)
        log?.add("unpaired a Mac")
        setState(activeMac == nil ? .notPaired : .searching)
        if activeMac != nil { ensureConnected() }
    }
}
