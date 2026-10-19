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

    /// "Send to: Claude" — the panel's header line.
    private func sendTo(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["send-to"] }
    /// The native Send after pasting switch.
    private func sendSwitch(_ app: XCUIApplication) -> XCUIElement { app.switches["send-toggle"] }
    /// The Cleanup menu by the switch (Oct 19 2026: a menu, not a segmented row).
    private func cleanupMenu(_ app: XCUIApplication) -> XCUIElement { app.buttons["cleanup-menu"] }
    /// Picks a cleanup level from the menu (waiting for the panel to be back first).
    private func pickLevel(_ app: XCUIApplication, _ title: String) {
        tapWhenBack(cleanupMenu(app))
        // A menu's items keep their names (not always their identifiers).
        let item = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "cleanup-\(title.lowercased())", title)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "\(title) in the Cleanup menu")
        item.tap()
    }
    /// The level the menu shows.
    private func isLevel(_ app: XCUIApplication, _ title: String) -> Bool { cleanupMenu(app).label.contains(title) }
    /// Edit Custom Instructions, from the menu.
    private func editCustom(_ app: XCUIApplication) {
        tapWhenBack(cleanupMenu(app))
        let item = app.buttons.matching(NSPredicate(format: "identifier == 'edit-custom' OR label BEGINSWITH 'Edit Custom Instructions'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
    }
    /// Flips the switch itself (the row is the element; the switch sits at its trailing end).
    /// Waits for the controls to be back (they step aside until a dictation has gone out), then taps.
    private func tapWhenBack(_ e: XCUIElement) {
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: e)
        waitForExpectations(timeout: 15)
        e.tap()
    }
    private func flip(_ e: XCUIElement) { e.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }

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
        XCTAssertFalse(app.switches["send-toggle"].isHittable, "the controls are hidden while recording")
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
        let chip = sendTo(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        XCTAssertTrue(chip.label.contains("Clipboard"), chip.label)
        XCTAssertFalse(sendSwitch(app).isEnabled, "Send after pasting is greyed out for Clipboard")
        // Every place is a button in the row — and no full list behind it.
        for name in ["Clipboard", "Where I'm typing", "Claude", "Messages", "Terminal"] {
            XCTAssertTrue(app.buttons[name].exists, "the row shows \(name)")
        }
        XCTAssertFalse(app.buttons["all-places"].exists, "no All places end-cap")
        // Where: Messages, one tap.
        let messages = app.buttons["Messages"]
        messages.tap()
        XCTAssertTrue(sendTo(app).label.contains("Messages"), sendTo(app).label)
        XCTAssertTrue(messages.isSelected, "the picked app is the prominent button")
        // Send after pasting: one tap, and the status line says what it does now.
        let send = sendSwitch(app)
        XCTAssertTrue(["Off", "0"].contains("\(send.value ?? "")"), "\(send.value ?? "nil")")
        XCTAssertTrue(send.label.contains("Presses Return in Messages after pasting"), send.label)
        flip(send)
        // The status line first: it says what changed for a few seconds only.
        XCTAssertTrue(statusContains(app, "Pastes into Messages, then sends", timeout: 3))
        XCTAssertTrue(["On", "1"].contains("\(send.value ?? "")"), "\(send.value ?? "nil")")
        // Cleanup: Light, from its menu.
        pickLevel(app, "Light")
        XCTAssertTrue(isLevel(app, "Light"))
        XCTAssertTrue(statusContains(app, "Light cleanup — Removes filler", timeout: 3))
        dictate(app)
        XCTAssertTrue(probe(app, contains: "target=app:com.apple.MobileSMS# send=1 cleanup=light said=0"))
        // Back to paste only, Heavy cleanup: the next one follows.
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: sendSwitch(app))
        waitForExpectations(timeout: 15)
        flip(sendSwitch(app))
        pickLevel(app, "Heavy")
        dictate(app)
        XCTAssertTrue(probe(app, contains: "target=app:com.apple.MobileSMS# send=0 cleanup=heavy"))
        // Custom: unedited, the cleaner is told Medium's instructions.
        XCTAssertFalse(app.buttons["edit-custom"].exists, "Edit instructions only with Custom")
        pickLevel(app, "Custom")
        XCTAssertTrue(isLevel(app, "Custom"))
        XCTAssertTrue(statusContains(app, "Custom cleanup — Medium's instructions", timeout: 3))
        dictate(app)
        XCTAssertTrue(probe(app, contains: "cleanup=custom said=0"))
        XCTAssertTrue(probe(app, contains: "instructions=You clean up speech-to-text transcripts."))
        // Edited (Edit instructions): the next dictation follows his words.
        editCustom(app)
        let editor = app.textViews["custom-instructions"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "Edit instructions opens them")
        replaceText(editor, with: "Write it all in capital letters.")
        XCTAssertEqual(app.staticTexts["custom-count"].label, "32 characters")
        app.navigationBars["Custom Cleanup"].buttons["Done"].tap()
        dictate(app)
        XCTAssertTrue(probe(app, contains: "cleanup=custom said=0"))
        XCTAssertTrue(probe(app, contains: "instructions=Write it all in capital letters."))
        // Emptied, it falls back to the default.
        editCustom(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
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
        XCTAssertTrue(sendTo(app).waitForExistence(timeout: 8))
        XCTAssertTrue(sendTo(app).label.contains("Messages"), "the pick is remembered")
        dictate(app)
        XCTAssertTrue(probe(app, contains: "target=app:com.anthropic.claudefordesktop# send=0 cleanup=off said=1 text=Tell Sam I'm late"))
        // No Mac in this run: copied here, or queued for the Mac (the mic pass's words), naming Claude or not.
        XCTAssertTrue(statusContains(app, "Copied on iPhone") || statusContains(app, "queued", timeout: 1) || statusContains(app, "Claude", timeout: 1))
        XCTAssertTrue(sendTo(app).label.contains("Messages"), "a spoken name is for that one dictation")
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
        XCTAssertTrue(app.collectionViews.segmentedControls["cleanup-level"].buttons["Custom"].isSelected)
        link.tap()
        XCTAssertEqual(editor.value as? String, "Keep it short.")
        app.buttons["custom-reset"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Reset to Default' AND identifier != 'custom-reset'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "the reset asks first")
        confirm.tap()
        XCTAssertTrue((editor.value as? String ?? "").hasPrefix("You clean up speech-to-text transcripts."), "reset to the default")
    }

    /// The Send to row: Clipboard and Where I'm typing first, then the Mac's open apps, one button
    /// each; an app with several windows lists them on a long-press; a picked app that closed stays
    /// in the row, dimmed, "Not open".
    func testPlacesAndWindows() {
        var app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac",
                          "MACROPHONE_FAKE_TARGETS": "long"])
        XCTAssertTrue(app.buttons["Clipboard"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Clipboard"].isSelected, "a fresh install sends to Clipboard")
        XCTAssertTrue(app.buttons["Where I'm typing"].exists)
        let terminal = app.buttons["Terminal, 2 windows"]
        XCTAssertTrue(terminal.exists, "one button per app, its windows counted")
        terminal.press(forDuration: 1.0)
        let window = app.buttons["claude"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), "the long-press lists the windows")
        window.tap()
        XCTAssertTrue(sendTo(app).label.contains("Terminal — claude"), sendTo(app).label)
        XCTAssertTrue(app.buttons["Terminal, 2 windows"].isSelected)
        app.terminate()
        // Relaunched with Terminal gone from the Mac: still picked, in the row, marked.
        app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac", "MACROPHONE_FAKE_TARGETS": "none"])
        let closed = app.buttons["Terminal — claude, not open on your Mac"]
        XCTAssertTrue(closed.waitForExistence(timeout: 8), "the closed pick stays in the row")
        XCTAssertTrue(closed.isSelected)
        XCTAssertTrue(sendTo(app).label.contains("not open on your Mac"))
    }

    /// Each control says what it does in words; one that can't apply says why.
    func testControlsExplainThemselves() {
        let app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac",
                          "MACROPHONE_CLEANUP_AVAILABLE": "1", "MACROPHONE_SEND_TO": "clipboard"])
        let send = sendSwitch(app)
        XCTAssertTrue(send.waitForExistence(timeout: 8))
        XCTAssertFalse(send.isEnabled)
        XCTAssertTrue(send.label.contains("Clipboard only copies — pick an app to send"), send.label)
        pickLevel(app, "Heavy")
        XCTAssertTrue(statusContains(app, "Heavy cleanup — Rewrites rambling speech", timeout: 3))
        XCTAssertTrue(isLevel(app, "Heavy"))
        app.buttons["Where I'm typing"].tap()
        XCTAssertTrue(statusContains(app, "Pastes where you're typing on your Mac", timeout: 3))
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(send.label.contains("Presses Return where you're typing"), send.label)
        pickLevel(app, "Custom")
        XCTAssertTrue(statusContains(app, "Custom cleanup — Medium's instructions", timeout: 3))
        cleanupMenu(app).tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'edit-custom' OR label BEGINSWITH 'Edit Custom Instructions'")).firstMatch.waitForExistence(timeout: 3),
                      "Edit Custom Instructions in Custom's menu")
    }

    func testScreensOpen() {
        let app = launch(["MACROPHONE_SCREEN": "main"])
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        app.buttons["History"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
    }

    func testSendToRemembersTheChoice() {
        let app = launch(["MACROPHONE_RESET": "1", "MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac"])
        XCTAssertTrue(sendTo(app).waitForExistence(timeout: 8))
        XCTAssertTrue(sendTo(app).label.contains("Clipboard"), sendTo(app).label)
        app.buttons["Terminal"].tap()
        XCTAssertTrue(sendTo(app).label.contains("Terminal"), sendTo(app).label)
        app.terminate()
        // Relaunched with Terminal no longer open on the Mac: still picked, marked not open.
        let again = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_FAKE_PAIRED": "Test Mac", "MACROPHONE_FAKE_TARGETS": "none"])
        XCTAssertTrue(sendTo(again).waitForExistence(timeout: 8))
        XCTAssertTrue(sendTo(again).label.contains("Terminal"), "the pick is remembered")
        XCTAssertTrue(sendTo(again).label.contains("not open on your Mac"), sendTo(again).label)
        XCTAssertTrue(again.staticTexts["Not open"].exists, "the closed app's button says so")
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
        for screen in only ?? ["main", "history", "settings", "custom", "pairing", "dictionary", "onboarding"] {
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
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Connected to'")).firstMatch.waitForExistence(timeout: 20), "connected")
        // The Mac's open apps are in the Send to row: one tap picks Messages.
        let messages = app.buttons["Messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 10), "the Mac's open apps are in the row")
        messages.tap()
        let send = sendSwitch(app)
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        if !["On", "1"].contains("\(send.value ?? "")") { flip(send) }
        print("LIVE picked Messages + send")
        let changed = NSPredicate(format: "label CONTAINS 'Claude'")
        expectation(for: changed, evaluatedWith: sendTo(app))
        waitForExpectations(timeout: 60)
        print("LIVE chip now: \(sendTo(app).label)")
    }

    /// Save to Mac's Downloads (Oct 19 2026): with Send to on the clipboard the ⋯ items save to
    /// Downloads; on a chat they send into it, with Save to Mac's Downloads one more choice.
    func testSaveToDownloadsItems() throws {
        guard ProcessInfo.processInfo.environment["MACROPHONE_LIVE"] == "1" else { throw XCTSkip("needs mpctl serve") }
        for (pick, expect) in [("clipboard", "Save a File to Mac's Downloads…"), ("Claude", "Send a File…")] {
            let app = launch(["MACROPHONE_SCREEN": "main", "MACROPHONE_SEND_TO": pick])
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Connected to'")).firstMatch.waitForExistence(timeout: 20), "connected")
            let more = app.buttons["send-to-more"]
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
            XCTAssertTrue(app.buttons[expect].waitForExistence(timeout: 5), "\(pick): \(expect)")
            if pick != "clipboard" {
                let save = app.buttons["Save to Mac's Downloads"]
                XCTAssertTrue(save.exists, "the choice under Send a File…")
                save.tap()
                XCTAssertTrue(app.buttons["A File…"].waitForExistence(timeout: 3))
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "downloads-\(pick)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
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
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Connected to'")).firstMatch.waitForExistence(timeout: 20), "connected")
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
