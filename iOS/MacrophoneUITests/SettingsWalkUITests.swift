import XCTest

/// Walks Settings, History, the pairing sheet and setup with real taps and swipes (Nov 4 2026, the
/// Settings and sheets polish): every page opens, pushes and pops, every sheet shows and closes,
/// nothing needs a Mac (`MACROPHONE_FAKE_PAIRED`, `MACROPHONE_FAKE_HISTORY`). Slow on purpose — a
/// beat between steps — so `simctl io recordVideo` beside it shows each motion whole.
/// Runs with `TEST_RUNNER_MACROPHONE_WALK=1`; setup's walk wants the microphone and speech granted
/// first (`simctl privacy <udid> grant microphone|speech-recognition com.sameer.macrophone`).
final class SettingsWalkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACROPHONE_WALK"] == "1", "TEST_RUNNER_MACROPHONE_WALK=1 to walk")
    }

    private func launch(_ env: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = env
        app.launch()
        return app
    }

    private func beat(_ s: Double = 1.2) { Thread.sleep(forTimeInterval: s) }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func back(_ app: XCUIApplication) {
        // The back button by name: the bar's first button can be the page under it's (Clear All).
        let named = app.navigationBars.buttons["BackButton"]
        (named.exists ? named : app.navigationBars.buttons.element(boundBy: 0)).tap()
        beat()
    }

    func testSettingsWalk() {
        let app = launch(["MACROPHONE_SCREEN": "settings", "MACROPHONE_FAKE_PAIRED": "Studio Mac|MacBook Air", "MACROPHONE_FAKE_HISTORY": "1"])
        let banner = any(app, "settings-mac")
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        beat()
        // The Mac's page, its steps, and back.
        banner.tap(); beat()
        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 3))
        app.swipeUp(); beat()
        let steps = any(app, "away-setup")
        XCTAssertTrue(steps.waitForExistence(timeout: 3))
        steps.tap(); beat()
        XCTAssertTrue(app.navigationBars["Away from Home"].waitForExistence(timeout: 3))
        back(app)
        XCTAssertTrue(any(app, "unpair-this-mac").waitForExistence(timeout: 3))
        back(app)
        // Send to, then Custom instructions, Dictionary.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Send to'")).firstMatch.tap(); beat()
        back(app)
        any(app, "custom-instructions-link").tap(); beat()
        XCTAssertTrue(any(app, "custom-instructions").waitForExistence(timeout: 3))
        app.swipeUp(); beat()
        back(app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dictionary'")).firstMatch.tap(); beat()
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        field.tap(); field.typeText("kubectl\n"); beat()
        XCTAssertTrue(app.staticTexts["kubectl"].waitForExistence(timeout: 3))
        back(app)
        // Down the list: the switches, the Macs and their swipe.
        app.swipeUp(); beat()
        let stop = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Stop when'")).firstMatch
        if stop.waitForExistence(timeout: 2) { stop.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); beat() }
        app.swipeUp(); beat()
        let air = any(app, "mac-row-MacBook Air")
        if air.waitForExistence(timeout: 3) {
            air.swipeLeft(); beat()
            XCTAssertTrue(app.buttons["Unpair"].firstMatch.exists, "a swipe offers Unpair")
            app.swipeDown(); beat()
        }
        app.swipeUp(); beat()
        app.navigationBars.buttons["Done"].tap(); beat()
    }

    func testHistoryWalk() {
        let app = launch(["MACROPHONE_SCREEN": "history", "MACROPHONE_FAKE_PAIRED": "Studio Mac", "MACROPHONE_FAKE_HISTORY": "1"])
        let first = app.cells.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        beat()
        first.tap(); beat()
        let version = app.segmentedControls["history-version"]
        if version.waitForExistence(timeout: 2) { version.buttons["Raw"].tap(); beat(); version.buttons["Cleaned"].tap(); beat() }
        back(app)
        app.cells.element(boundBy: 1).swipeLeft(); beat()
        app.cells.element(boundBy: 2).tap(); beat()   // closes the swipe
        app.swipeDown(); beat()
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 2) {
            search.tap(); search.typeText("zzz"); beat()
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No Results'")).firstMatch.exists, "no match says so")
            // iOS 26's search closes with an × (Cancel before).
            let close = app.buttons["Cancel"].exists ? app.buttons["Cancel"] : app.buttons["Close"]
            if close.exists { close.firstMatch.tap(); beat() }
        }
        app.navigationBars.buttons["Done"].firstMatch.tap(); beat()
    }

    func testPairingWalk() {
        let app = launch(["MACROPHONE_SCREEN": "pairing"])
        let code = app.buttons["Use a Code Instead"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        beat()
        code.tap(); beat(1.6)
        app.buttons["Scan the QR Code Instead"].tap(); beat(1.6)
        any(app, "pairing-close").tap(); beat()
    }

    func testSetupWalk() {
        let app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_ONBOARDING_STEP": "0"])
        let start = app.buttons["Get Started"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        beat()
        start.tap(); beat(1.6)   // a granted permission's step passes by itself; else allow it
        let have = app.buttons["I Have It"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<4 where !have.exists {
            let next = app.buttons["Continue"]
            guard next.waitForExistence(timeout: 2) else { break }
            next.tap(); beat()
            for label in ["Allow", "OK"] where springboard.buttons[label].waitForExistence(timeout: 2) {
                springboard.buttons[label].tap(); beat(1.6); break
            }
        }
        XCTAssertTrue(have.waitForExistence(timeout: 5))
        have.tap(); beat(1.6)
        app.buttons["Skip"].tap(); beat(1.6)
        app.buttons["Use a Code Instead"].tap(); beat(1.6)
        app.buttons["Skip"].tap(); beat(1.6)
        XCTAssertTrue(app.buttons["Finish"].waitForExistence(timeout: 3))
    }
}
