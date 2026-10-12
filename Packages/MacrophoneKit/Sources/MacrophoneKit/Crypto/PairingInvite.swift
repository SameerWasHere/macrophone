import CryptoKit
import Foundation

public enum LinkError: Error, Sendable, CustomStringConvertible {
    case protocolError(String)
    case connectionFailed(String)
    case timedOut
    case notPaired
    case macNotFound
    case rejected(PairRejection)
    case handshake(HandshakeFailure)
    case cancelled

    public var description: String {
        switch self {
        case .protocolError(let s): return "Protocol error: \(s)"
        case .connectionFailed(let s): return "Connection failed: \(s)"
        case .timedOut: return "Timed out"
        case .notPaired: return "Not paired"
        case .macNotFound: return "Mac not found"
        case .rejected(let r): return r.message
        case .handshake(let f): return "Handshake failed (\(f.rawValue))"
        case .cancelled: return "Cancelled"
        }
    }

    /// Plain words for a status line.
    public var userMessage: String {
        switch self {
        case .rejected(let r): return r.message
        case .handshake(.unknownPeer): return "This Mac no longer knows this iPhone. Pair again."
        case .handshake(.versionMismatch): return "Update Macrophone on both devices."
        case .macNotFound: return "Mac not found."
        case .timedOut: return "The Mac didn't answer in time."
        default: return "Couldn't reach your Mac."
        }
    }
}

/// What the Mac's QR code carries: who it is, and a one-time secret. Single use, expires
/// after 10 minutes. Rendered as
/// `macrophone://pair?v=1&i=<invite>&m=<macID>&n=<name>&k=<pubkey>&t=<token>`.
public struct PairingInvite: Sendable, Equatable {
    public static let lifetime: TimeInterval = 600

    public var inviteID: UUID
    public var macID: UUID
    public var macName: String
    public var macPublicKey: Data
    public var token: Data
    public var version: Int

    public init(inviteID: UUID, macID: UUID, macName: String, macPublicKey: Data, token: Data, version: Int = Product.protocolVersion) {
        self.inviteID = inviteID
        self.macID = macID
        self.macName = macName
        self.macPublicKey = macPublicKey
        self.token = token
        self.version = version
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Product.urlScheme
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "i", value: inviteID.uuidString),
            URLQueryItem(name: "m", value: macID.uuidString),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "k", value: macPublicKey.base64URL),
            URLQueryItem(name: "t", value: token.base64URL),
        ]
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == Product.urlScheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func q(_ k: String) -> String? { items.first { $0.name == k }?.value }
        guard let v = q("v").flatMap(Int.init),
              let i = q("i").flatMap(UUID.init(uuidString:)),
              let m = q("m").flatMap(UUID.init(uuidString:)),
              let n = q("n"),
              let k = q("k").flatMap(Data.init(base64URL:)), k.count == 32,
              let t = q("t").flatMap(Data.init(base64URL:)), t.count >= 16 else { return nil }
        self.init(inviteID: i, macID: m, macName: n, macPublicKey: k, token: t, version: v)
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }
}

extension Data {
    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
