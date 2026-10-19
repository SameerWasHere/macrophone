import XCTest

/// Several Macs on one iPhone (Oct 19 2026), against two demo Macs: `mpctl serve --name "Studio
/// Mac" --remote --port 47951 --state <A>` and `--name "MacBook Air" --port 47952 --state <B>`,
/// both paired already (MACROPHONE_OPEN_URL with each PAIR URL; the second paired is active).
/// Run with `TEST_RUNNER_MACROPHONE_MULTI_TEST=1`; screenshots go to
/// `TEST_RUNNER_MACROPHONE_MULTI_SHOTS=<dir>` when given. Each serve prints the dictations it
/// gets, so the shell checks which Mac received which words.
final class MultiMacUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACROPHONE_MULTI_TEST"] == "1", "needs two paired mpctl serves")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MACROPHONE_MULTI_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func pill(_ app: XCUIApplication) -> XCUIElement { app.buttons["mac-pill"].firstMatch }

    private func connected(_ app: XCUIApplication, to mac: String, timeout: TimeInterval = 20) -> Bool {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "Connected to \(mac)"), object: pill(app))
        return XCTWaiter().wait(for: [e], timeout: timeout) == .completed
    }

    /// A real swipe on the pill: a finger down on it, dragged up (the next Mac) or down (the one before).
    private func swipe(_ app: XCUIApplication, up: Bool) {
        let p = pill(app)
        let from = p.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = from.withOffset(CGVector(dx: 0, dy: up ? -70 : 70))
        from.press(forDuration: 0.1, thenDragTo: to)
        // The drag's touch is over; a beat before the next tap.
        usleep(400_000)
    }

    private func dictate(_ app: XCUIApplication) {
        let start = app.buttons["Start dictation"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: start)
        if XCTWaiter().wait(for: [ready], timeout: 10) != .completed { shot(app, "x-mic-not-hittable") }
        XCTAssertTrue(start.isHittable, "the mic is there to tap")
        start.tap()
        let stop = app.buttons["Stop and send"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        sleep(2)
        stop.tap()
        // The Mac's answer on the status line: the ack's words, then where it landed.
        let words = ["Printed by mpctl", "On your Mac's clipboard", "Pasted into", "Delivered"]
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: words.map { NSPredicate(format: "label CONTAINS %@", $0) })
        let landed = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(landed.waitForExistence(timeout: 20), "the Mac took it")
    }

    func testSwipeSwitchesMacsAndEachGetsItsOwnWords() {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SIM_RECORD": "words for the air"]
        app.launch()
        // The Mac paired last is the active one — unless a run before switched (the switch is
        // kept across launches): then one swipe brings it back.
        XCTAssertTrue(connected(app, to: ""), "connected to a Mac")
        if !pill(app).label.hasPrefix("Connected to MacBook Air") { swipe(app, up: true) }
        XCTAssertTrue(connected(app, to: "MacBook Air"), "connected to the Mac paired last")
        let before = pill(app).frame
        shot(app, "1-pill-air")
        dictate(app)
        shot(app, "2-sent-to-air")

        // A swipe up: the next Mac round the list (Studio Mac was paired first).
        swipe(app, up: true)
        XCTAssertTrue(connected(app, to: "Studio Mac"), "a swipe up switches to the other Mac and connects")
        XCTAssertEqual(pill(app).frame.minY, before.minY, accuracy: 0.5, "the pill stays on its line")
        XCTAssertEqual(pill(app).frame.minX, before.minX, accuracy: 0.5, "and in its corner")
        XCTAssertLessThan(abs(pill(app).frame.width - before.width), 60, "the pill's width follows the name, not the bar")
        shot(app, "3-pill-studio")
        app.terminate()

        // The same words go to the Studio Mac now (the serve's log says which got what).
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SIM_RECORD": "words for the studio"]
        app.launch()
        XCTAssertTrue(connected(app, to: "Studio Mac"), "the switch is kept across a launch")
        dictate(app)
        shot(app, "4-sent-to-studio")

        // A swipe down goes back.
        swipe(app, up: false)
        XCTAssertTrue(connected(app, to: "MacBook Air"), "a swipe down goes to the one before")

        // The tap: the Macs list, each with its standing; a tap picks one.
        // XCTest's tap right after its own drag sometimes doesn't land on a button that also
        // takes a drag; a finger does (checked by hand). One more tap by coordinate is fair.
        let list = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Your Macs'")).firstMatch
        for _ in 0..<3 where !list.exists {
            pill(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = list.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(list.exists, "the pill opens the Macs list")
        shot(app, "5-macs-list")
        // A row in a List is a cell to XCTest, not always a button: find by identifier, any kind.
        func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        XCTAssertTrue(element("mac-row-Studio Mac").waitForExistence(timeout: 3))
        XCTAssertTrue(element("mac-row-MacBook Air").exists)
        XCTAssertTrue(element("pair-another-mac").exists, "Pair Another Mac is in the list")
        element("mac-row-Studio Mac").tap()
        XCTAssertTrue(connected(app, to: "Studio Mac"), "a tap in the list switches")

        // Settings lists every Mac, with Unpair beside each.
        app.buttons["Settings"].tap()
        let unpairAir = element("unpair-MacBook Air")
        // The Macs section sits below Send to, Cleanup and Recording: scroll down to it.
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        for _ in 0..<5 where !unpairAir.exists { app.swipeUp(); sleep(1) }
        XCTAssertTrue(unpairAir.waitForExistence(timeout: 5), "Settings shows the other Mac too")
        XCTAssertTrue(element("unpair-Studio Mac").exists)
        shot(app, "6-settings-two-macs")
        unpairAir.tap()
        let confirm = app.buttons["Unpair"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        confirm.tap()
        XCTAssertTrue(unpairAir.waitForNonExistence(timeout: 10), "the forgotten Mac leaves the list")
        XCTAssertTrue(element("unpair-Studio Mac").exists, "the other stays")
        shot(app, "7-settings-one-mac")
        app.buttons["Done"].tap()
        XCTAssertTrue(connected(app, to: "Studio Mac"), "still on the Studio Mac")
        // With one Mac the pill opens Settings, as before.
        pill(app).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4), "one Mac: the pill opens Settings")
        shot(app, "8-one-mac-settings")
    }

    /// The pill held mid-roll (two fake Macs, no link), for the contact sheet.
    func testPillMidRollLook() {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Studio Mac|MacBook Air", "MACROPHONE_PILL_ROLL": "0.45"]
        app.launch()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 8))
        sleep(1)
        shot(app, "0-pill-mid-roll")
        // A real swipe on the fakes rolls the name too.
        swipe(app, up: true)
        XCTAssertTrue(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'Connected to MacBook Air'"), evaluatedWith: pill(app))], timeout: 5) == .completed)
    }
}
