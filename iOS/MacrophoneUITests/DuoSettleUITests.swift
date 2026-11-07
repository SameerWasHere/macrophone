import XCTest

/// The Duo's inner screen never shows a control in the wrong place (Nov 7 2026), on a real Duo
/// simulator held in a real pose (`duo-sim.sh pose <udid> tabletop|folded` before the run, and
/// `TEST_RUNNER_MACROPHONE_DUO_REAL=laptop|book` to say which): launched folded it goes straight
/// to the window in hand — the desktop's places and Send after pasting never show while the
/// window comes up — and on the laptop the mic, coming back from the keyboard, first appears
/// where it stays. Needs a paired `mpctl serve`.
final class DuoSettleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var pose: String? { ProcessInfo.processInfo.environment["MACROPHONE_DUO_REAL"] }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": "Claude"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        return app
    }

    /// Folded, the first thing drawn is the window in hand: never the desktop first.
    func testAFoldedLaunchGoesStraightToTheWindowInHand() throws {
        guard pose == "laptop" || pose == "book" else { throw XCTSkip("set TEST_RUNNER_MACROPHONE_DUO_REAL=laptop|book on a folded Duo") }
        let app = launch()
        let window = app.descendants(matching: .any)["duo-window"].firstMatch
        let places = app.descendants(matching: .any)["places"].firstMatch
        let sendToggle = app.descendants(matching: .any)["send-toggle"].firstMatch
        var sawWindow = false
        // From the launch until well after the link is up.
        let end = Date().addingTimeInterval(6)
        while Date() < end {
            XCTAssertFalse(places.exists, "the desktop's places never show on a folded launch")
            XCTAssertFalse(sendToggle.exists, "Send after pasting never shows on a folded launch")
            if window.exists { sawWindow = true }
        }
        XCTAssertTrue(sawWindow, "the window in hand appears")
        XCTAssertTrue(app.buttons["watch-done"].exists, "the window is in hand (Done is there)")
    }

    /// The laptop: keyboard, then mic — the mic's first frame on screen is its frame a second on.
    func testTheMicFirstAppearsWhereItStays() throws {
        guard pose == "laptop" else { throw XCTSkip("set TEST_RUNNER_MACROPHONE_DUO_REAL=laptop on a Duo held as a laptop") }
        let app = launch()
        let keyboard = app.descendants(matching: .any)["input-mode-keyboard"].firstMatch
        guard keyboard.waitForExistence(timeout: 20) else { throw XCTSkip("no Mac naming the keyboard is connected") }
        keyboard.tap()
        XCTAssertTrue(app.buttons["keyboard-hide"].waitForExistence(timeout: 5), "the keyboard is up")
        let mic = app.buttons["mic-button"].firstMatch
        app.descendants(matching: .any)["input-mode-mic"].firstMatch.tap()
        var first: CGRect?
        let end = Date().addingTimeInterval(4)
        while Date() < end, first == nil {
            if mic.exists, mic.isHittable { first = mic.frame }
        }
        guard let first else { return XCTFail("the mic appears") }
        Thread.sleep(forTimeInterval: 1)
        let later = mic.frame
        XCTAssertEqual(first.midX, later.midX, accuracy: 1, "the mic first appears where it stays (across)")
        XCTAssertEqual(first.midY, later.midY, accuracy: 1, "the mic first appears where it stays (down)")
        XCTAssertEqual(first.width, later.width, accuracy: 1, "…at the size it stays")
    }
}
