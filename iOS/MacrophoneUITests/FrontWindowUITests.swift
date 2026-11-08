import XCTest

/// What's in front on your Mac (Nov 7 2026): the "Now on your Mac" line under the desktop card
/// watches the Mac's front window without changing Send to, and Watch What's in Front (the quick
/// action, the intent) works from cold — open, wait for the Mac, watch what's in front.
///
/// Needs a simulator paired with `mpctl serve --front com.apple.Terminal#42 --front-every 0` and
/// `TEST_RUNNER_MACROPHONE_FRONT_TEST=1`; with `TEST_RUNNER_MACROPHONE_SERVE_LOG=<serve's output>` it
/// also checks what the Mac was asked to show ("WATCH TARGET <bundle id>#<key>"). Against
/// `serve --no-front` (a Mac from before) set `TEST_RUNNER_MACROPHONE_FRONT_OLD_MAC=1`: the cold path
/// asks for Where I'm typing. Frames go to `TEST_RUNNER_MACROPHONE_FRONT_SHOTS=<dir>`.
final class FrontWindowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var oldMac: Bool { env["MACROPHONE_FRONT_OLD_MAC"] == "1" }

    private func serveText() -> String {
        env["MACROPHONE_SERVE_LOG"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
    }
    private func serveLines(after count: Int) -> [String] {
        let all = serveText()
        return String(all.suffix(max(0, all.count - count))).components(separatedBy: "\n")
    }

    private func guardOn() throws {
        guard env["MACROPHONE_FRONT_TEST"] == "1" else { throw XCTSkip("set TEST_RUNNER_MACROPHONE_FRONT_TEST=1 with a paired mpctl serve --front com.apple.Terminal#42 --front-every 0") }
    }

    private func launch(_ extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main"].merging(extra) { $1 }
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        return app
    }

    /// The line under the card: Terminal's codex window is in front on the Mac, Claude is the pick.
    /// A tap watches Terminal's window 42; Done brings the desktop back with Claude still the pick.
    func testTheLineWatchesWhatsInFrontAndLeavesThePick() throws {
        try guardOn()
        guard !oldMac else { throw XCTSkip("a Mac from before says nothing: no line") }
        let before = serveText().count
        let app = launch(["MACROPHONE_SEND_TO": "Claude"])
        let card = app.buttons["desktop-window"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the pick's card")
        XCTAssertEqual(card.label, "Show Claude's window")
        let line = app.buttons["front-window-line"]
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the Mac's front window, under the card")
        XCTAssertTrue(line.label.contains("Terminal — codex — ~/api"), line.label)
        XCTAssertTrue(line.isHittable)
        XCTAssertGreaterThan(line.frame.minY, card.frame.maxY, "under the card")
        let cardAt = card.frame
        shot(app, "1-line-under-the-card")

        line.tap()
        let done = app.buttons["watch-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "one tap opens the window view")
        let kicker = app.descendants(matching: .any)["watch-kicker"].firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Terminal"), evaluatedWith: kicker)
        waitForExpectations(timeout: 10)
        sleep(2)
        shot(app, "2-watching-the-front-window")
        if env["MACROPHONE_SERVE_LOG"] != nil {
            let got = serveLines(after: before)
            XCTAssertTrue(got.contains("WATCH TARGET com.apple.Terminal#42"), "that very window: \(got.filter { $0.hasPrefix("WATCH") })")
        }

        done.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: done)
        waitForExpectations(timeout: 5)
        sleep(1)
        XCTAssertEqual(card.label, "Show Claude's window", "a look: Send to is still Claude")
        XCTAssertEqual(card.frame.minY, cardAt.minY, accuracy: 0.5, "the card is where it was")
        XCTAssertTrue(line.exists, "Terminal is still in front: the line stays")
        shot(app, "3-back-pick-unchanged")
    }

    /// The quick action from cold: the app opens on the Mac's front window once the Mac is here.
    func testWatchWhatsInFrontFromColdByTheQuickAction() throws {
        try guardOn()
        try coldRun(how: "quick", shotName: "4-cold-quick-action")
    }

    /// The App Intent (Siri, Shortcuts, the control) from cold: the same.
    func testWatchWhatsInFrontFromColdByTheIntent() throws {
        try guardOn()
        try coldRun(how: "intent", shotName: "5-cold-intent")
    }

    private func coldRun(how: String, shotName: String) throws {
        let before = serveText().count
        // Before the link is up: the request waits for the connect.
        let app = launch(["MACROPHONE_FRONT_ACTION": how, "MACROPHONE_FRONT_DELAY": "0",
                          "MACROPHONE_SEND_TO": "Claude"])
        let done = app.buttons["watch-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15), "the window view opens once the Mac connects")
        let kicker = app.descendants(matching: .any)["watch-kicker"].firstMatch
        XCTAssertTrue(kicker.waitForExistence(timeout: 5))
        if !oldMac {
            expectation(for: NSPredicate(format: "label CONTAINS %@", "Terminal"), evaluatedWith: kicker)
            waitForExpectations(timeout: 10)
        }
        sleep(2)
        shot(app, shotName + (oldMac ? "-older-mac" : ""))
        if env["MACROPHONE_SERVE_LOG"] != nil {
            let got = serveLines(after: before).filter { $0.hasPrefix("WATCH TARGET") }
            if oldMac {
                XCTAssertTrue(got.contains { $0.hasSuffix("(front)") }, "a Mac from before is asked for Where I'm typing: \(got)")
            } else {
                XCTAssertEqual(got.first, "WATCH TARGET com.apple.Terminal#42", "the Mac's front window at that moment: \(got)")
            }
        }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        guard let dir = env["MACROPHONE_FRONT_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
