import XCTest

/// The iPhone Duo's poses (Oct 25 2026; the second pass the same day), with real touches. The
/// laptop: the Mac fills the top half with a header laid over it that fades and comes back on a
/// touch, the question's answers floating over the picture's foot; the deck below opens on the
/// trackpad, which is the whole half — a drag there moves the pointer (read back off the
/// trackpad's value), the corner switcher brings the keyboard (the iOS keyboard rises, the Mac's
/// keys on its bar) and typing goes to the Mac (`mpctl serve` prints "WATCH TYPE N characters"),
/// then the mic; Done leaves the glance — the window still live — and Show it here takes it
/// back. The book: the same on the left and right pages. Open: the window large and the mic
/// and the panel off the fold; on its side, the rail. The simulator can't be folded from a
/// script, so the pose is forced (`MACROPHONE_POSTURE=…`) in the inner screen's frame
/// (`MACROPHONE_FRAME=…`, drawn to scale on the cover). Needs a paired `mpctl serve`.
final class DuoUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ pose: String, frame: String, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        var env = ["MACROPHONE_SCREEN": "main", "MACROPHONE_FRAME": frame, "MACROPHONE_POSTURE": pose, "MACROPHONE_SEND_TO": "Terminal"]
        env.merge(extra) { $1 }
        app.launchEnvironment = env
        app.launch()
        // A fresh simulator: the system's notifications prompt would take every touch.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        return app
    }

    /// The inner screen's frame on the cover: drawn to scale from the top left (`duo-frame`).
    private func innerFrame(_ app: XCUIApplication, _ frame: String) -> CGRect {
        let f = app.descendants(matching: .any)["duo-frame"].firstMatch
        XCTAssertTrue(f.waitForExistence(timeout: 10), "the inner screen's frame is drawn")
        return f.frame
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

    /// A page by the corner switcher: its cell by name (the frame is drawn at 0.4×, so a cell is
    /// 18 × 14 points on the cover — a tap on the cell itself lands, a fraction of the row may not).
    private func pick(_ switcher: XCUIElement, _ page: String, at fraction: CGFloat) {
        let cell = switcher.buttons[page]
        let want = NSPredicate(format: "value == %@", page)
        // A cell that small can be missed by a point or two: a few tries, a nudge up and down.
        for nudge in [0, -4, 4, 2, -2] as [CGFloat] {
            if cell.exists {
                cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: nudge)).tap()
            } else {
                switcher.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).withOffset(CGVector(dx: 0, dy: nudge)).tap()
            }
            if XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: want, object: switcher)], timeout: 1.5) == .completed { return }
        }
    }

    private func dismissTips(_ app: XCUIApplication) {
        let gotIt = app.buttons["Got it"]
        for _ in 0..<6 where gotIt.waitForExistence(timeout: 1) { gotIt.tap() }
    }

    func testLaptopPoseIsAMacAboveAndTheDeckBelow() throws {
        let app = launch("laptop", frame: "951x669")
        let inner = innerFrame(app, "951x669")
        // The pose opens the window view by itself, on the trackpad page (the corner switcher).
        let switcher = app.descendants(matching: .any)["input-pages"]
        guard switcher.waitForExistence(timeout: 20) else { throw XCTSkip("no Mac naming the keyboard and trackpad pages is connected") }
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        // The deck remembers its page per pose (a run before may have left it on the mic).
        if switcher.value as? String != "Trackpad" { pick(switcher, "Trackpad", at: 0.83) }
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5), "the laptop deck opens on the trackpad")
        XCTAssertEqual(switcher.value as? String, "Trackpad")
        // The header comes up on a touch of the Mac's half, fades a few seconds later, and comes
        // back on the next touch.
        let done = app.buttons["watch-done"]
        let screen = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: inner.midX, dy: inner.minY + inner.height * 0.2))
        screen.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 2), "a touch on the Mac's half brings the overlay header up")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: done)
        waitForExpectations(timeout: 8)
        shot("laptop-faded")
        screen.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 2), "and the next touch brings it back")
        dismissTips(app)
        // The trackpad is the whole bottom half.
        XCTAssertGreaterThan(trackpad.frame.minY, inner.midY - 2, "the trackpad is in the bottom half")
        XCTAssertGreaterThan(trackpad.frame.height, (inner.height / 2) * 0.8, "and takes nearly all of it: \(trackpad.frame.height) of \(inner.height / 2)")
        // The question's answers float over the Mac's half, not on the deck.
        let answer = app.buttons["watch-answer-0"]
        XCTAssertTrue(answer.waitForExistence(timeout: 8), "the demo Mac's question is up")
        XCTAssertLessThan(answer.frame.maxY, inner.midY, "the answers sit over the picture's foot")
        shot("laptop-trackpad")

        // A drag on the trackpad moves the pointer.
        let before = pointer(trackpad)
        let mid = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: trackpad.frame.midX, dy: trackpad.frame.midY))
        mid.press(forDuration: 0.05, thenDragTo: mid.withOffset(CGVector(dx: 60, dy: 14)))
        let after = pointer(trackpad)
        XCTAssertGreaterThan(after.0, before.0, "the pointer went right: \(before) → \(after)")
        XCTAssertGreaterThanOrEqual(after.1, before.1, "and a little down")
        mid.tap()

        // The corner switcher: the keyboard rises over the deck, with the Mac's keys on its bar.
        pick(switcher, "Keyboard", at: 0.17)
        // A fresh simulator's first keyboard may bring a system prompt that takes the keyboard's
        // first moment (and the page with it): put it away and ask again.
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 2) { cont.tap() }
        if switcher.value as? String != "Keyboard" { pick(switcher, "Keyboard", at: 0.17) }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 6), "the iOS keyboard comes up")
        XCTAssertEqual(switcher.value as? String, "Keyboard")
        XCTAssertTrue(app.buttons["keyboard-escape"].waitForExistence(timeout: 3), "esc and the arrows ride on the bar")
        app.typeText("duo")
        shot("laptop-keyboard")
        let hide = app.buttons["Hide the keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3))
        hide.tap()
        // Hide goes back to the page the keyboard rose over — the trackpad here, the hands
        // already on the deck (the third pass; the mic on a flat screen, as ever).
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5), "hide comes back to the trackpad it rose over")
        XCTAssertEqual(switcher.value as? String, "Trackpad")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        // The mic by the switcher: on the deck, under the fold.
        pick(switcher, "Mic", at: 0.5)
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "the switcher brings the mic")
        XCTAssertEqual(switcher.value as? String, "Mic")
        XCTAssertGreaterThan(mic.frame.minY, inner.midY, "the mic is on the deck")
        shot("laptop-mic")

        // Back to the trackpad by the switcher; Done leaves the glance — the window still live —
        // and Show it here takes it back in hand.
        pick(switcher, "Trackpad", at: 0.83)
        XCTAssertTrue(trackpad.waitForExistence(timeout: 3))
        // A tap on the overlay header's own ground is the header's, never a click on the Mac.
        screen.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        done.tap()
        XCTAssertTrue(app.buttons["duo-show"].waitForExistence(timeout: 5), "Done leaves the glance, with Show it here")
        XCTAssertTrue(app.staticTexts["Live on your Mac"].waitForExistence(timeout: 3), "the glance is the window, still live")
        XCTAssertFalse(trackpad.exists, "the deck's pages are put away")
        shot("laptop-glance")
        app.buttons["duo-show"].tap()
        XCTAssertTrue(trackpad.waitForExistence(timeout: 8), "Show it here brings the window and the deck back")
    }

    func testBookPoseHasTheMacOnTheLeftPageAndTheDeckOnTheRight() throws {
        let app = launch("book", frame: "669x951")
        let inner = innerFrame(app, "669x951")
        let switcher = app.descendants(matching: .any)["input-pages"]
        guard switcher.waitForExistence(timeout: 20) else { throw XCTSkip("no Mac naming the keyboard and trackpad pages is connected") }
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        if switcher.value as? String != "Trackpad" { pick(switcher, "Trackpad", at: 0.83) }
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5))
        // A touch on the left page brings its header up.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: inner.minX + inner.width * 0.25, dy: inner.midY)).tap()
        XCTAssertTrue(app.buttons["watch-done"].waitForExistence(timeout: 3), "a touch on the Mac's page brings the header up")
        dismissTips(app)
        // The deck is the right page, the trackpad nearly all of it; the answers on the left.
        XCTAssertGreaterThan(trackpad.frame.minX, inner.midX - 2, "the trackpad is on the right page")
        XCTAssertGreaterThan(trackpad.frame.height, inner.height * 0.8, "and takes nearly the whole page")
        let answer = app.buttons["watch-answer-0"]
        XCTAssertTrue(answer.waitForExistence(timeout: 8))
        XCTAssertLessThan(answer.frame.maxX, inner.midX, "the answers float over the Mac's page")
        shot("book")
    }

    func testOpenPortraitKeepsTheMicOffTheFold() throws {
        let app = launch("portrait", frame: "669x951")
        let inner = innerFrame(app, "669x951")
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        let places = app.descendants(matching: .any)["places"].firstMatch
        XCTAssertTrue(places.waitForExistence(timeout: 10), "Send to is on the screen beside the mic")
        // The fold runs down the middle: the mic sits in the right half, the panel in the left.
        XCTAssertGreaterThan(mic.frame.minX, inner.midX - 20, "the mic is clear of the fold")
        XCTAssertLessThan(places.frame.maxX, inner.midX + 20, "the panel is clear of the fold")
        // The window gets the room: the bottom bar is the lower part of the screen only.
        XCTAssertGreaterThan(places.frame.minY, inner.height * 0.62, "the bar is compact, under a large window")
        shot("portrait")
    }

    func testOpenLandscapeKeepsTheRailOnTheRight() throws {
        let app = launch("landscape", frame: "951x669")
        let inner = innerFrame(app, "951x669")
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        let places = app.descendants(matching: .any)["places"].firstMatch
        XCTAssertTrue(places.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(places.frame.minX, inner.width * 0.6, "Send to is in the rail")
        XCTAssertGreaterThan(mic.frame.minX, inner.width * 0.6, "and so is the mic")
        let switcher = app.descendants(matching: .any)["input-pages"]
        guard switcher.waitForExistence(timeout: 15) else { throw XCTSkip("no Mac naming the pages is connected") }
        pick(switcher, "Trackpad", at: 0.9)
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        XCTAssertTrue(trackpad.waitForExistence(timeout: 3), "the deck's trackpad fills the rail's foot")
        XCTAssertGreaterThan(trackpad.frame.minX, inner.width * 0.6)
        shot("landscape")
    }
}
