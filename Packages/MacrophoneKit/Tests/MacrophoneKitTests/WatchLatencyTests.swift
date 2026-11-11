import CoreGraphics
import CoreText
import XCTest
@testable import MacrophoneKit

final class WatchLatencyTests: XCTestCase {
    // MARK: While he's touching it

    func testATouchedWindowSendsEveryChangeAtTheStreamsRate() {
        let caret = 40.0 / 4_000_000
        // Idle: a caret waits (fifteen a second), a real change at 0.9 of the period.
        XCTAssertEqual(WatchTouchPace.minimumInterval(changed: caret, sinceInput: .infinity, rate: 60), 1.0 / 15, accuracy: 1e-9)
        XCTAssertEqual(WatchTouchPace.minimumInterval(changed: 0.3, sinceInput: .infinity, rate: 60), 0.9 / 60, accuracy: 1e-9)
        // Touched: any change at half the period, a caret's worth too.
        XCTAssertEqual(WatchTouchPace.minimumInterval(changed: caret, sinceInput: 0.1, rate: 60), 0.5 / 60, accuracy: 1e-9)
        XCTAssertEqual(WatchTouchPace.minimumInterval(changed: 0.3, sinceInput: 1.9, rate: 60), 0.5 / 60, accuracy: 1e-9)
        XCTAssertEqual(WatchTouchPace.minimumInterval(changed: caret, sinceInput: 0.1, rate: 24), 0.5 / 24, accuracy: 1e-9)
        // Two seconds on, the idle pace again.
        XCTAssertEqual(WatchTouchPace.minimumInterval(changed: caret, sinceInput: 2.0, rate: 60), 1.0 / 15, accuracy: 1e-9)
        // A still window sends nothing, touched or not.
        XCTAssertEqual(WatchTouchPace.minimumInterval(changed: 0, sinceInput: 0.1, rate: 60), .infinity)
        XCTAssertEqual(WatchTouchPace.minimumInterval(changed: 0, sinceInput: .infinity, rate: 60), .infinity)
        // Pictures (not live) keep their pace even touched.
        XCTAssertEqual(WatchTouchPace.minimumInterval(changed: caret, sinceInput: 0.1, rate: 10, live: false), 3)
        // A clock that went backwards isn't a touch.
        XCTAssertFalse(WatchTouchPace.touched(sinceInput: -1))
    }

    func testTheFinerGridIsOnlyForTouchedVideo() {
        XCTAssertEqual(WatchTouchPace.sampleStep(planar: true, sinceInput: .infinity), 8)
        XCTAssertEqual(WatchTouchPace.sampleStep(planar: true, sinceInput: 0.5), 4)
        XCTAssertEqual(WatchTouchPace.sampleStep(planar: false, sinceInput: 0.5), 4)
        XCTAssertEqual(WatchTouchPace.sampleStep(planar: false, sinceInput: .infinity), 4)
    }

    /// Why the finer grid: one character typed into a 2560-pixel window, at many places on the
    /// page — how often each grid sees it at all (a frame the grid calls unchanged is never sent).
    func testTheFinerGridSeesATypedCharacterTheIdleGridCanMiss() throws {
        let w = 1200, h = 400
        var seen8 = 0, seen4 = 0, tries = 0
        for x in stride(from: 40, to: 1100, by: 61) {
            for y in stride(from: 40, to: 340, by: 43) {
                let before = try gray(w, h, text: "", at: CGPoint(x: x, y: y))
                let after = try gray(w, h, text: ".", at: CGPoint(x: x, y: y))
                tries += 1
                func seen(_ step: Int) -> Bool {
                    let a = before.withUnsafeBytes { WatchChange.sample(base: $0.baseAddress!, width: w, height: h, bytesPerRow: w, bytesPerPixel: 1, step: step) }
                    let b = after.withUnsafeBytes { WatchChange.sample(base: $0.baseAddress!, width: w, height: h, bytesPerRow: w, bytesPerPixel: 1, step: step) }
                    return WatchChange.changedShare(a, b) > 0
                }
                if seen(8) { seen8 += 1 }
                if seen(4) { seen4 += 1 }
            }
        }
        // A full stop at 26 px (a 13 pt font at 2×) is a few pixels across.
        XCTAssertGreaterThan(seen4, seen8)
        XCTAssertGreaterThan(Double(seen4) / Double(tries), 0.9)
        print("a full stop seen by step 8: \(seen8)/\(tries), step 4: \(seen4)/\(tries)")
    }

