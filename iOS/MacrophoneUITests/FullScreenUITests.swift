import XCTest

/// Full screen on the Duo's inner screen on its side (Nov 3 2026): a hold on the picture brings a
/// see-through trackpad up under the finger, and the same finger moves the pointer without lifting;
/// a tap on the pad clicks; 3 s untouched, it goes. Run on a Duo simulator opened flat on its side
/// (`duo-sim.sh pose <udid> open`), paired with `mpctl serve` — whose log shows the moves and the
/// click ("WATCH MOUSE click … after N moves").
final class FullScreenUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testHoldBringsTheTrackpadAndDrives() {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": "Terminal",
                                 "MACROPHONE_WATCH": "1", "MACROPHONE_WATCH_ACTIONS": "fullscreen"]
        app.launch()
        let exit = app.buttons["watch-fullscreen-exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 15), "full screen is up")
        sleep(2)

        // Hold, then move on without lifting.
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.62))
        from.press(forDuration: 0.8, thenDragTo: to)

        let pad = app.descendants(matching: .any)["fullscreen-trackpad"]
        XCTAssertTrue(pad.waitForExistence(timeout: 1), "the hold brought the trackpad up")
        // A tap on it clicks on the Mac (serve's log says how many moves came before).
        pad.tap()
        sleep(1)
        XCTAssertTrue(pad.exists, "it stays while it's used")
        // 3 s untouched: gone.
        sleep(4)
        XCTAssertFalse(pad.exists, "it dissolved after 3 s unused")
    }
}
