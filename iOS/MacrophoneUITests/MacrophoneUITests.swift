import XCTest

/// Drives the real mic button, its gestures and the pairing link on the simulator.
/// The simulator can't load speech assets, so MACROPHONE_SIM_RECORD stands in for the
/// recognizer; everything after "stopped" (cleanup, delivery, status) is the real path.
///
/// Pairing test: start `mpctl serve --auto-approve` and pass its URL with
/// `TEST_RUNNER_MACROPHONE_PAIR_URL='macrophone://pair?…' xcodebuild test …`.
final class MacrophoneUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ env: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = env
        app.launch()
        return app
    }

    private func statusContains(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 20) -> Bool {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: timeout)
    }

    func testTapStartsAndTapSends() {
        let app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_SIM_RECORD": "testing the tap to talk path one two three"])
        let start = app.buttons["Start dictation"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        let stop = app.buttons["Stop and send"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "a tap starts recording")
        sleep(2)
        XCTAssertTrue(stop.exists, "a quick tap keeps recording (tap mode)")
        stop.tap()
        XCTAssertTrue(app.buttons["Start dictation"].waitForExistence(timeout: 5), "a second tap stops")
        XCTAssertTrue(statusContains(app, "Delivered") || statusContains(app, "Copied on iPhone", timeout: 1) || statusContains(app, "queued", timeout: 1))
    }

    func testHoldToTalkSendsOnRelease() {
        let app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_SIM_RECORD": "holding the button down while I talk"])
        let start = app.buttons["Start dictation"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Start dictation"].waitForExistence(timeout: 3), "letting go stops")
        XCTAssertFalse(app.buttons["Stop and send"].exists)
        XCTAssertTrue(statusContains(app, "Delivered") || statusContains(app, "Copied on iPhone", timeout: 1) || statusContains(app, "queued", timeout: 1))
    }

    func testScreensOpen() {
        let app = launch(["MACROPHONE_SCREEN": "main"])
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        app.buttons["History"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
    }

    func testSendToPickerRemembersTheChoice() {
        let app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac", "MACROPHONE_SEND_TO": "automatic"])
        let chip = app.buttons["send-to"]
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        XCTAssertTrue(chip.label.contains("Automatic"), chip.label)
        chip.tap()
        XCTAssertTrue(app.navigationBars["Send To"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Say “ChatGPT” first'")).firstMatch.exists, "the picker shows each target's lead-in")
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'ChatGPT'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["send-to"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["send-to"].label.contains("ChatGPT"), app.buttons["send-to"].label)
        app.terminate()
        let again = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac"])
        XCTAssertTrue(again.buttons["send-to"].waitForExistence(timeout: 8))
        XCTAssertTrue(again.buttons["send-to"].label.contains("ChatGPT"), "the pick is remembered")
    }

    /// iOS only tells apps "iPhone": pairing ends by asking what the Mac should call it, with the
    /// owner's name read off the Mac's ("Sameer's MacBook Pro" → "Sameer's iPhone").
    func testPairingSuccessAsksForTheName() {
        let app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "main", "MACROPHONE_DEVICE_NAME": "iPhone",
                          "MACROPHONE_PAIRING": "paired"])
        let field = app.textFields["device-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        XCTAssertEqual(field.value as? String, "iPhone")
        XCTAssertTrue(app.staticTexts["What should your Mac call this iPhone?"].exists)
        let use = app.buttons["Use “Sameer's iPhone”"]
        XCTAssertTrue(use.exists, "suggests a name from the Mac's")
        use.tap()
        XCTAssertEqual(field.value as? String, "Sameer's iPhone")
        app.buttons["Start Dictating"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 3))
        app.buttons["Settings"].tap()
        let setting = app.textFields["This iPhone's name"]
        XCTAssertTrue(setting.waitForExistence(timeout: 3))
        XCTAssertEqual(setting.value as? String, "Sameer's iPhone", "the name is saved")
    }

    /// No Mac: the first dictation is copied on the iPhone, says so, and offers the Mac app once.
    func testFirstDictationWithoutAMac() {
        // MACROPHONE_UNPAIR: this simulator may have paired with a test Mac earlier.
        let app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "main", "MACROPHONE_UNPAIR": "1",
                          "MACROPHONE_FAKE_TRANSCRIPT": "hello from my iPhone", "MACROPHONE_FAKE_DELAY": "3"])
        XCTAssertTrue(statusContains(app, "Copied on iPhone — paste it anywhere", timeout: 30))
        let nudge = app.buttons["mac-app-nudge"]
        XCTAssertTrue(nudge.waitForExistence(timeout: 3))
        app.buttons["Hide this"].tap()
        XCTAssertTrue(nudge.waitForNonExistence(timeout: 3))
        app.terminate()
        let again = launch(["MACROPHONE_SCREEN": "main"])
        XCTAssertTrue(again.buttons["Start dictation"].waitForExistence(timeout: 8))
        XCTAssertFalse(again.buttons["mac-app-nudge"].exists, "hidden for good")
    }

    func testVoicePrefixStatusHasNoEllipsis() {
        let app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac",
                          "MACROPHONE_STATUS": "delivered-prefix"])
        XCTAssertTrue(statusContains(app, "Sent to Claude — you said “Claude” first", timeout: 8))
    }

    /// Xcode's accessibility audit (labels, hit regions, clipped text, contrast, Dynamic Type) on each screen.
    func testAccessibilityAudit() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("needs iOS 17") }
        let paired = ["MACROPHONE_RESET": "1", "MACROPHONE_FAKE_PAIRED": "Sameer's MacBook Pro", "MACROPHONE_FAKE_HISTORY": "1"]
        var found: [String] = []
        for screen in ["main", "history", "settings", "sendto", "pairing", "dictionary", "onboarding"] {
            let app = launch(paired.merging(["MACROPHONE_SCREEN": screen]) { $1 })
            sleep(3)
            // Contrast and Dynamic Type are left out on purpose: the contrast check fails the system's own
            // toolbar buttons and white-on-ink text in this dark-only app (false positives), and a few
            // chrome pieces cap their text size by design (the Mac's name, Send to, the Cleaned/Raw toggle).
            let types: XCUIAccessibilityAuditType = [.elementDetection, .hitRegion, .sufficientElementDescription, .textClipped, .trait]
            try app.performAccessibilityAudit(for: types) { issue in
                // History's swipe-to-delete action is a hidden system node the audit can't size
                // (it has no element); Delete is also in each row's menu.
                if issue.auditType == .hitRegion, issue.element == nil, screen == "history" { return true }
                let e = issue.element
                let d = (e?.debugDescription ?? "") + " frame \(e?.frame ?? .zero) id '\(e?.identifier ?? "")' type \(e?.elementType.rawValue ?? 0)"
                print("AUDIT \(screen): \(issue.auditType.rawValue) \(issue.compactDescription) | \(issue.detailedDescription) — \(d.prefix(400))")
                found.append("\(screen): \(issue.compactDescription) \(issue.element?.label ?? "")")
                return true
            }
            app.terminate()
        }
        XCTAssertTrue(found.isEmpty, found.joined(separator: "\n"))
    }

    func testDumpHistory() throws {
        guard ProcessInfo.processInfo.environment["MACROPHONE_DUMP"] != nil else { throw XCTSkip("dump only") }
        let app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_FAKE_PAIRED": "Sameer's MacBook Pro", "MACROPHONE_FAKE_HISTORY": "1", "MACROPHONE_SCREEN": ProcessInfo.processInfo.environment["MACROPHONE_DUMP"] ?? "history"])
        sleep(3)
        print("DUMP\n" + app.debugDescription)
    }

    func testPairingLinkFromCamera() throws {
        guard let s = ProcessInfo.processInfo.environment["MACROPHONE_PAIR_URL"], let url = URL(string: s) else {
            throw XCTSkip("no MACROPHONE_PAIR_URL")
        }
        let app = launch(["MACROPHONE_SCREEN": "main"])
        XCTAssertTrue(app.buttons["Start dictation"].waitForExistence(timeout: 8))
        XCUIDevice.shared.system.open(url)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }
        XCTAssertTrue(statusContains(app, "Paired with", timeout: 20))
    }
}
