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

    func testAgentLikeApps() {
        XCTAssertTrue(WatchApps.isAgentLike("com.apple.Terminal"))
        XCTAssertTrue(WatchApps.isAgentLike("com.anthropic.claudefordesktop"))
        XCTAssertFalse(WatchApps.isAgentLike("com.apple.MobileSMS"))
        XCTAssertFalse(WatchApps.isAgentLike(nil))
    }
}
