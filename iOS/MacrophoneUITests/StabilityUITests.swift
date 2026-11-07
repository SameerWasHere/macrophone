import XCTest

/// Every change of state moves the screen once and leaves it where it was (Nov 7 2026): after a
/// window opens and Done closes it, the mic is exactly where it was at rest — on the Duo's cover
/// it used to sit 20 pt lower for good (the mic page measured itself in the shorter room the
/// window had left it). And while a window shows, the cover's vertical bar keeps one set of
/// items: the keyboard's item turns into Hide Keyboard in place; nothing arrives or leaves.
/// Needs `mpctl serve` paired with this simulator (the app opens and closes its window by itself
/// with MACROPHONE_WATCH=rest).
final class StabilityUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(actions: String) -> XCUIApplication {
        let app = XCUIApplication()
        // Two idle steps first: the screen at rest for a while once the Mac has connected.
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_WATCH": "rest",
                                 "MACROPHONE_WATCH_ACTIONS": actions]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        return app
    }

    func testDoneLeavesTheMicWhereItWasAtRest() throws {
        let app = launch(actions: "pick@Claude,rest,open")
        let mic = app.buttons["mic-button"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        let done = app.buttons["watch-done"].firstMatch
        // The frame at rest: the last one read before the window opened, once it had held still.
        var rest = CGRect.zero
        var stable = 0
        let deadline = Date().addingTimeInterval(25)
        while !done.exists, Date() < deadline {
            let f = mic.frame
            stable = abs(f.minY - rest.minY) < 0.5 && abs(f.minX - rest.minX) < 0.5 ? stable + 1 : 0
            rest = f
            usleep(250_000)
        }
        guard done.exists else { throw XCTSkip("no Mac connected: the window never opened") }
        XCTAssertGreaterThan(stable, 2, "the mic held still at rest before the window opened")
        sleep(2)
        done.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: done)
        waitForExpectations(timeout: 5)
        sleep(1)
        let after = mic.frame
        XCTAssertEqual(after.minX, rest.minX, accuracy: 0.5, "after Done the mic is where it was: \(rest) → \(after)")
        XCTAssertEqual(after.minY, rest.minY, accuracy: 0.5, "after Done the mic is where it was: \(rest) → \(after)")
        XCTAssertEqual(after.height, rest.height, accuracy: 0.5)
        // And it stays there.
        sleep(1)
        XCTAssertEqual(mic.frame.minY, rest.minY, accuracy: 0.5, "nothing drifts after Done")
    }

    func testTheCoversBarKeepsItsItemsWhileTheKeyboardComesAndGoes() throws {
        let app = launch(actions: "pick@Claude,open")
        let done = app.buttons["watch-done"].firstMatch
        guard done.waitForExistence(timeout: 20) else { throw XCTSkip("no Mac connected: the window never opened") }
        let keyboard = app.buttons["bar-keyboard"].firstMatch
        guard keyboard.waitForExistence(timeout: 3) else { throw XCTSkip("not the Duo's cover: no vertical bar") }
        sleep(2)
        let ids = ["watch-done", "watch-sound", "mac-controls", "cover-drag", "watch-whole"]
        let before = ids.filter { app.buttons[$0].exists }
        keyboard.tap()
        // (A simulator with its Mac's keyboard connected keeps the iOS keyboard down.)
        let keys = app.keyboards.firstMatch
        guard keys.waitForExistence(timeout: 5) else { throw XCTSkip("the iOS keyboard didn't come up") }
        // With the keyboard up the column holds Done and the system's ⋯ (round 5: the rest, Hide
        // Keyboard first, fold into it one by one); Done never leaves.
        XCTAssertTrue(done.exists)
        XCTAssertLessThanOrEqual(app.buttons.matching(identifier: "bar-keyboard").count, 1, "one keyboard item, never two")
        app.buttons["keyboard-hide"].firstMatch.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "back to Keyboard, in the same place")
        XCTAssertEqual(keyboard.label, "Keyboard")
        sleep(1)
        XCTAssertEqual(ids.filter { app.buttons[$0].exists }, before, "the bar has the items it had")
    }
}
