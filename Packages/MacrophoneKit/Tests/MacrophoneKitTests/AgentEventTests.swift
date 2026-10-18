import XCTest
@testable import MacrophoneKit

final class AgentEventTests: XCTestCase {
    func testPermissionIsWaitingWithTheCommand() {
        let e = AgentEvent(agent: "claude", event: "PermissionRequest", session: "s", tool: "Bash", toolDetail: "git push origin main")
        XCTAssertEqual(e.effect, .state(.waiting, detail: "Run git push origin main?"))
    }

    func testEditNamesTheFile() {
        let e = AgentEvent(agent: "claude", event: "PermissionRequest", session: "s", tool: "Edit", toolDetail: "Watcher.swift")
        XCTAssertEqual(e.question, "Edit Watcher.swift?")
    }

    func testNotificationKinds() {
        XCTAssertEqual(AgentEvent(agent: "claude", event: "Notification", session: "s", message: "Claude needs your permission to use Bash", kind: "permission_prompt").effect,
                       .state(.waiting, detail: "Claude needs your permission to use Bash"))
        XCTAssertEqual(AgentEvent(agent: "claude", event: "Notification", session: "s", message: "Claude is waiting for your input", kind: "idle_prompt").effect,
                       .state(.yourTurn, detail: nil))
        XCTAssertEqual(AgentEvent(agent: "claude", event: "Notification", session: "s", kind: "auth_success").effect, .nothing)
    }

    func testTurnsAndEnds() {
        XCTAssertEqual(AgentEvent(agent: "claude", event: "UserPromptSubmit", session: "s").effect, .state(.working, detail: nil))
        XCTAssertEqual(AgentEvent(agent: "claude", event: "Stop", session: "s", lastMessage: "Done.\n\nMore detail").effect, .state(.yourTurn, detail: "Done."))
        XCTAssertEqual(AgentEvent(agent: "codex", event: "agent-turn-complete", session: "t", lastMessage: "Tests pass").effect, .state(.yourTurn, detail: "Tests pass"))
        XCTAssertEqual(AgentEvent(agent: "claude", event: "SessionEnd", session: "s").effect, .ends)
    }

    func testClipCutsAtAWord() {
        let long = String(repeating: "word ", count: 60)
        let c = AgentEvent.clip(long, to: 40)!
        XCTAssertTrue(c.hasSuffix("…"))
        XCTAssertLessThanOrEqual(c.count, 41)
    }

    func testUnknownStateReadsAsWorking() throws {
        let json = #"{"id":"a","agent":"Claude Code","appName":"Terminal","stateName":"thinking","since":0,"fromScreen":false}"#
        let s = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))
        XCTAssertEqual(s.state, .working)
    }

    func testKeyGlyphs() {
        XCTAssertEqual(WatchKey.controlC.glyph, "⌃C")
        XCTAssertEqual(WatchKey.shiftTab.glyph, "⇧⇥")
        XCTAssertEqual(WatchKey.commandReturn.name, "Command-Return")
    }
}
