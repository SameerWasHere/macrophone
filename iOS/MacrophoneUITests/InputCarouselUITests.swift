import XCTest

/// The three ways in (Oct 19 2026), with real touches: a swipe beside the mic slides to the
/// trackpad, a drag on the trackpad moves the pointer, its bar's close comes back, a swipe the
/// other way opens the keyboard (the iOS keyboard rises), and the bar's hide
/// button comes back to the mic — and none of it starts a dictation. While a window shows there is
/// no page row and no Thread (every iPhone since Nov 7 2026, round 5 — the Duo's cover before it):
/// the keyboard and the trackpad are buttons beside the mic, and the window never moves for them.
/// Then Mac Controls' own button and panel, and a window closed from the phone bringing the main
/// screen back. Needs a Mac that names the pages: `mpctl serve` paired with this simulator (the
/// app opens its window view by itself with MACROPHONE_WATCH=1).
final class InputCarouselUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The keyboard's or the trackpad's button beside the mic (the cover's ids on the Duo's cover).
    private func pageButton(_ app: XCUIApplication, _ page: String) -> XCUIElement {
        let phone = app.buttons["phone-page-\(page)"]
        return phone.exists ? phone : app.buttons["cover-page-\(page)"]
    }

    /// The window's foot: the row under it (the answers, else the keys), whose top is the window's
    /// bottom edge — the window's top never moves.
    private func windowFoot(_ app: XCUIApplication) -> CGFloat {
        let answers = app.descendants(matching: .any)["watch-answers"].firstMatch
        if answers.exists { return answers.frame.minY }
        return app.buttons["watch-more-keys"].firstMatch.frame.minY
    }

    private func launchWatching() throws -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_WATCH": "1"]
        app.launch()
        // A fresh simulator: the system's notifications prompt would take the first touches.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(15)
        while !pageButton(app, "trackpad").exists, Date() < deadline { usleep(250_000) }
        guard pageButton(app, "trackpad").exists else { throw XCTSkip("no Mac naming the keyboard and trackpad pages is connected") }
        // The first-use tip, if it's up, would take the swipe.
        let gotIt = app.buttons["Got it"]
        for _ in 0..<6 where gotIt.waitForExistence(timeout: 1) { gotIt.tap() }
        return (app, mic)
    }

    /// "Pointer 52 percent across, 61 percent down" → (52, 61).
    private func pointer(_ trackpad: XCUIElement) -> (Int, Int) {
        let words = (trackpad.value as? String ?? "").components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        return (words.first ?? -1, words.dropFirst().first ?? -1)
    }

    func testSwipesBesideTheMicChangeThePage() throws {
        let (app, mic) = try launchWatching()
        XCTAssertFalse(app.descendants(matching: .any)["input-pages"].exists, "no page row while a window shows")
        sleep(1)
        let foot = windowFoot(app)

        // Right to left beside the mic (its right, above the trackpad's button): the trackpad.
        let micFrame = mic.frame
        let right = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: micFrame.maxX + 20, dy: micFrame.minY + 4))
        right.press(forDuration: 0.05, thenDragTo: right.withOffset(CGVector(dx: -220, dy: 0)))
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        XCTAssertTrue(trackpad.waitForExistence(timeout: 3), "a swipe right to left beside the mic shows the trackpad")
        XCTAssertFalse(app.buttons["Stop and send"].exists, "the swipe never started a dictation")
        XCTAssertTrue(app.buttons["trackpad-bar-close"].waitForExistence(timeout: 2), "the trackpad has its own row with a close")

        // Close: back to the mic, the window where it was. (The swipe in from the plate's left
        // edge isn't reached by a synthetic drag with the bar under the plate — as on the cover.)
        sleep(1)
        app.buttons["trackpad-bar-close"].tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mic)
        waitForExpectations(timeout: 3)
        sleep(1)
        XCTAssertEqual(windowFoot(app), foot, accuracy: 0.5, "the window is back exactly where it was")

        // Left to right, beside the mic (its left): the keyboard rises.
        let left = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: micFrame.minX - 20, dy: micFrame.minY + 4))
        left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: 220, dy: 0)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the iOS keyboard comes up")
        // iOS's own first-time keyboard tip, if it's there.
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 1) { cont.tap() }
        let hide = app.buttons["Hide the keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3), "the bar rides above the keys")
        XCTAssertTrue(app.buttons["keyboard-mac-keys"].exists, "Mac Keys is on the same bar")
        XCTAssertTrue(app.buttons["keyboard-escape"].exists, "and so are esc and the arrows")
        hide.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mic)
        waitForExpectations(timeout: 3)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.buttons["Stop and send"].exists)
        sleep(1)
        XCTAssertEqual(windowFoot(app), foot, accuracy: 0.5, "and back again after the keyboard")
        app.buttons["watch-done"].tap()
    }

    /// The buttons beside the mic (every way in and out without a swipe, as VoiceOver goes): the
    /// trackpad — a plate a thumb can use, a drag moves the pointer, close comes back — and the
    /// keyboard, typing into the Mac, hide comes back. The window is where it was after each.
    func testTheButtonsBesideTheMicAreTheWaysInAndOut() throws {
        let (app, mic) = try launchWatching()
        sleep(1)
        let foot = windowFoot(app)
        XCTAssertEqual(pageButton(app, "keyboard").label, "Keyboard")
        XCTAssertEqual(pageButton(app, "trackpad").label, "Trackpad")

        pageButton(app, "trackpad").tap()
        let trackpad = app.descendants(matching: .any)["input-trackpad"]
        XCTAssertTrue(trackpad.waitForExistence(timeout: 3))
        sleep(1)
        XCTAssertGreaterThan(trackpad.frame.height, 140, "a plate a thumb can use: \(trackpad.frame)")
        let before = pointer(trackpad)
        let mid = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: trackpad.frame.midX + 40, dy: trackpad.frame.midY))
        mid.press(forDuration: 0.05, thenDragTo: mid.withOffset(CGVector(dx: -140, dy: 30)))
        let after = pointer(trackpad)
        XCTAssertLessThan(after.0, before.0, "the pointer went left: \(before) → \(after)")
        app.buttons["trackpad-bar-close"].tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mic)
        waitForExpectations(timeout: 3)
        sleep(1)
        XCTAssertEqual(windowFoot(app), foot, accuracy: 0.5, "close: the window is back exactly where it was")

        pageButton(app, "keyboard").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the iOS keyboard comes up")
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 1) { cont.tap() }
        app.typeText("one row")
        let hide = app.buttons["Hide the keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3))
        hide.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mic)
        waitForExpectations(timeout: 3)
        sleep(1)
        XCTAssertEqual(windowFoot(app), foot, accuracy: 0.5, "hide: the window is back exactly where it was")
        app.buttons["watch-done"].tap()
    }

    func testMacControlsIsItsOwnButtonInTheWindowView() throws {
        let (app, _) = try launchWatching()
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
        let (app, _) = try launchWatching()
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
