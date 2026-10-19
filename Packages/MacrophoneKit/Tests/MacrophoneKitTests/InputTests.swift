import CoreGraphics
import Foundation
@testable import MacrophoneKit
import XCTest

final class InputWireTests: XCTestCase {
    func testMouseTypingAndHeldKeysRoundTrip() throws {
        let messages: [Message] = [
            .watchMouse(WatchMouseEvent(.click, x: 0.25, y: 0.75, right: false, count: 2, modifiers: [.command, .shift])),
            .watchMouse(WatchMouseEvent(.move, x: 0.5, y: 0.5)),
            .watchMouse(WatchMouseEvent(.show, x: 0, y: 0)),
            .watchType(WatchTyping(delete: 3, text: "he 👨‍👩‍👧")),
            .watchKeyState(WatchKey("command"), down: true),
            .watchKeyState(.appSwitcher, down: false),
        ]
        for m in messages {
            let data = try WireCoding.encoder.encode(m)
            let back = try WireCoding.decoder.decode(Message.self, from: data)
            switch (m, back) {
            case let (.watchMouse(a), .watchMouse(b)):
                XCTAssertEqual(a, b)
                XCTAssertTrue(b.isValid)
            case let (.watchType(a), .watchType(b)): XCTAssertEqual(a, b)
            case let (.watchKeyState(a, da), .watchKeyState(b, db)):
                XCTAssertEqual(a, b)
                XCTAssertEqual(da, db)
            default: XCTFail("\(m) came back as \(back)")
            }
        }
        // A click's count and modifiers read back as the Mac uses them.
        guard case let .watchMouse(click) = messages[0] else { return XCTFail() }
        XCTAssertEqual(click.clickCount, 2)
        XCTAssertEqual(click.heldModifiers, [.command, .shift])
        XCTAssertEqual(click.kindValue, .click)
        XCTAssertFalse(click.isRight)
        // A move carries no count, so the wire stays small.
        guard case let .watchMouse(move) = messages[1] else { return XCTFail() }
        XCTAssertNil(move.count)
        XCTAssertNil(move.modifiers)
    }

    func testAnOlderMacNeverHearsThem() throws {
        // The welcome gates each: a Mac from before names none of the three.
        let old = #"{"welcome":{"macName":"M","appVersion":"1.1","features":["video","fit","scroll","keys"]}}"#
        guard case let .welcome(_, _, features) = try JSONDecoder().decode(Message.self, from: Data(old.utf8)) else { return XCTFail() }
        let f = Set(features ?? [])
        XCTAssertFalse(f.contains(WatchMouse.feature))
        XCTAssertFalse(f.contains(WatchTyping.feature))
        XCTAssertFalse(f.contains(WatchKeyHold.feature))
    }

    func testAMouseEventIsCheckedBeforeItIsPosted() throws {
        XCTAssertFalse(WatchMouseEvent(.click, x: 1.2, y: 0.5).isValid, "off the window")
        XCTAssertFalse(WatchMouseEvent(.click, x: 0.5, y: 0.5, count: 4).isValid == true && WatchMouseEvent(.click, x: 0.5, y: 0.5, count: 4).count == 4)
        var e = WatchMouseEvent(.click, x: 0.5, y: 0.5)
        e.count = 4
        XCTAssertFalse(e.isValid, "a count past a triple")
        // A kind from a newer phone decodes (it's words) and is ignored, never a session's end.
        let json = #"{"watchMouse":{"_0":{"kind":"pinch","x":0.5,"y":0.5}}}"#
        guard case let .watchMouse(newer) = try WireCoding.decoder.decode(Message.self, from: Data(json.utf8)) else { return XCTFail() }
        XCTAssertNil(newer.kindValue)
        XCTAssertFalse(newer.isValid)
        XCTAssertTrue(WatchTyping(delete: 0, text: String(repeating: "a", count: 4000)).isValid)
        XCTAssertFalse(WatchTyping(delete: 0, text: String(repeating: "a", count: 4001)).isValid)
        XCTAssertFalse(WatchTyping(delete: 501, text: "").isValid)
    }
}

final class TypingDiffTests: XCTestCase {
    func testTypingAppendsDeletesAndCorrects() {
        XCTAssertEqual(TypingDiff.diff(old: "", new: "h"), WatchTyping(delete: 0, text: "h"))
        XCTAssertEqual(TypingDiff.diff(old: "hello", new: "hello "), WatchTyping(delete: 0, text: " "))
        XCTAssertEqual(TypingDiff.diff(old: "hello", new: "hell"), WatchTyping(delete: 1, text: ""))
        // Autocorrect: "teh" became "the " on the space — the common prefix is "t".
        XCTAssertEqual(TypingDiff.diff(old: "teh", new: "the "), WatchTyping(delete: 2, text: "he "))
        XCTAssertEqual(TypingDiff.diff(old: "same", new: "same"), WatchTyping(delete: 0, text: ""))
        XCTAssertTrue(TypingDiff.diff(old: "same", new: "same").isEmpty)
    }

    func testAnEmojiOrAnAccentIsOneCharacter() {
        // One delete on the Mac takes back one character a person sees, so the count is in those.
        XCTAssertEqual(TypingDiff.diff(old: "hi 👨‍👩‍👧", new: "hi "), WatchTyping(delete: 1, text: ""))
        XCTAssertEqual(TypingDiff.diff(old: "cafe", new: "café"), WatchTyping(delete: 1, text: "é"))
        XCTAssertEqual(TypingDiff.diff(old: "日本", new: "日本語"), WatchTyping(delete: 0, text: "語"))
    }
}

