import XCTest

/// Typing on the Duo's inner screen never moves the Mac's screen (Nov 7 2026, round 3). The
/// book stays a book: the window keeps its page's width and never reaches across the crease, only
/// its height gives way to the keyboard. On the laptop the top half keeps its left edge, its
/// width and its top — iOS's keyboard or the Mac's keys, a window or the Whole Screen — and
/// everything is back where it was once the keyboard goes. Runs on a real Duo simulator held in
/// the pose first (`duo-sim.sh pose <udid> folded|open` for the book, `tabletop|portrait` for the
/// laptop): `TEST_RUNNER_MACROPHONE_DUO_REAL=book|laptop|portrait` (portrait: flat upright). Needs a paired `mpctl serve`.
final class DuoTypingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var pose: String? { ProcessInfo.processInfo.environment["MACROPHONE_DUO_REAL"] }

    private func launch(_ extra: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        var env = ["MACROPHONE_SCREEN": "main", "MACROPHONE_WATCH": "1"]
        env.merge(extra) { $1 }
        app.launchEnvironment = env
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        return app
    }

    /// The window in hand's frame once it has settled (two reads a beat apart agree).
    private func settledWindow(_ app: XCUIApplication, _ what: String) -> CGRect {
        let window = app.descendants(matching: .any)["duo-window"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "\(what): the window is in hand")
        var last = CGRect.null
        for _ in 0..<14 {
            let f = window.frame
            if f.width > 50, abs(f.minY - last.minY) < 0.5, abs(f.height - last.height) < 0.5, abs(f.width - last.width) < 0.5 { return f }
            last = f
            usleep(500_000)
        }
        return last
    }

    /// The keyboard, raised: the laptop's mode bar (Trackpad · Mic · Keyboard) or the book's
    /// Keyboard button; up once the Mac's bar is on it.
    private func raiseKeyboard(_ app: XCUIApplication) {
        let switcher = app.descendants(matching: .any)["input-pages"]
        let button = app.buttons["deck-keyboard-button"]
        if switcher.waitForExistence(timeout: 8) {
            let cell = switcher.buttons["Keyboard"]
            if cell.exists { cell.tap() } else { switcher.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.5)).tap() }
        } else if button.waitForExistence(timeout: 3) {
            button.tap()
        } else {
            XCTFail("no way to the keyboard on this deck")
        }
        XCTAssertTrue(app.buttons["keyboard-hide"].waitForExistence(timeout: 8), "the keyboard rose with the Mac's bar on it")
        sleep(2)
    }

    private func lowerKeyboard(_ app: XCUIApplication) {
        let hide = app.buttons["keyboard-hide"]
        if hide.exists { hide.tap() }
        sleep(2)
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MACROPHONE_DUO_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testTypingNeverMovesTheMacsScreen() throws {
        guard let pose else { throw XCTSkip("set TEST_RUNNER_MACROPHONE_DUO_REAL=book|laptop|portrait with the Duo simulator held in that pose") }
        for macKeys in ["0", "1"] {
            for place in ["Claude", "screen"] {
                let what = "\(place), Mac Keys \(macKeys == "1" ? "on" : "off")"
                var env = ["MACROPHONE_SEND_TO": place, "MACROPHONE_MAC_KEYS": macKeys]
                // Flat, the window opens as the glance: Show it here takes it in hand.
                if pose == "portrait" { env["MACROPHONE_WATCH_ACTIONS"] = "wait@3,show" }
                let app = launch(env)
                let rest = settledWindow(app, "\(what): at rest")
                // XCUITest reports the app's frame upright (669 × 951) whichever way the inner
                // screen is held; the fold is across the long side's middle: the laptop's across
                // (y), the book's down it (x).
                let screen = app.frame
                let fold = max(screen.width, screen.height) / 2
                raiseKeyboard(app)
                let typed = settledWindow(app, "\(what): typing")
                shot("typing-\(pose)-\(place)-mackeys\(macKeys)")
                // For the log: where the keyboard's bar sits against the fold.
                // The bar itself (its keys' touch areas reach a few points past it).
                let barElement = app.descendants(matching: .any)["keyboard-bar"].firstMatch
                let bar = barElement.exists ? barElement.frame : app.buttons["keyboard-hide"].frame
                print("DuoTyping \(pose) \(what): window \(rest) → \(typed); the keyboard's bar top at \(bar.minY) (the fold at \(fold))")
                XCTAssertEqual(typed.minX, rest.minX, accuracy: 1, "\(what): the window's left edge never moves for the keyboard")
                XCTAssertEqual(typed.width, rest.width, accuracy: 1, "\(what): nor its width (\(rest.width) → \(typed.width))")
                XCTAssertEqual(typed.minY, rest.minY, accuracy: 1, "\(what): nor its top (\(rest.minY) → \(typed.minY))")
                XCTAssertGreaterThan(typed.height, rest.height * 0.5, "\(what): the Mac's screen is never a sliver (\(rest.height) → \(typed.height))")
                if pose == "laptop" || pose == "portrait" {
                    // Upright the keyboard never reaches the Mac's half (Nov 7 2026): the window keeps
                    // its whole frame, and the keyboard's bar sits under the window's foot — folded, in
                    // the hinge's band (iOS starts the keyboard's frame 20 pt above the fold, its keys
                    // ~50 pt below), flat on the deck under the fold.
                    XCTAssertEqual(typed.height, rest.height, accuracy: 1, "\(what): the window keeps its height (\(rest.height) → \(typed.height))")
                    XCTAssertGreaterThanOrEqual(bar.minY, rest.maxY - 1, "\(what): the keyboard's bar is under the window (\(bar.minY), its foot at \(rest.maxY))")
                    XCTAssertGreaterThanOrEqual(bar.minY, fold - (pose == "laptop" ? 24 : 0), "\(what): the keyboard reaches no higher than the fold's band (\(bar.minY), the fold at \(fold))")
                    // The bar takes a tap where it's drawn: Mac Keys swaps the keyboard, and back.
                    let toggle = app.buttons["keyboard-mac-keys"]
                    let before = toggle.value as? String
                    toggle.tap()
                    sleep(2)
                    XCTAssertNotEqual(toggle.value as? String, before, "\(what): Mac Keys answers a tap on the bar")
                    let swapped = settledWindow(app, "\(what): the keyboards swapped")
                    shot("typing-\(pose)-\(place)-mackeys\(macKeys)-swapped")
                    XCTAssertEqual(swapped.height, rest.height, accuracy: 1, "\(what): the other keyboard leaves the window whole too (\(rest.height) → \(swapped.height))")
                    XCTAssertGreaterThanOrEqual(barElement.frame.minY, rest.maxY - 1, "\(what): the other keyboard's bar is under the window too")
                    toggle.tap()
                    sleep(2)
                }
                if pose == "book" {
                    XCTAssertLessThanOrEqual(typed.maxX, fold + 1, "\(what): the book stays a book — the window never crosses the crease (\(typed.maxX), the fold at \(fold))")
                }
                lowerKeyboard(app)
                let back = settledWindow(app, "\(what): the keyboard gone")
                XCTAssertEqual(back.minX, rest.minX, accuracy: 1, "\(what): back where it was")
                XCTAssertEqual(back.width, rest.width, accuracy: 1, "\(what): at its width")
                XCTAssertEqual(back.minY, rest.minY, accuracy: 1, "\(what): at its top")
                XCTAssertEqual(back.height, rest.height, accuracy: 1, "\(what): at its height")
                app.terminate()
            }
        }
    }
}
