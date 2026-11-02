#if os(macOS)
import AppKit
import XCTest
@testable import MacrophoneKit

@MainActor
final class MacCursorTests: XCTestCase {
    // The system's cursors have no pictures until AppKit is up (a test or a command-line tool).
    override func setUp() { _ = NSApplication.shared }

    func testTheMacsCursorsTravel() throws {
        let reader = MacCursorReader()
        for cursor in [NSCursor.arrow, .iBeam, .pointingHand, .resizeLeftRight] {
            let c = try XCTUnwrap(reader.changed(cursor), "\(cursor.image.size)")
            XCTAssertTrue(c.isValid)
            XCTAssertLessThan(c.png.count, 16_000)
        }
    }

    func testTheSameShapeIsSentOnce() {
        // (Each read in a local: an XCTAssert's autoclosure isn't on the main actor.)
        let reader = MacCursorReader()
        let first = reader.changed(.iBeam), again = reader.changed(.iBeam), other = reader.changed(.arrow)
        reader.reset()
        let afterReset = reader.changed(.arrow)
        XCTAssertNotNil(first)
        XCTAssertNil(again)
        XCTAssertNotNil(other)
        XCTAssertNotNil(afterReset)
        XCTAssertEqual(other?.id, afterReset?.id)
        XCTAssertNotEqual(first?.id, other?.id)
    }

    func testABadCursorIsRefused() {
        XCTAssertFalse(MacCursor(id: "a", png: Data([1]), width: 20, height: 20, hotX: 30, hotY: 0).isValid)
        XCTAssertFalse(MacCursor(id: "a", png: Data(), width: 20, height: 20, hotX: 0, hotY: 0).isValid)
        XCTAssertFalse(MacCursor(id: "a", png: Data([1]), width: 400, height: 20, hotX: 0, hotY: 0).isValid)
    }

    func testItRoundTripsOnTheWire() throws {
        let c = MacCursor(id: "abc", png: Data([1, 2, 3]), width: 17, height: 23, hotX: 4, hotY: 4)
        let data = try JSONEncoder().encode(Message.macCursor(c))
        guard case let .macCursor(back) = try JSONDecoder().decode(Message.self, from: data) else { return XCTFail() }
        XCTAssertEqual(back, c)
    }
}
#endif
