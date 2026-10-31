import XCTest

/// The iPhone Duo's poses (Oct 25 2026; the laptop re-laid Oct 31), with real touches. The
/// laptop: the picture alone fills the top half; the header, the answers, the keys, the mic and
/// a big trackpad are the deck — a drag there moves the pointer (read back off the trackpad's
/// value), ⌨︎ brings the keyboard and typing goes to the Mac (`mpctl serve` prints "WATCH TYPE N
/// characters"); Done leaves the glance — the window still live — and Show it here takes it
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

    /// The laptop (Oct 31 2026): the top half is the picture alone — the header, the answers, the
    /// keys all on the deck — and the trackpad takes the most of the deck.
    func testLaptopPoseIsAMacAboveAndTheDeckBelow() throws {
        let app = launch("laptop", frame: "951x669")
        let inner = innerFrame(app, "951x669")
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        guard trackpad.waitForExistence(timeout: 20) else { throw XCTSkip("no Mac naming the trackpad is connected") }
        dismissTips(app)
        let done = app.buttons["watch-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "the header is on the deck, always there")
        let answer = app.buttons["watch-answer-0"]
        XCTAssertTrue(answer.waitForExistence(timeout: 8), "the demo Mac's question is up")
        // Nothing over the picture: the header, the answers and the keys are all under the fold.
        for (what, e) in [("Done", done), ("the answers", answer), ("return", app.buttons["deck-return"]), ("the trackpad", trackpad)] {
            XCTAssertGreaterThan(e.frame.minY, inner.midY - 2, "\(what) is on the deck, not over the picture")
        }
        // The header stays (nothing to fade: it covers nothing).
        sleep(5)
        XCTAssertTrue(done.isHittable, "the deck's header never fades")
        // The trackpad is the most of the deck: over half its width, most of its height.
        XCTAssertGreaterThan(trackpad.frame.width, inner.width * 0.55, "the trackpad is wide: \(trackpad.frame.width) of \(inner.width)")
        XCTAssertGreaterThan(trackpad.frame.height, (inner.height / 2) * 0.6, "and tall: \(trackpad.frame.height) of \(inner.height / 2)")
        shot("laptop-trackpad")

        // A drag on the trackpad moves the pointer.
        let before = pointer(trackpad)
        let mid = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: trackpad.frame.midX, dy: trackpad.frame.midY))
        mid.press(forDuration: 0.05, thenDragTo: mid.withOffset(CGVector(dx: 60, dy: 14)))
        let after = pointer(trackpad)
        XCTAssertGreaterThan(after.0, before.0, "the pointer went right: \(before) → \(after)")
        mid.tap()
        // Two fingers spreading on the trackpad zoom in (⌘=; `mpctl serve` prints "WATCH KEY ⌘=").
        trackpad.pinch(withScale: 2.5, velocity: 2)
        XCTAssertTrue(app.staticTexts["Zoom in"].waitForExistence(timeout: 3), "a pinch on the trackpad zooms the Mac's window")

        // ⌨︎ on the keys: the iOS keyboard rises over the deck; hide comes back to the trackpad.
        app.buttons["deck-keyboard"].tap()
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 2) { cont.tap(); app.buttons["deck-keyboard"].tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 6), "the iOS keyboard comes up")
        app.typeText("duo")
        shot("laptop-keyboard")
        let hide = app.buttons["Hide the keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3))
        hide.tap()
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5), "hide comes back to the trackpad")

        // Done leaves the glance — the window still live — and Show it here takes it back.
        done.tap()
        XCTAssertTrue(app.buttons["duo-show"].waitForExistence(timeout: 5), "Done leaves the glance, with Show it here")
        XCTAssertFalse(trackpad.exists, "the deck is put away")
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
        XCTAssertTrue(places.waitForExistence(timeout: 10), "Send to is on the screen under the window")
        // The fold runs down the middle: the mic sits in the right half; Send to spans the width
        // (the fourth pass: a grid of every place with its name) with no cell on the fold's line.
        XCTAssertGreaterThan(mic.frame.minX, inner.midX - 20, "the mic is clear of the fold")
        XCTAssertGreaterThan(places.frame.width, inner.width * 0.8, "Send to spans the screen")
        for cell in places.buttons.allElementsBoundByIndex where cell.frame.width > 10 {
            XCTAssertFalse(cell.frame.minX < inner.midX - 4 && cell.frame.maxX > inner.midX + 4, "no place sits on the fold: \(cell.label) at \(cell.frame)")
        }
        XCTAssertTrue(app.buttons["Send after pasting"].exists || app.switches["send-toggle"].exists || app.descendants(matching: .any)["send-toggle"].exists, "Send after pasting is laid out beside the mic")
        // The window gets the room: the panel is the lower part of the screen only.
        XCTAssertGreaterThan(places.frame.minY, inner.height * 0.5, "Send to is under a large window")
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
