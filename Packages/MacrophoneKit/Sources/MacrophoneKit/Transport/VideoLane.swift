import CryptoKit
import Foundation
import Network

// The video lane (Oct 19 2026): away from home, the window's pictures ride a second connection
// of their own, so one lost packet of video never holds up a tap, a key, a pong or an answer.
//
// Why not QUIC: Network.framework only does a pre-shared key over TLS 1.2 (adding one pins the
// handshake's highest version to 1.2 — boringssl logs `max_version(0x0303)`), and QUIC needs TLS
// 1.3, so QUIC with the pair key fails with NO_SUPPORTED_VERSIONS_ENABLED (-9858). QUIC with a
// certificate would need a signing identity made and kept in a keychain on his Mac. The lane gets
// what mattered from QUIC's streams — loss on the video never blocks input or control — with the
// same TCP, keys and handshake as today. (docs: CLAUDE.md "The video lane".)
//
// How it's negotiated: the Mac's welcome names `VideoLane.feature`; a phone whose hello named it
// too, connected from away, dials the same address again and sends `Handshake.laneHello` with a
// proof made from the pair key and this session's two nonces. The Mac checks it against the open
// session, answers `laneReady` with its own proof, and from then on `.watchVideo` / `.watchFrame`
// go on the lane, sealed under their own key and counter; everything else stays on the session.
// Anything else — an older phone, an older Mac, at home, a lane that doesn't open or drops — and
// every message goes on the session exactly as before.

public enum VideoLane {
    public static let feature = "videoLane"

    /// The messages that ride the lane: the window's pictures and video, nothing else.
    static func rides(_ message: Message) -> Bool {
        switch message {
        case .watchVideo, .watchFrame: return true
        default: return false
        }
    }

    /// Whether a session should open a lane: both ends named it, and it runs from away (at home,
    /// Bonjour and the direct link stay one connection, as before).
    public static func shouldOpen(phoneFeatures: [String], macFeatures: Set<String>, remote: Bool, enabled: Bool) -> Bool {
        enabled && remote && phoneFeatures.contains(feature) && macFeatures.contains(feature)
    }
}

/// One session's lane secrets: derived from the pair key and the session's two nonces, so a lane
/// can only join the session it was made for, and its frames have a key of their own.
struct LaneSecrets: Sendable {
    let phoneProof: Data
    let macProof: Data
    let macToPhone: SymmetricKey
    let phoneToMac: SymmetricKey

    init(pairKey: SymmetricKey, phoneNonce: Data, macNonce: Data) {
        let salt = phoneNonce + macNonce
        phoneProof = Data(HMAC<SHA256>.authenticationCode(for: Data("lane-phone".utf8) + salt, using: pairKey))
        macProof = Data(HMAC<SHA256>.authenticationCode(for: Data("lane-mac".utf8) + salt, using: pairKey))
        macToPhone = HKDF<SHA256>.deriveKey(inputKeyMaterial: pairKey, salt: salt, info: Data("m2p-lane".utf8), outputByteCount: 32)
        phoneToMac = HKDF<SHA256>.deriveKey(inputKeyMaterial: pairKey, salt: salt, info: Data("p2m-lane".utf8), outputByteCount: 32)
    }
}

/// The lane itself: one connection, its frames sealed one way with their own counter.
final class LaneLink: @unchecked Sendable {
    let connection: FramedConnection
    private var sealer: FrameSealer
    private var opener: FrameOpener
    private let sendLock = AsyncLock()
    private let lock = NSLock()
    private(set) var sent = 0
    private(set) var received = 0

    init(connection: FramedConnection, sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.connection = connection
        self.sealer = FrameSealer(key: sendKey)
        self.opener = FrameOpener(key: receiveKey)
    }

    func send(_ message: Message) async throws {
        try await sendLock.withLock {
            let plain = try WireCoding.encoder.encode(message)
            let sealed = try self.sealer.seal(plain)
            try await self.connection.send(sealed)
            self.lock.sync { self.sent += 1 }
        }
    }

    /// Only one task reads a lane (its loop).
    func receive() async throws -> Message {
        let frame = try await connection.receive()
        let plain: Data
        do { plain = try opener.open(frame) } catch { throw LinkError.protocolError("lane frame failed to open") }
        lock.sync { received += 1 }
        do { return try WireCoding.decoder.decode(Message.self, from: plain) } catch {
            throw LinkError.protocolError("unreadable lane message")
        }
    }

