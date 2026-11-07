import XCTest

/// iOS's keyboard first, the Mac's keys a tap away (Nov 7 2026). With a window in hand the
/// keyboard page brings up iOS's own keyboard (autocorrect, predictions) under one bar — esc ⇥
/// the arrows, what you typed, Mac Keys, hide; Mac Keys swaps in the Mac keyboard (`deck-keyboard`),
/// its ABC key swaps back, and the choice is kept for that screen. Needs a paired `mpctl serve`;
/// with `TEST_RUNNER_MACROPHONE_SERVE_LOG=<serve's output>` it checks what the Mac got, with
/// `TEST_RUNNER_MACROPHONE_KEYBOARD_SHOTS=<dir>` it keeps a frame of each step. Any other
/// `TEST_RUNNER_MACROPHONE_*` (a posture, a frame) is passed on to the app.
final class KeyboardChoiceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func launch(_ extra: [String: String] = [:]) throws -> XCUIApplication {
        let app = XCUIApplication()
        var e = ["MACROPHONE_SCREEN": "main", "MACROPHONE_WATCH": "1", "MACROPHONE_WATCH_ACTIONS": "page@keyboard"]
        for (k, v) in env where k.hasPrefix("MACROPHONE_") && !["MACROPHONE_SERVE_LOG", "MACROPHONE_KEYBOARD_SHOTS"].contains(k) { e[k] = v }
        for (k, v) in extra { e[k] = v }
        app.launchEnvironment = e
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        guard app.descendants(matching: .any)["keyboard-bar"].waitForExistence(timeout: 25) else {
            throw XCTSkip("no paired Mac naming the keyboard page: the keyboard never came up")
        }
        // iOS's own first-time keyboard tip, if it's there.
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 1) { cont.tap() }
        return app
    }

    private func shot(_ name: String) {
        guard let dir = env["MACROPHONE_KEYBOARD_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func serveLog() -> String {
        guard let p = env["MACROPHONE_SERVE_LOG"], let s = try? String(contentsOfFile: p, encoding: .utf8) else { return "" }
        return s.replacingOccurrences(of: "\0", with: "")
    }

    private func typedLines(since n: Int) -> [String] {
        let all = serveLog()
        return String(all.suffix(max(0, all.count - n))).components(separatedBy: "\n").filter { $0.hasPrefix("WATCH TYPE") || $0.hasPrefix("WATCH KEY") }
    }

    func testTheIOSKeyboardFirstAndMacKeysATapAway() throws {
        let app = try launch()
        let deck = app.descendants(matching: .any)["deck-keyboard"]
        let toggle = app.buttons["keyboard-mac-keys"]
        // A run left on the Mac's keys: back to iOS's first.
        if deck.waitForExistence(timeout: 2) { app.buttons["keyboard-abc"].tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the iOS keyboard is up")
        XCTAssertFalse(deck.exists, "not the Mac's")
        XCTAssertTrue(toggle.exists, "Mac Keys is on the bar")
        let bar = app.descendants(matching: .any)["keyboard-bar"]
        XCTAssertLessThanOrEqual(bar.frame.height, 60, "the bar is one row: \(bar.frame)")
        for id in ["keyboard-escape", "keyboard-tab", "keyboard-left", "keyboard-right", "keyboard-hide"] {
            XCTAssertTrue(app.buttons[id].exists || app.descendants(matching: .any)[id].exists, "\(id) on the bar")
        }

        let before = serveLog().count
        app.typeText("hello there")
        let echo = app.staticTexts["keyboard-echo"]
        XCTAssertTrue(echo.waitForExistence(timeout: 2))
        XCTAssertTrue((echo.label).contains("hello there"), "the bar shows what was typed: \(echo.label)")
        shot("1-ios-keyboard")
        sleep(2)
        XCTAssertTrue(echo.label.hasPrefix("Typing in"), "and fades back to where it goes: \(echo.label)")
        if env["MACROPHONE_SERVE_LOG"] != nil {
            XCTAssertTrue(typedLines(since: before).contains { $0.hasPrefix("WATCH TYPE") }, "the Mac got the typing")
        }

        toggle.tap()
        XCTAssertTrue(deck.waitForExistence(timeout: 3), "Mac Keys brings the Mac keyboard")
        shot("2-mac-keys")
        let before2 = serveLog().count
        app.descendants(matching: .any)["deck-key-q"].tap()
        app.descendants(matching: .any)["deck-key-return"].tap()
        sleep(1)
        if env["MACROPHONE_SERVE_LOG"] != nil {
            XCTAssertTrue(typedLines(since: before2).contains { $0.hasPrefix("WATCH TYPE") }, "a Mac key reaches the Mac: \(typedLines(since: before2))")
        }

        // Kept for this screen across a launch.
        app.terminate()
        let again = try launch()
        let deck2 = again.descendants(matching: .any)["deck-keyboard"]
        XCTAssertTrue(deck2.waitForExistence(timeout: 5), "Mac Keys is remembered")
        again.buttons["keyboard-abc"].tap()
        XCTAssertTrue(deck2.waitForNonExistence(timeout: 3), "ABC goes back to iOS's keyboard")
        XCTAssertTrue(again.keyboards.firstMatch.waitForExistence(timeout: 3))
        shot("3-back-to-ios")
        again.terminate()
        let third = try launch()
        XCTAssertTrue(third.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(third.descendants(matching: .any)["deck-keyboard"].waitForExistence(timeout: 2), "and iOS's is remembered too")
        third.buttons["keyboard-hide"].tap()
    }
}
