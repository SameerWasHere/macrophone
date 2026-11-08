import XCTest
@testable import MacrophoneKit

/// What's in front on the Mac (Nov 7 2026): the shape, the privacy rules, the pacing, and the wire
/// to a phone that names it — never to one that doesn't.
final class FrontWindowTests: XCTestCase {
    func testTheShapeAndTheWire() throws {
        let w = FrontWindow(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", window: 4182, title: "Fix the login bug")
        XCTAssertEqual(w.line, "Claude — Fix the login bug")
        XCTAssertEqual(w.target, .app(bundleID: "com.anthropic.claudefordesktop", windowKey: "4182", name: "Claude — Fix the login bug"))
        for m in [Message.frontWindow(w), Message.frontWindow(nil)] {
            let data = try WireCoding.encoder.encode(m)
            guard case let .frontWindow(back) = try WireCoding.decoder.decode(Message.self, from: data) else { return XCTFail("not a front window") }
            if case let .frontWindow(sent) = m { XCTAssertEqual(back, sent) }
        }
        // A newer Mac's field this phone doesn't know never breaks it.
        let extra = #"{"bundleID":"a","appName":"A","window":3,"title":"t","space":2}"#
        XCTAssertEqual(try WireCoding.decoder.decode(FrontWindow.self, from: Data(extra.utf8)).windowKey, "3")
        XCTAssertFalse(VideoLane.rides(.frontWindow(w)))
    }

    func testTitles() {
        XCTAssertNil(FrontWindow(bundleID: "a", appName: "Notes", window: 1, title: "Notes").title, "the app's name adds nothing")
        XCTAssertNil(FrontWindow(bundleID: "a", appName: "Finder", window: nil, title: "   ").title)
        XCTAssertEqual(FrontWindow(bundleID: "a", appName: "Finder", window: nil, title: nil).line, "Finder")
        XCTAssertEqual(FrontWindow.trimmed("a\n  b\tc"), "a b c")
        let t = FrontWindow.trimmed(String(repeating: "word ", count: 30))
        XCTAssertLessThanOrEqual(t.count, FrontWindow.titleLimit)
        XCTAssertTrue(t.hasSuffix("…"))
        XCTAssertEqual(FrontWindow.trimmed(String(repeating: "x", count: 100)).count, FrontWindow.titleLimit)
    }

    func testSameAsThePick() {
        let w = FrontWindow(bundleID: "com.apple.Terminal", appName: "Terminal", window: 42, title: "codex")
        XCTAssertTrue(w.isSame(as: .app(bundleID: "com.apple.Terminal", windowKey: "42", name: "x")))
        XCTAssertTrue(w.isSame(as: .app(bundleID: "com.apple.Terminal", windowKey: nil, name: "Terminal")), "the app: the Mac shows its front window")
        XCTAssertFalse(w.isSame(as: .app(bundleID: "com.apple.Terminal", windowKey: "41", name: "x")), "another of its windows")
        XCTAssertFalse(w.isSame(as: .app(bundleID: "com.apple.Notes", windowKey: nil, name: "Notes")))
        XCTAssertFalse(w.isSame(as: .frontApp))
        XCTAssertFalse(w.isSame(as: .clipboard))
    }

    func testNeverPrivateOrItsOwn() {
        XCTAssertFalse(FrontWindow.mayShow("com.1password.1password"))
        XCTAssertFalse(FrontWindow.mayShow("com.apple.keychainaccess"))
        XCTAssertFalse(FrontWindow.mayShow("com.apple.Passwords"))
        XCTAssertFalse(FrontWindow.mayShow("com.apple.loginwindow"))
        XCTAssertFalse(FrontWindow.mayShow("com.sameer.macrophone.mac.debug"))
        XCTAssertFalse(FrontWindow.mayShow(""))
        XCTAssertTrue(FrontWindow.mayShow("com.apple.Terminal"))
    }

    // MARK: Pacing

    func testAChangeWaitsToStayPutAndTheSameIsNeverSentTwice() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let a = FrontWindow(bundleID: "a", appName: "A", window: 1, title: nil)
        let b = FrontWindow(bundleID: "b", appName: "B", window: 2, title: nil)
        let c = FrontWindow(bundleID: "c", appName: "C", window: 3, title: nil)
        var p = FrontWindowPacer()
        p.saw(a, at: t0)
        XCTAssertNil(p.take(at: t0.addingTimeInterval(0.2)), "not yet: it may still change")
        XCTAssertEqual(p.take(at: t0.addingTimeInterval(0.5)), .some(a))
        p.saw(a, at: t0.addingTimeInterval(0.6))
        XCTAssertNil(p.due, "the same window: nothing to say")
        // ⌘Tab through two apps to a third: one send, the last.
        p.saw(b, at: t0.addingTimeInterval(1.0))
        p.saw(c, at: t0.addingTimeInterval(1.2))
        XCTAssertNil(p.take(at: t0.addingTimeInterval(1.5)), "c has stood only 0.3 s")
        XCTAssertEqual(p.take(at: t0.addingTimeInterval(1.7)), .some(c))
        // Back to what was sent before it went: nothing waits.
        p.saw(b, at: t0.addingTimeInterval(2.0))
        p.saw(c, at: t0.addingTimeInterval(2.1))
        XCTAssertNil(p.due)
        // Nothing safe to show is said too.
        p.saw(nil, at: t0.addingTimeInterval(3))
        XCTAssertEqual(p.take(at: t0.addingTimeInterval(3.5)), .some(nil))
    }

