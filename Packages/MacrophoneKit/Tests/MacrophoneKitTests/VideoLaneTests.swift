import CryptoKit
import Foundation
import XCTest
@testable import MacrophoneKit

/// The video lane's negotiation and its fallback (Oct 19 2026), and the Mac's permissions on the wire.
final class VideoLaneTests: XCTestCase {
    // MARK: The rule

    func testLaneOpensOnlyWhenBothNameItAndTheLinkIsAway() {
        let both = (phone: ["video", VideoLane.feature], mac: Set(["video", VideoLane.feature]))
        XCTAssertTrue(VideoLane.shouldOpen(phoneFeatures: both.phone, macFeatures: both.mac, remote: true, enabled: true))
        // At home: one connection, as before.
        XCTAssertFalse(VideoLane.shouldOpen(phoneFeatures: both.phone, macFeatures: both.mac, remote: false, enabled: true))
        // An older Mac (its welcome doesn't name it), an older phone, or switched off: as before.
        XCTAssertFalse(VideoLane.shouldOpen(phoneFeatures: both.phone, macFeatures: ["video"], remote: true, enabled: true))
        XCTAssertFalse(VideoLane.shouldOpen(phoneFeatures: ["video"], macFeatures: both.mac, remote: true, enabled: true))
        XCTAssertFalse(VideoLane.shouldOpen(phoneFeatures: both.phone, macFeatures: both.mac, remote: true, enabled: false))
    }

    func testOnlyPicturesRideTheLane() {
        let frame = WatchVideoFrame(seq: 1, data: Data([1, 2]), parameterSets: nil, keyframe: true, width: 2, height: 2,
                                    appName: "Claude", bundleID: nil, focus: nil)
        XCTAssertTrue(VideoLane.rides(.watchVideo(frame)))
        XCTAssertTrue(VideoLane.rides(.watchFrame(WatchFrame(seq: 1, jpeg: Data(), width: 2, height: 2, appName: "A", bundleID: nil, focus: nil))))
        for m: Message in [.ping, .pong, .watchClick(x: 0.5, y: 0.5), .watchKeyframe, .watchState(.live(appName: "A")),
                           .macPermissions(MacPermissions(accessibility: true, screenRecording: false))] {
            XCTAssertFalse(VideoLane.rides(m), "\(m)")
        }
    }

    func testLaneSecretsMatchOnBothSidesAndBelongToOneSession() {
        let key = SymmetricKey(size: .bits256)
        let pn = LinkCrypto.randomBytes(32), mn = LinkCrypto.randomBytes(32)
        let a = LaneSecrets(pairKey: key, phoneNonce: pn, macNonce: mn)
        let b = LaneSecrets(pairKey: key, phoneNonce: pn, macNonce: mn)
        XCTAssertEqual(a.phoneProof, b.phoneProof)
        XCTAssertEqual(a.macProof, b.macProof)
        XCTAssertNotEqual(a.phoneProof, a.macProof)
        XCTAssertEqual(a.macToPhone.rawData, b.macToPhone.rawData)
        XCTAssertNotEqual(a.macToPhone.rawData, a.phoneToMac.rawData)
        // Another session (new nonces) or another pairing: nothing carries over.
        let other = LaneSecrets(pairKey: key, phoneNonce: LinkCrypto.randomBytes(32), macNonce: mn)
        XCTAssertNotEqual(a.phoneProof, other.phoneProof)
        let stranger = LaneSecrets(pairKey: SymmetricKey(size: .bits256), phoneNonce: pn, macNonce: mn)
        XCTAssertNotEqual(a.phoneProof, stranger.phoneProof)
        // The lane's key is never the session's.
        let session = LinkCrypto.sessionKeys(key, phoneNonce: pn, macNonce: mn)
        XCTAssertNotEqual(a.macToPhone.rawData, session.macToPhone.rawData)
    }

    func testNewWireCasesRoundTrip() throws {
        let p = MacPermissions(accessibility: false, screenRecording: true)
        guard case let .macPermissions(back) = try WireCoding.decoder.decode(Message.self, from: WireCoding.encoder.encode(Message.macPermissions(p))) else {
            return XCTFail("not permissions")
        }
        XCTAssertEqual(back, p)
        guard case .showPermissions = try WireCoding.decoder.decode(Message.self, from: WireCoding.encoder.encode(Message.showPermissions)) else {
            return XCTFail("not showPermissions")
        }
        let id = UUID()
        let h = try WireCoding.decoder.decode(Handshake.self, from: WireCoding.encoder.encode(Handshake.laneHello(phoneID: id, proof: Data([9]))))
        guard case let .laneHello(back, proof) = h else { return XCTFail("not a lane hello") }
        XCTAssertEqual(back, id)
        XCTAssertEqual(proof, Data([9]))
    }

