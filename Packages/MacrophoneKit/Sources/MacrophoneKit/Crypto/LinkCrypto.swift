import CryptoKit
import Foundation

/// All key math for pairing and sessions. Pure functions, no I/O — the unit tests drive both
/// sides of every exchange through here.
public enum LinkCrypto {
    static let pairInfo = Data("macrophone-pair-v1".utf8)

    public static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    // MARK: Pairing

    /// The long-lived pairing key both sides store. Bound to both ids so a key can't be
    /// replayed for a different pair of devices.
    static func pairKey(shared: SharedSecret, salt: Data, macID: UUID, phoneID: UUID) -> SymmetricKey {
        var info = pairInfo
        info.append(macID.data)
        info.append(phoneID.data)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
    }

    /// QR pairing proof: only someone who read the QR (and so knows the token) can make it.
    static func qrProof(token: Data, phonePub: Data, macPub: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: phonePub + macPub, using: SymmetricKey(data: token)))
    }

    static func commitment(phonePub: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: phonePub + nonce))
    }

    /// Six digits both screens show, e.g. "482 913". Depends on both keys and both nonces;
    /// the phone committed to its key before seeing the Mac's, so a man in the middle gets
    /// one guess in a million per attempt, and attempts are rate limited.
    public static func confirmationCode(macPub: Data, phonePub: Data, macNonce: Data, phoneNonce: Data) -> String {
        let digest = Array(SHA256.hash(data: Data("macrophone-sas".utf8) + macPub + phonePub + macNonce + phoneNonce))
        let n = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let s = String(format: "%06u", n)
        return String(s.prefix(3)) + " " + String(s.suffix(3))
    }

    static func macConfirm(_ key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("mac-confirm".utf8), using: key))
    }

    // MARK: Session

    static func sessionProof(_ key: SymmetricKey, role: String, phoneNonce: Data, macNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(role.utf8) + phoneNonce + macNonce, using: key))
    }

    static func verify(_ mac: Data, _ expected: Data) -> Bool {
        guard mac.count == expected.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(mac, expected) { diff |= a ^ b }
        return diff == 0
    }

    /// Two keys per connection — one per direction — fresh for every connection.
    static func sessionKeys(_ pairKey: SymmetricKey, phoneNonce: Data, macNonce: Data) -> (phoneToMac: SymmetricKey, macToPhone: SymmetricKey) {
        let salt = phoneNonce + macNonce
        let p2m = HKDF<SHA256>.deriveKey(inputKeyMaterial: pairKey, salt: salt, info: Data("p2m".utf8), outputByteCount: 32)
        let m2p = HKDF<SHA256>.deriveKey(inputKeyMaterial: pairKey, salt: salt, info: Data("m2p".utf8), outputByteCount: 32)
        return (p2m, m2p)
    }
}

/// Seals session frames in one direction. Nonces are a strictly increasing counter, so a
/// replayed, dropped or re-ordered frame fails to open and the connection is closed.
/// Each direction has its own key and its own half, so sending and receiving never share state.
public struct FrameSealer: Sendable {
    let key: SymmetricKey
    var counter: UInt64 = 0
    init(key: SymmetricKey) { self.key = key }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.nonce(counter))
        counter += 1
        return Data(box.ciphertext) + Data(box.tag)
    }
}

public struct FrameOpener: Sendable {
    let key: SymmetricKey
    var counter: UInt64 = 0
    init(key: SymmetricKey) { self.key = key }

    mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= 16 else { throw LinkError.protocolError("short frame") }
        let box = try ChaChaPoly.SealedBox(nonce: FrameSealer.nonce(counter),
                                           ciphertext: frame.dropLast(16), tag: frame.suffix(16))
        let plain = try ChaChaPoly.open(box, using: key)
        counter += 1
        return plain
    }
}

extension UUID {
    var data: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}
