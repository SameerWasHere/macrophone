import XCTest

/// The three ways in (Oct 19 2026), with real touches: a swipe beside the mic slides to the
/// trackpad, a swipe in from the trackpad's edge comes back, a swipe the other way opens the
/// keyboard (the iOS keyboard rises), and the bar's hide button comes back to the mic — and none
/// of it starts a dictation. Needs a Mac that names the pages: `mpctl serve` paired with this
/// simulator (the app opens its window view by itself with MACROPHONE_WATCH=1).
final class InputCarouselUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSwipesBesideTheMicChangeThePage() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_WATCH": "1"]
        app.launch()
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        let row = app.descendants(matching: .any)["input-pages"]
        guard row.waitForExistence(timeout: 15) else { throw XCTSkip("no Mac naming the keyboard and trackpad pages is connected") }
        XCTAssertEqual(row.value as? String, "Mic")

        // Right to left, beside the mic (its right), on the status line's level: the trackpad.
        let micFrame = mic.frame
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: micFrame.maxX + 50, dy: micFrame.midY + 40))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -220, dy: 0)))
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        XCTAssertTrue(trackpad.waitForExistence(timeout: 3), "a swipe right to left shows the trackpad")
        XCTAssertEqual(row.value as? String, "Trackpad")
        XCTAssertFalse(app.buttons["Stop and send"].exists, "the swipe never started a dictation")

        // In from the trackpad's left edge: back to the mic.
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: trackpad.frame.minX + 8, dy: trackpad.frame.midY))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 160, dy: 0)))
        XCTAssertTrue(mic.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mic)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(row.value as? String, "Mic")

        // Left to right, beside the mic (its left): the keyboard rises.
        let left = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: micFrame.minX - 50, dy: micFrame.midY + 40))
        left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: 220, dy: 0)))
        let strip = app.descendants(matching: .any)["input-keyboard"]
        XCTAssertTrue(strip.waitForExistence(timeout: 3), "a swipe left to right shows the keyboard page")
        XCTAssertEqual(row.value as? String, "Keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the iOS keyboard comes up")
        // iOS's own first-time keyboard tip, if it's there.
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 1) { cont.tap() }
        let hide = app.buttons["Hide the keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3), "the bar rides above the keys")
        hide.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mic)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(row.value as? String, "Mic")
        XCTAssertFalse(app.buttons["Stop and send"].exists)
        app.buttons["watch-done"].tap()
    }
}
