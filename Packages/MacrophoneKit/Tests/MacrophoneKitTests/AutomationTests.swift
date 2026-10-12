import XCTest
@testable import MacrophoneKit

final class AutomationTests: XCTestCase {
    let claude = ProfileSummary(id: UUID(), name: "Claude prompt", cleanupLevel: .medium, isDefault: false, voicePrefixes: ["Claude", "Claude Code"])
    let note = ProfileSummary(id: UUID(), name: "Quick note", cleanupLevel: .light, isDefault: false, voicePrefixes: ["note"])

    func testVoicePrefixMatchesOnlyAfterAPause() {
        let m = VoicePrefix.match("Claude, refactor the uploader.", profiles: [claude, note])
        XCTAssertEqual(m?.profile.id, claude.id)
        XCTAssertEqual(m?.text, "Refactor the uploader.")
        XCTAssertEqual(VoicePrefix.match("note: buy milk", profiles: [claude, note])?.text, "Buy milk")
        XCTAssertEqual(VoicePrefix.match("Note colon buy milk", profiles: [claude, note])?.text, "Buy milk")
        XCTAssertNil(VoicePrefix.match("note that the API changed", profiles: [claude, note]))
        XCTAssertNil(VoicePrefix.match("Claudette, hi", profiles: [claude]))
        XCTAssertNil(VoicePrefix.match("Claude,", profiles: [claude]))
        // Longest prefix wins.
        XCTAssertEqual(VoicePrefix.match("Claude Code, run the tests", profiles: [claude])?.text, "Run the tests")
    }

    func testOutputFormats() {
        XCTAssertEqual(OutputFormat.singleLine.apply("one\n\n two \nthree"), "one two three")
        XCTAssertEqual(OutputFormat.codeBlock.apply("x"), "```\nx\n```")
        XCTAssertEqual(OutputFormat.codeBlock.apply("a ``` b"), "````\na ``` b\n````")
        XCTAssertEqual(OutputFormat.quote.apply("a\n\nb"), "> a\n>\n> b")
        XCTAssertEqual(OutputFormat.shellQuoted.apply("it's here"), "'it'\\''s here'")
        XCTAssertEqual(OutputFormat.jsonString.apply("say \"hi\"\n"), "\"say \\\"hi\\\"\\n\"")
    }

    func testSnippets() {
        let s = [Snippet(trigger: "my email", expansion: "sam@example.com"), Snippet(trigger: "today's date", expansion: "{{date}}")]
        XCTAssertEqual(SnippetExpander.expand("Send it to my email.", snippets: s), "Send it to sam@example.com.")
        XCTAssertEqual(SnippetExpander.expand("My, email please", snippets: s), "sam@example.com please")
        XCTAssertEqual(SnippetExpander.expand("myemail stays", snippets: s), "myemail stays")
        XCTAssertEqual(SnippetExpander.expand("Due today's date", snippets: s, context: ["date": "2026-10-12"]), "Due 2026-10-12")
    }

    func testTemplates() {
        XCTAssertEqual(TemplateRenderer.variables(in: "In {{ app }}: {{text}} {{url}}"), ["app", "text", "url"])
        XCTAssertEqual(TemplateRenderer.render(template: "Review this. {{text}} ({{app}})", text: "Fix it", context: ["app": "Xcode"]),
                       "Review this. Fix it (Xcode)")
        XCTAssertEqual(TemplateRenderer.render(template: "You are a reviewer.", text: "Fix it", context: [:]), "You are a reviewer.\n\nFix it")
        XCTAssertEqual(TemplateRenderer.render(template: "{{txet}} {{text}}", text: "a", context: [:]), "{{txet}} a")
        XCTAssertEqual(TemplateRenderer.render(template: nil, text: "a", context: [:]), "a")
        XCTAssertEqual(TemplateRenderer.clockContext(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)["date"], "1970-01-01")
    }

    func testProfileResolution() {
        let def = Profile(name: "Clipboard", isDefault: true)
        let term = Profile(name: "Terminal", destination: .focusedApp, pressEnter: true)
        let rules = [AppRule(bundleID: "com.apple.Terminal", appName: "Terminal", profileID: term.id)]
        var d = Dictation(raw: "x", profileID: def.id, profileSource: .automatic)
        XCTAssertEqual(AppRule.resolve(dictation: d, frontmostBundleID: "com.apple.Terminal", rules: rules, profiles: [def, term])?.id, term.id)
        XCTAssertEqual(AppRule.resolve(dictation: d, frontmostBundleID: "com.apple.Safari", rules: rules, profiles: [def, term])?.id, def.id)
        d.profileSource = .chosen
        XCTAssertEqual(AppRule.resolve(dictation: d, frontmostBundleID: "com.apple.Terminal", rules: rules, profiles: [def, term])?.id, def.id)
        d.profileSource = nil  // older phones: what they chose wins
        XCTAssertEqual(AppRule.resolve(dictation: d, frontmostBundleID: "com.apple.Terminal", rules: rules, profiles: [def, term])?.id, def.id)
    }

    func testOldProfilesStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","destination":{"clipboard":{}},"pressEnter":false,"isDefault":true}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(old.utf8))
        XCTAssertNil(p.outputFormat)
        XCTAssertNil(p.actions)
        let newer = Profile(name: "N", destination: .tmux(target: "dev:1.0"), actions: [ProfileAction(kind: .claude(model: "claude-sonnet-5-5", systemPrompt: nil, deliverReply: true))])
        let round = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(newer))
        XCTAssertEqual(round, newer)
        XCTAssertTrue(round.sendsOffDevice)
    }

    func testReminderParsing() {
        let now = Date(timeIntervalSince1970: 1_791_850_000)
        let r = ReminderParsing.parse("Remind me to call the dentist tomorrow at 5pm", now: now)
        XCTAssertEqual(r.title, "Call the dentist")
        XCTAssertNotNil(r.due)
        XCTAssertNil(ReminderParsing.parse("Buy milk").due)
    }
}
