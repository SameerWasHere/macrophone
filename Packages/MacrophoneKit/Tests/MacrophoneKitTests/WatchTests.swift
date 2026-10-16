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
