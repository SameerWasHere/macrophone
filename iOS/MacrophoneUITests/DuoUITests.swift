import XCTest

/// The iPhone Duo's poses (Oct 25 2026; the laptop re-laid Oct 31 and again Nov 1), with real
/// touches, in the inner screen's real shapes (Nov 1 2026, from his phone's log: upright
/// 669 × 951 with the fold across — the laptop, flat portrait; on its side 951 × 669 with the
/// fold down it — the book, flat landscape). The laptop: the picture alone fills the top half;
/// the deck below is the header, then one mode at a time taking the whole of the rest — the
/// trackpad (a drag there moves the pointer, read back off the trackpad's value), the mic, the
/// keyboard (typing goes to the Mac: `mpctl serve` prints "WATCH TYPE N characters") — picked
/// by the cluster in the corner; Done leaves the glance — the window still live — with the
/// cover's view in the deck, and Show it here takes it back. The book: the Mac on the left
/// page, the column of keys, trackpad and mic down the right. Flat: the glance in one half and
/// the cover's view in the other. The simulator can't be folded from a script, so the pose is
/// forced (`MACROPHONE_POSTURE=…`) in the inner screen's frame (`MACROPHONE_FRAME=…`, drawn to
/// scale on the cover with its bars stood in for). Needs a paired `mpctl serve`.
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

    /// The laptop (Nov 1 2026): the top half is the picture alone — the header, the answers and
    /// the modes all on the deck — and each mode takes the whole of the deck under its header.
    func testLaptopPoseIsAMacAboveAndTheDeckBelow() throws {
        let app = launch("laptop", frame: "669x951")
        let inner = innerFrame(app, "669x951")
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        guard trackpad.waitForExistence(timeout: 20) else { throw XCTSkip("no Mac naming the trackpad is connected") }
        dismissTips(app)
        let done = app.buttons["watch-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "the header is on the deck, always there")
        let answer = app.buttons["watch-answer-0"]
        XCTAssertTrue(answer.waitForExistence(timeout: 8), "the demo Mac's question is up")
        let switcher = app.descendants(matching: .any)["input-pages"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 3), "the modes' cluster is in the deck's corner")
        // The deck remembers its mode across launches (the trackpad the first time): start there.
        if switcher.value as? String != "Trackpad" { pick(switcher, "Trackpad", at: 0.83) }
        XCTAssertEqual(switcher.value as? String, "Trackpad")
        // Nothing over the picture: the header, the answers, the modes and the trackpad are all
        // under the fold.
        for (what, e) in [("Done", done), ("the answers", answer), ("the modes", switcher), ("the trackpad", trackpad)] {
            XCTAssertGreaterThan(e.frame.minY, inner.midY - 2, "\(what) is on the deck, not over the picture")
        }
        // The header stays (nothing to fade: it covers nothing; the book's overlay header leaves
        // the hierarchy when it goes, so existence is the check).
        sleep(4)
        XCTAssertTrue(done.exists && done.frame.height > 0, "the deck's header never fades")
        // The trackpad is the deck: its whole width, most of the half under the header.
        let deck = inner.height / 2
        XCTAssertGreaterThan(trackpad.frame.width, inner.width * 0.8, "the trackpad is the deck's width: \(trackpad.frame.width) of \(inner.width)")
        XCTAssertGreaterThan(trackpad.frame.height, deck * 0.6, "and most of its height: \(trackpad.frame.height) of \(deck)")
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

        // The mic mode: the mic takes the deck, the trackpad goes; the picture above is untouched.
        pick(switcher, "Mic", at: 0.5)
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 4), "the mic mode has the mic")
        // The pages slide: the trackpad's page is a width to the side, off the screen.
        XCTAssertFalse(trackpad.exists && trackpad.frame.intersects(inner.insetBy(dx: 4, dy: 4)), "one mode at a time")
        XCTAssertGreaterThan(mic.frame.minY, inner.midY, "the mic is on the deck")
        XCTAssertLessThan(mic.frame.maxY, inner.maxY + 2, "and whole in it")
        shot("laptop-mic")

        // The keyboard mode: the iOS keyboard rises over the deck; hide comes back to the trackpad.
        pick(switcher, "Keyboard", at: 0.17)
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 2) { cont.tap(); pick(switcher, "Keyboard", at: 0.17) }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 6), "the iOS keyboard comes up")
        app.typeText("duo")
        shot("laptop-keyboard")
        let hide = app.buttons["Hide the keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3))
        hide.tap()
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5), "hide comes back to the trackpad")

        // Done leaves the glance — the window still live, the cover's view in the deck — and
        // Show it here takes it back.
        done.tap()
        let show = app.buttons["duo-show"]
        XCTAssertTrue(show.waitForExistence(timeout: 5), "Done leaves the glance, with Show it here")
        XCTAssertFalse(trackpad.exists, "the deck is put away")
        let places = app.descendants(matching: .any)["places"].firstMatch
        XCTAssertTrue(places.waitForExistence(timeout: 3), "the cover's Send to is in the deck")
        XCTAssertGreaterThan(places.frame.minY, inner.midY, "under the fold")
        shot("laptop-glance")
        show.tap()
        XCTAssertTrue(trackpad.waitForExistence(timeout: 8), "Show it here brings the window and the deck back")
    }

    func testBookPoseHasTheMacOnTheLeftPageAndTheDeckOnTheRight() throws {
        let app = launch("book", frame: "951x669")
        let inner = innerFrame(app, "951x669")
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        guard trackpad.waitForExistence(timeout: 20) else { throw XCTSkip("no Mac naming the trackpad is connected") }
        // A touch on the left page brings its header up.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: inner.minX + inner.width * 0.25, dy: inner.midY)).tap()
        XCTAssertTrue(app.buttons["watch-done"].waitForExistence(timeout: 3), "a touch on the Mac's page brings the header up")
        dismissTips(app)
        // The deck is the right page: the keys, the trackpad (the most of it) and the mic.
        let split = inner.minX + inner.width / 2
        XCTAssertGreaterThan(trackpad.frame.minX, split - 2, "the trackpad is on the right page")
        XCTAssertGreaterThan(trackpad.frame.height, inner.height * 0.35, "and takes the most of it: \(trackpad.frame.height) of \(inner.height)")
        XCTAssertGreaterThan(app.buttons["deck-return"].frame.minX, split - 2, "the keys are on the right page")
        XCTAssertGreaterThan(app.buttons["Start dictation"].frame.minX, split - 2, "and the mic")
        let answer = app.buttons["watch-answer-0"]
        XCTAssertTrue(answer.waitForExistence(timeout: 8))
        XCTAssertLessThan(answer.frame.maxX, split, "the answers float over the Mac's page")
        shot("book")
    }

    /// Flat and upright the fold runs across: the picked app's window live above it (the
    /// glance), the cover's own view — Send to, the Thread, the mic — below it, nothing on it.
    func testOpenPortraitIsTheGlanceOverTheCoversView() throws {
        let app = launch("portrait", frame: "669x951")
        let inner = innerFrame(app, "669x951")
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        let places = app.descendants(matching: .any)["places"].firstMatch
        XCTAssertTrue(places.waitForExistence(timeout: 10), "Send to is on the screen")
        XCTAssertGreaterThan(places.frame.minY, inner.midY, "Send to is under the fold")
        XCTAssertGreaterThan(mic.frame.minY, inner.midY, "and so is the mic")
        XCTAssertGreaterThan(places.frame.width, inner.width * 0.8, "Send to spans the half")
        for cell in places.buttons.allElementsBoundByIndex where cell.frame.width > 10 {
            XCTAssertFalse(cell.frame.minY < inner.midY - 4 && cell.frame.maxY > inner.midY + 4, "no place sits on the fold: \(cell.label) at \(cell.frame)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["send-toggle"].exists, "Send after pasting is there, as on the cover")
        let show = app.buttons["duo-show"]
        guard show.waitForExistence(timeout: 15) else { throw XCTSkip("no Mac is connected: nothing to glance at") }
        XCTAssertLessThan(show.frame.maxY, inner.midY, "the window is live above the fold")
        shot("portrait")
    }

    /// Flat on its side the fold runs down the middle: the window live on the left page, the
    /// cover's view on the right — and in hand, the deck's column down the right page.
    func testOpenLandscapeIsTheGlanceBesideTheCoversView() throws {
        let app = launch("landscape", frame: "951x669")
        let inner = innerFrame(app, "951x669")
        let split = inner.minX + inner.width / 2
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        let places = app.descendants(matching: .any)["places"].firstMatch
        XCTAssertTrue(places.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(places.frame.minX, split, "Send to is on the right page")
        XCTAssertGreaterThan(mic.frame.minX, split, "and so is the mic")
        let show = app.buttons["duo-show"]
        guard show.waitForExistence(timeout: 15) else { throw XCTSkip("no Mac is connected: nothing to glance at") }
        XCTAssertLessThan(show.frame.maxX, split, "the window is live on the left page")
        shot("landscape-rest")
        show.tap()
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        XCTAssertTrue(trackpad.waitForExistence(timeout: 8), "in hand: the deck's trackpad is on the right page")
        XCTAssertGreaterThan(trackpad.frame.minX, split - 2)
        XCTAssertGreaterThan(app.buttons["deck-return"].frame.minX, split - 2, "with the keys")
        shot("landscape")
    }
}
