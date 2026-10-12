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
}

@MainActor
public protocol LinkClientDelegate: AnyObject {
    func linkClient(_ client: LinkClient, stateChanged state: LinkClient.State)
    func linkClient(_ client: LinkClient, discovered macs: [DiscoveredMac])
    func linkClient(_ client: LinkClient, profiles: [ProfileSummary], macID: UUID)
    /// The Mac forgot this phone ("Forget this iPhone"). The key is already deleted.
    func linkClient(_ client: LinkClient, unpairedBy macID: UUID)
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
    @MainActor public weak var delegate: LinkClientDelegate?
    public var log: DiagnosticLog?

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

    public init(identity: DeviceIdentity, store: PairingStore, appVersion: String, osDescription: String) {
        self.identity = identity
        self.store = store
        self.appVersion = appVersion
        self.osDescription = osDescription
        _state = store.peers().isEmpty ? .notPaired : .searching
    }

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
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
        let existing = lock.sync { () -> NWBrowser? in wantsConnection = true; return browser }
        if existing == nil {
            let params = LinkServer.parameters()
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: Product.serviceType, domain: nil), using: params)
            b.browseResultsChangedHandler = { [weak self] results, _ in self?.updateResults(results) }
            b.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let e): self?.log?.add("browser failed: \(e)"); self?.restartBrowser()
                case .waiting(let e): self?.log?.add("browser waiting: \(e)")
                case .ready: self?.log?.add("browser ready")
                default: break
                }
            }
            lock.sync { browser = b }
            b.start(queue: queue)
        }
        if activeMac == nil { setState(.notPaired) } else { ensureConnected() }
    }

    /// Stop browsing and drop the session (app went to the background with nothing to send).
    public func stop() {
        lock.lock()
        wantsConnection = false
        let b = browser; browser = nil
        let s = session; session = nil; sessionMacID = nil
        lock.unlock()
        b?.cancel()
        s?.close()
        retryTask?.cancel()
        pingTask?.cancel()
        failPending(LinkError.cancelled)
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
        if let active = activeMac, found.contains(where: { $0.macID == active.id }) { ensureConnected() }
    }

    private func endpoint(for mac: PairedPeer) -> NWEndpoint {
        if let d = discoveredMacs.first(where: { $0.macID == mac.id }) { return d.endpoint }
        // Not browsed yet — dial the service by name and let Bonjour resolve it.
        return .service(name: mac.name, type: Product.serviceType, domain: "local.", interface: nil)
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

    private func dial(mac: PairedPeer, key: SymmetricKey, timeout: TimeInterval) async throws -> SecureSession {
        setState(.connecting(mac.name))
        let conn = FramedConnection(NWConnection(to: endpoint(for: mac), using: LinkServer.parameters()), queue: queue)
        do {
            try await conn.start(timeout: timeout)
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
                let s = SecureSession(connection: conn, peerID: mac.id, sendKey: keys.phoneToMac, receiveKey: keys.macToPhone)
                try await s.send(.hello(phoneName: identity.name, appVersion: appVersion, os: osDescription))
                guard case let .welcome(macName, _, profiles) = try await receive(s, timeout: timeout) else {
                    throw LinkError.protocolError("expected welcome")
                }
                lock.sync { session = s; sessionMacID = mac.id; retryDelay = 1 }
                store.touch(mac.id)
                log?.add("connected to Mac")
                setState(.connected(macName))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.delegate?.linkClient(self, profiles: profiles, macID: mac.id)
                }
                conn.onState { [weak self, weak s] state in
                    if case .failed = state, let s { self?.sessionEnded(s, error: LinkError.connectionFailed("dropped")) }
                    if case .cancelled = state, let s { self?.sessionEnded(s, error: LinkError.cancelled) }
                }
                startLoops(s, macID: mac.id)
                return s
            case .failure(.unknownPeer):
                // The Mac forgot us while we were away.
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
            if case LinkError.handshake(.unknownPeer) = error {} else {
                setState(.unreachable(mac.name))
                scheduleRetry()
            }
            throw error
        }
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
        case let .profiles(p):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.linkClient(self, profiles: p, macID: macID)
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
        case .pong, .welcome, .hello, .dictation:
            break
        }
    }

    private func sessionEnded(_ s: SecureSession, error: Error) {
        lock.lock()
        guard session === s else { lock.unlock(); return }
        session = nil
        sessionMacID = nil
        lock.unlock()
        s.close()
        pingTask?.cancel()
        failPending(error)
        log?.add("session ended")
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
        retryDelay = min(retryDelay * 2, 30)
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
