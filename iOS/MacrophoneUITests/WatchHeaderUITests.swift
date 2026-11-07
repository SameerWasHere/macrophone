import XCTest

/// The watched window's own chrome (Nov 7 2026): the window's name reads whole on every phone —
/// light and dark, with an alert watch on (the gold bell beside it) and off — and a question's
/// answers never move the window. Run on an iPhone simulator paired with `mpctl serve` (its demo
/// windows "Claude" and "Terminal" ask a numbered question). `TEST_RUNNER_MACROPHONE_WATCH_SE=1`
/// draws the phone at an SE's size (`MACROPHONE_FRAME=375x667`).
final class WatchHeaderUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var se: Bool { ProcessInfo.processInfo.environment["MACROPHONE_WATCH_SE"] == "1" }

    private func launch(_ app: String, appearance: String, alert: Bool, actions: [String] = []) -> XCUIApplication {
        let a = XCUIApplication()
        var env = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": app, "MACROPHONE_WATCH": "1",
                   "MACROPHONE_WATCH_ACTIONS": ([alert ? "alert" : "alertoff"] + actions).joined(separator: ",")]
        if se { env["MACROPHONE_FRAME"] = "375x667" }
        a.launchEnvironment = env
        a.launchArguments = ["-settings.appearance", appearance]
        a.launch()
        return a
    }

    /// "● Claude": the live dot, 8 pt beside the name, and the name in full — "C…" was about 30 pt.
    private func minimumWidth(_ name: String) -> CGFloat { name == "Claude" ? 58 : 70 }

    func testTheNameReadsWhole() {
        for name in ["Claude", "Terminal"] {
            for appearance in ["light", "dark"] {
                for alert in [true, false] {
                    let app = launch(name, appearance: appearance, alert: alert)
                    let menu = app.buttons["watch-sessions"]
                    XCTAssertTrue(menu.waitForExistence(timeout: 20), "the window view is up (\(name))")
                    XCTAssertTrue(menu.label.contains(name), "the menu names \(name): \(menu.label)")
                    let kicker = app.descendants(matching: .any)["watch-kicker"]
                    XCTAssertTrue(kicker.waitForExistence(timeout: 5))
                    // The window live (its Mac connected, its features known), then a moment for
                    // the alert watch to reach the Mac and the bell to come (the actions are 2 s apart).
                    expectation(for: NSPredicate(format: "label BEGINSWITH 'Live'"), evaluatedWith: kicker)
                    waitForExpectations(timeout: 25)
                    sleep(4)
                    let bell = app.descendants(matching: .any)["watch-alert-on"]
                    XCTAssertEqual(bell.exists, alert, "the bell by the name follows the alert watch (\(name), \(appearance))")
                    if alert { XCTAssertEqual(bell.label, "Alerts on") }
                    XCTAssertGreaterThanOrEqual(kicker.frame.width, minimumWidth(name),
                                                "\(name) reads whole (\(appearance), alert \(alert)): \(kicker.frame.width) pt")
                    XCTAssertTrue(app.buttons["watch-done"].isHittable, "Done stays")
                    XCTAssertTrue(app.buttons["watch-window"].waitForExistence(timeout: 5), "the Window menu stays")
                    app.terminate()
                }
            }
        }
    }

    /// The answers are one row as tall as the key row they replace: the window keeps its frame
    /// while the question is up and after it goes (Esc).
    func testAQuestionNeverMovesTheWindow() {
        let app = launch("Terminal", appearance: "light", alert: false)
        let window = app.images.matching(NSPredicate(format: "label CONTAINS %@", "window on your Mac")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        let answers = app.descendants(matching: .any)["watch-answers"]
        XCTAssertTrue(answers.waitForExistence(timeout: 40), "the demo window asks its question")
        sleep(1)
        let asking = window.frame
        // One row: no taller than the key row (38 pt) and its shadow.
        XCTAssertLessThanOrEqual(answers.frame.height, 44, "the answers are one row: \(answers.frame.height) pt")
        let first = app.buttons["watch-answer-1"]
        XCTAssertTrue(first.exists)
        XCTAssertTrue(first.label.contains("don't ask again this session"), "the whole answer to VoiceOver: \(first.label)")
        app.buttons["watch-escape"].firstMatch.tap()
        XCTAssertTrue(app.buttons["watch-arrowUp"].waitForExistence(timeout: 10), "the keys are back")
        sleep(1)
        XCTAssertEqual(window.frame, asking, "the window kept its frame as the question went")
    }
}
