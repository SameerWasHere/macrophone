import XCTest

/// The window takes all the room, always — no resize handle (Nov 9 2026, Sameer: "The app should
/// just have the window take the max view available in any orientation"). Run on an iPhone simulator paired with
/// `mpctl serve`; `TEST_RUNNER_MACROPHONE_SERVE_LOG=<serve's output>` also checks the Mac was
/// sent the new shape. `TEST_RUNNER_MACROPHONE_RESIZE_SHOTS=<dir>` keeps a frame of each step.
final class ResizableWindowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // `TEST_RUNNER_MACROPHONE_SEND_TO=<app>` picks another window (a TextEdit document of your
        // own against a Debug copy of the Mac app — never someone's real Claude window).
        let pick = ProcessInfo.processInfo.environment["MACROPHONE_SEND_TO"] ?? "Claude"
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": pick, "MACROPHONE_WATCH": "1"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        return app
    }

    private func window(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "window on your Mac")).firstMatch
    }

    private func settled(_ e: XCUIElement) -> CGRect {
        var last = CGRect.null
        for _ in 0..<12 {
            let f = e.frame
            if abs(f.minX - last.minX) < 0.5, abs(f.width - last.width) < 0.5, abs(f.height - last.height) < 0.5 { return f }
            last = f
            usleep(400_000)
        }
        return last
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MACROPHONE_RESIZE_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private var serveLog: String {
        ProcessInfo.processInfo.environment["MACROPHONE_SERVE_LOG"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
    }

    /// The window runs to the screen's sides (Nov 9 2026), and a swipe in from the screen's edge
    /// still flips to the next window and back — with nothing over the window's own edge.
    func testTheWindowIsEdgeToEdgeAndTheScreenEdgeFlips() {
        let app = launch()
        let menu = app.buttons["watch-sessions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25))
        XCTAssertTrue(window(app).waitForExistence(timeout: 25))
        sleep(4)
        let win = settled(window(app))
        // No resize handle (Nov 9 2026): the window is always all the room.
        XCTAssertFalse(app.descendants(matching: .any)["watch-resize"].exists, "no resize handle")
        XCTAssertEqual(win.minX, 0, accuracy: 1, "the window starts at the screen's left side")
        XCTAssertEqual(win.width, app.frame.width, accuracy: 1, "and runs to its right")
        XCTAssertTrue(menu.label.contains("Claude"))
        let y = win.midY / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: y))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)))
        sleep(3)
        XCTAssertFalse(menu.label.contains("Claude"), "a swipe in from the right edge shows the next window: \(menu.label)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: y))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)))
        sleep(3)
        XCTAssertTrue(menu.label.contains("Claude"), "and from the left edge, back: \(menu.label)")
    }
}
