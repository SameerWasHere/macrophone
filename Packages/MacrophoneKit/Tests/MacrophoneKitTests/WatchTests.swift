import CoreGraphics
import Foundation
@testable import MacrophoneKit
import XCTest

final class WatchTests: XCTestCase {
    func testWatchMessagesRoundTrip() throws {
        let frame = WatchFrame(seq: 3, jpeg: Data(repeating: 7, count: 900_000), width: 1500, height: 960,
                               appName: "Claude", bundleID: "com.anthropic.claudefordesktop",
                               focus: CGRect(x: 0.25, y: 0.9, width: 0.45, height: 0.05))
        let messages: [Message] = [
            .watch(.app(bundleID: "com.apple.Terminal", windowKey: "41", name: "Terminal — claude")),
            .watch(nil),
            .watchAction(.returnKey),
            .watchState(.unavailable("Claude's window is minimized", canReveal: true)),
            .watchState(.needsPermission),
            .watchFrame(frame),
        ]
        for m in messages {
            let data = try WireCoding.encoder.encode(m)
            // The largest picture the Mac sends still fits in one frame, base64 and all.
            XCTAssertLessThan(data.count, FramedConnection.maxFrame)
            let back = try WireCoding.decoder.decode(Message.self, from: data)
            if case let .watchFrame(f) = back {
                XCTAssertEqual(f.seq, 3)
                XCTAssertEqual(f.jpeg.count, 900_000)
                XCTAssertEqual(f.focus?.width ?? 0, 0.45, accuracy: 0.0001)
            }
        }
    }
}

final class WatchStateWireTests: XCTestCase {
    /// The state keeps the shape a phone from before reads; `closed` rides along only when set.
    func testUnavailableKeepsItsShapeAndReadsAnOlderMacs() throws {
        let old = Data(#"{"unavailable":{"_0":"That Claude window is closed","canReveal":false}}"#.utf8)
        XCTAssertEqual(try WireCoding.decoder.decode(WatchState.self, from: old),
                       .unavailable("That Claude window is closed", canReveal: false, closed: false))
        let plain = try WireCoding.encoder.encode(WatchState.unavailable("Minimized", canReveal: true))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("closed"))
        let closed = try WireCoding.encoder.encode(WatchState.unavailable("Closed", canReveal: false, closed: true))
        XCTAssertTrue(String(decoding: closed, as: UTF8.self).contains(#""closed":true"#))
        XCTAssertEqual(try WireCoding.decoder.decode(WatchState.self, from: closed), .unavailable("Closed", canReveal: false, closed: true))
        for s: WatchState in [.live(appName: "Claude"), .needsPermission, .stopped] {
            XCTAssertEqual(try WireCoding.decoder.decode(WatchState.self, from: try WireCoding.encoder.encode(s)), s)
        }
        XCTAssertEqual(String(decoding: try WireCoding.encoder.encode(WatchState.needsPermission), as: UTF8.self), #"{"needsPermission":{}}"#)
    }

    func testFramesCarryTheMacsPointerWhenTold() throws {
        let f = WatchVideoFrame(seq: 1, data: Data(), parameterSets: nil, keyframe: false, width: 2, height: 2, appName: "Claude", bundleID: nil, focus: nil, cursor: CGPoint(x: 0.25, y: 0.75))
        let back = try WireCoding.decoder.decode(WatchVideoFrame.self, from: try WireCoding.encoder.encode(f))
        XCTAssertEqual(back.cursor?.x ?? 0, 0.25, accuracy: 0.0001)
        let bare = Data(#"{"seq":1,"data":"","keyframe":false,"width":2,"height":2,"appName":"Claude"}"#.utf8)
        XCTAssertNil(try WireCoding.decoder.decode(WatchVideoFrame.self, from: bare).cursor)
    }
}

final class WatchFrameRuleTests: XCTestCase {
    func testOnlyNewerPicturesShow() {
        // Pictures are decoded off the main thread, so an older one can finish after a newer one.
        XCTAssertTrue(WatchFrame.shouldShow(seq: 5, newest: 4))
        XCTAssertFalse(WatchFrame.shouldShow(seq: 4, newest: 5))
        XCTAssertFalse(WatchFrame.shouldShow(seq: 5, newest: 5))
        // The Mac started the watch over (after a pause, or its own restart): its first picture always shows.
        XCTAssertTrue(WatchFrame.shouldShow(seq: 1, newest: 40))
    }

    func testFocusJitterDoesNotMoveTheView() {
        let a = CGRect(x: 0.25, y: 0.9, width: 0.45, height: 0.05)
        let jitter = CGRect(x: 0.252, y: 0.905, width: 0.448, height: 0.05)
        let moved = CGRect(x: 0.55, y: 0.9, width: 0.45, height: 0.05)
        XCTAssertFalse(WatchFrame.focusMoved(from: a, to: jitter))
        XCTAssertTrue(WatchFrame.focusMoved(from: a, to: moved))
        XCTAssertTrue(WatchFrame.focusMoved(from: nil, to: a))
        XCTAssertTrue(WatchFrame.focusMoved(from: a, to: nil))
        XCTAssertFalse(WatchFrame.focusMoved(from: nil, to: nil))
    }
}

final class WatchPacingTests: XCTestCase {
    func testASliverWaitsAndARealChangeGoesAtOnce() {
        // Nothing changed: no picture. A caret (a few dozen pixels of 1.7 million): one every
        // few seconds. A highlight moving a row: about one a second. New output: right away.
        XCTAssertEqual(WatchPacing.minimumInterval(changed: 0), .infinity)
        XCTAssertEqual(WatchPacing.minimumInterval(changed: 40.0 / 1_700_000), 3)
        XCTAssertEqual(WatchPacing.minimumInterval(changed: 0.008), 1)
        XCTAssertEqual(WatchPacing.minimumInterval(changed: 0.05), 0.3)
        XCTAssertEqual(WatchPacing.minimumInterval(changed: 1), 0.3)
    }

    func testPixelSampleSeesABoxButNotACaret() throws {
        func image(box: CGRect?) -> CGImage {
            let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            if let box {
                ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
                ctx.fill(box)
            }
            return ctx.makeImage()!
        }
        let still = WatchChange.sample(image(box: nil))
        XCTAssertEqual(still.count, 100 * 75)
        XCTAssertEqual(WatchChange.changedShare(still, WatchChange.sample(image(box: nil))), 0)
        // A caret: two pixels wide, a line tall — a sliver.
        let caret = WatchChange.changedShare(still, WatchChange.sample(image(box: CGRect(x: 100, y: 100, width: 2, height: 16))))
        XCTAssertLessThan(caret, WatchPacing.sliver)
        // A row of output: a real change.
        let row = WatchChange.changedShare(still, WatchChange.sample(image(box: CGRect(x: 0, y: 100, width: 400, height: 20))))
        XCTAssertGreaterThan(row, WatchPacing.small)
        XCTAssertEqual(WatchChange.changedShare(still, []), 1)
    }
}
