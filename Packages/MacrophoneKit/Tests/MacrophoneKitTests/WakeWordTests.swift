import XCTest
@testable import MacrophoneKit

final class WakeWordTests: XCTestCase {
    private func m(_ phrase: String, _ s: WakeSensitivity = .normal) -> WakeMatcher {
        WakeMatcher(phrase: WakePhrase(phrase), sensitivity: s)
    }

    // MARK: The phrase

    func testPhraseParts() {
        let p = WakePhrase("Hey Mac")
        XCTAssertEqual(p.lead, WakeText.key("hey"))
        XCTAssertEqual(p.name, ["mak"])
        XCTAssertNil(WakePhrase("Computer").lead)
        XCTAssertEqual(WakePhrase("Okay Jarvis").lead, WakeText.key("okay"))
        XCTAssertNil(WakePhrase("Hey Mac").problem)
        XCTAssertNil(WakePhrase("Computer").problem)
        XCTAssertNotNil(WakePhrase("").problem)
        XCTAssertNotNil(WakePhrase("Mac").problem, "an everyday name alone")
        XCTAssertNotNil(WakePhrase("hey my dear old friend computer").problem)
        XCTAssertNotNil(WakePhrase("Hey Mac").advice, "short names get a word of advice")
    }

    func testSpellingKeys() {
        XCTAssertEqual(WakeText.key("Mac"), WakeText.key("Mack"))
        XCTAssertEqual(WakeText.key("Mac,"), "mak")
        XCTAssertEqual(WakeText.key("Claude"), WakeText.key("Clawd"))
        XCTAssertEqual(WakeText.key("Claude"), WakeText.key("claud"))
        XCTAssertNotEqual(WakeText.key("Mac"), WakeText.key("Max"))
        XCTAssertNotEqual(WakeText.key("Mac"), WakeText.key("Mike"))
        XCTAssertNotEqual(WakeText.key("Mac"), WakeText.key("man"))
    }

    // MARK: Matching

    func testHeyMacAndItsHearings() {
        let w = m("Hey Mac")
        XCTAssertEqual(w.matches(in: "Hey Mac, open my notes.").first?.command, "Open my notes.")
        XCTAssertEqual(w.matches(in: "Hey, Mac, open my notes.").first?.command, "Open my notes.")
        XCTAssertEqual(w.matches(in: "Hey Mack. Write this down").first?.command, "Write this down")
        XCTAssertEqual(w.matches(in: "Hi Mac, what's up").count, 1)
        XCTAssertEqual(w.matches(in: "Okay, hey Mac, remind me to call mom.").first?.command, "Remind me to call mom.")
        XCTAssertEqual(w.matches(in: "Hey Mac").first?.command, "")
        XCTAssertEqual(w.matches(in: "heymac write it").count, 1, "run together")
    }

    func testNearMissesNeverWake() {
        let w = m("Hey Mac")
        for s in ["Hey Max, are you coming?", "Hey man, how are you?", "Hey Mike.", "Hey Mark, look.",
                  "I bought a new Mac yesterday.", "Mac, Windows and Linux all work.", "Hey, my Mac is slow.",
                  "Big Mac and fries", "hey match it", "Hey Matt"] {
            XCTAssertTrue(w.matches(in: s).isEmpty, s)
        }
        // An everyday name is never taken as an address, even at High (the bench woke on this).
        XCTAssertTrue(m("Hey Mac", .high).matches(in: "Mac, Windows and Linux are all supported.").isEmpty)
        XCTAssertEqual(m("Hey Claude", .high).matches(in: "Claude, open Safari.").count, 1)
    }

    func testClaudeKeepsSameerOSHearingsAndTheVocative() {
        let w = m("Hey Claude")
        for s in ["Hey Claude, check my email", "Hey Clawd, check my email", "hi clod check my email",
                  "Hey Claudie, check my email"] {
            XCTAssertEqual(w.matches(in: s).first?.command, "Check my email", s)
        }
        // The address form: a comma (or the start) before, a pause after.
        XCTAssertEqual(w.matches(in: "Claude, check my email").first?.command, "Check my email")
        XCTAssertEqual(w.matches(in: "That's my view. Claude, what do you think?").first?.command, "What do you think?")
        XCTAssertTrue(w.matches(in: "I asked Claude about it").isEmpty)
        // Real words to a person: SameerOS's old hearings, High only (the bench woke on both).
        XCTAssertTrue(w.matches(in: "Hey Clyde, wait up for me.").isEmpty)
        XCTAssertTrue(w.matches(in: "Hey, cloud storage is almost full.").isEmpty)
        XCTAssertEqual(m("Hey Claude", .high).matches(in: "Hey cloud, check my email").first?.command, "Check my email")
        // Low: the phrase as written only.
        XCTAssertTrue(m("Hey Claude", .low).matches(in: "Claude, check my email").isEmpty)
        XCTAssertTrue(m("Hey Claude", .low).matches(in: "Hey Clod, check").isEmpty)
        XCTAssertEqual(m("Hey Claude", .low).matches(in: "Hey Claude, check").count, 1)
    }

