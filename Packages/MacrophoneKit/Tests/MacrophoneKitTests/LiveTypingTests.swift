import XCTest
@testable import MacrophoneKit

/// Type as I speak (Core/LiveTyping.swift): the phone's pieces, the Mac's stop rule and its plan
/// for the end. Loopback tests use ports 47991–47995.
final class LiveTypingTests: XCTestCase {
    let claude = TargetRef.app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude")

    // MARK: The phone's pieces

    func testNothingGoesUntilAFewWordsHaveSettled() {
        var t = LiveTypist(id: UUID(), target: claude)
        XCTAssertNil(t.next(settled: ""))
        XCTAssertNil(t.next(settled: "Make"))
        XCTAssertNil(t.next(settled: "Make the"))
        let p = t.next(settled: "Make the retry")
        XCTAssertEqual(p?.seq, 1)
        XCTAssertEqual(p?.delete, 0)
        XCTAssertEqual(p?.text, "Make the retry")
        XCTAssertEqual(p?.target, claude)
    }

    func testEachPieceIsWhatChangedAndTheSameWordsSendNothing() {
        var t = LiveTypist(id: UUID(), target: claude)
        _ = t.next(settled: "Make the retry")
        XCTAssertNil(t.next(settled: "Make the retry"))
        XCTAssertNil(t.next(settled: "  Make   the retry  "))   // only spacing differs
        let p = t.next(settled: "Make the retry logic back")
        XCTAssertEqual(p?.seq, 2)
        XCTAssertEqual(p?.delete, 0)
        XCTAssertEqual(p?.text, " logic back")
        // A revision takes back only the end that changed.
        let r = t.next(settled: "Make the retry logic backs off")
        XCTAssertEqual(r?.delete, 0)
        XCTAssertEqual(r?.text, "s off")
        let q = t.next(settled: "Make the retry logic back off")
        XCTAssertEqual(q?.delete, 5)
        XCTAssertEqual(q?.text, " off")
        XCTAssertEqual(t.typed, "Make the retry logic back off")
        XCTAssertEqual(t.seq, 4)
    }

    func testNeverANewlineOrATab() {
        var t = LiveTypist(id: UUID(), target: claude)
        let p = t.next(settled: "first line\nsecond\tline here")
        XCTAssertEqual(p?.text, "first line second line here")
        XCTAssertFalse(p!.text.contains("\n"))
    }

    func testStoodDownSendsNothingAndCancelFollowsTheLastNumber() {
        var t = LiveTypist(id: UUID(), target: claude)
        _ = t.next(settled: "one two three")
        _ = t.next(settled: "one two three four")
        t.standDown()
        XCTAssertNil(t.next(settled: "one two three four five"))
        let c = t.cancelPiece()
        XCTAssertTrue(c.isCancel)
        XCTAssertEqual(c.seq, 3)
        XCTAssertTrue(c.isValid)
    }

    func testARewriteBiggerThanAPieceStandsDown() {
        var t = LiveTypist(id: UUID(), target: claude)
        _ = t.next(settled: String(repeating: "word ", count: 3))
        XCTAssertNil(t.next(settled: String(repeating: "x", count: WatchTyping.maxText + 10)))
        XCTAssertTrue(t.stoodDown)
    }

