import XCTest

/// The Duo cover's vertical bar while the keyboard comes and goes (Nov 7 2026, round 5). The
/// cover's keyboard spans the bar's column, so with it up the column is a little under half as
/// tall: the system folds the lowest tiers into ⋯, one item at a time, and Done and the keyboard's
/// own item never leave. Nothing in the set changes with the keyboard — the same ids, in the same
/// order, before and after. Needs a Duo simulator on its cover, paired with `mpctl serve`.
/// Prints every item's frame in both states (the column's measure for CLAUDE.md).
final class CoverBarKeyboardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The watching set, top to bottom.
    static let set = ["watch-done", "bar-keyboard", "watch-sound", "mac-controls", "cover-alert", "cover-drag", "watch-whole", "watch-window"]

    func testTheBarsItemsHoldThroughTheKeyboard() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["MACROPHONE_SCREEN": "main", "MACROPHONE_WATCH": "rest", "MACROPHONE_WATCH_ACTIONS": "pick@Claude,open"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let done = app.buttons["watch-done"].firstMatch
        guard done.waitForExistence(timeout: 20) else { throw XCTSkip("no Mac connected: the window never opened") }
        let keyboard = app.buttons["bar-keyboard"].firstMatch
        guard keyboard.waitForExistence(timeout: 3) else { throw XCTSkip("not the Duo's cover: no vertical bar") }
        sleep(3)

        let down = frames(app)
        print("BAR keyboard down: \(words(down))")
        XCTAssertEqual(down.map(\.id), Self.set, "the whole set, in order, with the keyboard down")
        XCTAssertTrue(down.allSatisfy(\.hittable), "every item hittable with the keyboard down")
        XCTAssertEqual(keyboard.label, "Keyboard")

        keyboard.tap()
        let keys = app.keyboards.firstMatch
        XCTAssertTrue(keys.waitForExistence(timeout: 5), "the bar's Keyboard raises the keyboard")
        sleep(2)
        let up = frames(app)
        let overflow = more(app)
        print("BAR keyboard up: \(words(up)); keyboard top \(Int(keys.frame.minY)); ⋯ \(overflow.exists ? "y=\(Int(overflow.frame.minY))–\(Int(overflow.frame.maxY))" : "none")")
        print("BAR tree with the keyboard up:\n" + app.debugDescription.split(separator: "\n").filter { $0.contains("Button") && !$0.contains("Key,") }.joined(separator: "\n"))
        XCTAssertTrue(done.exists && done.isHittable, "Done stays in the bar with the keyboard up")
        XCTAssertEqual(done.frame.midY, down[0].frame.midY, accuracy: 1, "Done where it was")
        // The column holds two positions with the keyboard up: Done, and the system's ⋯ with the
        // rest — Hide Keyboard first, so it's one tap more than the bar's item was.
        XCTAssertTrue(overflow.exists && overflow.isHittable, "⋯ holds the folded items")
        overflow.tap()
        let hide = app.buttons["Hide Keyboard"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 3), "⋯ opens on Hide Keyboard")
        let rows = ["Sound", "Mac Controls", "Alerts Off", "Whole Window", "Window"]
        let shown = rows.filter { app.buttons[$0].firstMatch.exists || app.staticTexts[$0].firstMatch.exists }
        // (Pan | Scroll reads "What one finger does" to VoiceOver; its row is found by either.)
        let drag = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'one finger' OR label == 'Pan' OR label == 'Scroll'")).firstMatch
        print("BAR ⋯ rows: \(shown)\(drag.exists ? " + \(drag.label)" : ""); menu: \(app.buttons.allElementsBoundByIndex.filter { $0.frame.minY > 150 && $0.frame.maxY < 335 && $0.frame.maxX < 390 }.map(\.label))")
        XCTAssertEqual(shown.count, rows.count, "every folded item is in ⋯: \(shown)")
        XCTAssertTrue(drag.exists, "Pan | Scroll is in ⋯")
        hide.tap()

        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: keys)
        waitForExpectations(timeout: 5)
        sleep(2)
        let back = frames(app)
        print("BAR keyboard hidden again: \(words(back))")
        XCTAssertEqual(back.map(\.id), Self.set, "the bar has the items it had")
        XCTAssertEqual(keyboard.label, "Keyboard")
        for (a, b) in zip(back, down) {
            XCTAssertEqual(a.frame.midY, b.frame.midY, accuracy: 1, "\(a.id) back where it was")
        }
    }

    private struct Item { let id: String; let frame: CGRect; let hittable: Bool }

    private func frames(_ app: XCUIApplication) -> [Item] {
        Self.set.compactMap { id in
            let e = app.buttons[id].firstMatch
            guard e.exists else { return nil }
            return Item(id: id, frame: e.frame, hittable: e.isHittable)
        }
        .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func words(_ items: [Item]) -> String {
        items.map { "\($0.id) y=\(Int($0.frame.minY))–\(Int($0.frame.maxY))\($0.hittable ? "" : " (not hittable)")" }.joined(separator: ", ")
    }

    /// The system's overflow item (⋯).
    private func more(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label ==[c] 'More' OR identifier CONTAINS[c] 'overflow' OR label CONTAINS[c] 'more'")).firstMatch
    }
}