    func testANameWithoutAGreeting() {
        let w = m("Computer")
        XCTAssertEqual(w.matches(in: "Computer, what time is it?").first?.command, "What time is it?")
        XCTAssertEqual(w.matches(in: "Okay computer, what time is it?").first?.command, "What time is it?")
        XCTAssertTrue(w.matches(in: "My computer is slow today").isEmpty)
        XCTAssertTrue(w.matches(in: "Computers, phones and tablets are on sale.").isEmpty)
        XCTAssertTrue(w.matches(in: "The computer, it's slow").isEmpty)
    }

    func testCustomMultiWordPhrases() {
        let w = m("Hey Macrophone")
        XCTAssertEqual(w.matches(in: "Hey Macrophone, take a note").first?.command, "Take a note")
        XCTAssertEqual(w.matches(in: "Hey macro phone, take a note").first?.command, "Take a note", "split by the recognizer")
        XCTAssertEqual(m("Hey Macrophone", .high).matches(in: "Hey Macrofone take a note").count, 1, "one letter off at High")
        XCTAssertTrue(m("Hey Macrophone").matches(in: "Hey microphone test").isEmpty)
        let j = m("Okay Jarvis")
        XCTAssertEqual(j.matches(in: "OK Jarvis, lights").first?.command, "Lights")
    }

    func testCommandStaysAnchored() {
        let w = m("Hey Mac")
        let first = w.matches(in: "Hey Mac, write").first!
        // The recognizer revises the phrase away: the same number of words is dropped instead.
        XCTAssertEqual(w.command(in: "Hey Matt, write a note", anchoredAt: first.wordsBefore).command, "Write a note")
        // A later "hey mac" inside the message doesn't move the start.
        XCTAssertEqual(w.command(in: "Hey Mac, tell them hey Mac is great", anchoredAt: first.wordsBefore).command,
                       "Tell them hey Mac is great")
    }

    func testNameRangeForConfidence() {
        let h = m("Hey Mac").matches(in: "Okay, hey Mac, go").first!
        XCTAssertEqual(Array("Okay, hey Mac, go")[h.nameRange].map(String.init).joined(), "Mac")
    }

    // MARK: Endings

    private let lists = WakeEndingWords.default

    func testEndingWords() {
        XCTAssertEqual(WakeEndings.parse("Write the tests send it", words: lists), WakeOutcome(text: "Write the tests", action: .send, ending: "send it"))
        XCTAssertEqual(WakeEndings.parse("Write the tests, type it.", words: lists).action, .paste)
        XCTAssertEqual(WakeEndings.parse("Write the tests, type it.", words: lists).text, "Write the tests")
        XCTAssertEqual(WakeEndings.parse("Write the tests", words: lists), WakeOutcome(text: "Write the tests", action: .paste))
        XCTAssertEqual(WakeEndings.parse("Write the tests, never mind.", words: lists).action, .cancel)
        XCTAssertEqual(WakeEndings.parse("Nevermind", words: lists).action, .cancel)
        XCTAssertEqual(WakeEndings.parse("Cancel.", words: lists).action, .cancel)
        // One-word endings need a pause before them.
        XCTAssertEqual(WakeEndings.parse("We should not cancel", words: lists).action, .paste)
        XCTAssertEqual(WakeEndings.parse("Write it all up, cancel.", words: lists).action, .cancel)
        // "send it to Alex" is about Alex, not an ending (a person, at the end).
        XCTAssertEqual(WakeEndings.parse("I'll send it to you", words: lists).action, .paste)
    }

    func testPlacesByName() {
        let a = WakeEndings.parse("Run the tests, send to Claude.", words: lists)
        XCTAssertEqual(a, WakeOutcome(text: "Run the tests", action: .send, place: "Claude", ending: "send to Claude."))
        let b = WakeEndings.parse("Buy milk and eggs paste it in Notes", words: lists)
        XCTAssertEqual(b.action, .paste)
        XCTAssertEqual(b.place, "Notes")
        XCTAssertEqual(b.text, "Buy milk and eggs")
        XCTAssertEqual(WakeEndings.parse("hello type that into the Notes app", words: lists).place, "Notes app")
        XCTAssertEqual(WakeEndings.parse("summary send it over to Visual Studio Code", words: lists).place, "Visual Studio Code")
        XCTAssertNil(WakeEndings.parse("send to the store and back home again later", words: lists).place, "too long a name")
        // As the recognizer writes them (heard on this Mac's test set).
        XCTAssertEqual(WakeEndings.parse("Add eggs to the shopping list, pasted in notes.", words: lists).place, "notes")
        XCTAssertEqual(WakeEndings.parse("Add eggs to the shopping list, pasted in notes.", words: lists).text, "Add eggs to the shopping list")
        XCTAssertEqual(WakeEndings.parse("Draft it sent to Claude", words: lists).action, .send)
    }