    func testNeverMoreThanTwoASecond() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var p = FrontWindowPacer()
        var sends: [Date] = []
        // A window whose title changes every 0.1 s (a timer in it): sampled for 5 s.
        for i in 0..<50 {
            let now = t0.addingTimeInterval(Double(i) * 0.1)
            p.saw(FrontWindow(bundleID: "a", appName: "A", window: 1, title: "\(i)"), at: now)
            if p.take(at: now) != nil { sends.append(now) }
        }
        // Each new title restarts the settle: a title that never stands still is never sent mid-run…
        XCTAssertTrue(sends.isEmpty)
        // …and once it stops, it goes.
        XCTAssertNotNil(p.take(at: t0.addingTimeInterval(5.5)))
        // Two changes that each stand: at least `gap` apart.
        p.saw(FrontWindow(bundleID: "b", appName: "B", window: 2, title: nil), at: t0.addingTimeInterval(5.5))
        XCTAssertNil(p.take(at: t0.addingTimeInterval(5.9)))
        XCTAssertNotNil(p.take(at: t0.addingTimeInterval(6.0)))
    }

    // MARK: Over a real connection (loopback, the away door)

    func testAPhoneThatNamesItGetsItAfterTheWelcomeAndOnEachChange() async throws {
        let rig = try await Rig.make(port: 47941)
        defer { rig.stop() }
        rig.mac.front = FrontWindow(bundleID: "com.apple.Terminal", appName: "Terminal", window: 42, title: "codex — ~/api")
        rig.server.macFeatures.append(FrontWindow.feature)
        rig.client.features.append(FrontWindow.feature)
        try await rig.connect()
        XCTAssertTrue(rig.client.macSendsFrontWindow)
        try await rig.waitFor { rig.phone.fronts.count == 1 }
        XCTAssertEqual(rig.phone.fronts.first?.0, rig.mac.front)
        XCTAssertEqual(rig.phone.fronts.first?.1, rig.server.identity.id)
        rig.server.broadcastFrontWindow(nil)
        try await rig.waitFor { rig.phone.fronts.count == 2 }
        XCTAssertNil(rig.phone.fronts.last?.0 ?? nil)
        let sent = await rig.server.sendFrontWindow(FrontWindow(bundleID: "b", appName: "B", window: nil, title: nil), to: rig.phoneID)
        XCTAssertTrue(sent)
        try await rig.waitFor { rig.phone.fronts.count == 3 }
        XCTAssertEqual(rig.phone.fronts.last.flatMap { $0.0 }?.bundleID, "b")
    }

    func testAnOlderPhoneNeverGetsIt() async throws {
        let rig = try await Rig.make(port: 47942)
        defer { rig.stop() }
        rig.mac.front = FrontWindow(bundleID: "a", appName: "A", window: 1, title: nil)
        rig.server.macFeatures.append(FrontWindow.feature)
        try await rig.connect()
        let sent = await rig.server.sendFrontWindow(rig.mac.front, to: rig.phoneID)
        XCTAssertFalse(sent)
        rig.server.broadcastFrontWindow(rig.mac.front)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(rig.phone.fronts.isEmpty)
        XCTAssertEqual(rig.mac.frontAsks, 0)
        // The session carries on (an unknown message would have ended it).
        let rtt = await rig.client.roundTrip(); XCTAssertNotNil(rtt)
    }

    func testAnOlderMacSaysNothingAndThePhoneKnowsIt() async throws {
        let rig = try await Rig.make(port: 47943)
        defer { rig.stop() }
        rig.mac.front = FrontWindow(bundleID: "a", appName: "A", window: 1, title: nil)
        rig.client.features.append(FrontWindow.feature)
        try await rig.connect()
        XCTAssertFalse(rig.client.macSendsFrontWindow)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(rig.phone.fronts.isEmpty)
        XCTAssertEqual(rig.mac.frontAsks, 0)
    }
}

extension MacSide: LinkServerFrontWindowDelegate {
    func frontWindow(_ server: LinkServer, for peerID: UUID) -> FrontWindow? {
        frontAsks += 1
        return front
    }
}

extension PhoneSide: LinkClientFrontWindowDelegate {
    func linkClient(_ client: LinkClient, frontWindow: FrontWindow?, macID: UUID) {
        fronts.append((frontWindow, macID))
    }
}
