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

    func testSendToMoreHasDisplaysAndMacControls() {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Connected to'")).firstMatch.waitForExistence(timeout: 20), "connected")
        let more = app.buttons["send-to-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap()
        XCTAssertTrue(app.buttons["Whole Screen — Studio Display"].waitForExistence(timeout: 4), "a Whole Screen per display")
        XCTAssertTrue(app.buttons["Whole Screen — Built-in Retina Display"].exists)
        shot("1-more-menu")
        // Away from the ⋯ menu; Mac Controls is the button beside Watch (Oct 19 2026).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)).tap()
        let controlsButton = app.buttons["mac-controls"].firstMatch
        XCTAssertTrue(controlsButton.waitForExistence(timeout: 4), "Mac Controls beside Watch")
        controlsButton.tap()
        let up = app.buttons["mac-control-volumeUp"]
        XCTAssertTrue(up.waitForExistence(timeout: 4), "Mac Controls opens")
        shot("2-mac-controls")
        up.tap()
        // The panel stays open for another press.
        XCTAssertTrue(up.waitForExistence(timeout: 2))
        up.tap()
        app.buttons["mac-control-playPause"].tap()
        shot("3-after-presses")
        app.buttons["mac-controls-done"].tap()
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
        // Mac Controls is the header's own button (Oct 19 2026): one tap, the panel, a press.
        let button = app.buttons["mac-controls"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 4), "Mac Controls in the window view's header")
        button.tap()
        XCTAssertTrue(app.buttons["mac-control-mute"].waitForExistence(timeout: 4), "the panel opens")
        shot("7-mac-controls-panel")
        app.buttons["mac-control-mute"].tap()
        shot("8-after-mute")
        app.buttons["mac-controls-done"].tap()
    }
}
