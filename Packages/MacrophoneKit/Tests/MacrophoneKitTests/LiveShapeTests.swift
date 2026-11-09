import CoreGraphics
import Foundation
@testable import MacrophoneKit
import XCTest

/// The window's shape while the finger drags its corner (Nov 9 2026): `watchShapeLive` on the
/// wire, the phone's throttle, and the fallback to one `watchShape` on release for a Mac from before.
final class LiveShapeTests: XCTestCase {
    func testTheMessageRoundTrips() throws {
        for final in [false, true] {
            let data = try WireCoding.encoder.encode(Message.watchShapeLive(width: 382, height: 576, final: final))
            let back = try WireCoding.decoder.decode(Message.self, from: data)
            guard case let .watchShapeLive(w, h, f) = back else { return XCTFail("not a live shape") }
            XCTAssertEqual(w, 382); XCTAssertEqual(h, 576); XCTAssertEqual(f, final)
        }
    }

    func testALiveShapeIsDueOnlyAfterTheIntervalAndAMove() {
        let t0 = Date()
        // Nothing sent yet: due.
        XCTAssertTrue(WatchShape.liveShapeDue(size: CGSize(width: 382, height: 576), lastSent: nil, lastAt: nil, now: t0))
        // Too soon after the last one.
        XCTAssertFalse(WatchShape.liveShapeDue(size: CGSize(width: 300, height: 576), lastSent: CGSize(width: 382, height: 576), lastAt: t0, now: t0.addingTimeInterval(0.05)))
        // Late enough, but the aspect hardly moved.
        XCTAssertFalse(WatchShape.liveShapeDue(size: CGSize(width: 383, height: 576), lastSent: CGSize(width: 382, height: 576), lastAt: t0, now: t0.addingTimeInterval(0.2)))
        // Late enough and moved.
        XCTAssertTrue(WatchShape.liveShapeDue(size: CGSize(width: 360, height: 576), lastSent: CGSize(width: 382, height: 576), lastAt: t0, now: t0.addingTimeInterval(0.2)))
        // Nothing to say about a size that's no window.
        XCTAssertFalse(WatchShape.liveShapeDue(size: CGSize(width: 10, height: 576), lastSent: nil, lastAt: nil, now: t0))
    }

    // MARK: Over a real connection (loopback, the away door)

    func testAMacThatTakesLiveShapesGetsEachOneAndTheFinal() async throws {
        let rig = try await Rig.make(port: 47945)
        defer { rig.stop() }
        rig.server.macFeatures += [WatchShape.feature, WatchShape.liveFeature]
        try await rig.connect()
        XCTAssertTrue(rig.client.macTakesLiveShapes)
        XCTAssertTrue(rig.client.watchShape(CGSize(width: 382, height: 576), live: true, final: false))
        XCTAssertTrue(rig.client.watchShape(CGSize(width: 300, height: 576), live: true, final: false))
        XCTAssertTrue(rig.client.watchShape(CGSize(width: 262, height: 396), live: true, final: true))
        try await rig.waitFor { rig.mac.shapes.count == 3 }
        XCTAssertEqual(rig.mac.shapes.map { $0.1 }, [false, false, true])
        XCTAssertEqual(rig.mac.shapes.last!.0, 262.0 / 396.0, accuracy: 0.001)
    }

    func testAMacFromBeforeGetsOneShapeOnRelease() async throws {
        let rig = try await Rig.make(port: 47946)
        defer { rig.stop() }
        rig.server.macFeatures += [WatchShape.feature]
        try await rig.connect()
        XCTAssertFalse(rig.client.macTakesLiveShapes)
        // A live shape sends nothing to it.
        XCTAssertFalse(rig.client.watchShape(CGSize(width: 382, height: 576), live: true, final: false))
        // The release goes as today's `watchShape`.
        XCTAssertTrue(rig.client.watchShape(CGSize(width: 262, height: 396), live: true, final: true))
        try await rig.waitFor { rig.mac.shapes.count == 1 }
        XCTAssertNil(rig.mac.shapes.first!.1)
        XCTAssertEqual(rig.mac.shapes.first!.0, 262.0 / 396.0, accuracy: 0.001)
        // The session carries on (an unknown message would have ended it).
        let rtt = await rig.client.roundTrip(); XCTAssertNotNil(rtt)
    }
}

extension MacSide {
    func linkServer(_ server: LinkServer, watchShape aspect: CGFloat, from peerID: UUID) { shapes.append((aspect, nil)) }
    func linkServer(_ server: LinkServer, watchShapeLive aspect: CGFloat, final: Bool, from peerID: UUID) { shapes.append((aspect, final)) }
}
