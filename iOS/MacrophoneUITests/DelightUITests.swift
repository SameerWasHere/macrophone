import XCTest

/// Delight (Nov 8 2026): a real finger plucks the Thread at rest — a tap, then a pull down and
/// let go — and the mic beside it is untouched (it never starts recording from a touch on the
/// Thread). Each pluck is counted in the app's defaults under `debug.plucks` (DEBUG), so a run
/// can be checked with `plutil -p "$(xcrun simctl get_app_container <udid> com.sameer.macrophone
/// data)/Library/Preferences/com.sameer.macrophone.plist"` (two more per run).
/// Needs a paired simulator (the mic screen at rest).
final class DelightUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAFingerPlucksTheThreadAndNotTheMic() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main"]
        app.launch()
        let mic = app.buttons["mic-button"].firstMatch
        guard mic.waitForExistence(timeout: 10) else { throw XCTSkip("not at the mic screen (pair first)") }
        sleep(2)
        let f = mic.frame
        let window = app.windows.firstMatch.frame
        // The Thread's band sits just above the mic (its 84 pt slot, 30 pt over the mic's frame).
        let threadY = f.minY - 60
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        point(window.width * 0.3, threadY).tap()
        sleep(1)
        point(window.width * 0.7, threadY - 10).press(forDuration: 0.1, thenDragTo: point(window.width * 0.7, threadY + 30))
        sleep(2)
        XCTAssertEqual(app.staticTexts["Listening — tap to send"].exists, false, "a touch on the Thread never opens the mic")
        XCTAssertTrue(mic.exists)
        XCTAssertEqual(mic.label, "Start dictation", "the mic stayed closed")
    }
}