    func close() { connection.cancel() }
}

extension SecureSession {
    /// The session carries a lane now (the pictures go there).
    public var hasLane: Bool { laneSlot.get() != nil }

    /// Keeps the first lane only: a second hello for the same session is refused.
    func attachLane(_ lane: LaneLink) -> Bool { laneSlot.attach(lane) }

    /// The lane went (closed, failed): the pictures go back on the session.
    func detachLane(_ lane: LaneLink) {
        if laneSlot.detach(lane) { lane.close() }
    }
}

/// Holds a session's lane under a lock (a session's sends come from many tasks).
final class LaneSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var lane: LaneLink?
    private var closed = false

    func get() -> LaneLink? { lock.sync { lane } }

    func attach(_ l: LaneLink) -> Bool {
        lock.sync {
            guard lane == nil, !closed else { return false }
            lane = l
            return true
        }
    }

    @discardableResult
    func detach(_ l: LaneLink) -> Bool {
        lock.sync {
            guard lane === l else { return false }
            lane = nil
            return true
        }
    }

    /// The session closed: no lane can join it any more.
    func closeAll() {
        let l = lock.sync { () -> LaneLink? in closed = true; let v = lane; lane = nil; return v }
        l?.close()
    }
}

// MARK: The Mac's side

extension LinkServer {
    /// A lane hello on a fresh connection: join it to that phone's open session, or close it.
    func acceptLane(_ conn: FramedConnection, phoneID: UUID, proof: Data) async {
        guard laneEnabled, let s = openSession(phoneID), let secrets = s.laneSecrets,
              phoneFeatures(phoneID).contains(VideoLane.feature),
              LinkCrypto.verify(proof, secrets.phoneProof), !s.hasLane else {
            log?.add("video lane refused")
            try? await conn.sendHandshake(.failure(reason: .badProof))
            conn.cancel()
            return
        }
        do {
            try await conn.sendHandshake(.laneReady(proof: secrets.macProof))
        } catch {
            conn.cancel()
            return
        }
        let lane = LaneLink(connection: conn, sendKey: secrets.macToPhone, receiveKey: secrets.phoneToMac)
        guard s.attachLane(lane) else { conn.cancel(); return }
        log?.add("video lane open: pictures go on their own connection")
        // The phone never writes on the lane: a read comes back only when it closes.
        _ = try? await conn.receive()
        s.detachLane(lane)
        log?.add("video lane closed after \(lane.sent) frames: pictures back on the session")
    }
}

// MARK: The phone's side

extension LinkClient {
    /// Dials the lane for a session that just opened from away (the same address it won on).
    /// Everything that fails here leaves the session as it is: the pictures stay on it.
    func openLane(for s: SecureSession, endpoint: NWEndpoint, macID: UUID) {
        guard let secrets = s.laneSecrets else { return }
        let laneQueue = DispatchQueue(label: "macrophone.lane")
        Task.detached { [weak self] in
            guard let self else { return }
            let t0 = Date()
            let conn = FramedConnection(NWConnection(to: endpoint, using: LinkServer.awayParameters()), queue: laneQueue)
            var lane: LaneLink?
            do {
                try await conn.start(timeout: 5)
                try await conn.sendHandshake(.laneHello(phoneID: self.identity.id, proof: secrets.phoneProof))
                guard case let .laneReady(proof) = try await conn.receiveHandshake(timeout: 5),
                      LinkCrypto.verify(proof, secrets.macProof) else {
                    throw LinkError.protocolError("lane refused")
                }
                let l = LaneLink(connection: conn, sendKey: secrets.phoneToMac, receiveKey: secrets.macToPhone)
                guard self.isCurrentSession(s), s.attachLane(l) else { conn.cancel(); return }
                lane = l
                self.log?.add("video lane open in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                while true {
                    let m = try await l.receive()
                    guard VideoLane.rides(m) else { continue }
                    self.handle(m, from: s, macID: macID)
                }
            } catch {
                if let lane {
                    s.detachLane(lane)
                    self.log?.add("video lane closed after \(lane.received) frames")
                } else {
                    conn.cancel()
                    self.log?.add("video lane didn't open (\(conn.lastFailure ?? "refused")): pictures stay on the main link")
                }
            }
        }
    }
}
