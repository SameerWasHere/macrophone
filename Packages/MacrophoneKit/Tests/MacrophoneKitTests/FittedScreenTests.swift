import XCTest
@testable import MacrophoneKit

/// The Whole Screen fitted to the iPhone (Nov 16 2026): the size rule, the wire, and that neither
/// message ever reaches a peer that didn't name the feature.
final class FittedScreenTests: XCTestCase {
    func testTheSizeForAView() throws {
        // The Duo's inner screen, upright: half as big again, the same shape.
        let duo = try XCTUnwrap(FittedScreen.size(forView: 669, 951))
        XCTAssertEqual(duo, FittedScreenSize(width: 1004, height: 1426))
        XCTAssertEqual(duo.pixelsWide, 2008)
        // On its side.
        XCTAssertEqual(FittedScreen.size(forView: 951, 669), FittedScreenSize(width: 1426, height: 1004))
        // A Pro in full screen under the island: never narrower than 640, the shape kept.
        let pro = try XCTUnwrap(FittedScreen.size(forView: 402, 812))
        XCTAssertEqual(pro.width, 640)
        XCTAssertEqual(pro.aspect, 402.0 / 812.0, accuracy: 0.004)
        // The long side is capped (3,840 pixels), the shape kept.
        let big = try XCTUnwrap(FittedScreen.size(forView: 1400, 900))
        XCTAssertEqual(big.width, 1920)
        XCTAssertEqual(big.aspect, 1400.0 / 900.0, accuracy: 0.004)
        // Always even (a HiDPI mode's points).
        for (w, h) in [(382.0, 424.0), (438.0, 475.0), (645.0, 393.0), (355.0, 441.0)] {
            let s = try XCTUnwrap(FittedScreen.size(forView: w, h))
            XCTAssertEqual(s.width % 2, 0); XCTAssertEqual(s.height % 2, 0)
            XCTAssertGreaterThanOrEqual(s.width, 640)
            XCTAssertLessThanOrEqual(max(s.width, s.height), 1920)
            XCTAssertEqual(s.aspect, w / h, accuracy: 0.004)
        }
    }

    func testWhatIsNotAScreen() {
        XCTAssertNil(FittedScreen.size(forView: 0, 0))
        XCTAssertNil(FittedScreen.size(forView: 645, 117), "a strip mid-layout")
        XCTAssertNil(FittedScreen.size(forView: 200, 900), "narrower than any phone")
        XCTAssertNil(FittedScreen.size(forView: .nan, 500))
        XCTAssertNil(FittedScreenRequest(on: false, width: 669, height: 951).size)
        XCTAssertNotNil(FittedScreenRequest(on: true, width: 669, height: 951).size)
    }

    func testRemakingOnlyForARealChange() {
        let a = FittedScreenSize(width: 1004, height: 1426)
        XCTAssertFalse(FittedScreen.differs(a, a))
        XCTAssertFalse(FittedScreen.differs(a, FittedScreenSize(width: 1008, height: 1420)), "a layout settling")
        XCTAssertTrue(FittedScreen.differs(a, FittedScreenSize(width: 1426, height: 1004)), "turned")
        XCTAssertTrue(FittedScreen.differs(a, FittedScreenSize(width: 1004, height: 1300)), "the keyboard's room is another screen")
    }

    func testTheWire() throws {
        let messages: [Message] = [.screenFit(FittedScreenRequest(on: true, width: 669, height: 951)), .screenFit(FittedScreenRequest(on: false)),
                                   .screenFitState(FittedScreenState(on: true, key: "ABC", width: 1004, height: 1426)),
                                   .screenFitState(FittedScreenState(on: false, reason: "This Mac can't make a screen that shape"))]
        for m in messages {
            let data = try WireCoding.encoder.encode(m)
            switch (m, try WireCoding.decoder.decode(Message.self, from: data)) {
            case let (.screenFit(a), .screenFit(b)): XCTAssertEqual(a, b)
            case let (.screenFitState(a), .screenFitState(b)): XCTAssertEqual(a, b)
            default: XCTFail("came back as something else")
            }
            XCTAssertFalse(VideoLane.rides(m))
        }
        // Fields a newer peer adds, and ones an older one leaves out, never break it.
        XCTAssertEqual(try WireCoding.decoder.decode(FittedScreenRequest.self, from: Data(#"{"on":false,"inset":12}"#.utf8)), FittedScreenRequest(on: false))
        let s = try WireCoding.decoder.decode(FittedScreenState.self, from: Data(#"{"on":true,"width":640,"height":1292,"scale":2}"#.utf8))
        XCTAssertEqual(s.size, FittedScreenSize(width: 640, height: 1292))
        XCTAssertNil(FittedScreenState.off.size)
    }

    // MARK: Over a real connection (loopback)

    func testAskedAndAnswered() async throws {
        let rig = try await Rig.make(port: 47951)
        defer { rig.stop() }
        rig.server.macFeatures.append(FittedScreen.feature)
        rig.client.features.append(FittedScreen.feature)
        try await rig.connect()
        XCTAssertTrue(rig.client.macFitsScreen)
        XCTAssertTrue(rig.client.screenFit(FittedScreenRequest(on: true, width: 669, height: 951)))
        try await rig.waitFor { rig.mac.screenFits.count == 1 }
        XCTAssertEqual(rig.mac.screenFits.first?.0.size, FittedScreenSize(width: 1004, height: 1426))
        XCTAssertEqual(rig.mac.screenFits.first?.1, rig.phoneID)
        let sent = await rig.server.sendScreenFit(FittedScreenState(on: true, key: "K", width: 1004, height: 1426), to: rig.phoneID)
        XCTAssertTrue(sent)
        try await rig.waitFor { rig.phone.screenStates.count == 1 }
        XCTAssertEqual(rig.phone.screenStates.first?.key, "K")
    }

    func testAnOlderPhoneNeverHearsAndAnOlderMacIsNeverAsked() async throws {
        // A phone from before: the Mac's state never goes to it.
        let a = try await Rig.make(port: 47952)
        a.server.macFeatures.append(FittedScreen.feature)
        try await a.connect()
        let sent = await a.server.sendScreenFit(.off, to: a.phoneID)
        XCTAssertFalse(sent)
        let rtt = await a.client.roundTrip(); XCTAssertNotNil(rtt)
        a.stop()
        // A Mac from before: the phone can't ask.
        let b = try await Rig.make(port: 47953)
        defer { b.stop() }
        b.client.features.append(FittedScreen.feature)
        try await b.connect()
        XCTAssertFalse(b.client.macFitsScreen)
        XCTAssertFalse(b.client.screenFit(FittedScreenRequest(on: true, width: 669, height: 951)))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(b.mac.screenFits.isEmpty)
    }
}

extension MacSide: LinkServerFittedScreenDelegate {
    func linkServer(_ server: LinkServer, screenFit request: FittedScreenRequest, from peerID: UUID) {
        screenFits.append((request, peerID))
    }
}

extension PhoneSide: LinkClientFittedScreenDelegate {
    func linkClient(_ client: LinkClient, screenFit state: FittedScreenState, macID: UUID) {
        screenStates.append(state)
    }
}