    func testThePieceAndTheDictationOnTheWire() throws {
        let p = LivePiece(id: UUID(), seq: 7, delete: 2, text: "ab", target: claude)
        let data = try JSONEncoder().encode(Message.livePiece(p))
        guard case let .livePiece(back) = try JSONDecoder().decode(Message.self, from: data) else { return XCTFail() }
        XCTAssertEqual(back, p)
        XCTAssertNil(back.cancel)
        // The final dictation says how many pieces went; an ordinary one says nothing (older Macs
        // decode it as before — the field is optional).
        let d = Dictation(raw: "x", livePieces: 7)
        let e = try WireCoding.decoder.decode(Dictation.self, from: WireCoding.encoder.encode(d))
        XCTAssertEqual(e.livePieces, 7)
        let plain = try WireCoding.encoder.encode(Dictation(raw: "x"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("livePieces"))
    }

    func testAPieceOutOfRangeIsInvalid() {
        XCTAssertFalse(LivePiece(id: UUID(), seq: 0, target: claude).isValid)
        XCTAssertFalse(LivePiece(id: UUID(), seq: 1, delete: -1, target: claude).isValid)
        XCTAssertFalse(LivePiece(id: UUID(), seq: 1, delete: WatchTyping.maxDelete + 1, target: claude).isValid)
        XCTAssertFalse(LivePiece(id: UUID(), seq: LiveTyping.maxPieces + 1, target: claude).isValid)
    }

    // MARK: When the Mac stops typing

    func testTheSamePlaceUntouchedKeepsTyping() {
        let look = LiveFocusRule.Look(sameApp: true, sameWindow: true, sameField: true,
                                      sinceMouseDown: 60, sinceKeyDown: 0.01, sinceOwnKey: 0.01, sinceStart: 4)
        XCTAssertNil(LiveFocusRule.check(look))
        // A terminal: no window or field to compare, still the same app.
        XCTAssertNil(LiveFocusRule.check(.init(sameApp: true, sameWindow: nil, sameField: nil, sinceStart: 2)))
    }

    func testAnythingElseStops() {
        var l = LiveFocusRule.Look(sameApp: true, sameWindow: true, sameField: true, sinceMouseDown: 60, sinceStart: 4)
        l.sameApp = false
        XCTAssertEqual(LiveFocusRule.check(l), .appChanged)
        l.sameApp = true; l.sameWindow = false
        XCTAssertEqual(LiveFocusRule.check(l), .windowChanged)
        l.sameWindow = true; l.sameField = false
        XCTAssertEqual(LiveFocusRule.check(l), .fieldChanged)
        l.sameField = true; l.secure = true
        XCTAssertEqual(LiveFocusRule.check(l), .passwordField)
        l.secure = false; l.locked = true
        XCTAssertEqual(LiveFocusRule.check(l), .locked)
        l.locked = false
        // A click two seconds ago, after typing started four seconds ago.
        l.sinceMouseDown = 2
        XCTAssertEqual(LiveFocusRule.check(l), .someoneClicked)
        // A click from before it started doesn't count.
        l.sinceMouseDown = 5
        XCTAssertNil(LiveFocusRule.check(l))
    }

    func testAPersonsKeyIsOneNewerThanTheMacsOwn() {
        // The Mac's own key 0.05 s ago and the newest key 0.05 s ago: its own.
        var l = LiveFocusRule.Look(sameApp: true, sameWindow: true, sameField: true,
                                   sinceKeyDown: 0.05, sinceOwnKey: 0.05, sinceStart: 3)
        XCTAssertNil(LiveFocusRule.check(l))
        // A key 0.2 s ago, the Mac's own 1 s ago: someone typing.
        l.sinceKeyDown = 0.2; l.sinceOwnKey = 1
        XCTAssertEqual(LiveFocusRule.check(l), .someoneTyped)
        // Nothing typed by the Mac yet: a key since the start is a person's; one before isn't.
        l.sinceOwnKey = .infinity; l.sinceKeyDown = 1
        XCTAssertEqual(LiveFocusRule.check(l), .someoneTyped)
        l.sinceKeyDown = 10
        XCTAssertNil(LiveFocusRule.check(l))
    }

    // MARK: The end

    func testTheSameWordsDoNothing() {
        XCTAssertEqual(LiveReconcile.plan(typed: "Hello there", final: "Hello there", field: nil, untouched: false), .nothing)
        let f = LiveReconcile.Field(value: "Hello there", caret: 11)
        XCTAssertEqual(LiveReconcile.plan(typed: "Hello there", final: "Hello there", field: f, untouched: true), .nothing)
    }

    func testAReadableFieldIsReplacedExactlyInsideWhatWasTyped() {
        // The box had "Note: " before the dictation; it typed "so i think we should"; cleanup wrote
        // "So I think we should."
        let f = LiveReconcile.Field(value: "Note: so i think we should", caret: 26)
        let p = LiveReconcile.plan(typed: "so i think we should", final: "So I think we should.", field: f, untouched: true)
        XCTAssertEqual(p, .replace(location: 6, length: 20, text: "So I think we should."))
        // Only the end differs: only the end is replaced.
        let g = LiveReconcile.Field(value: "make it back off", caret: 16)
        XCTAssertEqual(LiveReconcile.plan(typed: "make it back off", final: "make it back off exponentially.", field: g, untouched: false),
                       .replace(location: 16, length: 0, text: " exponentially."))
        // Cleanup took words out at the end: replace them with nothing.
        let h = LiveReconcile.Field(value: "do it um", caret: 8)
        XCTAssertEqual(LiveReconcile.plan(typed: "do it um", final: "do it", field: h, untouched: true),
                       .replace(location: 5, length: 3, text: ""))
    }

    func testUnicodeCountsInUTF16() {
        let f = LiveReconcile.Field(value: "👍 ok so", caret: "👍 ok so".utf16.count)
        XCTAssertEqual(LiveReconcile.plan(typed: "ok so", final: "OK, so", field: f, untouched: true),
                       .replace(location: 3, length: 5, text: "OK, so"))
    }

    func testAReadableFieldThatDoesntEndWithItAtTheCaretIsNeverTouched() {
        // He clicked into the middle (the caret moved), or a selection is up, or the app rewrote it.
        let moved = LiveReconcile.Field(value: "so i think we should", caret: 4)
        XCTAssertEqual(LiveReconcile.plan(typed: "so i think we should", final: "So I think.", field: moved, untouched: true), .deliverNormally)
        let selected = LiveReconcile.Field(value: "so i think we should", caret: 0, selection: 20)
        XCTAssertEqual(LiveReconcile.plan(typed: "so i think we should", final: "So I think.", field: selected, untouched: true), .deliverNormally)
        let rewritten = LiveReconcile.Field(value: "so I think we should", caret: 20)
        XCTAssertEqual(LiveReconcile.plan(typed: "so i think we should", final: "So I think.", field: rewritten, untouched: true), .deliverNormally)
    }

    func testAnUnreadableFieldTakesBackTheEndOnlyIfUntouched() {
        XCTAssertEqual(LiveReconcile.plan(typed: "git status please", final: "git status, please.", field: nil, untouched: true),
                       .backspace(delete: 7, text: ", please."))
        XCTAssertEqual(LiveReconcile.plan(typed: "git status please", final: "git status, please.", field: nil, untouched: false),
                       .deliverNormally)
    }

    func testNothingTypedIsTheUsualPath() {
        XCTAssertEqual(LiveReconcile.plan(typed: "", final: "Hello.", field: nil, untouched: true), .deliverNormally)
    }

    func testCountsLine() {
        var c = LiveCounts()
        c.pieces = 14; c.typed = 212; c.deleted = 3
        XCTAssertEqual(c.line, "14 pieces, 212 characters typed, 3 taken back")
    }

    // MARK: Over a real connection

    func testAMacThatNamesItGetsThePiecesInOrder() async throws {
        let rig = try await Rig.make(port: 47994)
        defer { rig.stop() }
        rig.server.macFeatures.append(LiveTyping.feature)
        try await rig.connect()
        XCTAssertTrue(rig.client.macTypesLive)
        var t = LiveTypist(id: UUID(), target: claude)
        for words in ["one two three", "one two three four", "one two three four five"] {
            XCTAssertTrue(rig.client.sendLivePiece(t.next(settled: words)!))
        }
        XCTAssertTrue(rig.client.sendLivePiece(t.cancelPiece()))
        try await rig.waitFor { LiveBox.pieces.count == 4 }
        XCTAssertEqual(LiveBox.pieces.map(\.seq).sorted(), [1, 2, 3, 4])
        XCTAssertEqual(LiveBox.pieces.first { $0.seq == 2 }?.text, " four")
        XCTAssertTrue(LiveBox.pieces.first { $0.seq == 4 }?.isCancel == true)
        LiveBox.pieces = []
    }

    func testAMacFromBeforeIsNeverSentOne() async throws {
        let rig = try await Rig.make(port: 47992)
        defer { rig.stop() }
        try await rig.connect()
        XCTAssertFalse(rig.client.macTypesLive)
        var t = LiveTypist(id: UUID(), target: claude)
        XCTAssertFalse(rig.client.sendLivePiece(t.next(settled: "one two three")!))
        let rtt = await rig.client.roundTrip(); XCTAssertNotNil(rtt)
    }
}

/// What the test Mac heard (MacSide lives in VideoLaneTests.swift).
enum LiveBox { nonisolated(unsafe) static var pieces: [LivePiece] = [] }

extension MacSide: LinkServerLiveDelegate {
    func linkServer(_ server: LinkServer, livePiece: LivePiece, from peerID: UUID) {
        LiveBox.pieces.append(livePiece)
    }
}
