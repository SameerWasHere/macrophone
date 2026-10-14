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

    /// Delivered (in the Mac's own words: "Pasted into …", "Sent to …", "Copied …"), copied on the
    /// iPhone, or queued.
    private func delivered(_ app: XCUIApplication) -> Bool {
        statusContains(app, "Delivered") || ["Copied", "Pasted into", "Sent to", "Printed by", "queued", "In ", "clipboard", "Sending to"].contains { statusContains(app, $0, timeout: 1) }
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
        XCTAssertTrue(delivered(app))
    }

    func testHoldToTalkSendsOnRelease() {
        let app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_SIM_RECORD": "holding the button down while I talk"])
        let start = app.buttons["Start dictation"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Start dictation"].waitForExistence(timeout: 3), "letting go stops")
        XCTAssertFalse(app.buttons["Stop and send"].exists)
        XCTAssertTrue(delivered(app))
    }

    /// The mic button sits in one place: idle or recording, with or without history,
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
        // While the mic is open the controls step aside: the transcript has the whole area.
        XCTAssertFalse(app.descendants(matching: .any)["send-toggle"].isHittable, "the controls are hidden while recording")
        XCTAssertFalse(app.buttons["History"].isHittable, "the top bar is hidden while recording")
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
            ("a very long window name", ["MACROPHONE_FAKE_TARGETS": "long",
                                         "MACROPHONE_SEND_TO": "Terminal — claude — ~/Projects/macrophone/Packages/MacrophoneKit — 120×40"]),
            ("cleanup off", ["MACROPHONE_CLEANUP": "off", "MACROPHONE_CLEANUP_AVAILABLE": "1"]),
            ("heavy cleanup", ["MACROPHONE_CLEANUP": "heavy", "MACROPHONE_CLEANUP_AVAILABLE": "1"]),
            ("custom cleanup", ["MACROPHONE_CLEANUP": "custom", "MACROPHONE_CLEANUP_AVAILABLE": "1"]),
            ("custom's explanation", ["MACROPHONE_CLEANUP": "custom", "MACROPHONE_CLEANUP_AVAILABLE": "1",
                                      "MACROPHONE_EXPLAIN": "Custom cleanup — Medium's instructions until you edit them. Tap Custom again to edit"]),
            ("cleanup unavailable", ["MACROPHONE_CLEANUP": "medium"]),
            ("an app that closed", ["MACROPHONE_SEND_TO": "Claude", "MACROPHONE_FAKE_TARGETS": "none"]),
            ("no open apps", ["MACROPHONE_FAKE_TARGETS": "none", "MACROPHONE_SEND_TO": "clipboard"]),
            ("a control's explanation", ["MACROPHONE_EXPLAIN": "Pastes into Terminal — claude — ~/Projects/macrophone/Packages/MacrophoneKit — 120×40, then sends"]),
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

    /// At accessibility text sizes the page may scroll, but starting to record still doesn't move
    /// the button: the card keeps its room and fades, the quick controls stay where they are.
    func testMicButtonNeverMovesAtAccessibilitySizes() {
        for size in ["UICTContentSizeCategoryAccessibilityM", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", size]
            app.launchEnvironment = ["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac",
                                     "MACROPHONE_FAKE_HISTORY": "1", "MACROPHONE_SEND_TO": "Claude", "MACROPHONE_SEND": "1",
                                     "MACROPHONE_CLEANUP_AVAILABLE": "1", "MACROPHONE_CLEANUP": "custom",
                                     "MACROPHONE_SIM_RECORD": "Messages, a long enough sentence to fill a few lines of words while I keep on talking"]
            app.launch()
            let start = app.buttons["Start dictation"]
            XCTAssertTrue(start.waitForExistence(timeout: 8))
            let idle = start.frame
            start.tap()
            sleep(3)
            let stop = app.buttons["Stop and send"]
            XCTAssertTrue(stop.waitForExistence(timeout: 3))
            XCTAssertEqual(idle.midY, stop.frame.midY, accuracy: 0.5, "\(size): recording keeps the button in place")
            stop.tap()
            sleep(4)
            XCTAssertEqual(idle.midY, app.buttons["Start dictation"].frame.midY, accuracy: 0.5, "\(size): the new last dictation keeps the button in place")
            app.terminate()
        }
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
                    "MACROPHONE_ROUTE_PROBE": "1", "MACROPHONE_CLEANUP_AVAILABLE": "1", "MACROPHONE_FAKE_CLEANUP": "1"]
        var app = launch(base.merging(["MACROPHONE_SIM_RECORD": "running late, start without me"]) { $1 })
        // A fresh install sends to Clipboard, and Clipboard can't send.
        let chip = app.buttons["send-to"]
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        XCTAssertTrue(chip.label.contains("Clipboard"), chip.label)
        XCTAssertTrue(app.descendants(matching: .any)["send-toggle"].label.contains("Clipboard can't send"), app.descendants(matching: .any)["send-toggle"].label)
        // The full list is one tap away: the places and every window — and no automations.
        chip.tap()
        XCTAssertTrue(app.navigationBars["Send To"].waitForExistence(timeout: 3))
        for name in ["Clipboard", "Where I'm typing", "Claude", "Messages", "Terminal — claude"] {
            XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.exists, "the picker lists \(name)")
        }
        app.swipeUp()
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'automation'")).firstMatch.exists, "no Automations section")
        app.buttons["Done"].tap()
        // Where: Messages, one tap on the dock.
        let messages = app.buttons["Messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 3), "the dock shows the Mac's open apps")
        messages.tap()
        XCTAssertTrue(app.buttons["send-to"].label.contains("Messages"), app.buttons["send-to"].label)
        XCTAssertTrue(messages.isSelected, "the picked app is lit")
        // Send after pasting: one tap, and the status line says what it does now.
        let send = app.descendants(matching: .any)["send-toggle"]
        XCTAssertTrue(["Off", "0"].contains("\(send.value ?? "")"), "\(send.value ?? "nil")")
        send.tap()
        expectation(for: NSPredicate(format: "value == '1' OR value == 'On'"), evaluatedWith: send)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(statusContains(app, "Pastes into Messages, then sends", timeout: 3))
        // Cleanup: Light, one tap.
        app.buttons["cleanup-light"].tap()
        XCTAssertTrue(app.buttons["cleanup-light"].isSelected)
        XCTAssertTrue(statusContains(app, "Light cleanup — Removes filler", timeout: 3))
        dictate(app)
        XCTAssertTrue(probe(app, contains: "target=app:com.apple.MobileSMS# send=1 cleanup=light said=0"))
        // Back to paste only, Heavy cleanup: the next one follows.
        app.descendants(matching: .any)["send-toggle"].tap()
        app.buttons["cleanup-heavy"].tap()
        dictate(app)
        XCTAssertTrue(probe(app, contains: "target=app:com.apple.MobileSMS# send=0 cleanup=heavy"))
        // Custom: unedited, the cleaner is told Medium's instructions.
        app.buttons["cleanup-custom"].tap()
        XCTAssertTrue(app.buttons["cleanup-custom"].isSelected)
        XCTAssertTrue(statusContains(app, "Custom cleanup — Medium's instructions", timeout: 3))
        dictate(app)
        XCTAssertTrue(probe(app, contains: "cleanup=custom said=0"))
        XCTAssertTrue(probe(app, contains: "instructions=You clean up speech-to-text transcripts."))
        // Edited (tap Custom again): the next dictation follows his words.
        app.buttons["cleanup-custom"].tap()
        let editor = app.textViews["custom-instructions"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "tapping the picked Custom opens its instructions")
        replaceText(editor, with: "Write it all in capital letters.")
        XCTAssertEqual(app.staticTexts["custom-count"].label, "32 characters")
        app.navigationBars["Custom Cleanup"].buttons["Done"].tap()
        dictate(app)
        XCTAssertTrue(probe(app, contains: "cleanup=custom said=0"))
        XCTAssertTrue(probe(app, contains: "instructions=Write it all in capital letters."))
        // Emptied, it falls back to the default.
        app.buttons["cleanup-custom"].press(forDuration: 1.0)
        app.buttons["Edit Custom Instructions"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "a long-press opens them too")
        XCTAssertEqual(editor.value as? String, "Write it all in capital letters.", "saved as typed")
        replaceText(editor, with: "")
        app.navigationBars["Custom Cleanup"].buttons["Done"].tap()
        dictate(app)
        XCTAssertTrue(probe(app, contains: "instructions=You clean up speech-to-text transcripts."))
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

    /// Puts the cursor after the last word (scrolled to the end, a tap past it), deletes everything,
    /// then types. (A plain tap leaves the cursor wherever it lands.)
    private func replaceText(_ field: XCUIElement, with text: String) {
        field.tap()
        field.swipeUp(velocity: .fast)
        field.swipeUp(velocity: .fast)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.98)).tap()
        let count = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 5) + text)
    }

    /// The Custom instructions in Settings: prefilled with Medium's, "Use Custom" when another level
    /// is picked, saved as typed, and Reset to Default (confirmed) brings the default back.
    func testCustomInstructionsInSettings() {
        let app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "settings", "MACROPHONE_CLEANUP_AVAILABLE": "1",
                          "MACROPHONE_CLEANUP": "medium", "MACROPHONE_CUSTOM_INSTRUCTIONS": "default"])
        let link = app.buttons["custom-instructions-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 8))
        XCTAssertTrue(link.label.contains("Default"), link.label)
        link.tap()
        let editor = app.textViews["custom-instructions"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue((editor.value as? String ?? "").hasPrefix("You clean up speech-to-text transcripts."), "prefilled with Medium's")
        XCTAssertFalse(app.buttons["custom-reset"].isEnabled, "nothing to reset yet")
        app.buttons["use-custom"].tap()
        XCTAssertTrue(app.buttons["use-custom"].waitForNonExistence(timeout: 3), "Custom is now the level")
        replaceText(editor, with: "Keep it short.")
        XCTAssertEqual(app.staticTexts["custom-count"].label, "14 characters")
        app.navigationBars["Custom Cleanup"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(link.waitForExistence(timeout: 3))
        XCTAssertTrue(link.label.contains("Your own"), link.label)
        XCTAssertTrue(app.collectionViews.buttons["cleanup-custom"].isSelected)
        link.tap()
        XCTAssertEqual(editor.value as? String, "Keep it short.")
        app.buttons["custom-reset"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Reset to Default' AND identifier != 'custom-reset'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "the reset asks first")
        confirm.tap()
        XCTAssertTrue((editor.value as? String ?? "").hasPrefix("You clean up speech-to-text transcripts."), "reset to the default")
    }

    /// The dock: Clipboard and Where I'm typing first, then the Mac's open apps; an app with several
    /// windows wears a count and its long-press lists them; the end-cap opens every place; a picked
    /// app that closed stays on the dock, marked.
    func testDockPlacesAndWindows() {
        var app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac",
                          "MACROPHONE_FAKE_TARGETS": "long"])
        XCTAssertTrue(app.buttons["Clipboard"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Clipboard"].isSelected, "a fresh install sends to Clipboard")
        XCTAssertTrue(app.buttons["Where I'm typing"].exists)
        let terminal = app.buttons["Terminal, 2 windows"]
        XCTAssertTrue(terminal.exists, "one icon per app, its windows counted")
        terminal.press(forDuration: 1.0)
        let window = app.buttons["claude"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), "the long-press lists the windows")
        window.tap()
        XCTAssertTrue(app.buttons["send-to"].label.contains("Terminal — claude"), app.buttons["send-to"].label)
        XCTAssertTrue(app.buttons["Terminal, 2 windows"].isSelected)
        app.buttons["all-places"].tap()
        XCTAssertTrue(app.navigationBars["Send To"].waitForExistence(timeout: 3), "the end-cap opens every place")
        app.buttons["Done"].tap()
        app.terminate()
        // Relaunched with Terminal gone from the Mac: still picked, on the dock, marked.
        app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac", "MACROPHONE_FAKE_TARGETS": "none"])
        let closed = app.buttons["Terminal — claude, not open on your Mac"]
        XCTAssertTrue(closed.waitForExistence(timeout: 8), "the closed pick stays on the dock")
        XCTAssertTrue(closed.isSelected)
        XCTAssertTrue(app.buttons["send-to"].label.contains("not open on your Mac"))
    }

    /// A control that can't apply says why when tapped; each cleanup step says what it does.
    func testControlsExplainThemselves() {
        let app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac",
                          "MACROPHONE_CLEANUP_AVAILABLE": "1", "MACROPHONE_SEND_TO": "clipboard"])
        let send = app.descendants(matching: .any)["send-toggle"]
        XCTAssertTrue(send.waitForExistence(timeout: 8))
        XCTAssertTrue(send.label.contains("Clipboard can't send"), send.label)
        send.tap()
        XCTAssertTrue(statusContains(app, "Clipboard only copies", timeout: 3))
        app.buttons["cleanup-heavy"].tap()
        XCTAssertTrue(statusContains(app, "Heavy cleanup — Rewrites rambling speech", timeout: 3))
        XCTAssertTrue(app.buttons["cleanup-heavy"].isSelected)
        app.buttons["Where I'm typing"].tap()
        XCTAssertTrue(statusContains(app, "Pastes where you're typing on your Mac", timeout: 3))
        app.buttons["cleanup-custom"].tap()
        XCTAssertTrue(statusContains(app, "Tap Custom again to edit", timeout: 3))
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
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Terminal —'")).firstMatch.tap()
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
        let only = ProcessInfo.processInfo.environment["AUDIT_SCREENS"]?.split(separator: ",").map(String.init)
        for screen in only ?? ["main", "history", "settings", "sendto", "custom", "pairing", "dictionary", "onboarding"] {
            // AUDIT_ENV="KEY=VALUE;KEY=VALUE" adds launch settings (to narrow a finding down).
            var extra: [String: String] = [:]
            for kv in (ProcessInfo.processInfo.environment["AUDIT_ENV"] ?? "").split(separator: ";") {
                let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
                if p.count == 2 { extra[p[0]] = p[1] }
            }
            let app = launch(paired.merging(["MACROPHONE_SCREEN": screen]) { $1 }.merging(extra) { $1 })
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

    /// Against a real stand-in Mac (`mpctl serve --commands`, already paired): a pick on the phone
    /// reaches the Mac, and a change made on the Mac shows on the phone's chip while it's open.
    /// Run with TEST_RUNNER_MACROPHONE_LIVE=1; while it waits, type `select com.anthropic.claudefordesktop`
    /// into mpctl.
    func testLiveSyncWithMac() throws {
        guard ProcessInfo.processInfo.environment["MACROPHONE_LIVE"] == "1" else { throw XCTSkip("needs mpctl serve") }
        let app = launch(["MACROPHONE_SCREEN": "main"])
        XCTAssertTrue(statusContains(app, "Ready", timeout: 20), "connected")
        // The Mac's open apps are on the dock: one tap picks Messages.
        let messages = app.buttons["Messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 10), "the Mac's open apps are on the dock")
        messages.tap()
        XCTAssertTrue(app.descendants(matching: .any)["send-toggle"].waitForExistence(timeout: 3))
        let send = app.descendants(matching: .any)["send-toggle"]
        if !["On", "1"].contains("\(send.value ?? "")") { send.tap() }
        print("LIVE picked Messages + send")
        let changed = NSPredicate(format: "label CONTAINS 'Claude'")
        expectation(for: changed, evaluatedWith: app.buttons["send-to"])
        waitForExpectations(timeout: 60)
        print("LIVE chip now: \(app.buttons["send-to"].label)")
    }

    /// Where it landed, in the status line's words (the debug statuses, no Mac needed). The ✓ only
    /// for a landing where it was meant to go; a miss says what happened and what to do.
    func testLandingWords() {
        let cases: [(String, String)] = [
            ("landing", "Sending to Claude…"),
            ("landed-sent", "In Claude — sent"),
            ("landed-pasted", "Pasted into Claude"),
            ("landed-clipboard", "On your Mac's clipboard"),
            ("landed-failed", "Didn't land in Claude — the message box wasn't found. It's on your Mac's clipboard"),
            ("landed-copied", "Claude isn't open — copied instead. Press ⌘V on your Mac where you want it"),
            ("landed-cancelled", "Cancelled on your Mac — nothing was pasted"),
            ("unconfirmed", "Your Mac received it but didn't confirm where it landed"),
        ]
        var micFrame: CGRect?
        for (status, words) in cases {
            let app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac", "MACROPHONE_STATUS": status])
            XCTAssertTrue(statusContains(app, words, timeout: 6), "\(status): \(words)")
            let mic = app.buttons["Start dictation"]
            XCTAssertTrue(mic.waitForExistence(timeout: 3))
            if let f = micFrame {
                XCTAssertEqual(f.midY, mic.frame.midY, accuracy: 0.5, "\(status) keeps the mic in place")
            } else { micFrame = mic.frame }
            app.terminate()
        }
    }

    /// Against `mpctl serve` (paired already), one dictation, and where it landed. Run with
    /// TEST_RUNNER_MACROPHONE_LIVE=1 and TEST_RUNNER_MACROPHONE_LAND_EXPECT=sent|failed|copied|cancelled|timeout|old
    /// (serve with `--land failed` etc.; timeout and old drop the Mac's report on the phone).
    func testLandingLive() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MACROPHONE_LIVE"] == "1", let expect = env["MACROPHONE_LAND_EXPECT"] else { throw XCTSkip("needs mpctl serve") }
        var launchEnv = ["MACROPHONE_SCREEN": "main", "MACROPHONE_SIM_RECORD": "Claude, the landing test \(expect) one two three"]
        if expect == "timeout" { launchEnv["MACROPHONE_LANDINGS"] = "ignore" }
        if expect == "old" { launchEnv["MACROPHONE_LANDINGS"] = "ignore-old" }
        let app = launch(launchEnv)
        XCTAssertTrue(statusContains(app, "Ready", timeout: 20), "connected")
        let start = app.buttons["Start dictation"]
        let idle = start.frame
        start.tap()
        sleep(2)
        app.buttons["Stop and send"].tap()
        if ["timeout", "old"].contains(expect) {
            XCTAssertTrue(statusContains(app, "Sending to Claude", timeout: 10), "waits for where it landed")
        }
        let words: String
        switch expect {
        case "sent":
            // Sent, or pasted when Send after pasting is off for Claude.
            words = statusContains(app, "Pasted into Claude", timeout: 8) ? "Pasted into Claude" : "In Claude — sent"
        case "failed": words = "Didn't land in Claude"
        case "copied": words = "copied to your Mac's clipboard instead"
        case "cancelled": words = "Cancelled on your Mac"
        case "timeout": words = "didn't confirm where it landed"
        default: words = "Printed by mpctl"
        }
        XCTAssertTrue(statusContains(app, words, timeout: 20), words)
        XCTAssertEqual(app.buttons["Start dictation"].frame.midY, idle.midY, accuracy: 0.5, "the mic never moves")
        print("LIVE landing \(expect): \(words)")
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
