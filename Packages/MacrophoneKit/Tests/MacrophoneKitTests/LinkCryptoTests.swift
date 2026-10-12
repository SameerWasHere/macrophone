import CryptoKit
import XCTest
@testable import MacrophoneKit

final class LinkCryptoTests: XCTestCase {
    func testInviteRoundTrip() {
        let inv = PairingInvite(inviteID: UUID(), macID: UUID(), macName: "Sameer’s MacBook Pro",
                                macPublicKey: LinkCrypto.randomBytes(32), token: LinkCrypto.randomBytes(16))
        XCTAssertEqual(PairingInvite(url: inv.url), inv)
        XCTAssertNil(PairingInvite(string: "https://example.com"))
    }

    func testBothSidesDeriveTheSameCodeAndKey() throws {
        let mac = Curve25519.KeyAgreement.PrivateKey(), phone = Curve25519.KeyAgreement.PrivateKey()
        let mn = LinkCrypto.randomBytes(32), pn = LinkCrypto.randomBytes(32)
        let a = LinkCrypto.confirmationCode(macPub: mac.publicKey.rawRepresentation, phonePub: phone.publicKey.rawRepresentation, macNonce: mn, phoneNonce: pn)
        XCTAssertEqual(a.count, 7)
        let macID = UUID(), phoneID = UUID()
        let k1 = LinkCrypto.pairKey(shared: try mac.sharedSecretFromKeyAgreement(with: phone.publicKey), salt: mn + pn, macID: macID, phoneID: phoneID)
        let k2 = LinkCrypto.pairKey(shared: try phone.sharedSecretFromKeyAgreement(with: mac.publicKey), salt: mn + pn, macID: macID, phoneID: phoneID)
        XCTAssertEqual(k1.rawData, k2.rawData)
        // A different phone id gives a different key.
        let k3 = LinkCrypto.pairKey(shared: try mac.sharedSecretFromKeyAgreement(with: phone.publicKey), salt: mn + pn, macID: macID, phoneID: UUID())
        XCTAssertNotEqual(k1.rawData, k3.rawData)
    }

    func testSealedFramesRejectTamperReplayAndWrongDirection() throws {
        let pairKey = SymmetricKey(size: .bits256)
        let keys = LinkCrypto.sessionKeys(pairKey, phoneNonce: LinkCrypto.randomBytes(32), macNonce: LinkCrypto.randomBytes(32))
        var phoneOut = FrameSealer(key: keys.phoneToMac)
        var macIn = FrameOpener(key: keys.phoneToMac)
        let f1 = try phoneOut.seal(Data("one".utf8))
        let f2 = try phoneOut.seal(Data("two".utf8))
        XCTAssertEqual(try macIn.open(f1), Data("one".utf8))
        // Replay of frame 1 fails (counter moved on).
        XCTAssertThrowsError(try macIn.open(f1))
        var tampered = Data(f2); tampered[0] ^= 1
        var macIn2 = FrameOpener(key: keys.phoneToMac); _ = try macIn2.open(f1)
        XCTAssertThrowsError(try macIn2.open(tampered))
        // The other direction's key can't open it.
        var wrong = FrameOpener(key: keys.macToPhone)
        XCTAssertThrowsError(try wrong.open(f1))
    }

    func testSessionProofsDifferByRole() {
        let k = SymmetricKey(size: .bits256), a = LinkCrypto.randomBytes(32), b = LinkCrypto.randomBytes(32)
        XCTAssertNotEqual(LinkCrypto.sessionProof(k, role: "mac", phoneNonce: a, macNonce: b),
                          LinkCrypto.sessionProof(k, role: "phone", phoneNonce: a, macNonce: b))
    }
}

final class HistoryStoreTests: XCTestCase {
    func testRollingAndOff() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let h = HistoryStore<Dictation>(url: url, capacity: 3, enabled: true)
        for i in 0..<5 { h.add(Dictation(raw: "item \(i)")) }
        XCTAssertEqual(h.all.map(\.raw), ["item 4", "item 3", "item 2"])
        h.isEnabled = false
        XCTAssertTrue(h.all.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        h.add(Dictation(raw: "in memory"))
        XCTAssertEqual(h.latest?.raw, "in memory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
