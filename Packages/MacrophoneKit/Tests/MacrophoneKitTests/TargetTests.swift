import XCTest
@testable import MacrophoneKit

final class TargetTests: XCTestCase {
    let claude = LiveTarget(bundleID: "com.anthropic.claudefordesktop", appName: "Claude")
    let messages = LiveTarget(bundleID: "com.apple.MobileSMS", appName: "Messages")
    let chatgpt = LiveTarget(bundleID: "com.openai.chat", appName: "ChatGPT")
    let termWin = LiveTarget(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "claude — ~/app", windowKey: "41")

    func testSpokenAppName() {
        let all = [claude, messages, chatgpt, termWin]
        XCTAssertEqual(SpokenTarget.match("Messages, tell Sam I'm late.", targets: all)?.target.id, messages.id)
        XCTAssertEqual(SpokenTarget.match("Messages, tell Sam I'm late.", targets: all)?.text, "Tell Sam I'm late.")
        XCTAssertEqual(SpokenTarget.match("Chat GPT: compare these", targets: all)?.target.id, chatgpt.id)
        XCTAssertEqual(SpokenTarget.match("Terminal, run the tests", targets: all)?.target.id, termWin.id)
        XCTAssertNil(SpokenTarget.match("messages from the server are slow", targets: all))
        XCTAssertNil(SpokenTarget.match("Claude", targets: all))
    }

    func testRefsAndSelection() {
        XCTAssertTrue(termWin.ref.matches(termWin))
        XCTAssertFalse(TargetRef.app(bundleID: "com.apple.Terminal", windowKey: nil, name: "Terminal").matches(termWin))
        XCTAssertEqual(termWin.id, "com.apple.Terminal#41")
        XCTAssertEqual(termWin.title, "Terminal — claude — ~/app")
        // Send is meaningless for the clipboard, so it never sticks there.
        XCTAssertFalse(SendSelection(target: .clipboard, send: true).send)
        XCTAssertTrue(SendSelection(target: claude.ref, send: true).send)
        let sel = SendSelection(target: .frontApp, send: true)
        XCTAssertEqual(try JSONDecoder().decode(SendSelection.self, from: JSONEncoder().encode(sel)), sel)
    }
}
