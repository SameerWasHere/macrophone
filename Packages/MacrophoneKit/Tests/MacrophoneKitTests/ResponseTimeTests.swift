import CoreGraphics
import XCTest
@testable import MacrophoneKit

final class ResponseClockTests: XCTestCase {
    func testAnInputIsTimedToTheNextFrame() {
        var c = ResponseClock()
        XCTAssertNil(c.frameShown(at: 1), "a frame with no input times nothing")
        c.input(at: 10)
        XCTAssertEqual(c.frameShown(at: 10.085)!, 85, accuracy: 0.01)
        XCTAssertNil(c.frameShown(at: 10.1), "the next frame answers nothing")
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.last!, 85, accuracy: 0.01)
    }

    func testABurstIsTimedByItsFirstInput() {
        var c = ResponseClock()
        c.input(at: 0)
        c.input(at: 0.03)
        c.input(at: 0.06)
        XCTAssertEqual(c.frameShown(at: 0.1)!, 100, accuracy: 0.01)
        XCTAssertEqual(c.count, 1)
    }

    func testAnUnansweredInputIsDropped() {
        var c = ResponseClock()
        c.input(at: 0)
        XCTAssertNil(c.frameShown(at: 2.5), "past the give-up time")
        c.input(at: 5)
        c.input(at: 7.5) // the one at 5 went stale: this one starts the timing
        XCTAssertEqual(c.frameShown(at: 7.6)!, 100, accuracy: 0.01)
        c.input(at: 8)
        c.dropWaiting()
        XCTAssertNil(c.frameShown(at: 8.05))
    }

    func testMedianAndP90() {
        var c = ResponseClock()
        for (i, ms) in [50.0, 60, 70, 80, 90, 100, 110, 120, 130, 400].enumerated() {
            let t = Double(i) * 3
            c.input(at: t)
            c.frameShown(at: t + ms / 1000)
        }
        XCTAssertEqual(c.median!, 90, accuracy: 0.5)
        XCTAssertEqual(c.p90!, 130, accuracy: 0.5)
        XCTAssertEqual(c.summary, "watching: response median 90 ms, p90 130 ms over 10 inputs")
        c.reset()
        XCTAssertNil(c.summary)
        XCTAssertNil(c.median)
    }
}

final class ScrollPredictionTests: XCTestCase {
    func testTheShiftIsWhatTheMacHasNotShownYet() {
        var p = ScrollPrediction()
        p.sent(CGVector(dx: 0, dy: 10), at: 0)
        p.sent(CGVector(dx: 0, dy: 10), at: 0.05)
        XCTAssertEqual(p.offset(at: 0.06, lag: 0.1).dy, 20, accuracy: 0.001)
        // The first is older than the response time: the Mac's frame shows it by now.
        XCTAssertEqual(p.offset(at: 0.12, lag: 0.1).dy, 10, accuracy: 0.001)
        XCTAssertEqual(p.offset(at: 0.2, lag: 0.1).dy, 0, accuracy: 0.001)
        XCTAssertTrue(p.isEmpty)
    }

    func testCappedAndOffOverASlowLink() {
        var p = ScrollPrediction()
        for i in 0..<20 { p.sent(CGVector(dx: 0, dy: -30), at: Double(i) * 0.01) }
        let o = p.offset(at: 0.2, lag: 0.5)
        XCTAssertEqual(hypot(o.dx, o.dy), ScrollPrediction.cap, accuracy: 0.001)
        XCTAssertLessThan(o.dy, 0)
        XCTAssertEqual(p.offset(at: 0.2, lag: 1.5), .zero, "a stalled link isn't predicted over")
        XCTAssertTrue(p.isEmpty)
    }
}