final class TypingPlanTests: XCTestCase {
    func testReturnAndTabArePressedAsKeys() {
        XCTAssertEqual(TypingPlan.steps(for: "hi\n"), [.text("hi"), .key("return")])
        XCTAssertEqual(TypingPlan.steps(for: "a\tb\r\nc"), [.text("a"), .key("tab"), .text("b"), .key("return"), .text("c")])
        XCTAssertEqual(TypingPlan.steps(for: "\n\n"), [.key("return"), .key("return")])
        XCTAssertEqual(TypingPlan.steps(for: ""), [])
    }

    func testLongTextGoesInWholeCharacterPieces() {
        let text = String(repeating: "abcde", count: 9)   // 45 units
        let steps = TypingPlan.steps(for: text)
        XCTAssertEqual(steps.count, 3)
        for s in steps { if case let .text(t) = s { XCTAssertLessThanOrEqual(t.utf16.count, TypingPlan.chunk) } else { XCTFail() } }
        XCTAssertEqual(steps.compactMap { if case let .text(t) = $0 { return t } else { return nil } }.joined(), text)
        // A family emoji is 8 UTF-16 units: never split across two events.
        let family = String(repeating: "👨‍👩‍👧", count: 4)   // 32 units: 2 + 2 per piece
        let pieces = TypingPlan.steps(for: family).compactMap { if case let .text(t) = $0 { return t } else { return nil } }
        XCTAssertEqual(pieces.joined(), family)
        for p in pieces {
            XCTAssertLessThanOrEqual(p.utf16.count, TypingPlan.chunk)
            XCTAssertEqual(p.utf16.count % 8, 0, "a piece holds whole families")
        }
    }
}

final class HeldKeysTests: XCTestCase {
    func testHeldKeysReleaseInReverse() {
        var h = HeldKeys()
        XCTAssertTrue(h.isEmpty)
        XCTAssertTrue(h.press("command"))
        XCTAssertFalse(h.press("command"), "already down: nothing to press again")
        XCTAssertTrue(h.press("tab"))
        XCTAssertEqual(h.modifiers, [.command])
        XCTAssertTrue(h.isHeld("tab"))
        XCTAssertEqual(h.releaseAll(), ["tab", "command"], "Tab up before ⌘ up, as fingers lift")
        XCTAssertTrue(h.isEmpty)
        XCTAssertFalse(h.release("tab"), "not held")
        h.press("shift")
        XCTAssertTrue(h.release("shift"))
        XCTAssertTrue(h.isEmpty)
    }
}

final class TrackpadTests: XCTestCase {
    func testAFastFingerMovesThePointerFurther() {
        XCTAssertEqual(TrackpadMotion.gain(speed: 0), 1)
        XCTAssertEqual(TrackpadMotion.gain(speed: 50), 1)
        XCTAssertGreaterThan(TrackpadMotion.gain(speed: 600), 1)
        XCTAssertLessThan(TrackpadMotion.gain(speed: 600), TrackpadMotion.gain(speed: 1000))
        XCTAssertEqual(TrackpadMotion.gain(speed: 5000), 3.4)
        XCTAssertEqual(TrackpadMotion.gain(speed: .nan), 1)
        // A slow step is one to one; a flick's step is multiplied.
        let slow = TrackpadMotion.step(CGVector(dx: 1, dy: 0), dt: 1.0 / 60)
        XCTAssertEqual(slow.dx, 1, accuracy: 0.001)
        let flick = TrackpadMotion.step(CGVector(dx: 20, dy: 0), dt: 1.0 / 60)
        XCTAssertGreaterThan(flick.dx, 40)
    }

    func testThePointerStaysInTheWindow() {
        var p = TrackpadPointer()
        XCTAssertEqual(p.point, CGPoint(x: 0.5, y: 0.5))
        p.move(by: CGVector(dx: 100, dy: -50), window: CGSize(width: 1000, height: 500))
        XCTAssertEqual(p.x, 0.6, accuracy: 0.0001)
        XCTAssertEqual(p.y, 0.4, accuracy: 0.0001)
        p.move(by: CGVector(dx: 10_000, dy: 10_000), window: CGSize(width: 1000, height: 500))
        XCTAssertEqual(p.point, CGPoint(x: 1, y: 1))
        p.put(CGPoint(x: -1, y: 0.3))
        XCTAssertEqual(p.point, CGPoint(x: 0, y: 0.3))
        p.move(by: CGVector(dx: 5, dy: 5), window: .zero)
        XCTAssertEqual(p.point, CGPoint(x: 0, y: 0.3), "no window size: nothing moves")
    }
}

final class MacKeysTests: XCTestCase {
    func testEveryKeyHasAGlyphAndAName() {
        for name in MacKeys.allNames {
            let k = WatchKey(name)
            XCTAssertFalse(k.glyph.isEmpty, name)
            XCTAssertFalse(k.name.isEmpty, name)
        }
        XCTAssertEqual(WatchKey("f5").glyph, "F5")
        XCTAssertEqual(WatchKey("grave", command: true).glyph, "⌘`")
        XCTAssertEqual(WatchKey("forwarddelete").name, "Forward Delete")
        XCTAssertEqual(WatchKey.spotlight.title, "Spotlight")
        XCTAssertEqual(WatchKey.appSwitcher.title, "Switch App")
        XCTAssertEqual(WatchKey.missionControl.glyph, "⌃↑\u{FE0E}")
        XCTAssertEqual(MacKeys.functionKeys.count, 20)
        XCTAssertEqual(Set(MacKeys.allNames).count, MacKeys.allNames.count, "no name twice")
        // The window's More keys menu ends with the Mac section; nothing is listed twice.
        let all = WatchKey.menuSections.flatMap(\.keys)
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(WatchKey.menuSections.last?.title, "Your Mac")
    }
}
