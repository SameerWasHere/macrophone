import XCTest

/// The pick's window on the desktop (Nov 7 2026): one tap on the card opens the window view, Done
/// brings the desktop and the card back. Needs `mpctl serve` paired with this simulator (Claude is
/// open there). Frames go to TEST_RUNNER_MACROPHONE_DESKTOP_SHOTS=<dir>.
final class DesktopWindowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["MACROPHONE_DESKTOP_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testTheCardOpensTheWindow() throws {
        let app = XCUIApplication()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let claude = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Claude")).firstMatch
        guard claude.waitForExistence(timeout: 15) else { throw XCTSkip("no Mac with Claude open is connected") }
        sleep(2)
        let sendTo = app.descendants(matching: .any)["send-to"]
        if !(sendTo.exists && sendTo.label.contains("Claude")) { claude.tap(); sleep(1) }

        let card = app.buttons["desktop-window"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "the pick's window is on the desktop")
        XCTAssertEqual(card.label, "Show Claude's window")
        XCTAssertTrue(card.isHittable)
        shot("1-card")

        card.tap()
        let done = app.buttons["watch-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "one tap on the card opens the window view")
        sleep(2)
        shot("2-window")

        done.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: done)
        waitForExpectations(timeout: 3)
        sleep(1)
        XCTAssertTrue(card.isHittable, "Done brings the card back")
        shot("3-back")
    }
}