    func testPermissionWordsArePlain() {
        XCTAssertNil(MacPermissions(accessibility: true, screenRecording: true).missingLine)
        XCTAssertEqual(MacPermissions(accessibility: true, screenRecording: false).missingLine,
                       "Your Mac needs to allow Screen Recording — open Macrophone on your Mac")
        XCTAssertEqual(MacPermissions(accessibility: false, screenRecording: true).missingLine,
                       "Your Mac needs to allow Accessibility — open Macrophone on your Mac")
        XCTAssertTrue(MacPermissions(accessibility: false, screenRecording: false).missingLine!.contains("Accessibility and Screen Recording"))
    }

    // MARK: Over a real connection (loopback, the away door)

    func testLaneOpensAwayAndCarriesTheVideo() async throws {
        let rig = try await Rig.make(port: 47918)
        defer { rig.stop() }
        try await rig.connect()
        XCTAssertTrue(rig.client.isRemote)
        try await rig.waitFor { rig.client.hasVideoLane && rig.server.hasLane(rig.phoneID) }
        // A frame goes on the lane and arrives; a pong still comes back on the session.
        let frame = WatchVideoFrame(seq: 7, data: Data(repeating: 1, count: 40_000), parameterSets: nil, keyframe: true,
                                    width: 4, height: 4, appName: "Claude", bundleID: nil, focus: nil)
        let sent = await rig.server.send(.watchVideo(frame), to: rig.phoneID); XCTAssertTrue(sent)
        try await rig.waitFor { rig.phone.videoSeqs == [7] }
        XCTAssertEqual(rig.server.openSession(rig.phoneID)?.laneSlot.get()?.sent, 1)
        let rtt = await rig.client.roundTrip()
        XCTAssertNotNil(rtt)
    }

    func testAnOlderMacKeepsEverythingOnOneConnection() async throws {
        let rig = try await Rig.make(port: 47919)
        defer { rig.stop() }
        rig.server.laneEnabled = false   // its welcome doesn't name the lane
        try await rig.connect()
        XCTAssertFalse(rig.client.macFeatures.contains(VideoLane.feature))
        let frame = WatchVideoFrame(seq: 3, data: Data([1]), parameterSets: nil, keyframe: true, width: 2, height: 2,
                                    appName: "A", bundleID: nil, focus: nil)
        let sent = await rig.server.send(.watchVideo(frame), to: rig.phoneID); XCTAssertTrue(sent)
        try await rig.waitFor { rig.phone.videoSeqs == [3] }
        XCTAssertFalse(rig.client.hasVideoLane)
        XCTAssertFalse(rig.server.hasLane(rig.phoneID))
    }

    func testAnOlderPhoneKeepsEverythingOnOneConnection() async throws {
        let rig = try await Rig.make(port: 47917)
        defer { rig.stop() }
        rig.client.laneEnabled = false   // its hello doesn't name the lane
        try await rig.connect()
        XCTAssertTrue(rig.client.macFeatures.contains(VideoLane.feature))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(rig.client.hasVideoLane)
        XCTAssertFalse(rig.server.hasLane(rig.phoneID))
        // A lane hello from a phone that didn't name it is refused; the session carries on.
        let s = rig.server.openSession(rig.phoneID)!
        let conn = FramedConnection(NWConnectionFactory.loopback(port: 47917))
        try await conn.start(timeout: 3)
        try await conn.sendHandshake(.laneHello(phoneID: rig.phoneID, proof: s.laneSecrets!.phoneProof))
        guard case .failure = try await conn.receiveHandshake(timeout: 3) else { return XCTFail("lane wasn't refused") }
        conn.cancel()
        let rtt = await rig.client.roundTrip(); XCTAssertNotNil(rtt)
    }

