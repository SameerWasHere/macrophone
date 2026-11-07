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

    /// Nov 7 2026: the slider stands at the Mac's real volume before any key (serve says 56%), and
    /// a drag to about 30% sends the keys for that distance — four down — not five more on top of
    /// the real level from a drawn 0. With `TEST_RUNNER_MACROPHONE_REACH_OLD_MAC=1` (serve run with
    /// `--no-volume`) the level is unknown: the bare track, and only the ends move it.
    func testTheVolumeSliderStandsAtTheMacsLevelBeforeATouch() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_REACH": "controls"]
        app.launch()
        let slider = app.descendants(matching: .any)["mac-volume-slider"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 25), "the panel opens")
        if ProcessInfo.processInfo.environment["MACROPHONE_REACH_OLD_MAC"] == "1" {
            sleep(2)
            XCTAssertEqual(slider.value as? String, "Unknown", "a Mac from before: no guessed level")
            XCTAssertTrue(app.staticTexts["Press + or − to change your Mac's volume"].exists)
            shot("old-mac-unknown")
            app.buttons["mac-control-volumeUp"].tap()
            let after = NSPredicate(format: "value ENDSWITH ' percent'")
            expectation(for: after, evaluatedWith: slider)
            waitForExpectations(timeout: 5)
            shot("old-mac-after-plus")
            return
        }
        let known = NSPredicate(format: "value == '56 percent'")
        expectation(for: known, evaluatedWith: slider)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.staticTexts["Volume 56%"].exists, "the footer says the level before any key")
        shot("1-level-before-touch")
        // From the fill's end (56%) to 30% of the track.
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5625, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        let landed = NSPredicate(format: "value == '31 percent'")
        expectation(for: landed, evaluatedWith: slider)
        waitForExpectations(timeout: 8)
        shot("2-after-drag")
    }
}