    private func gray(_ w: Int, _ h: Int, text: String, at p: CGPoint) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            guard !text.isEmpty else { return }
            let font = CTFontCreateWithName("Menlo" as CFString, 26, nil)
            let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                     NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = p
            CTLineDraw(line, ctx)
        }
        return bytes
    }

    // MARK: The picture follows the wire

    func testTheLadderStartsAtTheCeiling() {
        XCTAssertEqual(WatchWireSizer(ceiling: 2560).ladder, [2560, 2000, 1600, 1200])
        XCTAssertEqual(WatchWireSizer(ceiling: 2000).ladder, [2000, 1600, 1200])
        XCTAssertEqual(WatchWireSizer(ceiling: 1500).ladder, [1500, 1200])
        XCTAssertEqual(WatchWireSizer(ceiling: 1000).ladder, [1000])
        // A watch already stepped down starts at its step.
        XCTAssertEqual(WatchWireSizer(ceiling: 2560, width: 1600).width, 1600)
        XCTAssertEqual(WatchWireSizer(ceiling: 2560, width: 1300).width, 1200)
        XCTAssertEqual(WatchWireSizer(ceiling: 2560, width: 500).width, 1200)
    }

    /// A sizer past its first seconds (nothing steps down in a watch's opening moments).
    private func settled(ceiling: Int, at t: Double) -> WatchWireSizer {
        var s = WatchWireSizer(ceiling: ceiling)
        _ = s.sent(seconds: 0.001, at: t - WatchWireSizer.grace - 1)
        return s
    }

    func testFastSendsNeverStep() {
        var s = WatchWireSizer(ceiling: 2560)
        var t = 0.0
        for _ in 0..<5000 { XCTAssertNil(s.sent(seconds: 0.001, at: t)); t += 1.0 / 60 }
        // A lone slow send, or a burst of held frames (the phone busy for a moment), don't either.
        XCTAssertNil(s.sent(seconds: 0.3, at: t))
        for _ in 0..<5 { XCTAssertNil(s.heldForWire(at: t)) }
        XCTAssertNil(s.sent(seconds: 0.002, at: t))
        for _ in 0..<40 { XCTAssertNil(s.heldForWire(at: t)); t += 0.01 }
        XCTAssertEqual(s.width, 2560)
    }

    func testAtHomeItNeverSteps() {
        var s = settled(ceiling: 2560, at: 100)
        s.follows = false
        var t = 100.0
        for _ in 0..<400 { XCTAssertNil(s.sent(seconds: 0.5, at: t)); XCTAssertNil(s.heldForWire(at: t)); t += 0.05 }
        XCTAssertEqual(s.width, 2560)
    }

    func testNothingStepsDownInAWatchsFirstSeconds() {
        var s = WatchWireSizer(ceiling: 2560)
        var t = 50.0
        // Ten held in a sixth of a second two seconds in (his Duo, at home): no step.
        for _ in 0..<30 { XCTAssertNil(s.heldForWire(at: t)); XCTAssertNil(s.sent(seconds: 0.2, at: t)); t += 0.09 }
        XCTAssertEqual(s.width, 2560)
    }

    func testSlowSendsStepDownOneAtATimeAndSettle() {
        var s = settled(ceiling: 2560, at: 100)
        var t = 100.0
        var steps: [WatchWireSizer.Step] = []
        for _ in 0..<40 { if let st = s.sent(seconds: 0.14, at: t) { steps.append(st) }; t += 0.05 }
        // 40 slow sends over 2 s: one step (the next must wait `settleDown`).
        XCTAssertEqual(steps, [WatchWireSizer.Step(width: 2000, down: true, sendMs: 140, held: 0)])
        for _ in 0..<200 { if let st = s.sent(seconds: 0.14, at: t) { steps.append(st) }; t += 0.05 }
        XCTAssertEqual(steps.map(\.width), [2000, 1600, 1200])
        // The floor: no further.
        for _ in 0..<200 { XCTAssertNil(s.sent(seconds: 0.5, at: t)); t += 0.05 }
        XCTAssertEqual(s.width, 1200)
    }

    func testAStepDownGoesBelowWhatTheFramesReallyAre() {
        // A window 1440 px wide under a 2560 ceiling: 2000 and 1600 would change nothing — to 1200.
        var s = settled(ceiling: 2560, at: 5)
        s.showing = 1440
        var step: WatchWireSizer.Step?
        for _ in 0..<10 { step = s.sent(seconds: 0.2, at: 5) ?? step }
        XCTAssertEqual(step?.width, 1200)
        // Already at or under the floor: nothing to step to.
        var t = settled(ceiling: 2560, at: 5)
        t.showing = 900
        for _ in 0..<40 { XCTAssertNil(t.sent(seconds: 0.2, at: 5)) }
    }

    func testFramesHeldForASecondStepDownToo() {
        var s = settled(ceiling: 1600, at: 10)
        var step: WatchWireSizer.Step?
        var t = 10.0
        for _ in 0..<9 { XCTAssertNil(s.heldForWire(at: t)); t += 0.1 }       // 0.9 s of holding: not yet
        for _ in 0..<4 { step = s.heldForWire(at: t) ?? step; t += 0.1 }
        XCTAssertEqual(step?.width, 1200)
        XCTAssertGreaterThanOrEqual(step?.held ?? 0, WatchWireSizer.recent)
    }

    func testItStepsBackUpAfterACleanStretchAndNeverFlaps() {
        var s = settled(ceiling: 2560, at: 0)
        var t = 0.0
        for _ in 0..<10 { _ = s.sent(seconds: 0.2, at: t); t += 0.05 }
        XCTAssertEqual(s.width, 2000)
        // Quick arrivals, but not yet a clean stretch: nothing.
        for _ in 0..<60 { XCTAssertNil(s.sent(seconds: 0.01, at: t)); t += 0.1 }      // 6 s
        // One medium send starts the stretch over.
        XCTAssertNil(s.sent(seconds: 0.05, at: t))
        for _ in 0..<70 { XCTAssertNil(s.sent(seconds: 0.01, at: t)); t += 0.1 }      // 7 s clean
        var up: WatchWireSizer.Step?
        for _ in 0..<20 { up = s.sent(seconds: 0.01, at: t) ?? up; t += 0.1 }          // past 8 s
        XCTAssertEqual(up?.width, 2560)
        XCTAssertEqual(up?.down, false)
        // A mostly still window gets there too: a handful of quick arrivals spread over the stretch.
        var still = settled(ceiling: 2560, at: 0)
        var u = 0.0
        for _ in 0..<10 { _ = still.sent(seconds: 0.2, at: u); u += 0.05 }
        var back: WatchWireSizer.Step?
        for _ in 0..<8 { u += 2; back = still.sent(seconds: 0.005, at: u) ?? back }
        XCTAssertEqual(back?.width, 2560)
        // Slow again soon after: down, and the next step up needs twice the clean stretch.
        t += 3
        for _ in 0..<10 { _ = s.sent(seconds: 0.2, at: t); t += 0.05 }
        XCTAssertEqual(s.width, 2000)
        XCTAssertEqual(s.upBackoff, 2)
        for _ in 0..<120 { XCTAssertNil(s.sent(seconds: 0.01, at: t)); t += 0.1 }     // 12 s: not enough now
        var again: WatchWireSizer.Step?
        for _ in 0..<60 { again = s.sent(seconds: 0.01, at: t) ?? again; t += 0.1 }
        XCTAssertEqual(again?.width, 2560)
    }
}
