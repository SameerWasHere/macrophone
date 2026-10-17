import CoreGraphics
import Foundation
@testable import MacrophoneKit
import XCTest

final class ScrollWireTests: XCTestCase {
    func testScrollPhasesRoundTrip() throws {
        for p in WatchScrollPhase.allCases {
            let data = try WireCoding.encoder.encode(Message.watchScrollPhase(p, x: 0.5, y: 0.25))
            guard case let .watchScrollPhase(back, x, y) = try WireCoding.decoder.decode(Message.self, from: data) else { return XCTFail() }
            XCTAssertEqual(back, p)
            XCTAssertEqual(x, 0.5)
            XCTAssertEqual(y, 0.25)
        }
        // A Mac from before "scroll" never hears a phase: the welcome gates it (the client checks
        // `macFeatures`), and a welcome without it decodes to none.
        let old = #"{"welcome":{"macName":"M","appVersion":"1.1","features":["video","fit"]}}"#
        guard case let .welcome(_, _, features) = try JSONDecoder().decode(Message.self, from: Data(old.utf8)) else { return XCTFail() }
        XCTAssertFalse(features?.contains(WatchScroll.feature) ?? false)
    }
}

final class ScrollEventsTests: XCTestCase {
    func testASwipeIsOneGestureThenACoast() {
        var s = ScrollEvents()
        XCTAssertNil(s.idleTimeout)
        XCTAssertNil(s.phase(.began))
        XCTAssertEqual(s.idleTimeout, 2)
        XCTAssertEqual(s.delta(dx: 0, dy: 12), .init(wheel1: 12, wheel2: 0, phase: .began))
        XCTAssertEqual(s.delta(dx: -3, dy: 8), .init(wheel1: 8, wheel2: -3, phase: .changed))
        XCTAssertEqual(s.phase(.ended), .init(wheel1: 0, wheel2: 0, phase: .ended))
        XCTAssertNil(s.idleTimeout)
        XCTAssertNil(s.phase(.momentumBegan))
        XCTAssertEqual(s.idleTimeout, 0.5)
        XCTAssertEqual(s.delta(dx: 0, dy: 20), .init(wheel1: 20, wheel2: 0, phase: .momentumBegan))
        XCTAssertEqual(s.delta(dx: 0, dy: 19), .init(wheel1: 19, wheel2: 0, phase: .momentumChanged))
        XCTAssertEqual(s.phase(.momentumEnded), .init(wheel1: 0, wheel2: 0, phase: .momentumEnded))
        XCTAssertNil(s.idleTimeout)
    }

    func testAPhaseWithNoDeltaPostsNothing() {
        var s = ScrollEvents()
        XCTAssertNil(s.phase(.began))
        XCTAssertNil(s.phase(.ended), "the Mac never sees an end without its beginning")
        XCTAssertNil(s.phase(.momentumBegan))
        XCTAssertNil(s.phase(.momentumEnded))
        // A new swipe while the last is still open closes it first.
        XCTAssertNil(s.phase(.began))
        _ = s.delta(dx: 0, dy: 5)
        XCTAssertEqual(s.phase(.began), .init(wheel1: 0, wheel2: 0, phase: .ended))
    }

    func testSubPointStepsAddUp() {
        var s = ScrollEvents()
        _ = s.phase(.began)
        // Four steps of 0.4 points: nothing, nothing, 1, nothing, 1 — 2 points in all, not 0.
        let wheels = (0..<5).map { _ in s.delta(dx: 0, dy: 0.4)!.wheel1 }
        XCTAssertEqual(wheels, [0, 1, 0, 1, 0])
        XCTAssertEqual(wheels.reduce(0, +), 2)
        XCTAssertNil(s.delta(dx: Double.nan, dy: 1), "a bad delta is dropped")
        XCTAssertEqual(s.delta(dx: 0, dy: 1e12)?.wheel1, Int32.max)
    }

    func testAPhoneFromBeforeSendsBareWheels() {
        var s = ScrollEvents()
        XCTAssertEqual(s.delta(dx: 0, dy: 7), .init(wheel1: 7, wheel2: 0, phase: .none))
        XCTAssertNil(s.quiet())
    }

    func testAQuietSwipeIsClosedAndStartsAgain() {
        var s = ScrollEvents()
        _ = s.phase(.began)
        _ = s.delta(dx: 0, dy: 5)
        XCTAssertEqual(s.quiet(), .init(wheel1: 0, wheel2: 0, phase: .ended))
        // Resting fingers that move again begin a fresh gesture.
        XCTAssertEqual(s.delta(dx: 0, dy: 5)?.phase, .began)
        _ = s.phase(.momentumBegan)
        _ = s.delta(dx: 0, dy: 5)
        XCTAssertEqual(s.quiet(), .init(wheel1: 0, wheel2: 0, phase: .momentumEnded))
        XCTAssertEqual(s.delta(dx: 0, dy: 5)?.phase, .momentumBegan)
    }
}

final class ScrollMomentumTests: XCTestCase {
    func testAPlacementDoesNotCoast() {
        XCTAssertNil(ScrollMomentum(velocity: CGVector(dx: 0, dy: 100)))
        XCTAssertNil(ScrollMomentum(velocity: CGVector(dx: Double.nan, dy: 1000)))
        XCTAssertNotNil(ScrollMomentum(velocity: CGVector(dx: 0, dy: 400)))
    }

    func testAFlickCoastsForAboutTwoSecondsAndStops() {
        var m = ScrollMomentum(velocity: CGVector(dx: 0, dy: 2000))!
        var travelled = 0.0, ticks = 0
        while let step = m.step(dt: 1 / 60) {
            travelled += step.dy
            ticks += 1
            XCTAssertGreaterThan(step.dy, 0)
        }
        // About 0.42 s of the lift-off speed, over 1.6–2.1 s, and every step smaller than the last.
        XCTAssertEqual(travelled, 2000 * 0.42, accuracy: 100)
        XCTAssertGreaterThan(Double(ticks) / 60, 1.6)
        XCTAssertLessThan(Double(ticks) / 60, 2.2)
        // A stall can't become one big jump.
        var stalled = ScrollMomentum(velocity: CGVector(dx: 0, dy: 2000))!
        XCTAssertLessThan(stalled.step(dt: 3)!.dy, 2000 * 0.1 + 1)
    }
}