    func testEditingTheLists() {
        var w = WakeEndingWords.default
        w.set(.send, ["Ship it", "send it", "ship it", ""])
        XCTAssertEqual(w.send, ["ship it", "send it"])
        w.set(.cancel, ["send it"])
        XCTAssertEqual(w.cancel, ["send it"])
        XCTAssertEqual(w.send, ["ship it"], "a phrase belongs to one list")
        w.set(.paste, [])
        XCTAssertEqual(w.paste, WakeEndingWords.defaultPaste)
    }

    func testPlaceLookup() {
        let apps = [WakePlaceCandidate(id: "claude", name: "Claude"), WakePlaceCandidate(id: "notes", name: "Notes"),
                    WakePlaceCandidate(id: "chrome", name: "Google Chrome"), WakePlaceCandidate(id: "vsc", name: "Visual Studio Code"),
                    WakePlaceCandidate(id: "gpt", name: "ChatGPT"), WakePlaceCandidate(id: "term", name: "Terminal")]
        XCTAssertEqual(WakePlaces.match("Claude", in: apps)?.id, "claude")
        XCTAssertEqual(WakePlaces.match("Clawd", in: apps)?.id, "claude")
        XCTAssertEqual(WakePlaces.match("the Notes app", in: apps)?.id, "notes")
        XCTAssertEqual(WakePlaces.match("Chrome", in: apps)?.id, "chrome")
        XCTAssertEqual(WakePlaces.match("Visual Studio", in: apps)?.id, "vsc")
        XCTAssertEqual(WakePlaces.match("Chat GPT", in: apps)?.id, "gpt")
        XCTAssertEqual(WakePlaces.match("Terminl", in: apps)?.id, "term")
        XCTAssertNil(WakePlaces.match("Alex", in: apps))
        XCTAssertNil(WakePlaces.match("Slack", in: apps))
    }

    // MARK: The capture

    func testCaptureEndsOnAPause() {
        var c = WakeCapture(config: .init(endSilence: 1.5), words: lists, at: 0)
        c.heard("Write a", at: 0.5)
        c.voice(at: 0.9)
        c.heard("Write a note", at: 1.0)
        XCTAssertNil(c.decide(at: 2.0))
        c.voice(at: 2.2)        // still talking: no new words yet
        XCTAssertNil(c.decide(at: 3.0))
        XCTAssertEqual(c.decide(at: 3.8), .finish(WakeOutcome(text: "Write a note", action: .paste)))
    }

    func testCaptureEndsQuicklyOnEndingWords() {
        var c = WakeCapture(config: .init(endSilence: 3), words: lists, at: 0)
        c.heard("Run the tests send it", at: 1)
        XCTAssertTrue(c.armed)
        XCTAssertNil(c.decide(at: 1.5))
        XCTAssertEqual(c.decide(at: 1.85), .finish(WakeOutcome(text: "Run the tests", action: .send, ending: "send it")))
        var d = WakeCapture(config: .init(), words: lists, at: 0)
        d.heard("Never mind", at: 1)
        XCTAssertEqual(d.decide(at: 1.55)?.isCancel, true)
    }

    func testANoisyRoomStillEnds() {
        var c = WakeCapture(config: .init(endSilence: 1.5), words: lists, at: 0)
        c.heard("Hello there", at: 0.5)
        for t in stride(from: 0.6, through: 10, by: 0.1) { c.voice(at: t) }   // a TV keeps the mic above the room
        XCTAssertNil(c.decide(at: 2.5))
        XCTAssertNotNil(c.decide(at: 3.6), "no new words for the pause plus 1.5 s")
    }

    func testBareWakeAndKeyHeld() {
        var c = WakeCapture(config: .init(), words: lists, at: 0)
        XCTAssertNil(c.decide(at: 4))
        XCTAssertEqual(c.decide(at: 6.1), .nothingSaid)
        var d = WakeCapture(config: .init(endSilence: 1), words: lists, command: "Words", at: 0)
        d.held = true
        XCTAssertNil(d.decide(at: 30), "held: only the key's release ends it")
        d.held = false
        XCTAssertNotNil(d.decide(at: 30))
    }
}

private extension WakeCapture.Decision {
    var isCancel: Bool { if case .finish(let o) = self { return o.action == .cancel }; return false }
}
