import XCTest

/// An alert from the Mac as it reaches the phone (Nov 6 2026): the app posts one with a picture
/// (`MACROPHONE_FAKE_ALERT`), goes home, and the notification is looked at in Notification Center
/// and held open. `TEST_RUNNER_MACROPHONE_ALERT_TEST=1`; screenshots go to
/// `TEST_RUNNER_MACROPHONE_ALERT_SHOTS=<dir>`. Notifications must be allowed for the app.
final class AlertNotificationUITests: XCTestCase {
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MACROPHONE_ALERT_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testTheAlertCarriesThePicture() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACROPHONE_ALERT_TEST"] == "1", "a look at the notification, on request")
        let app = XCUIApplication()
        app.launchEnvironment["MACROPHONE_FAKE_ALERT"] = "3"
        app.launch()
        sleep(5)
        shot("1-banner")
        XCUIDevice.shared.press(.home)
        sleep(2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Notification Center: a swipe down from the top.
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
        sleep(2)
        shot("2-center")
        let note = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Build finished'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "the alert is in Notification Center")
        // A stack opens on the first hold; the notification itself on the next.
        note.press(forDuration: 1.2)
        sleep(2)
        if springboard.buttons["Show less"].exists || springboard.buttons["Show Less"].exists {
            springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Build finished'")).firstMatch.press(forDuration: 1.2)
            sleep(2)
        }
        shot("3-expanded")
    }
}
