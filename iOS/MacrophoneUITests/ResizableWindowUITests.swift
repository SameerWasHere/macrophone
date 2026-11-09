import XCTest

/// The window as a window (Nov 8 2026): it opens taking all the room, its corner arc resizes it
/// (the width round the middle, the height from the top), the next open takes all the room again, and a
/// double tap on the arc gives it all the room again. Run on an iPhone simulator paired with
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

    /// The Duo's inner screen (Nov 9 2026): the arc on every pose but the laptop, whose half is the
    /// Mac's screen, whole. Run on a Duo simulator held in the pose (`duo-sim.sh pose <udid>
    /// portrait|open|folded|tabletop`) with `TEST_RUNNER_MACROPHONE_DUO_REAL=portrait|side|book|laptop`.
    func testTheInnerScreenResizesExceptTheLaptop() throws {
        guard let pose = ProcessInfo.processInfo.environment["MACROPHONE_DUO_REAL"] else { throw XCTSkip("set TEST_RUNNER_MACROPHONE_DUO_REAL") }
        let app = XCUIApplication()
        var env = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": "Claude", "MACROPHONE_WATCH": "1"]
        // Flat, the window opens as the glance: Show it here takes it in hand.
        if pose == "portrait" || pose == "side" { env["MACROPHONE_WATCH_ACTIONS"] = "wait@3,show" }
        app.launchEnvironment = env
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let win = app.descendants(matching: .any)["duo-window"].firstMatch
        XCTAssertTrue(win.waitForExistence(timeout: 25), "the window is in hand")
        sleep(4)
        let handle = app.descendants(matching: .any)["watch-resize"]
        if pose == "laptop" {
            XCTAssertFalse(handle.exists && handle.isHittable, "the laptop's half is the Mac's screen, whole: no arc")
            return
        }
        XCTAssertTrue(handle.waitForExistence(timeout: 10), "the arc is there on the \(pose) pose")
        let full = settled(window(app))
        shot("duo-\(pose)-1-full")
        let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: -60, dy: -120)))
        sleep(2)
        let small = settled(window(app))
        shot("duo-\(pose)-2-resized")
        print("ResizableWindow \(pose): \(full) → \(window(app).frame)")
        XCTAssertLessThan(small.width, full.width - 40, "smaller across on the \(pose) pose")
        handle.doubleTap()
        sleep(2)
        shot("duo-\(pose)-3-full-again")
    }

    func testTheCornerResizesTheWindowAndEveryOpenIsFull() {
        let app = launch()
        let handle = app.descendants(matching: .any)["watch-resize"]
        XCTAssertTrue(handle.waitForExistence(timeout: 25), "the corner arc is there once the window is live")
        let win = window(app)
        XCTAssertTrue(win.waitForExistence(timeout: 5))
        // Start from all the room (a run before may have left a size).
        handle.doubleTap()
        sleep(2)
        let full = settled(win)
        shot("1-full")
        let shapesBefore = serveLog.components(separatedBy: "WATCH SHAPE").count

        // Drag the corner up and in.
        let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: -60, dy: -180)))
        sleep(2)
        let small = settled(win)
        shot("2-resized")
        print("ResizableWindow: \(full) → \(small)")
        XCTAssertEqual(small.minY, full.minY, accuracy: 1, "the window's top stays put")
        XCTAssertEqual(small.midX, full.midX, accuracy: 1, "it stays centred across")
        XCTAssertEqual(small.width, full.width - 120, accuracy: 6, "the width shrinks both ways round the middle (\(full.width) → \(small.width))")
        XCTAssertEqual(small.height, full.height - 180, accuracy: 6, "the height shrinks from the foot (\(full.height) → \(small.height))")
        if !serveLog.isEmpty {
            sleep(1)
            XCTAssertGreaterThan(serveLog.components(separatedBy: "WATCH SHAPE").count, shapesBefore, "the Mac was sent the new shape")
        }

        // A size lasts while the window's open, never into the next open: every window opens as
        // big as the phone allows (Sameer, Nov 8 2026).
        app.terminate()
        let again = launch()
        let handle2 = again.descendants(matching: .any)["watch-resize"]
        XCTAssertTrue(handle2.waitForExistence(timeout: 25))
        let reopened = settled(window(again))
        shot("3-reopened")
        XCTAssertEqual(reopened.width, full.width, accuracy: 1, "the next open takes all the room again (\(reopened.width))")
        XCTAssertEqual(reopened.height, full.height, accuracy: 1)

        // Smaller again, then a double tap: all the room.
        let from2 = handle2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from2.press(forDuration: 0.1, thenDragTo: from2.withOffset(CGVector(dx: -40, dy: -120)))
        sleep(2)
        XCTAssertLessThan(settled(window(again)).height, full.height - 60, "smaller again")
        handle2.doubleTap()
        sleep(2)
        let back = settled(window(again))
        shot("4-full-again")
        XCTAssertEqual(back.width, full.width, accuracy: 1, "a double tap gives it all the room")
        XCTAssertEqual(back.height, full.height, accuracy: 1)
    }

    /// The window follows the finger (Nov 8 2026): a slow drag of the corner, held a moment at
    /// the end, then let go — the window's frame, its picture and the arc move together. Driven
    /// here, read frame by frame from a recording made outside (`simctl io recordVideo`,
    /// `drag-frames.py`); the test itself checks only the end: the window at the dragged size,
    /// and the shapes the Mac was sent — several live ones while the finger moved (Nov 9 2026,
    /// the Mac reshapes the window under the finger) and one final on the release.
    func testASlowDragForTheRecording() {
        let app = launch()
        let handle = app.descendants(matching: .any)["watch-resize"]
        XCTAssertTrue(handle.waitForExistence(timeout: 25), "the corner arc is there once the window is live")
        let win = window(app)
        XCTAssertTrue(win.waitForExistence(timeout: 5))
        handle.doubleTap()
        sleep(3)
        let full = settled(win)
        let before = serveLog
        let shapesBefore = before.components(separatedBy: "WATCH SHAPE").count
        let liveBefore = before.components(separatedBy: "WATCH SHAPE live").count
        let finalBefore = before.components(separatedBy: "WATCH SHAPE final").count
        print("ResizableWindow: slow drag starts \(Date().timeIntervalSince1970)")
        let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // In and a little up — mostly narrower, so the window's shape changes all the way (the
        // Mac reshapes to the aspect; a drag that shrinks both sides alike changes it little) —
        // slowly, held a moment.
        from.press(forDuration: 0.3, thenDragTo: from.withOffset(CGVector(dx: -70, dy: -60)), withVelocity: .slow, thenHoldForDuration: 1.0)
        print("ResizableWindow: slow drag ended \(Date().timeIntervalSince1970)")
        sleep(4)
        let small = settled(win)
        print("ResizableWindow: \(full) → \(small)")
        XCTAssertEqual(small.width, full.width - 140, accuracy: 8, "the width shrank round the middle")
        XCTAssertEqual(small.height, full.height - 60, accuracy: 8, "the height shrank from the foot")
        if !serveLog.isEmpty {
            let log = serveLog
            let live = log.components(separatedBy: "WATCH SHAPE live").count - liveBefore
            let final = log.components(separatedBy: "WATCH SHAPE final").count - finalBefore
            print("ResizableWindow: \(live) live shapes, \(final) final (\(log.components(separatedBy: "WATCH SHAPE").count - shapesBefore) this drag)")
            XCTAssertEqual(final, 1, "one final shape, sent when the finger let go")
            XCTAssertGreaterThanOrEqual(live, 3, "the Mac's window followed the finger: several live shapes during the drag")
        }
    }
}
