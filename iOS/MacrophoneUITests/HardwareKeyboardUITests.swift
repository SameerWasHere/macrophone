import XCTest

/// A real keyboard types into the Mac (Nov 5 2026): with a window in hand, the simulator's
/// hardware keyboard (XCUITest's `typeText` / `typeKey` go through it) types on the Mac and its
/// chords arrive as chords — ⌘ held on the Mac, the key with it, ⌘ let go. Needs a paired
/// `mpctl serve`, which prints what arrives: "WATCH TYPE 5 characters", "WATCH KEY ⌘ down",
/// "WATCH KEY ⌘⇥ pressed", "WATCH KEY ⌘ up". With `TEST_RUNNER_MACROPHONE_SERVE_LOG=<serve's
/// output file>` the test reads what the Mac got and checks it.
///
/// XCUITest's limits, found here: `typeText` goes to a key input as inserted text (not presses), and
/// `typeKey` with no modifier never reaches a responder as a press (Esc, Delete and Return
/// generate no events at all); a chord with ⌘ or ⌥ is a real press. iOS keeps ⌘Tab: Tab never
/// arrives while ⌘ is down — ⌥Tab is the Mac's switcher instead.
final class HardwareKeyboardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAHardwareKeyboardTypesAndChordsOnTheMac() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": "Terminal", "MACROPHONE_WATCH": "1"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        // The note says where a keyboard's typing goes, once, in the status line for a few seconds
        // as the window opens (Nov 7 2026, round 4) — looked for from the start, it's brief.
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Keyboard connected · typing on")).firstMatch
        let noted = note.waitForExistence(timeout: 20)
        let done = app.buttons["watch-done"].firstMatch
        guard done.waitForExistence(timeout: 20) else { throw XCTSkip("no paired Mac: the window view never opened") }
        XCTAssertTrue(noted, "the status line says where the keyboard types")
        sleep(1)

        let logPath = ProcessInfo.processInfo.environment["MACROPHONE_SERVE_LOG"]
        let before = logPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.count ?? 0

        app.typeText("hello")
        sleep(1)
        // ⌘C, ⌘Z, ⌥⌫, ⌘←, Esc, an arrow, Return, a function key.
        app.typeKey("c", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: .option)
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.F5.rawValue, modifierFlags: [])
        sleep(2)

        if let logPath, let all = try? String(contentsOfFile: logPath, encoding: .utf8) {
            let got = String(all.replacingOccurrences(of: "\0", with: "").suffix(max(0, all.count - before)))
            for line in ["WATCH TYPE 1 characters", "WATCH KEY ⌘ down", "WATCH KEY ⌘C pressed", "WATCH KEY ⌘Z pressed",
                         "WATCH KEY ⌘←\u{FE0E} pressed", "WATCH KEY ⌘ up"] {
                XCTAssertTrue(got.contains(line), "the Mac got \(line): \(got.components(separatedBy: "\n").filter { $0.hasPrefix("WATCH TYPE") || $0.hasPrefix("WATCH KEY") })")
            }
            XCTAssertEqual(got.components(separatedBy: "WATCH TYPE 1 characters").count - 1, 5, "hello, a character at a time")
        }

        XCTAssertTrue(done.exists, "the window view is still up: none of it went to the phone itself")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "no iOS keyboard came up for it")
        done.tap()
    }

    /// The app switcher, as a keyboard's presses would come (`hwkeys@`: XCUITest never delivers Tab,
    /// and iOS keeps ⌘Tab): ⌘ held on the Mac, Tab twice with it, ⌘ let go — then ⌥Tab, the
    /// stand-in, the same on the Mac.
    func testTheSwitcherChordReachesTheMac() throws {
        let logPath = ProcessInfo.processInfo.environment["MACROPHONE_SERVE_LOG"]
        let before = logPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.count ?? 0
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": "Terminal", "MACROPHONE_WATCH": "1",
                                 "MACROPHONE_WATCH_ACTIONS": "hwkeys@command+tab+tab,hwkeys@option+tab+tab"]
        app.launch()
        let done = app.buttons["watch-done"].firstMatch
        guard done.waitForExistence(timeout: 20) else { throw XCTSkip("no paired Mac: the window view never opened") }
        sleep(8)
        guard let logPath, let all = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        let got = String(all.suffix(max(0, all.count - before)))
        let keys = got.components(separatedBy: "\n").filter { $0.hasPrefix("WATCH KEY ") }
        XCTAssertEqual(keys, ["WATCH KEY ⌘ down", "WATCH KEY ⌘⇥ pressed", "WATCH KEY ⌘⇥ pressed", "WATCH KEY ⌘ up",
                              "WATCH KEY ⌘ down", "WATCH KEY ⌘⇥ pressed", "WATCH KEY ⌘⇥ pressed", "WATCH KEY ⌘ up"])
        done.tap()
    }
}
