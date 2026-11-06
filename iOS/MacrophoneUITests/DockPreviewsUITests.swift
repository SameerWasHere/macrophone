import XCTest

/// A long press on a Dock icon shows its windows as pictures (Nov 5 2026), with real touches:
/// Terminal's two windows as cards (the one watched before with its kept picture, the other the
/// app's icon on a plate), a tap on a card picks that window, a one-window app's card and Show
/// Window, and the Dock's tap and scrub still pick without opening anything. Needs `mpctl serve`
/// paired with this simulator (Terminal has two windows there); watch a Terminal window once first
/// so a picture is kept (MACROPHONE_WATCH=rest MACROPHONE_WATCH_ACTIONS=attend@com.apple.Terminal@41,wait,close).
/// Frames go to TEST_RUNNER_MACROPHONE_DOCK_SHOTS=<dir> (TEST_RUNNER_MACROPHONE_DOCK_SUFFIX names them, e.g. "dark").
final class DockPreviewsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MACROPHONE_DOCK_SHOTS"] else { return }
        let suffix = env["MACROPHONE_DOCK_SUFFIX"].map { "-\($0)" } ?? ""
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(suffix).png"))
    }

    private func icon(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    func testLongPressShowsTheWindowsAsPictures() throws {
        let app = XCUIApplication()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let terminal = icon(app, "Terminal, 2 windows")
        guard terminal.waitForExistence(timeout: 15) else { throw XCTSkip("no Mac with two Terminal windows is connected") }
        sleep(2)

        // A plain tap still picks (and opens nothing). (A tap on the pick would watch it.)
        let sendTo = app.descendants(matching: .any)["send-to"]
        XCTAssertTrue(sendTo.waitForExistence(timeout: 3))
        let other = sendTo.label.contains("Messages") ? "Notes" : "Messages"
        icon(app, other).tap()
        sleep(1)
        XCTAssertTrue(sendTo.label.contains(other), sendTo.label)
        XCTAssertFalse(app.descendants(matching: .any)["dock-windows"].exists, "a tap never opens the previews")

        // A long press: Terminal's windows as cards.
        terminal.press(forDuration: 0.8)
        let popover = app.descendants(matching: .any)["dock-windows"]
        XCTAssertTrue(popover.waitForExistence(timeout: 3), "a long press shows the windows")
        let first = app.descendants(matching: .any)["dock-window-com.apple.Terminal#41"]
        let second = app.descendants(matching: .any)["dock-window-com.apple.Terminal#42"]
        XCTAssertTrue(first.waitForExistence(timeout: 2))
        XCTAssertTrue(second.exists)
        XCTAssertEqual(first.label, "claude — ~/app")
        XCTAssertFalse(sendTo.label.contains("Terminal"), "the long press's lift isn't a tap: \(sendTo.label)")
        sleep(1)
        shot("1-terminal-windows")

        // A tap on a card picks that window and puts the previews away.
        second.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: popover)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(sendTo.label.contains("codex"), sendTo.label)
        sleep(1)
        shot("2-picked-from-a-card")

        // Again: the picked card is ringed now.
        terminal.press(forDuration: 0.8)
        XCTAssertTrue(popover.waitForExistence(timeout: 3))
        XCTAssertTrue(second.waitForExistence(timeout: 2))
        XCTAssertTrue(second.isSelected, "the pick's card is selected")
        sleep(1)
        shot("3-pick-ringed")
        // Tapped outside: gone, nothing picked.
        let outside = app.otherElements["PopoverDismissRegion"]
        if outside.exists { outside.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap() }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: popover)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(sendTo.label.contains("codex"), sendTo.label)

        // A one-window app: one card and Show Window.
        let claude = icon(app, "Claude")
        claude.press(forDuration: 0.8)
        XCTAssertTrue(popover.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["dock-show-window"].exists)
        sleep(1)
        shot("4-one-window")
        app.buttons["dock-show-window"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: popover)
        waitForExpectations(timeout: 3)
        // Show Window: Claude is the pick and its window shows.
        XCTAssertTrue(app.buttons["watch-done"].waitForExistence(timeout: 6), "Show Window watches it")
        sleep(2)
        shot("5-show-window")
        app.buttons["watch-done"].tap()
        sleep(2)
    }

    /// A drag along the Dock never opens the previews (the long press gives way to it). XCUITest's
    /// synthetic drag doesn't drive the Dock's scrub on the simulator — on main before this change
    /// too (the pick stays) — so the scrub's own pick is checked by hand.
    func testDragNeverOpensThePreviews() throws {
        let app = XCUIApplication()
        app.launch()
        let terminal = icon(app, "Terminal, 2 windows")
        guard terminal.waitForExistence(timeout: 15) else { throw XCTSkip("no Mac with two Terminal windows is connected") }
        sleep(2)
        let sendTo = app.descendants(matching: .any)["send-to"]
        if sendTo.waitForExistence(timeout: 3), !sendTo.label.contains("Messages") { icon(app, "Messages").tap() }
        let popover = app.descendants(matching: .any)["dock-windows"]
        let notes = icon(app, "Notes")
        let start = icon(app, "Claude").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = notes.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        sleep(1)
        XCTAssertFalse(popover.exists, "a drag never opens the previews")
        XCTAssertTrue(sendTo.exists)
    }

    /// A window that answered you wears the ember mark and says so (MACROPHONE_FAKE_NEEDS marks
    /// Claude and Terminal's windows — Terminal's as asking — from the open apps kept last time).
    func testAnsweredMarkOnTheCards() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_FAKE_NEEDS": "1"]
        app.launch()
        let terminal = icon(app, "Terminal, 2 windows")
        guard terminal.waitForExistence(timeout: 15) else { throw XCTSkip("no Mac with two Terminal windows is connected") }
        sleep(3)
        terminal.press(forDuration: 0.8)
        let card = app.descendants(matching: .any)["dock-window-com.apple.Terminal#42"]
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        guard (card.value as? String)?.isEmpty == false else { throw XCTSkip("the Mac cleared the fake marks") }
        sleep(1)
        shot("6-answered-you")
    }
}
