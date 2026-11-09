import XCTest
#if os(iOS)
import UserNotifications
#endif
@testable import MacrophoneKit
final class AlertAnswerTests: XCTestCase {
    private let ref = TargetRef.app(bundleID: "com.apple.Terminal", windowKey: "42", name: "Terminal")

    #if os(iOS)
    func testAQuestionCarriesItsAnswersAndReply() {
        var a = MacAlert(ref: ref, appName: "Terminal", title: "codex", kind: .asking, headline: "Terminal is asking you something", promptID: "p1")
        a.answers = ["Yes", "Yes, and don't ask again this session for anything at all", "No", "A fourth"]
        let c = AlertNotification.category(for: a)
        XCTAssertEqual(c?.actions.map(\.identifier), ["answer-0", "answer-1", "answer-2", "reply"], "three answers at most, then Reply")
        XCTAssertEqual(c?.actions.first?.title, "1. Yes")
        XCTAssertTrue((c?.actions[1].title.count ?? 99) <= 40, "a long answer is cut to fit a button")
        XCTAssertTrue(c?.actions.last is UNTextInputNotificationAction)
        // The same buttons, the same id (the system keeps categories by id); others differ.
        XCTAssertEqual(c?.identifier, AlertNotification.category(for: a)?.identifier)
        a.answers = ["Yes", "No"]
        XCTAssertNotEqual(c?.identifier, AlertNotification.category(for: a)?.identifier)
    }

    func testOnlyQuestionsAndChatsCanBeAnswered() {
        let finished = MacAlert(ref: ref, appName: "Terminal", title: "build", kind: .finished, headline: "Build finished")
        XCTAssertNil(AlertNotification.category(for: finished), "a build finishing has nothing to answer")
        let chat = MacAlert(ref: ref, appName: "Claude", title: "Claude", kind: .answered, headline: "Claude answered you", chat: true)
        XCTAssertEqual(AlertNotification.category(for: chat)?.actions.map(\.identifier), ["reply"], "a chat's answer takes a reply")
        let noAnswers = MacAlert(ref: ref, appName: "Claude Code", title: "api", kind: .asking, headline: "Claude Code is asking you something", promptID: "agent-1")
        let ids = AlertNotification.category(for: noAnswers)?.actions.map { $0.identifier }
        XCTAssertEqual(ids, ["reply"])
    }

    #endif

    func testTheRecordCarriesTheAnswers() throws {
        var a = MacAlert(ref: ref, appName: "Terminal", title: "codex", kind: .asking, headline: "Terminal is asking you something", promptID: "p1", chat: true)
        a.answers = ["Yes", "No"]
        let f = try XCTUnwrap(CloudAlertRecord.fields(a))
        let back = try XCTUnwrap(CloudAlertRecord.alert(line: f["line"], window: f["window"], ref: f["ref"], payload: f["promptID"]))
        XCTAssertEqual(back.answers, ["Yes", "No"])
        XCTAssertEqual(back.chat, true)
        XCTAssertEqual(back.promptID, "p1")
    }

    func testTheAnswerOnTheWire() throws {
        let m = Message.alertAnswer(AlertAnswer(ref: ref, promptID: "p1", index: 2))
        let back = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(m))
        guard case let .alertAnswer(x) = back else { return XCTFail("not an answer") }
        XCTAssertEqual(x, AlertAnswer(ref: ref, promptID: "p1", index: 2))
    }
}
