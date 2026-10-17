import XCTest
@testable import MacrophoneKit

final class PromptTests: XCTestCase {
    /// Lines from the top down, each starting at `x`.
    private func lines(_ rows: [(String, Double)]) -> [ReadLine] {
        rows.enumerated().map { i, r in ReadLine(text: r.0, minX: r.1, midY: 0.5 + Double(i) * 0.03) }
    }

    func testClaudeCodeMenuWithMarker() throws {
        let p = try XCTUnwrap(PromptReader.read(lines([
            ("I'll move the check after the refresh.", 0.05),
            ("Do you want to make this edit to AuthView.swift?", 0.05),
            ("> 1. Yes", 0.05),
            ("2. Yes, and don't ask again this session", 0.07),
            ("3. No, and tell Claude what to do instead", 0.07),
            ("Reply to Claude…", 0.08),
        ])))
        XCTAssertEqual(p.style, .menu)
        XCTAssertEqual(p.question, "Do you want to make this edit to AuthView.swift?")
        XCTAssertEqual(p.choices.map(\.label), ["Yes", "Yes, and don't ask again this session", "No, and tell Claude what to do instead"])
        XCTAssertEqual(p.highlighted, 0)
        XCTAssertEqual(p.keys(for: 2), [.down, .down, .returnKey])
        XCTAssertEqual(p.keys(for: 0), [.returnKey])
    }

    func testHighlightFromIndentWhenTheMarkIsDropped() throws {
        // The mark wasn't recognized, but it still pushed the highlighted answer left.
        let p = try XCTUnwrap(PromptReader.read(lines([
            ("Allow this command?", 0.05),
            ("1. Yes", 0.07),
            ("2. Yes, always", 0.05),
            ("3. No", 0.07),
        ])))
        XCTAssertEqual(p.highlighted, 1)
        XCTAssertEqual(p.keys(for: 0), [.up, .returnKey])
    }

    func testGluedMarkAndParenNumbers() throws {
        let p = try XCTUnwrap(PromptReader.read(lines([
            ("Run `npm test`?", 0.05),
            ("›1) Yes", 0.05),
            ("2) No", 0.06),
        ])))
        XCTAssertEqual(p.choices.map(\.number), [1, 2])
        XCTAssertEqual(p.highlighted, 0)
    }

    func testAgentsNumberedReplyIsNotAPrompt() {
        // A plan in the reply: no mark, no question right above.
        XCTAssertNil(PromptReader.read(lines([
            ("Here's the plan:", 0.05),
            ("1. Update the token check", 0.05),
            ("2. Add a test for expiry", 0.05),
            ("3. Run the suite", 0.05),
        ])))
    }

    func testListFarFromTheBottomIsOld() {
        XCTAssertNil(PromptReader.read(lines([
            ("Do you want to proceed?", 0.05),
            ("> 1. Yes", 0.05),
            ("2. No", 0.07),
            ("● Update(AuthView.swift)", 0.05),
            ("12 lines changed", 0.06),
            ("Done. The test passes now.", 0.05),
            ("Anything else?", 0.05),
            ("Reply to Claude…", 0.05),
        ])))
    }

    func testNumbersThatArentAnswers() {
        XCTAssertNil(PromptReader.numbered("12 lines changed"))
        XCTAssertNil(PromptReader.numbered("2026 was a year"))
        XCTAssertNil(PromptReader.numbered("1.5 seconds"))
        XCTAssertEqual(PromptReader.numbered("❯ 1. Yes")?.marked, true)
    }

    func testWrappedLabelIsJoined() throws {
        let p = try XCTUnwrap(PromptReader.read(lines([
            ("Do you want to make this edit?", 0.05),
            ("> 1. Yes", 0.05),
            ("2. No, and tell Claude what to do", 0.07),
            ("instead", 0.1),
        ])))
        // "instead" is below the last answer: it's a trailing line, not part of the list.
        XCTAssertEqual(p.choices.count, 2)
        let q = try XCTUnwrap(PromptReader.read(lines([
            ("Do you want to make this edit?", 0.05),
            ("> 1. Yes, and don't ask again for", 0.05),
            ("this session", 0.1),
            ("2. No", 0.07),
        ])))
        XCTAssertEqual(q.choices.first?.label, "Yes, and don't ask again for this session")
    }

    func testWhatFastRecognitionReallyReturns() throws {
        // The demo window through Vision's fast level, verbatim.
        let raw: [(String, Double, Double)] = [
            (" Update(AuthView. swif t )", 0.249, 0.552), ("12 lines changed", 0.276, 0.594),
            ("Do you want to make this edit to AuthView. swift7", 0.228, 0.679), (") l. Yes", 0.229, 0.720),
            ("2. Yes. and don't ask again this session", 0.249, 0.763), ("3. No, and tell Claude what to do instead", 0.249, 0.805),
            ("Reply to Claude...", 0.238, 0.902),
        ]
        let p = try XCTUnwrap(PromptReader.read(raw.map { ReadLine(text: $0.0, minX: $0.1, midY: $0.2) }))
        XCTAssertEqual(p.choices.count, 3)
        XCTAssertEqual(p.choices.first?.label, "Yes")
        XCTAssertEqual(p.highlighted, 0)
        XCTAssertEqual(p.question, "Do you want to make this edit to AuthView.swift?")
        XCTAssertEqual(p.choices[1].label, "Yes, and don't ask again this session")
    }

    func testYesNo() throws {
        let p = try XCTUnwrap(PromptReader.read(lines([
            ("Removing node_modules", 0.02),
            ("Overwrite package-lock.json? (y/N)", 0.02),
        ])))
        XCTAssertEqual(p.style, .typed)
        XCTAssertEqual(p.question, "Overwrite package-lock.json?")
        XCTAssertEqual(p.keys(for: 0), [.character("y"), .returnKey])
        XCTAssertEqual(p.keys(for: 1), [.character("n"), .returnKey])
    }

    func testHelloWithoutFeaturesStillDecodes() throws {
        // A phone from before alerts sends a hello without features.
        let json = #"{"hello":{"phoneName":"P","appVersion":"1.0","os":"iOS"}}"#
        let m = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        guard case let .hello(_, _, _, features) = m else { return XCTFail() }
        XCTAssertNil(features)
    }

    func testIDIsStableAndDiffers() {
        let a = WatchPrompt(question: "Q?", choices: [.init(label: "Yes"), .init(label: "No")], highlighted: 0, style: .menu)
        var b = a
        XCTAssertEqual(a.id, b.id)
        b.question = "Other?"
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNil(a.keys(for: 5))
    }

    func testFrameCarriesThePromptAndOldFramesDecode() throws {
        let p = WatchPrompt(question: "Q?", choices: [.init(label: "Yes"), .init(label: "No")], highlighted: 0, style: .menu)
        let f = WatchFrame(seq: 1, jpeg: Data([1]), width: 1, height: 1, appName: "Claude", bundleID: nil, focus: nil, prompt: p)
        let back = try JSONDecoder().decode(WatchFrame.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back.prompt, p)
        // A Mac that doesn't read prompts sends frames without the field.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f)) as? [String: Any])
        json["prompt"] = nil
        let old = try JSONDecoder().decode(WatchFrame.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.prompt)
    }
}
