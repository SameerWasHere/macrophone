import XCTest

/// Undo you can reach (Nov 7 2026): after a paste the landed pill has its moment in the status
/// line's place under the mic, then becomes the small Undo chip in that same place for as long as
/// the Mac can take the paste back — here shortened to `MACROPHONE_UNDO_LIFE` seconds — and goes by
/// itself; its Undo reaches the Mac; a shake asks first; History shows Undo on the newest row while
/// it can. Needs `mpctl serve` paired with this simulator (it answers an undo: `UNDO <id>` in its log).
final class UndoChipUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(actions: String = "pick@Claude,record,stoprecord", life: String = "9", extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        var env = ["MACROPHONE_SCREEN": "main", "MACROPHONE_WATCH": "rest",
                   "MACROPHONE_WATCH_ACTIONS": actions,
                   "MACROPHONE_SIM_RECORD": "Hello from the phone",
                   "MACROPHONE_UNDO_LIFE": life]
        extra.forEach { env[$0] = $1 }
        app.launchEnvironment = env
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        return app
    }

    func testThePillBecomesTheChipInPlaceWhichLivesOutTheUndoWindowAndGoes() throws {
        let app = launch()
        let mic = app.buttons["mic-button"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        let pill = app.otherElements["landed-pill"].firstMatch
        let chip = app.buttons["landed-undo-chip"].firstMatch
        // The landing: the simulator's cleanup takes a while, then serve's 1.5 s.
        XCTAssertTrue(pill.waitForExistence(timeout: 40), "the landed pill shows")
        let micAtPill = mic.frame
        let pillFrame = pill.frame
        XCTAssertFalse(pillFrame.intersects(mic.frame.insetBy(dx: 6, dy: 6)), "the pill clears the mic's ring: \(pillFrame) vs \(mic.frame)")
        XCTAssertGreaterThan(pillFrame.midY, mic.frame.maxY - 6, "the pill sits under the mic, in the status line's place: \(pillFrame) vs \(mic.frame)")
        XCTAssertTrue(chip.waitForExistence(timeout: 4), "the pill becomes the chip")
        XCTAssertFalse(pill.exists, "the pill is gone once the chip is there")
        XCTAssertFalse(chip.frame.intersects(mic.frame), "the chip is clear of the mic: \(chip.frame) vs \(mic.frame)")
        XCTAssertEqual(chip.frame.midY, pillFrame.midY, accuracy: 8, "the chip takes the pill's place: \(chip.frame) vs \(pillFrame)")
        XCTAssertEqual(chip.frame.midX, pillFrame.midX, accuracy: 8, "the chip is centred where the pill was")
        XCTAssertEqual(mic.frame.midY, micAtPill.midY, accuracy: 0.5, "the mic never moves")
        XCTAssertTrue(chip.label.hasPrefix("Undo paste into"), chip.label)
        // Still there well into the window.
        sleep(3)
        XCTAssertTrue(chip.exists, "the chip stays through the window")
        // And gone a breath after it.
        let gone = NSPredicate(format: "exists == false")
        let wait = XCTNSPredicateExpectation(predicate: gone, object: chip)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 8), .completed, "the chip goes when the Mac can't undo any more")
        XCTAssertEqual(mic.frame.midY, micAtPill.midY, accuracy: 0.5, "the mic never moved")
    }

    func testTheChipsUndoReachesTheMac() throws {
        let app = launch(life: "20")
        let chip = app.buttons["landed-undo-chip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 45))
        chip.tap()
        // The pill says Undone once the Mac answers (serve answers at once).
        let undone = app.staticTexts["Undone"].firstMatch
        XCTAssertTrue(undone.waitForExistence(timeout: 5), "the pill says Undone")
        XCTAssertFalse(chip.exists)
        // Then the line under the mic says what happened, by name.
        let took = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Took the paste out of")).firstMatch
        XCTAssertTrue(took.waitForExistence(timeout: 6), "the status line says what was taken out")
    }

    func testAShakeAsksBeforeUndoing() throws {
        // The hook stands in for Device › Shake, 2 s after the stop; the alert waits for the landing.
        let app = launch(actions: "pick@Claude,record,stoprecord,shake,shake,shake,shake,shake,shake,shake,shake,shake,shake", life: "25")
        let chip = app.buttons["landed-undo-chip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 45))
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 25), "a shake asks")
        XCTAssertTrue(alert.label.hasPrefix("Undo Paste into"), alert.label)
        alert.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts["Undone"].firstMatch.waitForExistence(timeout: 5))
    }

    func testHistoryShowsUndoOnTheNewestRowOnlyWhileItCan() throws {
        // History opens 2 s after the stop; the landing comes while it's up.
        let app = launch(actions: "pick@Claude,record,stoprecord,sheet@history", life: "12")
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let undo = app.buttons["history-undo-button"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 40), "the newest paste shows Undo")
        XCTAssertTrue(undo.label.hasPrefix("Undo paste into"), undo.label)
        XCTAssertTrue(undo.frame.midY < row.frame.maxY && undo.frame.midY > row.frame.minY, "Undo sits on the newest row: \(undo.frame) vs \(row.frame)")
        // Gone once the window has passed.
        let gone = NSPredicate(format: "exists == false")
        let wait = XCTNSPredicateExpectation(predicate: gone, object: undo)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 16), .completed, "no Undo once the Mac can't")
        // The swipe and the menu never offered it either, then.
        row.swipeRight()
        XCTAssertFalse(app.buttons["history-undo"].firstMatch.waitForExistence(timeout: 2), "no Undo Paste in the swipe once the Mac can't")
    }
}
