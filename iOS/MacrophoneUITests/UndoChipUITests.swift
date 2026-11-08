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
        // History opens 2 s after the stop; the landing comes while it's up (it reaches
        // `rememberUndoable` with the sheet up, and the row's Undo shows).
        let (app, row) = historyWithUndoableRow(life: "12")
        let undo = app.buttons["history-undo-button"].firstMatch
        XCTAssertTrue(undo.label.hasPrefix("Undo paste into"), undo.label)
        XCTAssertTrue(undo.frame.midY < row.frame.maxY && undo.frame.midY > row.frame.minY, "Undo sits on the newest row: \(undo.frame) vs \(row.frame)")
        XCTAssertGreaterThan(undo.frame.midX, row.frame.midX, "at the row's trailing end")
        // Gone once the window has passed.
        let gone = NSPredicate(format: "exists == false")
        let wait = XCTNSPredicateExpectation(predicate: gone, object: undo)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 16), .completed, "no Undo once the Mac can't")
        // The swipe never offers it either, then (Send Again is there: the swipe did open).
        row.swipeRight()
        XCTAssertTrue(app.buttons["Send Again"].firstMatch.waitForExistence(timeout: 3), "the leading swipe opened")
        XCTAssertFalse(undoSwipeAction(app).exists, "no Undo Paste in the swipe once the Mac can't")
        // Nor the page's bottom bar (a first tap closes the swipe, the next opens the page).
        openPage(row)
        sleep(1)
        if !app.buttons["Copy"].firstMatch.exists { openPage(row) }
        XCTAssertTrue(app.buttons["Copy"].firstMatch.waitForExistence(timeout: 5), "the page is up")
        XCTAssertFalse(app.buttons["history-page-undo"].exists, "no Undo Paste on the page once the Mac can't")
    }

    // MARK: History's three ways to Undo, each reaching the Mac (Nov 7 2026)
    //
    // The newest paste's row is found by the Undo button it holds while the Mac can take it back
    // (History lives on between runs, so every run adds another "To Claude" row), then held by its
    // place in the list. The row reading "Undone from the phone" is the Mac's answer (`undoDone`,
    // ok) arriving — the Mac took it; serve's log says `UNDO <id>` for each (read after the run:
    // its output is block-buffered).

    /// Opens History over a fresh landing and returns the newest paste's row, held by position.
    private func historyWithUndoableRow(life: String = "40") -> (XCUIApplication, XCUIElement) {
        let app = launch(actions: "pick@Claude,record,stoprecord,sheet@history", life: life)
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 30))
        let undo = app.buttons["history-undo-button"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 40), "the newest paste shows Undo")
        let cells = app.cells.allElementsBoundByIndex
        guard let i = cells.firstIndex(where: { $0.frame.minY <= undo.frame.midY && undo.frame.midY <= $0.frame.maxY }) else {
            XCTFail("no row holds Undo"); return (app, app.cells.firstMatch)
        }
        let row = app.cells.element(boundBy: i)
        let words = rowWords(row)
        XCTAssertTrue(words.label.hasPrefix("To Claude"), "the newest paste's row: \(words.label)")
        XCTAssertFalse(words.label.contains(Self.undone), "not undone yet: \(words.label)")
        return (app, row)
    }

    private static let undone = "Undone from the phone"

    /// The row's one element of words ("To Claude, 4:41 PM, Pasted into Claude") — the cell
    /// itself carries no label.
    private func rowWords(_ row: XCUIElement) -> XCUIElement {
        row.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "To ")).firstMatch
    }

    /// The swipe's Undo Paste (its identifier, or its title — SwiftUI's swipe buttons don't always
    /// carry the identifier through).
    private func undoSwipeAction(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'history-undo' OR label == 'Undo Paste'")).firstMatch
    }

    /// A tap on the row's leading side (its trailing end holds Undo): the row's page.
    private func openPage(_ row: XCUIElement) {
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
    }

    private func waitUndone(_ row: XCUIElement, _ how: String) {
        let undone = NSPredicate(format: "label CONTAINS %@", Self.undone)
        let words = rowWords(row)
        let wait = XCTNSPredicateExpectation(predicate: undone, object: words)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 8), .completed, "\(how): the row reads “\(Self.undone)” — \(words.label)")
    }

    func testHistoryRowsUndoButtonReachesTheMac() throws {
        let (app, row) = historyWithUndoableRow()
        let undo = app.buttons["history-undo-button"].firstMatch
        XCTAssertTrue(undo.label.hasPrefix("Undo paste into Claude"), undo.label)
        undo.tap()
        waitUndone(row, "the row's Undo")
        XCTAssertFalse(undo.exists, "Undo goes once the paste is taken back")
        row.swipeRight()
        XCTAssertTrue(app.buttons["Send Again"].firstMatch.waitForExistence(timeout: 3), "the leading swipe opened")
        XCTAssertFalse(undoSwipeAction(app).exists, "nothing left to undo in the swipe")
    }

    func testHistorySwipeUndoPasteReachesTheMac() throws {
        let (app, row) = historyWithUndoableRow()
        row.swipeRight()
        let action = undoSwipeAction(app)
        XCTAssertTrue(action.waitForExistence(timeout: 3), "the leading swipe offers Undo Paste")
        // First: a full swipe never undoes by accident, so Undo Paste leads, Send Again after it.
        let again = app.buttons["Send Again"].firstMatch
        XCTAssertTrue(again.exists)
        XCTAssertLessThan(action.frame.minX, again.frame.minX, "Undo Paste leads the swipe")
        action.tap()
        waitUndone(row, "the swipe's Undo Paste")
        XCTAssertFalse(app.buttons["history-undo-button"].exists, "the row's Undo goes with it")
    }

    func testHistoryPagesUndoPasteReachesTheMac() throws {
        let (app, row) = historyWithUndoableRow()
        openPage(row)
        let undo = app.buttons["history-page-undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the page's bottom bar offers Undo Paste")
        undo.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: undo)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "Undo Paste goes from the page once asked")
        // Back to the list: the row says so.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitUndone(row, "the page's Undo Paste")
    }
}
