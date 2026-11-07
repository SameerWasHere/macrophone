import XCTest

/// The window view meets Apple's basics (Nov 7 2026, round 3): VoiceOver never lands on a layer
/// nobody can see. With a window in hand the desktop under it (the Mac pill, the Dock, Send after
/// pasting, Cleanup) and the pages that aren't up (the trackpad under the mic page, the mic page
/// under the trackpad) are out of the accessibility tree — not merely faded; at rest no blank
/// line and no "Selected" check stops the cursor. Needs a paired `mpctl serve` (the app opens
/// its window view by itself with MACROPHONE_WATCH=1).
///
/// `TEST_RUNNER_MACROPHONE_TREE_DIR=<dir>` keeps each state's tree, audit and frame there.
/// Any other `TEST_RUNNER_MACROPHONE_*` (a frame, a posture) is passed on to the app.
final class AccessibilityTreeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var dir: URL? { env["MACROPHONE_TREE_DIR"].map { URL(fileURLWithPath: $0) } }

    private func launch(_ extra: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        var e = ["MACROPHONE_SCREEN": "main"]
        for (k, v) in env where k.hasPrefix("MACROPHONE_") && k != "MACROPHONE_TREE_DIR" { e[k] = v }
        for (k, v) in extra { e[k] = v }
        app.launchEnvironment = e
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// What's in the tree, by id (the snapshot is one call, however many ids are asked).
    private func ids(in app: XCUIApplication) -> Set<String> {
        var out = Set<String>()
        func walk(_ s: XCUIElementSnapshot) {
            if !s.identifier.isEmpty { out.insert(s.identifier) }
            for c in s.children { walk(c) }
        }
        if let snap = try? app.snapshot() { walk(snap) }
        return out
    }

    /// Every static text's label, trimmed, and every element's selected flag with its label.
    private func texts(in app: XCUIApplication) -> (blank: Int, selected: [String]) {
        var blank = 0, selected: [String] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.elementType == .staticText, s.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blank += 1 }
            if s.isSelected { selected.append("\(s.identifier)|\(s.label)") }
            for c in s.children { walk(c) }
        }
        if let snap = try? app.snapshot() { walk(snap) }
        return (blank, selected)
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        var tree = ""
        func walk(_ s: XCUIElementSnapshot, _ depth: Int) {
            let f = s.frame
            tree += String(repeating: "  ", count: depth) + "\(s.elementType.rawValue) id='\(s.identifier)' label='\(s.label)' value='\(s.value.map { "\($0)" } ?? "")' sel=\(s.isSelected) frame=(\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height)))\n"
            for c in s.children { walk(c, depth + 1) }
        }
        if let snap = try? app.snapshot() { walk(snap, 0) }
        try? tree.write(to: dir.appendingPathComponent("\(name).tree.txt"), atomically: true, encoding: .utf8)
        var audit = ""
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                let el = issue.element.map { "el=\($0.elementType.rawValue) id=\($0.identifier) label=\($0.label) frame=\($0.frame)" } ?? "el=nil"
                audit += "\(issue.auditType.rawValue) | \(issue.compactDescription) | \(el)\n"
                return true
            }
        } catch { audit += "audit error \(error)\n" }
        try? audit.write(to: dir.appendingPathComponent("\(name).audit.txt"), atomically: true, encoding: .utf8)
    }

    /// Names in the audit's issues that no one can see (the desktop under a window, a page that
    /// isn't up).
    private func invisibleNamed(byAuditOf app: XCUIApplication, _ ids: [String]) -> [String] {
        var named: [String] = []
        try? app.performAccessibilityAudit(for: .all) { issue in
            if let id = issue.element?.identifier, ids.contains(id) { named.append(id) }
            return true
        }
        return Array(Set(named)).sorted()
    }

    private static let desktop = ["mac-pill", "places", "send-toggle", "cleanup-menu", "whole-screen", "send-to-more"]

    func testAWindowInHandLeavesTheDesktopOutOfTheTree() throws {
        let app = launch(["MACROPHONE_WATCH": "1", "MACROPHONE_SEND_TO": "Claude"])
        guard any(app, "watch-done").waitForExistence(timeout: 20) else { throw XCTSkip("no paired Mac: the window never came up") }
        // (A regular iPhone: the keyboard and the trackpad are buttons beside the mic, no row.)
        guard any(app, "phone-page-trackpad").waitForExistence(timeout: 10) else { throw XCTSkip("the Mac names no pages") }
        let gotIt = app.buttons["Got it"]
        for _ in 0..<6 where gotIt.waitForExistence(timeout: 1) { gotIt.tap() }
        sleep(1)
        keep(app, "watch-mic")

        var tree = ids(in: app)
        XCTAssertTrue(tree.contains("watch-done"))
        XCTAssertTrue(tree.contains("mic-button"), "the mic page is up")
        for id in Self.desktop { XCTAssertFalse(tree.contains(id), "\(id) is under the window — not in the tree") }
        XCTAssertFalse(tree.contains("input-trackpad"), "the trackpad page isn't up")
        XCTAssertFalse(tree.contains("input-keyboard"), "nor the keyboard page")
        XCTAssertEqual(invisibleNamed(byAuditOf: app, Self.desktop + ["input-trackpad"]), [], "the audit names nothing invisible")

        // The trackpad page: the trackpad in, the mic page out.
        any(app, "phone-page-trackpad").tap()
        let trackpad = any(app, "input-trackpad")
        XCTAssertTrue(trackpad.waitForExistence(timeout: 4), "the trackpad page came up")
        sleep(1)
        keep(app, "watch-trackpad")
        tree = ids(in: app)
        XCTAssertTrue(tree.contains("input-trackpad"))
        XCTAssertFalse(tree.contains("mic-button"), "the mic page is away")
        for id in Self.desktop { XCTAssertFalse(tree.contains(id), "\(id) still out") }

        // Done: the desktop is back, the window's controls gone.
        any(app, "trackpad-bar-close").tap()
        XCTAssertTrue(any(app, "mic-button").waitForExistence(timeout: 4))
        any(app, "watch-done").tap()
        XCTAssertTrue(any(app, "places").waitForExistence(timeout: 6), "the Dock is back")
        sleep(1)
        keep(app, "rest")
        tree = ids(in: app)
        XCTAssertFalse(tree.contains("watch-done"))
        XCTAssertFalse(tree.contains("input-trackpad"))
        let t = texts(in: app)
        XCTAssertEqual(t.blank, 0, "no blank static text at rest")
        XCTAssertFalse(t.selected.contains { $0.hasSuffix("|Selected") || $0.hasSuffix("|Delivered") }, "no stray check at rest: \(t.selected)")
    }

    func testAtRestNoBlankLineAndNoStrayCheck() throws {
        let app = launch([:])
        XCTAssertTrue(any(app, "mic-button").waitForExistence(timeout: 15))
        sleep(2)
        keep(app, "rest-launch")
        let t = texts(in: app)
        XCTAssertEqual(t.blank, 0, "no blank static text at rest")
        XCTAssertFalse(ids(in: app).contains("watch-done"))
        XCTAssertFalse(t.selected.contains { $0.hasSuffix("|Selected") }, "no stray check: \(t.selected)")
    }
}
