import XCTest

/// The app icon's long press (Nov 5 2026), on a phone paired with `mpctl serve` that has
/// watched a window of its demo Claude once (`MACROPHONE_INTENT_WATCH=Claude`). Run with
/// `TEST_RUNNER_MACROPHONE_QUICK_TEST=1`; screenshots go to `TEST_RUNNER_MACROPHONE_QUICK_SHOTS=<dir>`.
/// serve's log is the proof of each: `WATCH Claude`, `WATCH Whole Screen …`, `RECEIVED … quick action`.
final class QuickActionsUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACROPHONE_QUICK_TEST"] == "1", "needs a paired mpctl serve")
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MACROPHONE_QUICK_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    /// Home, then a long press on the icon; the menu's item that starts with `title`.
    private func longPressIcon(choose title: String, shotName: String) {
        XCUIDevice.shared.press(.home)
        springboard.activate()
        // A system tip over the Home Screen (the keyboard's "slide to type") goes first.
        let tip = springboard.buttons["Continue"]
        if tip.waitForExistence(timeout: 2) { tip.tap() }
        let icon = springboard.icons["Macrophone"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "the app's icon on the Home Screen")
        // A fresh simulator puts it on the second page.
        for _ in 0..<3 where !icon.isHittable { springboard.swipeLeft(); sleep(1) }
        icon.press(forDuration: 1.2)
        let item = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title) in the long press")
        shot(shotName)
        item.tap()
    }

    /// Cold: launched once so the Home Screen is the test's to drive, then quit.
    private func notRunning(_ app: XCUIApplication) {
        app.launch()
        app.terminate()
    }

    private func connected(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Connected to'")).firstMatch
    }

    /// The app not running: Watch Claude opens it on Claude's window once the Mac connects.
    func testColdWatchOpensTheWindow() {
        let app = XCUIApplication()
        notRunning(app)
        longPressIcon(choose: "Watch Claude", shotName: "1-menu-cold")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.buttons["watch-done"].waitForExistence(timeout: 20), "watching")
        sleep(2)
        shot("2-cold-watch-claude")
        app.buttons["watch-done"].tap()
    }

    /// Cold too: Whole Screen waits for the Mac to say it can show it.
    func testColdWholeScreen() {
        let app = XCUIApplication()
        notRunning(app)
        longPressIcon(choose: "Whole Screen", shotName: "3-menu-screen")
        XCTAssertTrue(app.buttons["watch-done"].waitForExistence(timeout: 20), "watching the whole screen")
        sleep(2)
        shot("4-cold-whole-screen")
        app.buttons["watch-done"].tap()
    }

    /// The scene's own delegate (for the long press) leaves SwiftUI's links alone: the Watch
    /// widget's URL still opens its window.
    func testWidgetLinkStillWatches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(connected(app).waitForExistence(timeout: 20), "connected")
        XCUIDevice.shared.system.open(URL(string: "macrophone://watch?target=app:com.anthropic.claudefordesktop%23")!)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(app.buttons["watch-done"].waitForExistence(timeout: 15), "the widget's link watches")
        shot("8-widget-link")
        app.buttons["watch-done"].tap()
    }

    /// Siri, as far as the simulator goes: "Watch my Mac with Macrophone" (no follow-up question;
    /// the simulator's Siri didn't match the parameterized "Watch Claude with Macrophone").
    func testSiriWatch() throws {
        let app = XCUIApplication()
        notRunning(app)
        XCUIDevice.shared.siriService.activate(voiceRecognitionText: "Watch my Mac with Macrophone")
        sleep(6)
        shot("9-siri-watch")
        try XCTSkipUnless(app.buttons["watch-done"].waitForExistence(timeout: 20), "Siri didn't run it on this simulator")
        app.buttons["watch-done"].tap()
    }

    /// The app in the background: Dictate to the pick starts the mic at once; the stand-in
    /// recognizer's words go to the Mac on stop.
    func testWarmDictate() {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SIM_RECORD": "Sent from the quick action"]
        app.launch()
        XCTAssertTrue(connected(app).waitForExistence(timeout: 20), "connected")
        longPressIcon(choose: "Dictate to", shotName: "5-menu-warm")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let stop = app.buttons["Stop and send"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 8), "the mic opened by itself")
        sleep(2)
        shot("6-warm-dictating")
        stop.tap()
        // Cleanup on the simulator's model takes a few seconds before it goes.
        sleep(15)
        shot("7-warm-sent")
    }
}
