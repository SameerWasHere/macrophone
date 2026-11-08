import XCTest

/// The answer finds you (Nov 8 2026): a dictation sent into a chat, and a few seconds after it
/// lands the chat "answers" — the phone gets "Claude answered you" with the reply's last lines and
/// a picture, as a notification; a tap opens that window live. Needs `mpctl serve --answer-after 4`
/// paired with this simulator (`TEST_RUNNER_MACROPHONE_CHAT_TEST=1`; frames to
/// `TEST_RUNNER_MACROPHONE_CHAT_SHOTS=<dir>`).
final class ChatAnswersUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MACROPHONE_CHAT_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func launch(switchOn: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_WATCH": "rest",
                                 "MACROPHONE_SEND_TO": "Claude", "MACROPHONE_SEND": "1",
                                 "MACROPHONE_WATCH_ACTIONS": "record,stoprecord",
                                 "MACROPHONE_SIM_RECORD": "Fix the login bug please"]
        // The window doesn't open after sending (it would be "looking at it": no alert then).
        app.launchArguments = ["-settings.watchAfterSending", "<false/>", "-settings.chatAnswers", switchOn ? "<true/>" : "<false/>"]
        app.launch()
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        return app
    }

    /// Waits for the banner, allowing notifications when the app asks (it asks at the first send
    /// into a chat — the landing — not at launch).
    private func waitForBanner(_ seconds: Int) -> Bool {
        for _ in 0..<seconds {
            if banner.exists { return true }
            let allow = springboard.buttons["Allow"]
            if allow.exists { allow.tap() }
            sleep(1)
        }
        return banner.exists
    }

    private var banner: XCUIElement {
        springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Claude answered you'")).firstMatch
    }

    func testTheAnswerArrivesAndATapOpensTheWindow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACROPHONE_CHAT_TEST"] == "1", "needs mpctl serve --answer-after")
        let app = launch(switchOn: true)
        XCTAssertTrue(app.buttons["mic-button"].firstMatch.waitForExistence(timeout: 10))
        // The landing (the simulator's cleanup, then serve's 1.5 s), then the answer 4 s on.
        XCTAssertTrue(waitForBanner(70), "the answer comes as a notification")
        shot("1-banner")
        XCTAssertTrue(banner.label.contains("login test passes"), "the reply's last lines are under it: \(banner.label)")
        banner.tap()
        // The header is built only while a window shows (the kept panel leaves it out).
        XCTAssertTrue(app.descendants(matching: .any)["watch-done"].firstMatch.waitForExistence(timeout: 10), "the tap opens the window")
        sleep(2)
        shot("2-opened")
    }

    /// The switch turned off and on again in Settings while connected reaches the Mac at once
    /// (serve prints "CHAT ANSWERS off", then "CHAT ANSWERS on" — the live message, not a hello).
    func testTurningTheSwitchOffInSettingsReachesTheMac() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACROPHONE_CHAT_TEST"] == "1", "needs mpctl serve --answer-after")
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "settings", "MACROPHONE_SEND_TO": "Claude", "MACROPHONE_SEND": "1",
                                 "MACROPHONE_SIM_RECORD": "Fix the login bug please"]
        app.launchArguments = ["-settings.watchAfterSending", "<false/>"]
        app.launch()
        let toggle = app.switches["chat-answers"].firstMatch
        for _ in 0..<12 where !toggle.isHittable { app.swipeUp(); sleep(1) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if (toggle.value as? String) == "1" { toggle.switches.firstMatch.tap() }
        sleep(1)
        shot("3-switch-off")
        XCTAssertEqual(toggle.value as? String, "0", "the switch is off")
        sleep(2)
        // Turned back on for the next run (the Mac hears that too).
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
    }

    func testWithTheSwitchOffNothingComes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACROPHONE_CHAT_TEST"] == "1", "needs mpctl serve --answer-after")
        let app = launch(switchOn: false)
        XCTAssertTrue(app.buttons["mic-button"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["landed-pill"].firstMatch.waitForExistence(timeout: 45), "it landed")
        XCTAssertFalse(waitForBanner(14), "no answer alert with the switch off")
    }
}
