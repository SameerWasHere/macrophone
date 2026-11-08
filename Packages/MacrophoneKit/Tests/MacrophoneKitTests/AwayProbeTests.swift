import CryptoKit
import XCTest
@testable import MacrophoneKit

/// The Tailscale guide's Test it (Nov 7 2026): the paired Mac answering on the away door is
/// "works"; a shut door, nothing there, or someone else each say so.
final class AwayProbeTests: XCTestCase {
    private func here(_ port: UInt16) -> [RemoteAddress] { [RemoteAddress(host: "127.0.0.1", port: port, source: .mac)] }

    func testThePairedMacAnsweringWorksAndLeavesNoSession() async throws {
        let rig = try await Rig.make(port: 47941)
        defer { rig.stop() }
        let result = await rig.client.probeAway(addresses: here(47941), timeout: 3)
        XCTAssertEqual(result, .works)
        XCTAssertFalse(rig.client.isConnected, "a test never installs a session")
        // And the real link still connects afterwards.
        try await rig.connect()
        XCTAssertTrue(rig.client.isConnected)
    }

    func testNothingListeningIsTheMacsAwayDoorShut() async throws {
        let rig = try await Rig.make(port: 47942)
        defer { rig.stop() }
        let result = await rig.client.probeAway(addresses: here(47949), timeout: 3)
        XCTAssertEqual(result, .remoteOff)
    }

    func testAnotherMacAtTheAddressIsNotThisMac() async throws {
        let rig = try await Rig.make(port: 47943)
        defer { rig.stop() }
        // A phone paired with a Mac of the same id under another key: the proof can't match.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FilePairingStore(url: dir.appendingPathComponent("phone.json"))
        let macID = rig.client.activeMac!.id
        store.save(PairedPeer(id: macID, name: "Test Mac"), key: SymmetricKey(size: .bits256))
        let other = LinkClient(identity: DeviceIdentity(id: rig.phoneID, name: "Test iPhone"), store: store, appVersion: "test", osDescription: "test")
        let result = await other.probeAway(addresses: here(47943), timeout: 3)
        XCTAssertEqual(result, .notThisMac)
    }

    func testNoTailscaleAddressFromTheMacSaysSo() async throws {
        let rig = try await Rig.make(port: 47944)
        defer { rig.stop() }
        // The rig's stored address is a typed loopback one, not a Tailscale address from the Mac.
        let result = await rig.client.probeAway(timeout: 2)
        XCTAssertEqual(result, .noAddress)
    }
}
