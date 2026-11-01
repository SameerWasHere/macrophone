import XCTest

/// The iPhone Duo's frames for `docs/screens/duo` (Oct 25 2026, the third pass): every pose's
/// main screen and window view on each page, the glance and the live words — the inner screen
/// drawn to scale on the cover (`MACROPHONE_FRAME` + `MACROPHONE_POSTURE`), a paired `mpctl
/// serve` showing Terminal. Runs only with `TEST_RUNNER_MACROPHONE_DUO_SHOTS=<dir>` (the
/// screenshots go there, `<pose>/<name>.png`); Xcode 27's simulator has no window of its own to
/// screenshot from a script — `XCUIScreen` is the one way to the cover's pixels.
final class DuoShotsTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MACROPHONE_DUO_SHOTS"] }

    override func setUp() { continueAfterFailure = true }

    private func shoot(_ pose: String, frame: String, name: String, wait: TimeInterval, extra: [String: String] = [:], keepTips: Bool = false) {
        guard let dir else { return }
        // `MACROPHONE_DUO_ONLY=a,b`: these names alone (a look at one frame while iterating).
        if let only = ProcessInfo.processInfo.environment["MACROPHONE_DUO_ONLY"].map({ Set($0.split(separator: ",").map(String.init)) }), !only.contains(name) { return }
        let app = XCUIApplication()
        var env = ["MACROPHONE_SCREEN": "main", "MACROPHONE_FRAME": frame, "MACROPHONE_POSTURE": pose,
                   "MACROPHONE_SEND_TO": "Terminal", "MACROPHONE_DUO_HEADER": "held", "MACROPHONE_WATCH": "1"]
        env.merge(extra) { $1 }
        app.launchEnvironment = env
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 1.5) { allow.tap() }
        _ = app.descendants(matching: .any)["duo-frame"].firstMatch.waitForExistence(timeout: 10)
        // The window view comes up once the Mac is connected; the tips are put away first.
        let gotIt = app.buttons["Got it"]
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if !keepTips, gotIt.exists { gotIt.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let folder = URL(fileURLWithPath: dir).appendingPathComponent(pose)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
        app.terminate()
    }

    /// The frames: the Duo's inner screen is upright (669 × 951) for the laptop and flat
    /// portrait — the fold across — and on its side (951 × 669) for the book and flat landscape
    /// (Nov 1 2026, from his phone's log; the frames had been the other way round).
    private func pose(_ pose: String, frame: String) {
        let upright = frame.hasPrefix("669")
        // Nothing in hand: the cover's view in its half, the picked app's window live in the
        // other (the glance — a flat pose opens it so; folded, the window is in hand at once).
        shoot(pose, frame: frame, name: "0-rest", wait: 8, extra: ["MACROPHONE_WATCH": "0"])
        shoot(pose, frame: frame, name: "1-main", wait: 7)
        shoot(pose, frame: frame, name: "2-window-mic", wait: 9, extra: ["MACROPHONE_WATCH_ACTIONS": "page@mic"])
        // A stand-in keyboard at the frame's scale: an iPhone's landscape keyboard is 216 pt;
        // upright at 669 pt wide it's about 300 (the real one needs a real Duo).
        shoot(pose, frame: frame, name: "3-window-keyboard", wait: 9, extra: ["MACROPHONE_WATCH_ACTIONS": "page@keyboard", "MACROPHONE_FAKE_KEYBOARD": upright ? "300" : "216"])
        shoot(pose, frame: frame, name: "4-window-trackpad", wait: 9, extra: ["MACROPHONE_WATCH_ACTIONS": "page@trackpad"])
        shoot(pose, frame: frame, name: "7-glance", wait: 9, extra: ["MACROPHONE_WATCH_ACTIONS": "done"])
        shoot(pose, frame: frame, name: "8-live-words", wait: 10, extra: ["MACROPHONE_WATCH_ACTIONS": "say@Fix the login bug where the token expires early"])
        // The first-run tip, where the open screen on its side shows one (a strip under the
        // window); the folded halves and the laptop's screen show none.
        if pose == "landscape" {
            shoot(pose, frame: frame, name: "9-first-run-tip", wait: 9, extra: ["MACROPHONE_WATCH_ACTIONS": "page@mic"], keepTips: true)
        }
    }

    func testPortraitFrames() throws {
        guard dir != nil else { throw XCTSkip("MACROPHONE_DUO_SHOTS not set") }
        pose("portrait", frame: "669x951")
    }

    func testLandscapeFrames() throws {
        guard dir != nil else { throw XCTSkip("MACROPHONE_DUO_SHOTS not set") }
        pose("landscape", frame: "951x669")
    }

    func testLaptopFrames() throws {
        guard dir != nil else { throw XCTSkip("MACROPHONE_DUO_SHOTS not set") }
        pose("laptop", frame: "669x951")
    }

    func testBookFrames() throws {
        guard dir != nil else { throw XCTSkip("MACROPHONE_DUO_SHOTS not set") }
        pose("book", frame: "951x669")
    }

    /// A look at the real keyboard rising on the laptop's deck (what the simulator does with it),
    /// a frame a second: `MACROPHONE_DUO_PROBE=1`.
    func testLaptopRealKeyboardProbe() throws {
        guard let dir, ProcessInfo.processInfo.environment["MACROPHONE_DUO_PROBE"] == "1" else { throw XCTSkip("MACROPHONE_DUO_PROBE not set") }
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_FRAME": "951x669", "MACROPHONE_POSTURE": "laptop",
                                 "MACROPHONE_SEND_TO": "Terminal", "MACROPHONE_DUO_HEADER": "held", "MACROPHONE_WATCH": "1"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 1.5) { allow.tap() }
        let switcher = app.descendants(matching: .any)["input-pages"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 20))
        let folder = URL(fileURLWithPath: dir).appendingPathComponent("probe")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switcher.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.5)).tap()
        for i in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("k\(i).png"))
            print("PROBE \(i): switcher=\(switcher.value ?? "") keyboards=\(app.keyboards.count) continue=\(app.buttons["Continue"].exists) sb-continue=\(XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Continue"].exists)")
        }
        try? app.debugDescription.write(to: folder.appendingPathComponent("hierarchy.txt"), atomically: true, encoding: .utf8)
    }

    /// The cover screen as it really runs (no frame, no forced pose — the simulator's cover, with
    /// its vertical bar): `MACROPHONE_DUO_COVER=1`. Names can be filtered: `MACROPHONE_DUO_ONLY=a,b`.
    func testCoverFrames() throws {
        guard let dir, ProcessInfo.processInfo.environment["MACROPHONE_DUO_COVER"] == "1" else { throw XCTSkip("MACROPHONE_DUO_COVER not set") }
        let only = ProcessInfo.processInfo.environment["MACROPHONE_DUO_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let shots: [(String, [String: String], TimeInterval)] = [
            ("1-main", [:], 6),
            ("2-window-mic", ["MACROPHONE_WATCH": "1", "MACROPHONE_WATCH_ACTIONS": "page@mic"], 9),
            ("3-window-keyboard", ["MACROPHONE_WATCH": "1", "MACROPHONE_WATCH_ACTIONS": "page@keyboard"], 9),
            ("4-window-keyboard-hidden", ["MACROPHONE_WATCH": "1", "MACROPHONE_WATCH_ACTIONS": "page@keyboard,page@mic"], 12),
            ("5-window-trackpad", ["MACROPHONE_WATCH": "1", "MACROPHONE_WATCH_ACTIONS": "page@trackpad"], 9),
            ("6-live-words", ["MACROPHONE_WATCH": "1", "MACROPHONE_WATCH_ACTIONS": "say@Fix the login bug where the token expires early"], 10),
        ]
        for (name, env, wait) in shots where only?.contains(name) ?? true {
            let app = XCUIApplication()
            app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": "Terminal"].merging(env) { $1 }
            app.launch()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
            if allow.waitForExistence(timeout: 1.5) { allow.tap() }
            let gotIt = app.buttons["Got it"]
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline {
                if gotIt.exists { gotIt.tap() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            let folder = URL(fileURLWithPath: dir).appendingPathComponent("cover")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
            if name.hasPrefix("4") { try? app.debugDescription.write(to: folder.appendingPathComponent("4-hierarchy.txt"), atomically: true, encoding: .utf8) }
            app.terminate()
        }
    }

    /// A hold on the cover's mic while a window shows (Oct 31 2026, Sameer: "press and hold on
    /// the mic button is not working"): the hold flips the screen to the live words, and the mic
    /// must still be the button under the finger — let go, and the mic closes.
    func testCoverMicHold() throws { try micHold(watching: true) }

    /// The same hold with no window: the mic alone.
    func testCoverMicHoldAtRest() throws { try micHold(watching: false) }

    private func micHold(watching: Bool) throws {
        guard ProcessInfo.processInfo.environment["MACROPHONE_DUO_COVER"] == "1" else { throw XCTSkip("MACROPHONE_DUO_COVER not set") }
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": "Terminal", "MACROPHONE_SIM_RECORD": "holding the button down while I talk"]
            .merging(watching ? ["MACROPHONE_WATCH": "1"] : [:]) { $1 }
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 1.5) { allow.tap() }
        if watching { XCTAssertTrue(app.buttons["cover-page-trackpad"].waitForExistence(timeout: 10), "the window's mic row") }
        let mic = app.buttons["Start dictation"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        mic.press(forDuration: 2.5)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(app.buttons["Stop and send"].exists, "the hold's release reached the mic")
        app.terminate()
    }

    /// The regular iPhone's main screen and window view, for `docs/screens/duo/regular-iphone`
    /// (unchanged by the Duo work; the proof is the frame).
    func testRegularFrames() throws {
        guard let dir, ProcessInfo.processInfo.environment["MACROPHONE_DUO_REGULAR"] == "1" else { throw XCTSkip("MACROPHONE_DUO_REGULAR not set") }
        for (name, env) in [("1-main", [:]), ("2-window", ["MACROPHONE_WATCH": "1"]), ("3-window-keyboard", ["MACROPHONE_WATCH": "1", "MACROPHONE_WATCH_ACTIONS": "page@keyboard"])] as [(String, [String: String])] {
            let app = XCUIApplication()
            app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": "Terminal"].merging(env) { $1 }
            app.launch()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
            if allow.waitForExistence(timeout: 1.5) { allow.tap() }
            let gotIt = app.buttons["Got it"]
            let deadline = Date().addingTimeInterval(env.isEmpty ? 5 : 9)
            while Date() < deadline {
                if gotIt.exists { gotIt.tap() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            let folder = URL(fileURLWithPath: dir).appendingPathComponent("regular-iphone")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
            app.terminate()
        }
    }
}
