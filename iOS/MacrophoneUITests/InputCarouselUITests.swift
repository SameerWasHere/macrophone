import XCTest

/// The three ways in (Oct 19 2026), with real touches: a swipe on the Thread slides to the
/// trackpad, a drag on the trackpad moves the pointer, a swipe in from the trackpad's edge comes
/// back, a swipe the other way opens the keyboard (the iOS keyboard rises), and the bar's hide
/// button comes back to the mic — and none of it starts a dictation. Then Mac Controls' own
/// button and panel, and a window closed from the phone bringing the main screen back. Needs a
/// Mac that names the pages: `mpctl serve` paired with this simulator (the app opens its window
/// view by itself with MACROPHONE_WATCH=1).
final class InputCarouselUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchWatching() throws -> (XCUIApplication, XCUIElement, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_WATCH": "1"]
        app.launch()
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        let row = app.descendants(matching: .any)["input-pages"]
        guard row.waitForExistence(timeout: 15) else { throw XCTSkip("no Mac naming the keyboard and trackpad pages is connected") }
        // The first-use tip, if it's up, would take the swipe.
        let gotIt = app.buttons["Got it"]
        for _ in 0..<6 where gotIt.waitForExistence(timeout: 1) { gotIt.tap() }
        return (app, mic, row)
    }

    /// "Pointer 52 percent across, 61 percent down" → (52, 61).
    private func pointer(_ trackpad: XCUIElement) -> (Int, Int) {
        let words = (trackpad.value as? String ?? "").components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        return (words.first ?? -1, words.dropFirst().first ?? -1)
    }

    func testSwipesOnTheThreadAndBesideTheMicChangeThePage() throws {
        let (app, mic, row) = try launchWatching()
        XCTAssertEqual(row.value as? String, "Mic")

        // Right to left ON THE THREAD (the band right under the page row): the trackpad.
        let threadY = row.frame.maxY + 40
        let fromThread = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width - 40, dy: threadY))
        fromThread.press(forDuration: 0.05, thenDragTo: fromThread.withOffset(CGVector(dx: -240, dy: 0)))
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        XCTAssertTrue(trackpad.waitForExistence(timeout: 3), "a swipe right to left on the Thread shows the trackpad")
        XCTAssertEqual(row.value as? String, "Trackpad")
        XCTAssertFalse(app.buttons["Stop and send"].exists, "the swipe never started a dictation")
        // The trackpad took the Thread's room: it's taller than the mic's area was.
        XCTAssertGreaterThan(trackpad.frame.height, 180)

        // A drag on the trackpad moves the pointer (its place is the trackpad's value).
        let before = pointer(trackpad)
        let mid = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: trackpad.frame.midX + 40, dy: trackpad.frame.midY))
        mid.press(forDuration: 0.05, thenDragTo: mid.withOffset(CGVector(dx: -140, dy: 30)))
        let after = pointer(trackpad)
        XCTAssertLessThan(after.0, before.0, "the pointer went left: \(before) → \(after)")
        XCTAssertGreaterThanOrEqual(after.1, before.1, "and a little down")

        // In from the trackpad's left edge: back to the mic.
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: trackpad.frame.minX + 8, dy: trackpad.frame.midY))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 160, dy: 0)))
        XCTAssertTrue(mic.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mic)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(row.value as? String, "Mic")

        // Left to right, beside the mic (its left): the keyboard rises.
        let micFrame = mic.frame
        let left = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: micFrame.minX - 50, dy: micFrame.midY + 40))
        left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: 220, dy: 0)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the iOS keyboard comes up")
        XCTAssertEqual(row.value as? String, "Keyboard")
        // iOS's own first-time keyboard tip, if it's there.
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 1) { cont.tap() }
        let hide = app.buttons["Hide the keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3), "the bar rides above the keys")
        XCTAssertTrue(app.buttons["keyboard-command"].exists, "the modifiers are on the same bar")
        XCTAssertTrue(app.buttons["keyboard-escape"].exists, "and so are esc and the arrows")
        hide.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mic)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(row.value as? String, "Mic", "hide comes back to the mic page")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.buttons["Stop and send"].exists)
        app.buttons["watch-done"].tap()
    }

    func testMacControlsIsItsOwnButtonInTheWindowView() throws {
        let (app, _, _) = try launchWatching()
        let button = app.buttons["mac-controls"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Mac Controls sits in the window view's header")
        button.tap()
        let up = app.buttons["mac-control-volumeUp"]
        XCTAssertTrue(up.waitForExistence(timeout: 4), "a tap opens the panel")
        up.tap()
        XCTAssertTrue(up.waitForExistence(timeout: 2), "the panel stays for the next press")
        up.tap()
        let readout = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Volume'")).firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 4), "the Mac's answer shows in the panel")
        app.buttons["mac-control-playPause"].tap()
        app.buttons["mac-controls-done"].tap()
        XCTAssertTrue(app.buttons["watch-done"].waitForExistence(timeout: 3), "back on the window view")
        app.buttons["watch-done"].tap()
    }

    func testClosingTheWindowBringsTheMainScreenBack() throws {
        let (app, _, _) = try launchWatching()
        let menu = app.descendants(matching: .any)["watch-window"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let close = app.buttons["Close Window"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        close.tap()
        // The confirmation: the same words, destructive.
        let confirm = app.buttons["Close Window"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        confirm.tap()
        // The demo Mac confirms a beat later; the window view goes and the selector is back.
        let places = app.descendants(matching: .any)["places"].firstMatch
        XCTAssertTrue(places.waitForExistence(timeout: 8), "the main screen's Send to panel is back")
        XCTAssertFalse(app.buttons["watch-done"].exists, "the window view closed by itself")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Closed'")).firstMatch.waitForExistence(timeout: 3), "the status line says so")
    }
}
