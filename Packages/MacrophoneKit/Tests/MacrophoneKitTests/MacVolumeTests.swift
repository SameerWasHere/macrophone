import Foundation
import XCTest
@testable import MacrophoneKit

/// The Mac's volume on the phone (Nov 7 2026): its shape on the wire, the steps a drag sends, and
/// that only a phone that named it ever gets it.
final class MacVolumeTests: XCTestCase {
    func testItRoundTripsAndClamps() throws {
        let v = MacVolume(volume: 0.5625, muted: false)
        let data = try WireCoding.encoder.encode(Message.macVolume(v))
        guard case let .macVolume(back) = try WireCoding.decoder.decode(Message.self, from: data) else { return XCTFail("not a volume") }
        XCTAssertEqual(back, v)
        XCTAssertEqual(MacVolume(volume: 1.4, muted: false).volume, 1)
        XCTAssertEqual(MacVolume(volume: -0.2, muted: true).volume, 0)
    }

    func testADeviceWithNoVolumeLeavesItOut() throws {
        let v = MacVolume(volume: nil, muted: false)
        let json = String(decoding: try WireCoding.encoder.encode(v), as: UTF8.self)
        XCTAssertFalse(json.contains("volume"))
        XCTAssertEqual(try WireCoding.decoder.decode(MacVolume.self, from: Data(#"{"muted":true}"#.utf8)), MacVolume(volume: nil, muted: true))
        XCTAssertNil(v.line)
    }

    func testTheLine() {
        XCTAssertEqual(MacVolume(volume: 0.5625, muted: false).line, "Volume 56%")
        XCTAssertEqual(MacVolume(volume: 0.5625, muted: true).line, "Muted")
        XCTAssertEqual(MacVolume(volume: nil, muted: true).line, "Muted")
    }

    /// A drag from the real 56% to about 30% is four keys down — not five more on top of 56%.
    func testADragSendsTheKeysForTheDistanceDragged() {
        XCTAssertEqual(MacVolume.keys(from: 0.5625, to: 0.30), -4)
        XCTAssertEqual(MacVolume.keys(from: 0.5625, to: 0.5625), 0)
        XCTAssertEqual(MacVolume.keys(from: 0, to: 1), 16)
        XCTAssertEqual(MacVolume.keys(from: 0.5625, to: 1.3), 7)
        XCTAssertEqual(MacVolume.step(of: 0.56), 9)
    }

    func testItNeverRidesTheVideoLane() {
        XCTAssertFalse(VideoLane.rides(.macVolume(MacVolume(volume: 0.5, muted: false))))
    }

    // MARK: Over a real connection (loopback, the away door)

    func testAPhoneThatNamesItGetsTheVolumeAfterTheWelcomeAndWhenItChanges() async throws {
        let rig = try await Rig.make(port: 47931)
        defer { rig.stop() }
        rig.mac.volume = MacVolume(volume: 0.5625, muted: false)
        rig.server.macFeatures.append(MacVolume.feature)
        rig.client.features.append(MacVolume.feature)
        try await rig.connect()
        XCTAssertTrue(rig.client.macSendsVolume)
        try await rig.waitFor { rig.phone.volumes.count == 1 }
        XCTAssertEqual(rig.phone.volumes.first?.0, MacVolume(volume: 0.5625, muted: false))
        XCTAssertEqual(rig.phone.volumes.first?.1, rig.server.identity.id)
        // The Mac's own mute key: the phone hears it.
        let sent = await rig.server.sendMacVolume(MacVolume(volume: 0.5625, muted: true), to: rig.phoneID)
        XCTAssertTrue(sent)
        try await rig.waitFor { rig.phone.volumes.count == 2 }
        XCTAssertEqual(rig.phone.volumes.last?.0.muted, true)
        rig.server.broadcastMacVolume(MacVolume(volume: 0.25, muted: false))
        try await rig.waitFor { rig.phone.volumes.count == 3 }
        XCTAssertEqual(rig.phone.volumes.last?.0.volume, 0.25)
    }

    func testAnOlderPhoneNeverGetsIt() async throws {
        let rig = try await Rig.make(port: 47932)
        defer { rig.stop() }
        rig.mac.volume = MacVolume(volume: 0.5, muted: false)
        rig.server.macFeatures.append(MacVolume.feature)
        // The phone's hello doesn't name it.
        try await rig.connect()
        XCTAssertTrue(rig.client.macSendsVolume)
        let sent = await rig.server.sendMacVolume(MacVolume(volume: 0.5, muted: false), to: rig.phoneID)
        XCTAssertFalse(sent)
        rig.server.broadcastMacVolume(MacVolume(volume: 0.5, muted: false))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(rig.phone.volumes.isEmpty)
        XCTAssertEqual(rig.mac.volumeAsks, 0)
        // The session carries on (an unknown message would have ended it).
        let rtt = await rig.client.roundTrip(); XCTAssertNotNil(rtt)
    }

    func testAnOlderMacSaysNothingAndThePhoneKnowsIt() async throws {
        let rig = try await Rig.make(port: 47933)
        defer { rig.stop() }
        rig.mac.volume = MacVolume(volume: 0.5, muted: false)
        rig.client.features.append(MacVolume.feature)
        try await rig.connect()
        XCTAssertFalse(rig.client.macSendsVolume)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(rig.phone.volumes.isEmpty)
        XCTAssertEqual(rig.mac.volumeAsks, 0)
    }
}

extension MacSide: LinkServerVolumeDelegate {
    func macVolume(_ server: LinkServer, for peerID: UUID) -> MacVolume? {
        volumeAsks += 1
        return volume
    }
}

extension PhoneSide: LinkClientVolumeDelegate {
    func linkClient(_ client: LinkClient, macVolume: MacVolume, macID: UUID) {
        volumes.append((macVolume, macID))
    }
}
