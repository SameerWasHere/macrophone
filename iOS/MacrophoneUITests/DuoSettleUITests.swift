import XCTest

/// The Duo's inner screen never shows a control in the wrong place (Nov 7 2026), on a real Duo
/// simulator held in a real pose (`duo-sim.sh pose <udid> tabletop|folded` before the run, and
/// `TEST_RUNNER_MACROPHONE_DUO_REAL=laptop|book` to say which): launched folded it goes straight
/// to the window in hand — the glance and Send after pasting never show while the window comes
/// up — and on the laptop the mic, coming back from the keyboard, is only ever where it stays.
/// Needs a paired `mpctl serve`.
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
        // (Not `places`: the desktop's Dock is a scroll view, which stays in the accessibility tree
        // while its layer is kept built and hidden under the window in hand.)
        let glance = app.buttons["duo-show"]
        let sendToggle = app.descendants(matching: .any)["send-toggle"].firstMatch
        var sawWindow = false
        // From the launch until well after the link is up.
        let end = Date().addingTimeInterval(6)
        while Date() < end {
            XCTAssertFalse(glance.exists && glance.isHittable, "a folded launch never shows the glance (the window at rest)")
            XCTAssertFalse(sendToggle.exists && sendToggle.isHittable, "Send after pasting never shows on a folded launch")
            if window.exists { sawWindow = true }
        }
        XCTAssertTrue(sawWindow, "the window in hand appears")
        XCTAssertTrue(app.buttons["watch-done"].exists, "the window is in hand (Done is there)")
    }

    /// The laptop: the mic mode, the keyboard over it, hide — the mic is only ever where it stays.
    func testTheMicFirstAppearsWhereItStays() throws {
        guard pose == "laptop" else { throw XCTSkip("set TEST_RUNNER_MACROPHONE_DUO_REAL=laptop on a Duo held as a laptop") }
        let app = launch()
        let keyboard = app.descendants(matching: .any)["input-mode-keyboard"].firstMatch
        guard keyboard.waitForExistence(timeout: 20) else { throw XCTSkip("no Mac naming the keyboard is connected") }
        let mic = app.buttons["mic-button"].firstMatch
        app.descendants(matching: .any)["input-mode-mic"].firstMatch.tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "the mic mode shows the mic")
        keyboard.tap()
        let hide = app.buttons["keyboard-hide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "the keyboard is up")
        Thread.sleep(forTimeInterval: 1)
        hide.tap()
        // Hidden, it's never placed anywhere but a settled slot: every frame from here on is the last.
        var frames: [CGRect] = []
        let end = Date().addingTimeInterval(1.5)
        while Date() < end { if mic.exists, mic.isHittable { frames.append(mic.frame) } }
        guard let last = frames.last else { return XCTFail("the mic appears") }
        for f in frames {
            XCTAssertEqual(f.midX, last.midX, accuracy: 1, "the mic is only ever where it stays (across)")
            XCTAssertEqual(f.midY, last.midY, accuracy: 1, "the mic is only ever where it stays (down)")
            XCTAssertEqual(f.width, last.width, accuracy: 1, "…at the size it stays")
        }
        XCTAssertTrue(mic.isHittable, "the mic is back")
    }
}