    func testAWrongProofIsRefusedAndTheLaneFallsBackWhenItDrops() async throws {
        let rig = try await Rig.make(port: 47916)
        defer { rig.stop() }
        try await rig.connect()
        try await rig.waitFor { rig.server.hasLane(rig.phoneID) }
        // Someone else's hello (a made-up proof) never joins the session.
        let conn = FramedConnection(NWConnectionFactory.loopback(port: 47916))
        try await conn.start(timeout: 3)
        try await conn.sendHandshake(.laneHello(phoneID: rig.phoneID, proof: LinkCrypto.randomBytes(32)))
        guard case .failure = try await conn.receiveHandshake(timeout: 3) else { return XCTFail("bad proof wasn't refused") }
        conn.cancel()
        // The lane drops: the pictures come back on the session.
        rig.server.openSession(rig.phoneID)?.laneSlot.get()?.close()
        try await rig.waitFor { !rig.server.hasLane(rig.phoneID) }
        let frame = WatchVideoFrame(seq: 9, data: Data([1]), parameterSets: nil, keyframe: true, width: 2, height: 2,
                                    appName: "A", bundleID: nil, focus: nil)
        let sent = await rig.server.send(.watchVideo(frame), to: rig.phoneID); XCTAssertTrue(sent)
        try await rig.waitFor { rig.phone.videoSeqs.contains(9) }
        let rtt = await rig.client.roundTrip(); XCTAssertNotNil(rtt)
    }
}

import Network

enum NWConnectionFactory {
    static func loopback(port: UInt16) -> NWConnection {
        NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), using: LinkServer.awayParameters())
    }
}

/// A Mac and a phone already paired, on loopback through the away door (no Bonjour).
final class Rig: @unchecked Sendable {
    let server: LinkServer
    let client: LinkClient
    let mac: MacSide
    let phone: PhoneSide
    let phoneID: UUID
    let dir: URL

    private init(server: LinkServer, client: LinkClient, mac: MacSide, phone: PhoneSide, phoneID: UUID, dir: URL) {
        self.server = server; self.client = client; self.mac = mac; self.phone = phone; self.phoneID = phoneID; self.dir = dir
    }

    @MainActor
    static func make(port: UInt16) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lane-\(UUID().uuidString)")
        let key = SymmetricKey(size: .bits256)
        let macID = UUID(), phoneID = UUID()
        let macStore = FilePairingStore(url: dir.appendingPathComponent("mac.json"))
        macStore.save(PairedPeer(id: phoneID, name: "Test iPhone"), key: key)
        let phoneStore = FilePairingStore(url: dir.appendingPathComponent("phone.json"))
        phoneStore.save(PairedPeer(id: macID, name: "Test Mac", remoteAddresses: [RemoteAddress(host: "127.0.0.1", port: port, source: .typed)]), key: key)
        let server = LinkServer(identity: DeviceIdentity(id: macID, name: "Test Mac"), store: macStore, appVersion: "test", seenIDsURL: nil)
        let mac = MacSide()
        server.delegate = mac
        server.macFeatures = [WatchVideo.feature]
        server.setRemote(RemoteConfig(port: port))
        server.start()
        let client = LinkClient(identity: DeviceIdentity(id: phoneID, name: "Test iPhone"), store: phoneStore, appVersion: "test", osDescription: "test")
        let phone = PhoneSide()
        client.delegate = phone
        client.browsesBonjour = false
        client.features = [WatchVideo.feature, MacPermissions.feature]
        // The away door takes a moment to open.
        try await Task.sleep(nanoseconds: 300_000_000)
        return Rig(server: server, client: client, mac: mac, phone: phone, phoneID: phoneID, dir: dir)
    }

    func connect() async throws {
        client.start()
        try await client.connect()
    }

    func waitFor(_ seconds: TimeInterval = 4, _ check: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if check() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("timed out waiting")
    }

    func stop() {
        client.stop()
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }
}

@MainActor
final class MacSide: LinkServerDelegate {
    func linkServer(_ server: LinkServer, approveCode code: String, phoneName: String) async -> Bool { false }
    func linkServer(_ server: LinkServer, didPair peer: PairedPeer) {}
    func linkServer(_ server: LinkServer, didUnpair peerID: UUID) {}
    func linkServer(_ server: LinkServer, peerConnected peer: PairedPeer, appVersion: String, os: String) {}
    func linkServer(_ server: LinkServer, peerDisconnected peerID: UUID) {}
    func linkServer(_ server: LinkServer, deliver dictation: Dictation, delayed: Bool, from peer: PairedPeer) async -> (DeliveryOutcome, String?) { (.delivered, nil) }
    func linkServer(_ server: LinkServer, listenerChanged state: LinkServer.ListenerState) {}
}

@MainActor
final class PhoneSide: LinkClientDelegate {
    nonisolated(unsafe) var videoSeqs: [Int] = []
    func linkClient(_ client: LinkClient, stateChanged state: LinkClient.State) {}
    func linkClient(_ client: LinkClient, discovered macs: [DiscoveredMac]) {}
    func linkClient(_ client: LinkClient, unpairedBy macID: UUID) {}
    func linkClient(_ client: LinkClient, watchVideo: WatchVideoFrame) { videoSeqs.append(watchVideo.seq) }
}
