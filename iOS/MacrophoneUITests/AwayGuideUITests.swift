import XCTest

/// The Tailscale guide (Nov 7 2026): each step checks itself and says done; Test it says exactly
/// what's wrong; the one-time offer after pairing; the desktop's "Can't find" away from home.
/// Fake states (`MACROPHONE_FAKE_TAILSCALE`, `_AWAY`, `_AWAY_TEST`) — no Mac needed — with
/// `TEST_RUNNER_MACROPHONE_AWAY=1`. The live test (`TEST_RUNNER_MACROPHONE_AWAY_LIVE=1`) wants the
/// simulator paired with `mpctl serve --remote` on a Mac that's on Tailscale: the simulator shares
/// the Mac's network, so Test it dials the Mac's real Tailscale address.
final class AwayGuideUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ e: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = e
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func value(_ app: XCUIApplication, _ id: String) -> String? { any(app, id).value as? String }
    private func detail(_ app: XCUIApplication, _ step: String) -> String { app.staticTexts["\(step)-detail"].label }

    private func guide(_ extra: [String: String]) -> XCUIApplication {
        var e = ["MACROPHONE_SCREEN": "awaysetup", "MACROPHONE_FAKE_PAIRED": "Studio Mac"]
        e.merge(extra) { $1 }
        let app = launch(e)
        XCTAssertTrue(app.navigationBars["Away from Home"].waitForExistence(timeout: 10))
        return app
    }

    func testNothingSetUpSaysEveryStepAndWhatTheTestFound() throws {
        try XCTSkipUnless(env["MACROPHONE_AWAY"] == "1", "TEST_RUNNER_MACROPHONE_AWAY=1")
        let app = guide(["MACROPHONE_FAKE_AWAY": "off", "MACROPHONE_FAKE_TAILSCALE": "off",
                         "MACROPHONE_FAKE_TAILSCALE_APP": "0", "MACROPHONE_FAKE_AWAY_TEST": "remoteOff"])
        for step in ["away-step-mac", "away-step-app", "away-step-signin", "away-step-test"] {
            XCTAssertTrue(any(app, step).waitForExistence(timeout: 3), step)
            XCTAssertEqual(value(app, step), "To do", step)
        }
        XCTAssertTrue(detail(app, "away-step-mac").contains("turn on Away from home"))
        XCTAssertTrue(any(app, "away-get-tailscale").exists, "the App Store button while the app isn't known")
        XCTAssertTrue(app.buttons["away-open-tailscale"].exists)
        app.swipeUp()
        app.buttons["away-test"].tap()
        let words = app.staticTexts["away-step-test-detail"]
        XCTAssertTrue(words.waitForExistence(timeout: 3))
        let shut = NSPredicate(format: "label CONTAINS 'Away from home is off'")
        expectation(for: shut, evaluatedWith: words)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(value(app, "away-step-test"), "To do")
    }

    func testAMacOnTailscaleButNotThisIPhoneSaysTurnItOn() throws {
        try XCTSkipUnless(env["MACROPHONE_AWAY"] == "1", "TEST_RUNNER_MACROPHONE_AWAY=1")
        let app = guide(["MACROPHONE_FAKE_AWAY": "tailscale", "MACROPHONE_FAKE_TAILSCALE": "off",
                         "MACROPHONE_FAKE_TAILSCALE_APP": "1", "MACROPHONE_FAKE_AWAY_TEST": "unreachable"])
        XCTAssertTrue(any(app, "away-step-mac").waitForExistence(timeout: 3))
        XCTAssertEqual(value(app, "away-step-mac"), "Done")
        XCTAssertEqual(value(app, "away-step-app"), "Done", "the app answers its link: installed")
        XCTAssertEqual(value(app, "away-step-signin"), "To do")
        XCTAssertFalse(any(app, "away-get-tailscale").exists)
        app.swipeUp()
        app.buttons["away-test"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Tailscale is off on this iPhone'"), evaluatedWith: app.staticTexts["away-step-test-detail"])
        waitForExpectations(timeout: 5)
    }

    func testEverythingReadyAndTheTestWorks() throws {
        try XCTSkipUnless(env["MACROPHONE_AWAY"] == "1", "TEST_RUNNER_MACROPHONE_AWAY=1")
        let app = guide(["MACROPHONE_FAKE_AWAY": "tailscale", "MACROPHONE_FAKE_TAILSCALE": "on", "MACROPHONE_FAKE_AWAY_TEST": "works"])
        for step in ["away-step-mac", "away-step-app", "away-step-signin"] {
            XCTAssertTrue(any(app, step).waitForExistence(timeout: 3), step)
            XCTAssertEqual(value(app, step), "Done", step)
        }
        XCTAssertFalse(app.buttons["away-open-tailscale"].exists)
        app.swipeUp()
        app.buttons["away-test"].tap()
        expectation(for: NSPredicate(format: "label == 'Works away from home.'"), evaluatedWith: app.staticTexts["away-step-test-detail"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(value(app, "away-step-test"), "Done")
        // Without Tailscale stays a small disclosure.
        XCTAssertTrue(any(app, "away-without-tailscale").exists)
        XCTAssertFalse(app.textFields["away-address"].exists, "folded until asked")
    }

    func testTheOfferComesOnceAndSetUpOpensTheGuide() throws {
        try XCTSkipUnless(env["MACROPHONE_AWAY"] == "1", "TEST_RUNNER_MACROPHONE_AWAY=1")
        let base = ["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Studio Mac", "MACROPHONE_FAKE_AWAY": "off", "MACROPHONE_FAKE_TAILSCALE": "off"]
        var e = base; e["MACROPHONE_AWAY_OFFER"] = "1"
        var app = launch(e)
        let setUp = app.buttons["away-offer-setup"]
        XCTAssertTrue(setUp.waitForExistence(timeout: 8))
        setUp.tap()
        XCTAssertTrue(app.navigationBars["Away from Home"].waitForExistence(timeout: 6), "Set Up opens the guide")
        app.terminate()
        // Answered: never again.
        e = base; e["MACROPHONE_AWAY_OFFER"] = "again"
        app = launch(e)
        XCTAssertFalse(app.buttons["away-offer-setup"].waitForExistence(timeout: 5))
        app.terminate()
        // Not Now is an answer too.
        e = base; e["MACROPHONE_AWAY_OFFER"] = "1"
        app = launch(e)
        XCTAssertTrue(app.buttons["away-offer-later"].waitForExistence(timeout: 8))
        app.buttons["away-offer-later"].tap()
        app.terminate()
        e = base; e["MACROPHONE_AWAY_OFFER"] = "again"
        app = launch(e)
        XCTAssertFalse(app.buttons["away-offer-setup"].waitForExistence(timeout: 5))
    }

    func testCantFindTheMacAwayOffersTheMissingStep() throws {
        try XCTSkipUnless(env["MACROPHONE_AWAY"] == "1", "TEST_RUNNER_MACROPHONE_AWAY=1")
        var app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Studio Mac@offline", "MACROPHONE_FAKE_AWAY": "off"])
        let setUp = app.buttons["empty-away-setup"]
        XCTAssertTrue(setUp.waitForExistence(timeout: 10))
        setUp.tap()
        XCTAssertTrue(app.navigationBars["Away from Home"].waitForExistence(timeout: 6))
        app.terminate()
        app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Studio Mac@offline",
                      "MACROPHONE_FAKE_AWAY": "tailscale", "MACROPHONE_FAKE_TAILSCALE": "off"])
        XCTAssertTrue(app.buttons["empty-turn-on-tailscale"].waitForExistence(timeout: 10))
    }

    /// The real thing, against `mpctl serve --remote --port <TEST_RUNNER_MACROPHONE_AWAY_PORT>`: the
    /// Mac's real Tailscale address arrives and step 1 checks itself; the test dials the serve's
    /// away door. (A Mac can't connect to its own Tailscale address — `nc` to it times out too —
    /// so the dial goes to the same door on loopback, `MACROPHONE_AWAY_TEST_ADDRESS`: the whole
    /// path from the button through the handshake's proof, only the route differs.)
    func testTheLiveTestReachesTheMacOverTailscale() throws {
        try XCTSkipUnless(env["MACROPHONE_AWAY_LIVE"] == "1", "TEST_RUNNER_MACROPHONE_AWAY_LIVE=1 with a paired mpctl serve --remote")
        let port = env["MACROPHONE_AWAY_PORT"] ?? "47821"
        let app = launch(["MACROPHONE_SCREEN": "awaysetup", "MACROPHONE_AWAY_TEST_ADDRESS": "127.0.0.1:\(port)"])
        XCTAssertTrue(app.navigationBars["Away from Home"].waitForExistence(timeout: 10))
        let mac = any(app, "away-step-mac")
        expectation(for: NSPredicate(format: "value == 'Done'"), evaluatedWith: mac)
        waitForExpectations(timeout: 15)
        XCTAssertEqual(value(app, "away-step-signin"), "Done", "the simulator shares the Mac's Tailscale address")
        app.swipeUp()
        app.buttons["away-test"].tap()
        expectation(for: NSPredicate(format: "label == 'Works away from home.'"), evaluatedWith: app.staticTexts["away-step-test-detail"])
        waitForExpectations(timeout: 15)
        XCTAssertEqual(value(app, "away-step-test"), "Done")
        if let dir = env["MACROPHONE_AWAY_SHOTS"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("guide-live-works.png"))
        }
    }
}
