import CryptoKit
import Foundation
import Network

/// What the Mac app supplies to the server. Called on the main actor.
@MainActor
public protocol LinkServerDelegate: AnyObject {
    /// A phone wants to pair by confirmation code. Show `code` and ask the person whether it
    /// matches the phone. Return false if they decline or don't answer.
    func linkServer(_ server: LinkServer, approveCode code: String, phoneName: String) async -> Bool
    func linkServer(_ server: LinkServer, didPair peer: PairedPeer)
    /// The phone removed this pairing on its side.
    func linkServer(_ server: LinkServer, didUnpair peerID: UUID)
    func linkServer(_ server: LinkServer, peerConnected peer: PairedPeer, appVersion: String, os: String)
    func linkServer(_ server: LinkServer, peerDisconnected peerID: UUID)
    /// Deliver a dictation. Already de-duplicated: a repeated id never reaches here.
    func linkServer(_ server: LinkServer, deliver dictation: Dictation, delayed: Bool, from peer: PairedPeer) async -> (DeliveryOutcome, String?)
    func linkServer(_ server: LinkServer, listenerChanged state: LinkServer.ListenerState)
    func profilesForPhones(_ server: LinkServer) -> [ProfileSummary]
    /// A code-pairing attempt finished (approved, declined or timed out): dismiss the prompt.
    func linkServerCodePairingEnded(_ server: LinkServer)
    /// A phone changed the Send-to choice (or sent its own on connecting — the phone wins).
    /// The server already relayed it to any other connected phones.
    func linkServer(_ server: LinkServer, selectionChanged selection: SendSelection, from peer: PairedPeer)
    /// A phone asked for a fresh scan; answer with `broadcastTargets`.
    func linkServerRefreshTargets(_ server: LinkServer)
    /// The current list, sent to a phone right after its welcome.
    func liveTargets(_ server: LinkServer) -> [LiveTarget]
}

public extension LinkServerDelegate {
    func linkServerCodePairingEnded(_ server: LinkServer) {}
    func linkServer(_ server: LinkServer, selectionChanged selection: SendSelection, from peer: PairedPeer) {}
    func linkServerRefreshTargets(_ server: LinkServer) {}
    func liveTargets(_ server: LinkServer) -> [LiveTarget] { [] }
}

/// True for exactly one caller.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.sync { if done { return false }; done = true; return true } }
}

/// The Mac end of the link: advertises over Bonjour (peer-to-peer included), runs pairing,
/// and keeps one encrypted session per connected phone.
public final class LinkServer: @unchecked Sendable {
    public enum ListenerState: Equatable, Sendable {
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    public let identity: DeviceIdentity
    public let store: PairingStore
    public let appVersion: String
    @MainActor public weak var delegate: LinkServerDelegate?
    public var log: DiagnosticLog?

    private let queue = DispatchQueue(label: "macrophone.server")
    private var listener: NWListener?
    private let lock = NSLock()
    private var sessions: [UUID: SecureSession] = [:]

    // Pairing state
    private struct ActiveInvite { var invite: PairingInvite; var privateKey: Curve25519.KeyAgreement.PrivateKey; var expires: Date }
    private var invite: ActiveInvite?
    private var pairingOpenUntil: Date?
    private var codeAttempts: [Date] = []
    private var codePairingBusy = false

    // De-duplication of dictation ids (ids only — never text).
    private let seen: SeenIDs

    public init(identity: DeviceIdentity, store: PairingStore, appVersion: String, seenIDsURL: URL?) {
        self.identity = identity
        self.store = store
        self.appVersion = appVersion
        self.seen = SeenIDs(url: seenIDsURL)
    }

    // MARK: Listener

