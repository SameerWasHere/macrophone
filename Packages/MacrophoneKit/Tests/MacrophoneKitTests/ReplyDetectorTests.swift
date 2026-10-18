import XCTest
@testable import MacrophoneKit

final class ReplyDetectorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Looks every three seconds from `start`, with these changed shares.
    private func run(_ shares: [Double], start: TimeInterval = 3) -> ReplyDetector {
        var d = ReplyDetector(engagedAt: t0)
        for (i, s) in shares.enumerated() { d.look(changed: s, at: t0 + start + Double(i) * 3) }
        return d
    }

    func testYourOwnMessageIsNotAnAnswer() {
        // Your words land in the first look, then nothing.
        XCTAssertNil(run([0.05, 0, 0, 0, 0]).answeredAt)
    }

    func testASpinnerIsNotAnAnswer() {
        XCTAssertNil(run([0.05, 0.002, 0.003, 0.002, 0.002, 0.003]).answeredAt)
    }

    func testAStreamedReplyThatSettlesIsAnAnswer() {
        let d = run([0.04, 0.002, 0.03, 0.05, 0.02, 0.001, 0, 0])
        XCTAssertNotNil(d.answeredAt)
        XCTAssertFalse(d.asking)
    }

    func testNotBeforeItSettles() {
        XCTAssertNil(run([0.04, 0.03, 0.05, 0, 0]).answeredAt)
    }

    func testMoreContentTakesItBack() {
        var d = run([0.04, 0.03, 0, 0, 0])
        XCTAssertNotNil(d.answeredAt)
        d.look(changed: 0.02, at: t0 + 30)
        XCTAssertNil(d.answeredAt)
        for i in 1...3 { d.look(changed: 0, at: t0 + 30 + Double(i) * 3) }
        XCTAssertNotNil(d.answeredAt)
    }

    func testNeverWhileItSaysItsWorking() {
        // A tool running: the picture stays still, but the Stop button is up.
        var d = ReplyDetector(engagedAt: t0)
        d.look(changed: 0.05, at: t0 + 3)
        for i in 2...8 { d.look(changed: 0, working: true, at: t0 + Double(i) * 3) }
        XCTAssertNil(d.answeredAt)
        // Done: the button goes, the window stays still.
        for i in 9...11 { d.look(changed: 0, at: t0 + Double(i) * 3) }
        XCTAssertNotNil(d.answeredAt)
    }

    func testWorkingWithoutAnyNewPictureStillLeadsToAnAnswer() {
        var d = ReplyDetector(engagedAt: t0)
        d.look(changed: 0.001, working: true, at: t0 + 2)
        for i in 1...3 { d.look(changed: 0, at: t0 + 2 + Double(i) * 3) }
        XCTAssertNotNil(d.answeredAt)
    }

    func testAgentDoneAfterYouWrote() {
        var d = ReplyDetector(engagedAt: t0)
        d.agent(.working, since: t0 + 1)
        XCTAssertNil(d.answeredAt)
        d.agent(.yourTurn, since: t0 + 20)
        XCTAssertEqual(d.answeredAt, t0 + 20)
        XCTAssertFalse(d.asking)
    }

    func testAgentAskingIsAnAnswerThatAsks() {
        var d = ReplyDetector(engagedAt: t0)
        d.agent(.waiting, since: t0 + 5)
        XCTAssertNotNil(d.answeredAt)
        XCTAssertTrue(d.asking)
    }

    func testAgentsEarlierTurnDoesNotCount() {
        var d = ReplyDetector(engagedAt: t0)
        d.agent(.yourTurn, since: t0 - 60)
        XCTAssertNil(d.answeredAt)
    }

    func testAQuickReplyWithinTheSendCounts() {
        var d = ReplyDetector(engagedAt: t0)
        d.agent(.yourTurn, since: t0 - 1)
        XCTAssertNotNil(d.answeredAt)
    }

    func testNeedsConcernsItsWindowOrTheApp() {
        let n = NeedsYou(bundleID: "com.apple.Terminal", windowKey: "42", since: t0, asking: false)
        XCTAssertTrue(n.concerns(LiveTarget(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "a", windowKey: "42")))
        XCTAssertFalse(n.concerns(LiveTarget(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "b", windowKey: "43")))
        XCTAssertTrue(n.concerns(LiveTarget(bundleID: "com.apple.Terminal", appName: "Terminal")))
        XCTAssertFalse(n.concerns(LiveTarget(bundleID: "com.anthropic.claudefordesktop", appName: "Claude")))
    }
}
