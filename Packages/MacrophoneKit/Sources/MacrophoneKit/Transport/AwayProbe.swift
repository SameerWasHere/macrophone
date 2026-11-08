import Foundation
import Network

// Test it (Nov 7 2026, the Tailscale guide): dial the active Mac's Tailscale address right now —
// at home too — and say whether the paired Mac answered there, or exactly why not. Phone side only:
// the Mac sees an ordinary hello on its away door that never finishes (no session, nothing new on
// the wire), and the link in use is never touched.

/// What a test of the away path found.
public enum AwayProbeResult: Equatable, Sendable {
    /// The paired Mac answered over Tailscale and proved it's ours: it works away from home.
    case works
    /// No Mac paired (or its key is gone).
    case notPaired
    /// The Mac hasn't told this phone a Tailscale address (Tailscale or Away from home is off there).
    case noAddress
    /// The Mac's Tailscale address answered, but nothing listens on Macrophone's port: Away from
    /// home (Remote access) is off on the Mac.
    case remoteOff
    /// Nothing answered at the Mac's Tailscale address: the Mac is asleep, offline, or Tailscale is
    /// off on it (or this phone isn't on the same tailnet).
    case unreachable
    /// Something answered that isn't this paired Mac (another Mac now has the address, or the
    /// pairing changed on the Mac).
    case notThisMac
}

extension LinkClient {
    /// Dials `addresses` (by default the active Mac's Tailscale address and name) on the away
    /// path, does the first half of the handshake and checks the Mac's proof, then closes. Never
    /// installs a session, never changes the link's state. Logs the outcome, never an address.
    public func probeAway(addresses: [RemoteAddress]? = nil, timeout: TimeInterval = 6) async -> AwayProbeResult {
        guard let mac = activeMac, let key = store.key(for: mac.id) else { return .notPaired }
        let list = addresses ?? RemoteAddressRule.ordered(mac.remoteAddresses).filter { $0.source == .mac && $0.isTailscale }
        guard !list.isEmpty else { log?.add("away test: no Tailscale address from the Mac"); return .noAddress }
        let queue = DispatchQueue(label: "macrophone.awayprobe")
        let refused = RefusedFlag()
        let conns = list.map { a -> FramedConnection in
            let c = FramedConnection(NWConnection(to: a.endpoint, using: LinkServer.awayParameters()), queue: queue)
            c.onState { state in
                switch state {
                case .waiting(let e), .failed(let e): if Self.isRefused(e) { refused.set() }
                default: break
                }
            }
            return c
        }
        defer { conns.forEach { $0.cancel() } }
        let winner: FramedConnection? = await withTaskGroup(of: FramedConnection?.self) { g in
            for c in conns { g.addTask { (try? await c.start(timeout: timeout)) != nil ? c : nil } }
            var w: FramedConnection?
            for await r in g where w == nil { if let r { w = r; g.cancelAll() } }
            return w
        }
        guard let conn = winner else {
            let result: AwayProbeResult = refused.isSet ? .remoteOff : .unreachable
            log?.add("away test: \(result == .remoteOff ? "the Mac's Tailscale address answered but its away door is shut" : "nothing answered at the Mac's Tailscale address")")
            return result
        }
        do {
            let nonce = LinkCrypto.randomBytes(32)
            try await conn.sendHandshake(.clientHello(phoneID: identity.id, nonce: nonce, version: Product.protocolVersion))
            switch try await conn.receiveHandshake(timeout: timeout) {
            case let .serverHello(macID, macNonce, proof):
                let ours = macID == mac.id && LinkCrypto.verify(proof, LinkCrypto.sessionProof(key, role: "mac", phoneNonce: nonce, macNonce: macNonce))
                log?.add(ours ? "away test: the Mac answered over Tailscale" : "away test: something else answered at the Mac's address")
                return ours ? .works : .notThisMac
            case .failure(.unknownPeer):
                log?.add("away test: the Mac at that address doesn't know this phone")
                return .notThisMac
            default:
                log?.add("away test: an unexpected reply")
                return .notThisMac
            }
        } catch LinkError.timedOut {
            log?.add("away test: connected, then no answer")
            return .unreachable
        } catch {
            // Connected, then cut off before the hello: a Mac with Away from home off closes a
            // connection from away at once.
            log?.add("away test: the Mac closed the connection (\(String(describing: error)))")
            return .remoteOff
        }
    }

    static func isRefused(_ e: NWError) -> Bool {
        if case .posix(let code) = e { return code == .ECONNREFUSED }
        return false
    }
}

private final class RefusedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