    public func start() {
        stop()
        let params = Self.parameters()
        do {
            let l = try NWListener(using: params)
            let txt = NWTXTRecord(["id": identity.id.uuidString, "v": String(Product.protocolVersion)])
            l.service = NWListener.Service(name: identity.name, type: Product.serviceType, domain: nil, txtRecord: txt)
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let port = l?.port?.rawValue ?? 0
                    self.log?.add("listener ready on port \(port), advertising \(Product.serviceType)")
                    self.notify { $0.linkServer(self, listenerChanged: .ready(port: port)) }
                case .failed(let e):
                    self.log?.add("listener failed: \(e)")
                    self.notify { $0.linkServer(self, listenerChanged: .failed(e.localizedDescription)) }
                    // Retry after a moment — e.g. the network came back.
                    self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
                case .waiting(let e):
                    self.log?.add("listener waiting: \(e)")
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            lock.sync { listener = l }
            notify { $0.linkServer(self, listenerChanged: .starting) }
            l.start(queue: queue)
        } catch {
            log?.add("listener could not start: \(error)")
            notify { $0.linkServer(self, listenerChanged: .failed(error.localizedDescription)) }
        }
    }

    public func stop() {
        lock.lock()
        let l = listener
        listener = nil
        let all = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        l?.cancel()
        all.forEach { $0.close() }
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        let p = NWParameters(tls: nil, tcp: tcp)
        // Lets the devices find each other over AWDL when Wi-Fi isolates clients or they're
        // on different networks.
        p.includePeerToPeer = true
        return p
    }

    // MARK: Pairing controls (call from the pairing screen)

    /// Opens pairing for 10 minutes and returns a fresh QR invite. Calling again replaces it.
    public func makeInvite() -> PairingInvite {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let inv = PairingInvite(inviteID: UUID(), macID: identity.id, macName: identity.name,
                                macPublicKey: key.publicKey.rawRepresentation, token: LinkCrypto.randomBytes(16))
        lock.lock()
        invite = ActiveInvite(invite: inv, privateKey: key, expires: Date().addingTimeInterval(PairingInvite.lifetime))
        pairingOpenUntil = Date().addingTimeInterval(PairingInvite.lifetime)
        lock.unlock()
        log?.add("pairing opened (QR + code)")
        return inv
    }

    /// Stops accepting new pairings (the pairing screen closed).
    public func closePairing() {
        lock.sync { invite = nil; pairingOpenUntil = nil }
    }

    public var isPairingOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return (pairingOpenUntil ?? .distantPast) > Date()
    }

    /// Forget a phone: delete the key and tell it, if it's connected, so it stops trying.
    public func forget(_ peerID: UUID) async {
        let s = lock.sync { sessions.removeValue(forKey: peerID) }
        if let s {
            try? await s.send(.unpair)
            s.close()
        }
        store.remove(peerID)
        log?.add("forgot a phone")
    }

