import CoreGraphics
@testable import MacrophoneKit
import XCTest

final class WatchReconnectTests: XCTestCase {
    func testTheSameWindowAtAnotherResolutionIsTheSameShape() {
        // Away (1,600 px) and home (2,560 px), each side rounded to an even number.
        XCTAssertTrue(WatchReconnect.sameShape(CGSize(width: 1600, height: 1212), CGSize(width: 2560, height: 1940)))
        XCTAssertTrue(WatchReconnect.sameShape(CGSize(width: 1400, height: 900), CGSize(width: 1400, height: 900)))
        // A window given another shape (Fit to iPhone, a text size) is not.
        XCTAssertFalse(WatchReconnect.sameShape(CGSize(width: 1400, height: 900), CGSize(width: 900, height: 1400)))
        XCTAssertFalse(WatchReconnect.sameShape(CGSize(width: 1400, height: 900), CGSize(width: 1400, height: 960)))
        // Nothing yet is never the same shape.
        XCTAssertFalse(WatchReconnect.sameShape(.zero, CGSize(width: 1400, height: 900)))
    }

    func testTheCarriedZoomDrawsThePictureAtTheSameSize() {
        let old = CGSize(width: 1600, height: 1000), new = CGSize(width: 2560, height: 1600)
        let zoom = WatchReconnect.carriedZoom(0.5, from: old, to: new)
        XCTAssertEqual(new.width * zoom, old.width * 0.5, accuracy: 0.001)
        XCTAssertEqual(WatchReconnect.carriedZoom(0.7, from: .zero, to: new), 0.7)
    }

    func testTheTimesHoldTogether() {
        // A hiccup shows nothing; the answer wait fits inside the hold.
        XCTAssertLessThan(WatchReconnect.quietFor, 1)
        XCTAssertLessThan(WatchReconnect.answerWait, WatchReconnect.limit)
        XCTAssertGreaterThanOrEqual(WatchReconnect.limit, 20)
        XCTAssertLessThanOrEqual(WatchReconnect.limit, 30)
    }
}
