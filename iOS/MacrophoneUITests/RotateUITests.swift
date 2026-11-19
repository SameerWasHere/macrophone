import XCTest

/// Turns the simulator (this Mac has no Simulator window to do it by hand): the turn outlives the
/// test, so a script can shoot the app on its side after. `TEST_RUNNER_MACROPHONE_ROTATE=landscape|portrait`.
final class RotateUITests: XCTestCase {
    func testRotate() throws {
        guard let want = ProcessInfo.processInfo.environment["MACROPHONE_ROTATE"] else { throw XCTSkip("no MACROPHONE_ROTATE") }
        XCUIDevice.shared.orientation = want == "landscape" ? .landscapeLeft : .portrait
        Thread.sleep(forTimeInterval: 1.5)
        // A system prompt left up (notifications) would sit over every shot after.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }
}