    public var connectedPeerIDs: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return Set(sessions.keys)
    }

    /// Push the open apps/windows list to every connected phone.
    public func broadcastTargets(_ targets: [LiveTarget]) {
        lock.lock(); let all = Array(sessions.values); lock.unlock()
        for s in all { Task { try? await s.send(.targets(targets)) } }
    }

    /// The Send-to choice changed on the Mac (or arrived from one phone): tell every phone
    /// except `except`.
    public func broadcastSelection(_ selection: SendSelection, except: UUID? = nil) {
        lock.lock(); let all = sessions.filter { $0.key != except }.map(\.value); lock.unlock()
        for s in all { Task { try? await s.send(.selection(selection)) } }
    }

    /// Push the current profile list to every connected phone.
    public func broadcastProfiles(_ profiles: [ProfileSummary]) {
        let all = lock.sync { Array(sessions.values) }
        for s in all { Task { try? await s.send(.profiles(profiles)) } }
    }

    // MARK: Connections

    private func accept(_ nw: NWConnection) {
        let conn = FramedConnection(nw, queue: queue)
        conn.startAccepted()
        Task { await self.handle(conn) }
    }

    private func handle(_ conn: FramedConnection) async {
        do {
            let first = try await conn.receiveHandshake(timeout: 15)
            switch first {
            case let .clientHello(phoneID, nonce, version):
                try await runSession(conn, phoneID: phoneID, phoneNonce: nonce, version: version)
            case let .pairQR(phoneID, phoneName, phonePub, inviteID, proof, version):
                try await pairByQR(conn, phoneID: phoneID, phoneName: phoneName, phonePub: phonePub,
                                   inviteID: inviteID, proof: proof, version: version)
            case let .pairCodeCommit(phoneID, phoneName, commitment, version):
                try await pairByCode(conn, phoneID: phoneID, phoneName: phoneName, commitment: commitment, version: version)
            default:
                try? await conn.sendHandshake(.failure(reason: .protocolError))
                conn.cancel()
            }
        } catch {
            log?.add("connection ended: \(String(describing: error))")
            conn.cancel()
        }
    }

    // MARK: QR pairing

    private func pairByQR(_ conn: FramedConnection, phoneID: UUID, phoneName: String, phonePub: Data,
                          inviteID: UUID, proof: Data, version: Int) async throws {
        log?.add("QR pairing request")
        guard version == Product.protocolVersion else { return try await reject(conn, .versionMismatch) }
        let active = lock.sync { invite }
        guard let active else { return try await reject(conn, .notPairing) }
        guard active.expires > Date() else { return try await reject(conn, .expired) }
        guard active.invite.inviteID == inviteID else { return try await reject(conn, .badProof) }
        let expected = LinkCrypto.qrProof(token: active.invite.token, phonePub: phonePub, macPub: active.invite.macPublicKey)
        guard LinkCrypto.verify(proof, expected) else { return try await reject(conn, .badProof) }
        guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePub),
              let shared = try? active.privateKey.sharedSecretFromKeyAgreement(with: pub) else {
            return try await reject(conn, .badProof)
        }
        let key = LinkCrypto.pairKey(shared: shared, salt: active.invite.token, macID: identity.id, phoneID: phoneID)
        // Single use.
        lock.sync { invite = nil; pairingOpenUntil = nil }
        try await finishPairing(conn, phoneID: phoneID, phoneName: phoneName, key: key)
    }

    // MARK: Code pairing

    private func pairByCode(_ conn: FramedConnection, phoneID: UUID, phoneName: String, commitment: Data, version: Int) async throws {
        log?.add("code pairing request")
        guard version == Product.protocolVersion else { return try await reject(conn, .versionMismatch) }
        guard isPairingOpen else { return try await reject(conn, .notPairing) }
        // At most 5 tries in 10 minutes, one at a time.
        let tooMany = lock.sync { () -> Bool in
            codeAttempts = codeAttempts.filter { $0 > Date().addingTimeInterval(-600) }
            let tooMany = codeAttempts.count >= 5 || codePairingBusy
            if !tooMany { codeAttempts.append(Date()); codePairingBusy = true }
            return tooMany
        }
        guard !tooMany else { return try await reject(conn, .tooManyAttempts) }
        defer { lock.sync { codePairingBusy = false } }

        let key = Curve25519.KeyAgreement.PrivateKey()
        let macPub = key.publicKey.rawRepresentation
        let macNonce = LinkCrypto.randomBytes(32)
        try await conn.sendHandshake(.pairCodeMacKey(macID: identity.id, macName: identity.name, macPub: macPub, nonce: macNonce))
        guard case let .pairCodeReveal(phonePub, phoneNonce) = try await conn.receiveHandshake(timeout: 20) else {
            throw LinkError.protocolError("expected reveal")
        }
        guard LinkCrypto.verify(LinkCrypto.commitment(phonePub: phonePub, nonce: phoneNonce), commitment),
              let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePub),
              let shared = try? key.sharedSecretFromKeyAgreement(with: pub) else {
            return try await reject(conn, .badProof)
        }
        let code = LinkCrypto.confirmationCode(macPub: macPub, phonePub: phonePub, macNonce: macNonce, phoneNonce: phoneNonce)
        try await conn.sendHandshake(.pairCodeWaiting)

        // The person compares codes on the Mac; the code expires after 2 minutes. A race on a
        // continuation (not a task group, which would wait for the unanswered prompt).
        let approved = await withCheckedContinuation { (c: CheckedContinuation<Bool?, Never>) in
            let once = OnceFlag()
            Task { @MainActor [weak self] in
                guard let self, let d = self.delegate else { if once.claim() { c.resume(returning: false) }; return }
                let answer = await d.linkServer(self, approveCode: code, phoneName: phoneName)
                if once.claim() { c.resume(returning: answer) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                if once.claim() { c.resume(returning: nil) }
            }
        }
        // Whatever happened, the Mac's code prompt is over.
        notify { $0.linkServerCodePairingEnded(self) }
        guard let approved else { return try await reject(conn, .expired) }
        guard approved else { return try await reject(conn, .declined) }
        let pairKey = LinkCrypto.pairKey(shared: shared, salt: macNonce + phoneNonce, macID: identity.id, phoneID: phoneID)
        lock.sync { invite = nil; pairingOpenUntil = nil }
        try await finishPairing(conn, phoneID: phoneID, phoneName: phoneName, key: pairKey)
    }

    private func finishPairing(_ conn: FramedConnection, phoneID: UUID, phoneName: String, key: SymmetricKey) async throws {
        let peer = PairedPeer(id: phoneID, name: phoneName)
        store.save(peer, key: key)
        try await conn.sendHandshake(.pairAccepted(macID: identity.id, macName: identity.name, confirm: LinkCrypto.macConfirm(key)))
        log?.add("paired a phone")
        notify { $0.linkServer(self, didPair: peer) }
        // The phone opens a fresh session connection next; this one is done.
        conn.cancel()
    }

    private func reject(_ conn: FramedConnection, _ reason: PairRejection) async throws {
        log?.add("pairing rejected: \(reason.rawValue)")
        try? await conn.sendHandshake(.pairRejected(reason: reason))
        conn.cancel()
    }

    // MARK: Sessions

    private func runSession(_ conn: FramedConnection, phoneID: UUID, phoneNonce: Data, version: Int) async throws {
        guard version == Product.protocolVersion else {
            try? await conn.sendHandshake(.failure(reason: .versionMismatch)); conn.cancel(); return
        }
        guard phoneNonce.count == 32, let key = store.key(for: phoneID),
              var peer = store.peers().first(where: { $0.id == phoneID }) else {
            log?.add("session from an unknown phone")
            try? await conn.sendHandshake(.failure(reason: .unknownPeer)); conn.cancel(); return
        }
        let macNonce = LinkCrypto.randomBytes(32)
        try await conn.sendHandshake(.serverHello(macID: identity.id, nonce: macNonce,
                                                  proof: LinkCrypto.sessionProof(key, role: "mac", phoneNonce: phoneNonce, macNonce: macNonce)))
        guard case let .clientFinish(proof) = try await conn.receiveHandshake(timeout: 10),
              LinkCrypto.verify(proof, LinkCrypto.sessionProof(key, role: "phone", phoneNonce: phoneNonce, macNonce: macNonce)) else {
            log?.add("session proof failed")
            try? await conn.sendHandshake(.failure(reason: .badProof)); conn.cancel(); return
        }
        let keys = LinkCrypto.sessionKeys(key, phoneNonce: phoneNonce, macNonce: macNonce)
        let session = SecureSession(connection: conn, peerID: phoneID, sendKey: keys.macToPhone, receiveKey: keys.phoneToMac)

        let old = lock.sync { () -> SecureSession? in let o = sessions[phoneID]; sessions[phoneID] = session; return o }
        old?.close()
        store.touch(phoneID)
        log?.add("session open")

        defer {
            let mine = lock.sync { () -> Bool in
                let mine = sessions[phoneID] === session
                if mine { sessions.removeValue(forKey: phoneID) }
                return mine
            }
            session.close()
            if mine { notify { $0.linkServer(self, peerDisconnected: phoneID) } }
        }

        while true {
            let message = try await session.receive()
            switch message {
            case let .hello(phoneName, appVersion, os):
                // The phone may have been renamed since pairing: remember its current name.
                let name = phoneName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, name != peer.name {
                    peer.name = name
                    peer.lastSeen = Date()
                    store.save(peer, key: key)
                }
                let p = peer
                let profiles = await profilesOnMain()
                try await session.send(.welcome(macName: identity.name, appVersion: self.appVersion, profiles: profiles))
                try await session.send(.targets(await targetsOnMain()))
                notify { $0.linkServer(self, peerConnected: p, appVersion: appVersion, os: os) }
            case let .dictation(d, delayed):
                if seen.contains(d.id) {
                    log?.add("duplicate dictation ignored")
                    try await session.send(.ack(id: d.id, outcome: .duplicate, detail: nil))
                    continue
                }
                seen.insert(d.id)
                let (outcome, detail) = await deliverOnMain(d, delayed: delayed, from: peer)
                if outcome == .failed { seen.remove(d.id) }
                log?.add("dictation delivered: \(outcome.rawValue)\(delayed ? " (delayed)" : "")")
                try await session.send(.ack(id: d.id, outcome: outcome, detail: detail))
            case .ping:
                try await session.send(.pong)
            case .pong:
                break
            case .unpair:
                log?.add("phone unpaired itself")
                store.remove(phoneID)
                notify { $0.linkServer(self, didUnpair: phoneID) }
                return
            case let .selection(sel):
                broadcastSelection(sel, except: phoneID)
                let from = peer
                notify { $0.linkServer(self, selectionChanged: sel, from: from) }
            case .refreshTargets:
                notify { $0.linkServerRefreshTargets(self) }
            case .welcome, .profiles, .ack, .targets:
                break
            }
        }
    }

    @MainActor private func deliverOnMain(_ d: Dictation, delayed: Bool, from peer: PairedPeer) async -> (DeliveryOutcome, String?) {
        guard let delegate else { return (.failed, "Macrophone isn't ready") }
        return await delegate.linkServer(self, deliver: d, delayed: delayed, from: peer)
    }

    @MainActor private func targetsOnMain() -> [LiveTarget] {
        guard let delegate else { return [] }
        return delegate.liveTargets(self)
    }

    @MainActor private func profilesOnMain() -> [ProfileSummary] {
        delegate?.profilesForPhones(self) ?? []
    }

    private func notify(_ body: @escaping @MainActor (LinkServerDelegate) -> Void) {
        Task { @MainActor [weak self] in
            guard let d = self?.delegate else { return }
            body(d)
        }
    }
}

/// Recently seen dictation ids, persisted so a retry after a Mac restart is still caught.
final class SeenIDs: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var order: [UUID] = []
    private var set: Set<UUID> = []
    private let cap = 1000

    init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let ids = try? JSONDecoder().decode([UUID].self, from: d) {
            order = ids
            set = Set(ids)
        }
    }

    func contains(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return set.contains(id) }

    func insert(_ id: UUID) {
        lock.lock()
        if set.insert(id).inserted { order.append(id) }
        if order.count > cap { let drop = order.prefix(order.count - cap); drop.forEach { set.remove($0) }; order.removeFirst(drop.count) }
        let snapshot = order
        lock.unlock()
        persist(snapshot)
    }

    func remove(_ id: UUID) {
        lock.lock()
        set.remove(id)
        order.removeAll { $0 == id }
        let snapshot = order
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ ids: [UUID]) {
        guard let url, let d = try? JSONEncoder().encode(ids) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
