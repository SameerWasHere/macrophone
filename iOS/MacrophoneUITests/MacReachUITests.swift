import XCTest

/// Pick a display, Mac Controls (Oct 19 2026), on a phone paired with `mpctl serve` (two demo
/// displays, keys counted, never pressed). Pair the simulator first (MACROPHONE_OPEN_URL with the
/// serve's URL), then run with `TEST_RUNNER_MACROPHONE_REACH_TEST=1`; screenshots go to
/// `TEST_RUNNER_MACROPHONE_REACH_SHOTS=<dir>` when given.
final class MacReachUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACROPHONE_REACH_TEST"] == "1", "needs a paired mpctl serve")
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MACROPHONE_REACH_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func controls(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Mac Controls'")).firstMatch
    }

    func testSendToMoreHasDisplaysAndMacControls() {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main"]
        app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Ready'")).firstMatch.waitForExistence(timeout: 20), "connected")
        let more = app.buttons["send-to-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap()
        XCTAssertTrue(app.buttons["Whole Screen — Studio Display"].waitForExistence(timeout: 4), "a Whole Screen per display")
        XCTAssertTrue(app.buttons["Whole Screen — Built-in Retina Display"].exists)
        shot("1-more-menu")
        controls(app).tap()
        let up = app.buttons["Volume Up"]
        XCTAssertTrue(up.waitForExistence(timeout: 4), "Mac Controls opens")
        shot("2-mac-controls")
        up.tap()
        // The menu stays open for another press.
        XCTAssertTrue(up.waitForExistence(timeout: 2))
        up.tap()
        app.buttons["Play or Pause"].tap()
        shot("3-after-presses")
        // Dismiss and read the answer in the status line.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)).tap()
        shot("4-status")

        // The window view: the whole screen of the second display, and the keys menu's Mac Controls.
        more.tap()
        app.buttons["Whole Screen — Studio Display"].tap()
        XCTAssertTrue(app.buttons["watch-done"].waitForExistence(timeout: 10), "watching")
        sleep(2)
        shot("5-studio-display")
        app.descendants(matching: .any)["watch-sessions"].firstMatch.tap()
        XCTAssertTrue(item(app, "Whole Screen — Studio Display").waitForExistence(timeout: 4), "a Whole Screen per display in the switcher")
        shot("6-switcher")
        item(app, "Whole Screen — Built-in Retina Display").tap()
        sleep(2)
        // The window is asking a question: its answers stand in for the keys until Keys.
        if app.buttons["watch-keys"].waitForExistence(timeout: 3) { app.buttons["watch-keys"].tap() }
        let keys = app.buttons["watch-more-keys"]
        if keys.waitForExistence(timeout: 4) {
            keys.tap()
            sleep(1)
            shot("7a-keys-open")
            XCTAssertTrue(controls(app).waitForExistence(timeout: 4), "Mac Controls in the keys menu")
            shot("7-keys-menu")
            controls(app).tap()
            app.buttons["Mute"].tap()
            shot("8-keys-mac-controls")
        }
    }
}
