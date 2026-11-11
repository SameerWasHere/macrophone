import XCTest

/// Real swipes on the window in Scroll (Nov 10 2026), for recording the scroll prediction frame by
/// frame (`xcrun simctl io <udid> recordVideo` beside it). Needs `mpctl serve` paired with this
/// simulator. `TEST_RUNNER_MACROPHONE_PREDICT_SCROLL=1|0` turns the prediction on or off for the
/// run, `TEST_RUNNER_MACROPHONE_FAKE_LAG=<ms>` stands in for a slow link (every frame shown that
/// much later). It checks only that the swipes reach the window and nothing breaks; the judging is
/// by eye.
final class ScrollAheadUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSwipesInScroll() throws {
        let app = XCUIApplication()
        var env = ["MACROPHONE_SCREEN": "main", "MACROPHONE_WATCH": "1", "MACROPHONE_SEND_TO": "Claude"]
        let mine = ProcessInfo.processInfo.environment
        for k in ["MACROPHONE_PREDICT_SCROLL", "MACROPHONE_FAKE_LAG", "MACROPHONE_WATCH_TIMING"] { if let v = mine[k] { env[k] = v } }
        app.launchEnvironment = env
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let done = app.buttons["watch-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        sleep(3)
        let scroll = app.buttons["Scroll"].firstMatch
        if scroll.exists { scroll.tap() }
        sleep(1)
        let screen = app.windows.firstMatch
        // Slow drags up and down over the window's middle, a pause between, then two flicks.
        for (from, to) in [(0.55, 0.30), (0.30, 0.55), (0.55, 0.25), (0.25, 0.6)] {
            let a = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            let b = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: 300, thenHoldForDuration: 0.4)
            sleep(1)
        }
        for (from, to) in [(0.6, 0.3), (0.3, 0.6)] {
            let a = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            let b = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
            a.press(forDuration: 0.02, thenDragTo: b, withVelocity: 1500, thenHoldForDuration: 0)
            sleep(3)
        }
        XCTAssertTrue(done.exists)
    }
}
