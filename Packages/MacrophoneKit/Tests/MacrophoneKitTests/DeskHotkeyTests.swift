import XCTest
@testable import MacrophoneKit

final class DeskHotkeyTests: XCTestCase {
    /// Runs the ticks the tap would send up to `t`, then the event.
    private func feed(_ m: inout DeskHotkey, _ e: DeskHotkey.Event, at t: TimeInterval) -> [DeskHotkey.Effect] {
        var fx: [DeskHotkey.Effect] = []
        while let d = m.nextDeadline, d <= t { fx += m.handle(.tick, at: d).effects }
        return fx + m.handle(e, at: t).effects
    }

    func testHoldOpensAtPressShowsPillAndFinishesOnRelease() {
        var m = DeskHotkey(key: .fn)
        XCTAssertEqual(feed(&m, .down, at: 0), [.openMic])
        XCTAssertEqual(m.nextDeadline, 0.15)
        XCTAssertEqual(m.handle(.tick, at: 0.15).effects, [.showPill])
        XCTAssertEqual(m.phase, .holding)
        XCTAssertTrue(m.isListening)
        XCTAssertEqual(feed(&m, .up, at: 2.4), [.finish])
        XCTAssertEqual(m.phase, .idle)
        XCTAssertFalse(m.isListening)
    }

    func testQuickTapLetsTheMicGoQuietly() {
        var m = DeskHotkey(key: .fn)
        XCTAssertEqual(feed(&m, .down, at: 0), [.openMic])
        // Released before the pill: nothing ever shown.
        XCTAssertEqual(feed(&m, .up, at: 0.1), [.cancel(quiet: true)])
        // A tap that outlived the pill's delay still pastes nothing.
        XCTAssertEqual(feed(&m, .down, at: 5), [.openMic])
        XCTAssertEqual(feed(&m, .up, at: 5.25), [.showPill, .cancel(quiet: false)])
    }

    func testDoubleTapIsHandsFreeUntilTappedAgain() {
        var m = DeskHotkey(key: .fn)
        _ = feed(&m, .down, at: 0)
        _ = feed(&m, .up, at: 0.1)
        XCTAssertEqual(feed(&m, .down, at: 0.3), [.openMic, .showPill, .handsFree])
        XCTAssertEqual(feed(&m, .up, at: 0.4), [])
        XCTAssertEqual(m.phase, .handsFree)
        XCTAssertTrue(m.isListening)
        // Typing while hands-free changes nothing.
        XCTAssertEqual(feed(&m, .otherKey, at: 3), [])
        XCTAssertEqual(feed(&m, .down, at: 9), [.finish])
        XCTAssertEqual(feed(&m, .up, at: 9.1), [])
        XCTAssertEqual(m.phase, .idle)
        // The release that ended it isn't the first tap of another double tap.
        XCTAssertEqual(feed(&m, .down, at: 9.3), [.openMic])
    }

    func testTwoTapsTooFarApartAreTwoTaps() {
        var m = DeskHotkey(key: .fn)
        _ = feed(&m, .down, at: 0)
        _ = feed(&m, .up, at: 0.1)
        XCTAssertEqual(feed(&m, .down, at: 0.6), [.openMic])
        XCTAssertEqual(m.phase, .pressed)
    }

    func testTypingBetweenTapsBreaksTheDoubleTap() {
        var m = DeskHotkey(key: .fn)
        _ = feed(&m, .down, at: 0)
        _ = feed(&m, .up, at: 0.1)
        _ = feed(&m, .otherKey, at: 0.2)
        XCTAssertEqual(feed(&m, .down, at: 0.3), [.openMic])
        XCTAssertEqual(m.phase, .pressed)
    }

    func testEscCancelsAndIsSwallowed() {
        var m = DeskHotkey(key: .fn)
        _ = feed(&m, .down, at: 0)
        _ = m.handle(.tick, at: 0.2)
        let r = m.handle(.escape, at: 1)
        XCTAssertEqual(r.effects, [.cancel(quiet: false)])
        XCTAssertTrue(r.swallow)
        // The key's release after Esc does nothing.
        XCTAssertEqual(feed(&m, .up, at: 1.5), [])
        XCTAssertEqual(m.phase, .idle)
    }

