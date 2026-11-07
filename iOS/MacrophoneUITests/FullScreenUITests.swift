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

    /// Nov 7 2026: the way out stays beside the mic (no fade), and the trackpad button on the mic's
    /// other side brings the same pad up, lit while it's up; a drag on the pad moves the pointer,
    /// a tap on the button puts it away.
    func testTheTrackpadButtonAndThePermanentExit() {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": "Terminal",
                                 "MACROPHONE_WATCH": "1", "MACROPHONE_WATCH_ACTIONS": "fullscreen"]
        app.launch()
        let exit = app.buttons["watch-fullscreen-exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 15), "full screen is up")
        // A toggle (`.isToggle`): XCUITest lists it as a switch, not a button.
        let button = app.descendants(matching: .any)["watch-fullscreen-trackpad"]
        XCTAssertTrue(button.waitForExistence(timeout: 2), "the trackpad button is beside the mic")
        // The mic (52 pt) between them: the way out left, the trackpad right, both level with it.
        // (`mic-button` matches the hidden layout's kept mic too, so measure the pair.)
        XCTAssertEqual(button.frame.midX - exit.frame.midX, 2 * (52 * 0.65 + 6 + 20), accuracy: 2,
                       "the way out left of the mic, the trackpad right of it")
        XCTAssertEqual(exit.frame.midY, button.frame.midY, accuracy: 1, "both level with the disc")
        // Longer than the old 3.5 s fade, nothing touched: still there, and hittable.
        sleep(6)
        XCTAssertTrue(exit.isHittable, "the way out never fades")
        XCTAssertEqual(button.value as? String, "Off")

        button.tap()
        let pad = app.descendants(matching: .any)["fullscreen-trackpad"]
        XCTAssertTrue(pad.waitForExistence(timeout: 1), "the button brought the trackpad up")
        XCTAssertEqual(button.value as? String, "On", "lit while the pad is up")
        XCTAssertLessThan(pad.frame.maxY, button.frame.minY + 1, "the pad sits above the mic, clear of it")
        // A drag moves the pointer (serve's log: WATCH MOUSE …).
        let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)))
        // …then a click where it went ("WATCH MOUSE click … after N moves").
        sleep(1)
        pad.tap()
        sleep(1)
        XCTAssertTrue(pad.exists, "it stays while it's used")
        button.tap()
        sleep(1)
        XCTAssertFalse(pad.exists, "a second tap puts it away")
        XCTAssertEqual(button.value as? String, "Off")

        // And it dissolves by itself after 3 s unused.
        button.tap()
        XCTAssertTrue(pad.waitForExistence(timeout: 1))
        sleep(4)
        XCTAssertFalse(pad.exists, "it dissolved after 3 s unused")
    }
}
