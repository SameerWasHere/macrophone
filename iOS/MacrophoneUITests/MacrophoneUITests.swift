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

    /// The mic button sits in one place: idle or recording, with or without a last dictation,
    /// paired or not, whatever the quick controls and the status line say. A button that slides
    /// out from under a held finger is the worst feeling.
    func testMicButtonNeverMoves() {
        func frame(_ app: XCUIApplication, _ label: String) -> CGRect {
            let b = app.buttons[label]
            XCTAssertTrue(b.waitForExistence(timeout: 8), "\(label) exists")
            return b.frame
        }
        func same(_ a: CGRect, _ b: CGRect, _ what: String) {
            XCTAssertEqual(a.midX, b.midX, accuracy: 0.5, what)
            XCTAssertEqual(a.midY, b.midY, accuracy: 0.5, what)
        }
        let paired = ["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac", "MACROPHONE_FAKE_HISTORY": "1"]
        // Paired, a last dictation on screen, Paste & send to an app; then say another app's name.
        var app = launch(paired.merging(["MACROPHONE_RESET": "1", "MACROPHONE_SEND_TO": "Claude", "MACROPHONE_SEND": "1",
                                         "MACROPHONE_SIM_RECORD": "Messages, a long enough sentence to fill a few lines of words while I keep on talking about the uploader and how it retries"]) { $1 })
        let idle = frame(app, "Start dictation")
        app.buttons["Start dictation"].tap()
        sleep(3)
        same(idle, frame(app, "Stop and send"), "recording (an app said first) keeps the button in place")
        // Changing the quick controls mid-recording doesn't move it either.
        app.buttons["Paste"].tap()
        same(idle, frame(app, "Stop and send"), "a send change while recording keeps the button in place")
        app.buttons["Stop and send"].tap()
        same(idle, frame(app, "Start dictation"), "sending keeps the button in place")
        sleep(4)
        same(idle, frame(app, "Start dictation"), "the new last dictation keeps the button in place")
        app.terminate()
        // Hold to talk: the button is under the finger the whole time.
        app = launch(paired.merging(["MACROPHONE_SIM_RECORD": "holding the button down while I talk"]) { $1 })
        let holdStart = app.buttons["Start dictation"]
        XCTAssertTrue(holdStart.waitForExistence(timeout: 8))
        same(idle, holdStart.frame, "before a hold")
        holdStart.press(forDuration: 2)
        same(idle, frame(app, "Start dictation"), "after a hold")
        app.terminate()
        // Every status line, target and control state.
        let states: [(String, [String: String])] = [
            ("queued", ["MACROPHONE_STATUS": "queued"]),
            ("failed with the Mac's reason", ["MACROPHONE_STATUS": "failed"]),
            ("a problem with Open Settings", ["MACROPHONE_STATUS": "problem"]),
            ("not open on the Mac", ["MACROPHONE_STATUS": "not-open"]),
            ("delivered by a spoken name", ["MACROPHONE_STATUS": "delivered-spoken"]),
            ("Clipboard (send unavailable)", ["MACROPHONE_SEND_TO": "clipboard"]),
            ("Where I'm typing", ["MACROPHONE_SEND_TO": "front", "MACROPHONE_SEND": "1"]),
            ("an automation", ["MACROPHONE_SEND_TO": "Quick note"]),
            ("a very long window name", ["MACROPHONE_FAKE_TARGETS": "long",
                                         "MACROPHONE_SEND_TO": "Terminal — claude — ~/Projects/macrophone/Packages/MacrophoneKit — 120×40"]),
            ("cleanup off", ["MACROPHONE_CLEANUP": "off", "MACROPHONE_CLEANUP_AVAILABLE": "1"]),
            ("heavy cleanup", ["MACROPHONE_CLEANUP": "heavy", "MACROPHONE_CLEANUP_AVAILABLE": "1"]),
            ("no history yet", ["MACROPHONE_RESET": "1", "MACROPHONE_FAKE_HISTORY": "0"]),
        ]
        for (what, env) in states {
            app = launch(paired.merging(env) { $1 })
            same(idle, frame(app, "Start dictation"), "\(what) keeps the button in place")
            app.terminate()
        }
        // Not paired, then the first dictation copied on the iPhone with the Mac-app nudge.
        app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_UNPAIR": "1", "MACROPHONE_RESET": "1"])
        same(idle, frame(app, "Start dictation"), "unpaired keeps the button in place")
        app.terminate()
        app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_UNPAIR": "1", "MACROPHONE_RESET": "1",
                      "MACROPHONE_FAKE_TRANSCRIPT": "hello from my iPhone", "MACROPHONE_FAKE_DELAY": "1"])
        XCTAssertTrue(app.buttons["mac-app-nudge"].waitForExistence(timeout: 10))
        same(idle, frame(app, "Start dictation"), "the Mac-app nudge keeps the button in place")
    }

    /// Each quick control changes the next dictation: where it goes, Paste or Paste & send, and the
    /// cleanup level — and saying an app's name first sends just that one there, name taken off.
    func testQuickControlsChangeTheNextDictation() {
        func probe(_ app: XCUIApplication, contains s: String) -> Bool {
            let e = app.otherElements["debug-route"].exists ? app.otherElements["debug-route"] : app.staticTexts["debug-route"]
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if e.exists, e.label.contains(s) { return true }
                usleep(250_000)
            }
            print("PROBE \(e.exists ? e.label : "missing")")
            return false
        }
        func dictate(_ app: XCUIApplication) {
            let start = app.buttons["Start dictation"]
            XCTAssertTrue(start.waitForExistence(timeout: 8))
            start.tap()
            sleep(2)
            app.buttons["Stop and send"].tap()
        }
        let base = ["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac",
                    "MACROPHONE_ROUTE_PROBE": "1", "MACROPHONE_CLEANUP_AVAILABLE": "1"]
        var app = launch(base.merging(["MACROPHONE_SIM_RECORD": "running late, start without me"]) { $1 })
        // A fresh install sends to Clipboard, and Clipboard can't send.
        let chip = app.buttons["send-to"]
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        XCTAssertTrue(chip.label.contains("Clipboard"), chip.label)
        XCTAssertTrue(app.staticTexts["Clipboard can't send"].exists || app.otherElements["send-toggle"].label.contains("Clipboard can't send"))
        // Where: Messages, from the picker.
        chip.tap()
        XCTAssertTrue(app.navigationBars["Send To"].waitForExistence(timeout: 3))
        for name in ["Clipboard", "Where I'm typing", "Claude", "Messages", "Terminal — claude"] {
            XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.exists, "the picker lists \(name)")
        }
        app.swipeUp()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Quick note'")).firstMatch.waitForExistence(timeout: 2), "the picker lists automations")
        app.swipeDown()
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Messages'")).firstMatch.tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["send-to"].label.contains("Messages"), app.buttons["send-to"].label)
        // Paste & send: one tap.
        app.buttons["Paste & send"].tap()
        // Cleanup: Light, from the menu.
        app.buttons["cleanup-level"].tap()
        let light = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Light'")).firstMatch
        XCTAssertTrue(light.waitForExistence(timeout: 3))
        light.tap()
        XCTAssertTrue(app.buttons["cleanup-level"].label.contains("Light"), app.buttons["cleanup-level"].label)
        dictate(app)
        XCTAssertTrue(probe(app, contains: "target=app:com.apple.MobileSMS# send=1 cleanup=light said=0"))
        // Back to Paste, Heavy cleanup: the next one follows.
        app.buttons["Paste"].tap()
        app.buttons["cleanup-level"].tap()
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Heavy'")).firstMatch.tap()
        dictate(app)
        XCTAssertTrue(probe(app, contains: "target=app:com.apple.MobileSMS# send=0 cleanup=heavy"))
        app.terminate()
        // The choices are remembered; saying another app's name first sends just that one there.
        app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac", "MACROPHONE_ROUTE_PROBE": "1",
                      "MACROPHONE_CLEANUP_AVAILABLE": "1", "MACROPHONE_CLEANUP": "off",
                      "MACROPHONE_SIM_RECORD": "Claude, tell Sam I'm late"])
        XCTAssertTrue(app.buttons["send-to"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["send-to"].label.contains("Messages"), "the pick is remembered")
        dictate(app)
        XCTAssertTrue(probe(app, contains: "target=app:com.anthropic.claudefordesktop# send=0 cleanup=off said=1 text=Tell Sam I'm late"))
        XCTAssertTrue(statusContains(app, "Copied on iPhone") || statusContains(app, "Claude", timeout: 1))
        XCTAssertTrue(app.buttons["send-to"].label.contains("Messages"), "a spoken name is for that one dictation")
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
        let app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac"])
        let chip = app.buttons["send-to"]
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        XCTAssertTrue(chip.label.contains("Clipboard"), chip.label)
        chip.tap()
        XCTAssertTrue(app.navigationBars["Send To"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Automatic'")).firstMatch.exists, "no Automatic")
        app.swipeUp()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Say “Note” first'")).firstMatch.waitForExistence(timeout: 2), "automations show their lead-in")
        app.swipeDown()
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Terminal'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["send-to"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["send-to"].label.contains("Terminal"), app.buttons["send-to"].label)
        app.terminate()
        // Relaunched with Terminal no longer open on the Mac: still picked, marked not open.
        let again = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac", "MACROPHONE_FAKE_TARGETS": "none"])
        XCTAssertTrue(again.buttons["send-to"].waitForExistence(timeout: 8))
        XCTAssertTrue(again.buttons["send-to"].label.contains("Terminal"), "the pick is remembered")
        XCTAssertTrue(again.buttons["send-to"].label.contains("not open on your Mac"), again.buttons["send-to"].label)
        again.buttons["send-to"].tap()
        XCTAssertTrue(again.staticTexts["Not open on your Mac — it'll be copied instead"].waitForExistence(timeout: 3)
                      || again.buttons.containing(NSPredicate(format: "label CONTAINS 'Not open on your Mac'")).firstMatch.exists)
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
