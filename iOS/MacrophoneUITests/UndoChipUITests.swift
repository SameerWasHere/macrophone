import XCTest

/// Undo you can reach (Nov 7 2026): after a paste the landed pill has its moment, then the small
/// Undo chip by the Thread stays for as long as the Mac can take the paste back — here shortened
/// to `MACROPHONE_UNDO_LIFE` seconds — and goes by itself; its Undo reaches the Mac; a shake asks
/// first; History offers Undo Paste while it can. Needs `mpctl serve` paired with this simulator
/// (it answers an undo: `UNDO <id>` in its log).
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

    func testThePillBecomesTheChipWhichLivesOutTheUndoWindowAndGoes() throws {
        let app = launch()
        let mic = app.buttons["mic-button"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        let pill = app.otherElements["landed-pill"].firstMatch
        let chip = app.buttons["landed-undo-chip"].firstMatch
        // The landing: the simulator's cleanup takes a while, then serve's 1.5 s.
        XCTAssertTrue(pill.waitForExistence(timeout: 40), "the landed pill rises")
        let micAtPill = mic.frame
        XCTAssertFalse(pill.frame.intersects(mic.frame.insetBy(dx: 6, dy: 6)), "the pill clears the mic's ring: \(pill.frame) vs \(mic.frame)")
        XCTAssertTrue(chip.waitForExistence(timeout: 4), "the pill becomes the chip")
        XCTAssertFalse(pill.exists, "the pill is gone once the chip is there")
        XCTAssertFalse(chip.frame.intersects(mic.frame), "the chip is clear of the mic: \(chip.frame) vs \(mic.frame)")
        XCTAssertEqual(mic.frame.midY, micAtPill.midY, accuracy: 0.5, "the mic never moves")
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

    func testHistoryOffersUndoPasteOnlyWhileItCan() throws {
        // History opens 2 s after the stop; the landing comes while it's up.
        let app = launch(actions: "pick@Claude,record,stoprecord,sheet@history", life: "12")
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        // A swipe action's identifier doesn't always reach XCUITest: its title is the sure name.
        let undo = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "history-undo", "Undo Paste")).firstMatch
        var offered = false
        for _ in 0..<12 where !offered {
            row.swipeRight()
            offered = undo.waitForExistence(timeout: 1.5)
            if !offered { row.swipeLeft(); sleep(2) }
        }
        XCTAssertTrue(offered, "the newest paste offers Undo Paste")
        // Put the row back, wait the window out, look again.
        row.swipeLeft()
        sleep(13)
        row.swipeRight()
        XCTAssertFalse(undo.waitForExistence(timeout: 2), "no Undo Paste once the Mac can't")
    }
}