    func testEscInHandsFreeCancels() {
        var m = DeskHotkey(key: .fn)
        _ = feed(&m, .down, at: 0); _ = feed(&m, .up, at: 0.1)
        _ = feed(&m, .down, at: 0.2); _ = feed(&m, .up, at: 0.3)
        let r = m.handle(.escape, at: 4)
        XCTAssertEqual(r.effects, [.cancel(quiet: false)])
        XCTAssertTrue(r.swallow)
        XCTAssertEqual(m.phase, .idle)
    }

    func testEscWhenNotListeningGoesThrough() {
        var m = DeskHotkey(key: .rightCommand)
        let r = m.handle(.escape, at: 0)
        XCTAssertEqual(r.effects, [])
        XCTAssertFalse(r.swallow)
    }

    func testAShortcutIsNotADictation() {
        // Right ⌘ + C: the mic never opens (it waits for a hold), nothing happens.
        var m = DeskHotkey(key: .rightCommand)
        XCTAssertEqual(feed(&m, .down, at: 0), [])
        XCTAssertEqual(feed(&m, .otherKey, at: 0.08), [])
        XCTAssertEqual(feed(&m, .up, at: 0.6), [])
        XCTAssertEqual(m.phase, .idle)
        // …and isn't the first half of a double tap.
        XCTAssertEqual(feed(&m, .down, at: 0.7), [])
        XCTAssertEqual(m.phase, .pressed)
    }

    func testFnShortcutLetsTheOpenMicGo() {
        // Fn + an arrow: the mic opened at the press and is let go quietly.
        var m = DeskHotkey(key: .fn)
        _ = feed(&m, .down, at: 0)
        XCTAssertEqual(feed(&m, .otherKey, at: 0.05), [.cancel(quiet: true)])
        XCTAssertEqual(feed(&m, .up, at: 0.4), [])
    }

    func testShortcutAfterThePillCancelsVisibly() {
        var m = DeskHotkey(key: .rightOption)
        _ = feed(&m, .down, at: 0)
        XCTAssertEqual(m.handle(.tick, at: 0.18).effects, [.openMic, .showPill])
        XCTAssertEqual(feed(&m, .otherKey, at: 1), [.cancel(quiet: false)])
    }

    func testRightKeysWaitBeforeOpeningTheMic() {
        var m = DeskHotkey(key: .rightOption)
        XCTAssertEqual(feed(&m, .down, at: 0), [])
        XCTAssertEqual(m.nextDeadline, 0.18)
        XCTAssertEqual(feed(&m, .up, at: 0.1), [])  // a tap: nothing at all
        _ = feed(&m, .down, at: 3)
        XCTAssertEqual(feed(&m, .up, at: 4), [.openMic, .showPill, .finish])
    }

    func testHandsFreeEndsItselfAfterTheLimit() {
        var m = DeskHotkey(key: .fn)
        m.handsFreeLimit = 60
        _ = feed(&m, .down, at: 0); _ = feed(&m, .up, at: 0.1)
        _ = feed(&m, .down, at: 0.2); _ = feed(&m, .up, at: 0.3)
        XCTAssertEqual(m.nextDeadline, 60.3)
        XCTAssertEqual(m.handle(.tick, at: 60.3).effects, [.finish])
        XCTAssertEqual(m.phase, .idle)
    }

    func testResetWhileHeldIgnoresTheRelease() {
        var m = DeskHotkey(key: .fn)
        _ = feed(&m, .down, at: 0)
        m.reset(keyDown: true)
        XCTAssertEqual(feed(&m, .up, at: 1), [])
        XCTAssertEqual(m.phase, .idle)
    }

    func testFnUsageConflicts() {
        XCTAssertNil(FnKeyUsage.doNothing.conflict)
        XCTAssertNotNil(FnKeyUsage.showEmoji.conflict)
        XCTAssertNotNil(FnKeyUsage(rawValue: 3)?.conflict)
        XCTAssertEqual(DeskKey.fn.keyCode, 63)
        XCTAssertTrue(DeskKey.fn.opensMicAtPress)
        XCTAssertFalse(DeskKey.rightCommand.opensMicAtPress)
    }
}
