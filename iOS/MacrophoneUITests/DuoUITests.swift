import XCTest

/// The iPhone Duo's laptop pose (Oct 25 2026), with real touches: the Mac on the top half, the
/// deck below it opening on the trackpad — a drag there moves the pointer (read back off the
/// trackpad's value), the page row switches to the keyboard (the iOS keyboard rises, the bar's
/// keys with it) and typing goes to the Mac (`mpctl serve` prints "WATCH TYPE N characters"),
/// then the mic page; Done brings the glance. The simulator can't be folded from a script, so
/// the pose is forced (`MACROPHONE_POSTURE=laptop`) in the inner screen's frame
/// (`MACROPHONE_FRAME=951x669`, drawn to scale on the cover). Needs a paired `mpctl serve`.
final class DuoUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ pose: String, frame: String, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        var env = ["MACROPHONE_SCREEN": "main", "MACROPHONE_FRAME": frame, "MACROPHONE_POSTURE": pose]
        env.merge(extra) { $1 }
        app.launchEnvironment = env
        app.launch()
        return app
    }

    /// "Pointer 52 percent across, 61 percent down" → (52, 61).
    private func pointer(_ trackpad: XCUIElement) -> (Int, Int) {
        let words = (trackpad.value as? String ?? "").components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        return (words.first ?? -1, words.dropFirst().first ?? -1)
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MACROPHONE_DUO_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testLaptopPoseTrackpadKeyboardAndMic() throws {
        let app = launch("laptop", frame: "951x669")
        // The pose opens the window view by itself, on the trackpad page.
        let row = app.descendants(matching: .any)["input-pages"]
        guard row.waitForExistence(timeout: 20) else { throw XCTSkip("no Mac naming the keyboard and trackpad pages is connected") }
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5), "the laptop pose opens on the trackpad")
        XCTAssertEqual(row.value as? String, "Trackpad")
        XCTAssertTrue(app.buttons["watch-done"].exists, "the window's controls are on the deck")
        // The first-use tip, if it's up, would take the touches.
        let gotIt = app.buttons["Got it"]
        for _ in 0..<6 where gotIt.waitForExistence(timeout: 1) { gotIt.tap() }
        shot("laptop-trackpad")

        // A drag on the trackpad moves the pointer.
        let before = pointer(trackpad)
        let mid = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: trackpad.frame.midX, dy: trackpad.frame.midY))
        mid.press(forDuration: 0.05, thenDragTo: mid.withOffset(CGVector(dx: 60, dy: 14)))
        let after = pointer(trackpad)
        XCTAssertGreaterThan(after.0, before.0, "the pointer went right: \(before) → \(after)")
        XCTAssertGreaterThanOrEqual(after.1, before.1, "and a little down")
        // A tap on the trackpad clicks (the demo Mac prints the click).
        mid.tap()

        // The page row: the keyboard rises over the deck, with the Mac's keys on its bar.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 6), "the iOS keyboard comes up")
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 1) { cont.tap() }
        XCTAssertEqual(row.value as? String, "Keyboard")
        XCTAssertTrue(app.buttons["keyboard-escape"].waitForExistence(timeout: 3), "esc and the arrows ride on the bar")
        app.typeText("duo")
        shot("laptop-keyboard")
        let hide = app.buttons["Hide the keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3))
        hide.tap()
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "hide comes back to the mic")
        XCTAssertEqual(row.value as? String, "Mic")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        shot("laptop-mic")

        // Back to the trackpad by the row; Done leaves the glance on the Mac's half.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(trackpad.waitForExistence(timeout: 3))
        app.buttons["watch-done"].tap()
        XCTAssertTrue(app.buttons["duo-show"].waitForExistence(timeout: 5), "Done leaves the glance: the picked app, and Show it here")
        shot("laptop-glance")
        app.buttons["duo-show"].tap()
        XCTAssertTrue(app.buttons["watch-done"].waitForExistence(timeout: 8), "Show it here brings the window back")
    }

    func testBookPoseHasTheDeckOnTheRightPage() throws {
        let app = launch("book", frame: "669x951")
        let row = app.descendants(matching: .any)["input-pages"]
        guard row.waitForExistence(timeout: 20) else { throw XCTSkip("no Mac naming the keyboard and trackpad pages is connected") }
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5))
        let window = app.descendants(matching: .any)["watch-done"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        // The deck (Done, the trackpad) is on the right page; the Mac's picture on the left.
        XCTAssertGreaterThan(trackpad.frame.minX, app.frame.width * 0.4, "the trackpad is on the right page")
        shot("book")
    }

    func testOpenPortraitKeepsTheMicOffTheFold() throws {
        let app = launch("portrait", frame: "669x951")
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        let places = app.descendants(matching: .any)["places"].firstMatch
        XCTAssertTrue(places.waitForExistence(timeout: 10), "Send to is on the screen beside the window")
        // The fold runs down the middle: the mic sits in the right half, the panel in the left.
        XCTAssertGreaterThan(mic.frame.minX, app.frame.width * 0.5 - 40, "the mic is clear of the fold")
        XCTAssertLessThan(places.frame.maxX, app.frame.width * 0.5 + 40, "the panel is clear of the fold")
        shot("portrait")
    }
}
