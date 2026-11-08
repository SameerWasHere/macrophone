import XCTest

/// A window held while the link is made, and a window of an app that isn't open (Nov 7 2026).
///
/// - `testAWindowOpenedBeforeTheMacIsUpSaysConnecting` (`TEST_RUNNER_MACROPHONE_NO_MAC=1`, a
///   simulator paired with a Mac that isn't running): the widget's link opens Claude's window at
///   launch, before any link — nothing over the held picture while the app comes up, then
///   "Connecting to ‹Mac›", never "Reconnecting".
/// - `testAnAppThatIsntOpenClosesTheView` (`TEST_RUNNER_MACROPHONE_QUIT_TEST=1`, paired with
///   `mpctl serve --quit com.tinyspeck.slackmacgap`): the phone's list (held stale by the fake
///   targets) names Slack, the Mac says it isn't open — the view closes and the desktop's card
///   says "Slack isn't open" with Open Slack.
final class WatchConnectingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testAWindowOpenedBeforeTheMacIsUpSaysConnecting() throws {
        guard env["MACROPHONE_NO_MAC"] == "1" else { throw XCTSkip("set TEST_RUNNER_MACROPHONE_NO_MAC=1 with the paired Mac stopped") }
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main",
                                 "MACROPHONE_OPEN_URL": "macrophone://watch?target=app:com.anthropic.claudefordesktop%23"]
        app.launch()
        let capsule = app.descendants(matching: .any)["watch-reconnecting"].firstMatch
        // The app coming up (`settling`, 2.5 s): nothing over the held picture.
        let quietEnd = Date().addingTimeInterval(2)
        while Date() < quietEnd {
            XCTAssertFalse(capsule.exists, "nothing over the held picture while the app comes up")
        }
        XCTAssertTrue(app.buttons["watch-done"].exists, "the window view is open")
        XCTAssertTrue(capsule.waitForExistence(timeout: 6), "once the app has come up, the hold says what it's waiting for")
        XCTAssertTrue(capsule.label.hasPrefix("Connecting to"), "a first connect, not a reconnect: \(capsule.label)")
    }

    func testAnAppThatIsntOpenClosesTheView() throws {
        guard env["MACROPHONE_QUIT_TEST"] == "1" else { throw XCTSkip("set TEST_RUNNER_MACROPHONE_QUIT_TEST=1 with mpctl serve --quit com.tinyspeck.slackmacgap paired") }
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_TARGETS": "default",
                                 "MACROPHONE_SEND_TO": "Slack", "MACROPHONE_WATCH": "rest", "MACROPHONE_WATCH_ACTIONS": "open"]
        app.launch()
        // The view opens on the stale list's Slack and the Mac answers at once, so it's gone within
        // a few milliseconds: what's checked is where it lands. The status line's words come only
        // from the Mac's answer (`AppModel.watchedAppNotOpen`).
        let said = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Slack isn't open on your Mac")).firstMatch
        XCTAssertTrue(said.waitForExistence(timeout: 15), "the status line says the Mac answered that Slack isn't open")
        let open = app.buttons["desktop-window-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 3), "the desktop's card says Slack isn't open, with Open")
        XCTAssertTrue(app.staticTexts["Slack isn't open"].exists)
        let done = app.buttons["watch-done"]
        XCTAssertFalse(done.exists && done.isHittable, "no dead window view is left open")
    }
}
