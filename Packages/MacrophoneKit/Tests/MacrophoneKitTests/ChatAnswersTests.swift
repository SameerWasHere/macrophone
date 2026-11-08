import XCTest
@testable import MacrophoneKit

/// The answer finds you (Nov 8 2026): a chat the phone wrote to alerts when it answers.
final class ChatAnswersTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testEachAnswerIsToldOnceAndTwiceAtMost() {
        var f = AnswerFollower(engagedAt: t0)
        let a1 = t0 + 40
        XCTAssertTrue(f.shouldTell(answeredAt: a1, at: a1))
        // The same answer, seen again on the next look: not again.
        XCTAssertFalse(f.shouldTell(answeredAt: a1, at: a1 + 3))
        // It went on and stopped again: a second answer.
        let a2 = t0 + 200
        XCTAssertTrue(f.shouldTell(answeredAt: a2, at: a2))
        // A third with no new message from the phone: no longer followed.
        XCTAssertFalse(f.following(at: t0 + 400))
        XCTAssertFalse(f.shouldTell(answeredAt: t0 + 400, at: t0 + 400))
        XCTAssertEqual(f.told, 2)
    }

    func testAnAnswerThatFlickersIsntToldTwice() {
        var f = AnswerFollower(engagedAt: t0)
        XCTAssertTrue(f.shouldTell(answeredAt: t0 + 20, at: t0 + 20))
        // More words a few seconds on, still again: within the quiet, not news.
        XCTAssertFalse(f.shouldTell(answeredAt: t0 + 35, at: t0 + 35))
        XCTAssertEqual(f.told, 1)
        // Past the quiet, a new answer is.
        XCTAssertTrue(f.shouldTell(answeredAt: t0 + 90, at: t0 + 90))
    }

    func testFollowedForTwoHours() {
        var f = AnswerFollower(engagedAt: t0)
        XCTAssertTrue(f.following(at: t0 + ChatAnswers.followFor - 1))
        XCTAssertFalse(f.shouldTell(answeredAt: t0 + ChatAnswers.followFor + 1, at: t0 + ChatAnswers.followFor + 1))
        // Writing to it again re-arms it (a new follower).
        var again = AnswerFollower(engagedAt: t0 + ChatAnswers.followFor + 10)
        XCTAssertTrue(again.shouldTell(answeredAt: t0 + ChatAnswers.followFor + 60, at: t0 + ChatAnswers.followFor + 60))
    }

    func testWhatHeSawIsntToldAfter() {
        var f = AnswerFollower(engagedAt: t0)
        f.seen(answeredAt: t0 + 30)
        XCTAssertFalse(f.shouldTell(answeredAt: t0 + 30, at: t0 + 60))
        XCTAssertEqual(f.told, 0)
        XCTAssertTrue(f.shouldTell(answeredAt: t0 + 120, at: t0 + 120))
    }

    func testTheHelloSaysHowTheSwitchStands() {
        XCTAssertEqual(ChatAnswers.choice(in: ["macAlerts", ChatAnswers.feature, ChatAnswers.onWord]), true)
        XCTAssertEqual(ChatAnswers.choice(in: [ChatAnswers.feature, ChatAnswers.offWord]), false)
        XCTAssertNil(ChatAnswers.choice(in: ["macAlerts"]))
    }

    func testTheReplysLastLinesReadAsASentence() {
        let lines = ["You asked about the login bug.", "Here's the change: the token now refreshes a minute",
                     "before it expires, and the login test passes again.", "me@Mac ~ %"]
        XCTAssertEqual(AlertWords.reply(lines),
                       "You asked about the login bug. Here's the change: the token now refreshes a minute before it expires, and the login test passes again.")
        // Long: cut at a word, under the limit.
        let long = Array(repeating: "a reply that goes on and on for a good long while", count: 6)
        // Whole lines only while they fit: the last one alone here.
        XCTAssertEqual(AlertWords.reply(long, limit: 80), long[0])
        // One line longer than the limit on its own: cut at a word.
        let r = AlertWords.reply([String(repeating: "word ", count: 60)], limit: 40)!
        XCTAssertLessThanOrEqual(r.count, 40)
        XCTAssertTrue(r.hasSuffix("word…"), r)
        XCTAssertNil(AlertWords.reply([]))
        XCTAssertNil(AlertWords.reply(["~ %"]))
    }

    func testTheWireCarriesTheSwitchAndTheChatMark() throws {
        let data = try JSONEncoder().encode(Message.chatAnswers(on: false))
        guard case .chatAnswers(let on) = try JSONDecoder().decode(Message.self, from: data) else { return XCTFail() }
        XCTAssertFalse(on)
        // An alert from a chat says so; one from a Mac from before (no "chat") decodes as nil.
        let a = MacAlert(ref: .app(bundleID: "com.anthropic.claudefordesktop", windowKey: "9", name: "Claude"), appName: "Claude",
                         title: "Claude", kind: .answered, headline: "Claude answered you", chat: true)
        let back = try JSONDecoder().decode(MacAlert.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back.chat, true)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        json.removeValue(forKey: "chat")
        let old = try JSONDecoder().decode(MacAlert.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.chat)
        XCTAssertEqual(old.headline, "Claude answered you")
    }

    func testTheHeadlineNamesTheApp() {
        XCTAssertEqual(AlertWords.headline(.answered, app: "Claude", newLines: ["anything"]), "Claude answered you")
    }
}
