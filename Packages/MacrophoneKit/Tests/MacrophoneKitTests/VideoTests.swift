import CoreGraphics
import CoreVideo
import Foundation
@testable import MacrophoneKit
import XCTest

final class VideoWireTests: XCTestCase {
    func testVideoMessagesRoundTrip() throws {
        let frame = WatchVideoFrame(seq: 2, data: Data(repeating: 1, count: 120_000), parameterSets: [Data([1, 2]), Data([3]), Data([4, 5, 6])],
                                    keyframe: true, width: 1500, height: 960, appName: "Claude", bundleID: "com.anthropic.claudefordesktop",
                                    focus: CGRect(x: 0.25, y: 0.9, width: 0.45, height: 0.05))
        let messages: [Message] = [.watchVideo(frame), .watchKeyframe, .watchFit(.larger), .welcome(macName: "M", appVersion: "1.1", features: ["video", "fit"])]
        for m in messages {
            let data = try WireCoding.encoder.encode(m)
            XCTAssertLessThan(data.count, FramedConnection.maxFrame)
            let back = try WireCoding.decoder.decode(Message.self, from: data)
            switch back {
            case let .watchVideo(f):
                XCTAssertEqual(f.seq, 2)
                XCTAssertTrue(f.keyframe)
                XCTAssertEqual(f.parameterSets?.count, 3)
                XCTAssertEqual(f.data.count, 120_000)
                XCTAssertFalse(f.isWordsOnly)
            case .watchKeyframe: break
            case let .watchFit(f): XCTAssertEqual(f, .larger)
            case let .welcome(_, _, features): XCTAssertEqual(features, ["video", "fit"])
            default: XCTFail("\(back)")
            }
        }
        // Only the words changed: nothing to decode.
        XCTAssertTrue(WatchVideoFrame(seq: 3, data: Data(), parameterSets: nil, keyframe: false, width: 1, height: 1, appName: "", bundleID: nil, focus: nil).isWordsOnly)
    }

    func testWelcomeWithoutFeaturesStillDecodes() throws {
        // A Mac from before video sends a welcome without features — and a phone from before
        // ignores the features a new Mac sends (Codable skips keys it doesn't know).
        let old = #"{"welcome":{"macName":"M","appVersion":"1.0"}}"#
        guard case let .welcome(_, _, features) = try JSONDecoder().decode(Message.self, from: Data(old.utf8)) else { return XCTFail() }
        XCTAssertNil(features)
        let newer = #"{"welcome":{"macName":"M","appVersion":"1.1","features":["video"],"later":1}}"#
        guard case let .welcome(name, _, f2) = try JSONDecoder().decode(Message.self, from: Data(newer.utf8)) else { return XCTFail() }
        XCTAssertEqual(name, "M")
        XCTAssertEqual(f2, ["video"])
    }

    func testFramesDecodeInOrderOrFromAKeyframe() {
        XCTAssertTrue(WatchVideoFrame.canDecode(seq: 1, keyframe: true, newest: 0, waitingForKeyframe: true))
        XCTAssertTrue(WatchVideoFrame.canDecode(seq: 6, keyframe: false, newest: 5, waitingForKeyframe: false))
        // One was lost: wait for a keyframe.
        XCTAssertFalse(WatchVideoFrame.canDecode(seq: 7, keyframe: false, newest: 5, waitingForKeyframe: false))
        XCTAssertFalse(WatchVideoFrame.canDecode(seq: 6, keyframe: false, newest: 5, waitingForKeyframe: true))
        XCTAssertTrue(WatchVideoFrame.canDecode(seq: 9, keyframe: true, newest: 5, waitingForKeyframe: true))
    }

    func testVideoEarnsFramesSooner() {
        XCTAssertEqual(WatchPacing.minimumInterval(changed: 0, video: true), .infinity)
        XCTAssertEqual(WatchPacing.minimumInterval(changed: 40.0 / 1_700_000, video: true), 3)
        XCTAssertEqual(WatchPacing.minimumInterval(changed: 0.008, video: true), 0.5)
        XCTAssertEqual(WatchPacing.minimumInterval(changed: 0.3, video: true), 0.1)
        // The pictures' pacing is unchanged.
        XCTAssertEqual(WatchPacing.minimumInterval(changed: 0.3), 0.3)
    }
}

final class WatchFitTests: XCTestCase {
    func testAFitIsTheFullHeightAndNarrower() {
        let area = CGRect(x: 0, y: 25, width: 1728, height: 1092)
        let window = CGRect(x: 300, y: 200, width: 1200, height: 800)
        XCTAssertNil(WatchFit.normal.frame(for: window, in: area))
        let larger = WatchFit.larger.frame(for: window, in: area)!
        XCTAssertEqual(larger, CGRect(x: 300, y: 25, width: 560, height: 1092))
        let largest = WatchFit.largest.frame(for: window, in: area)!
        XCTAssertEqual(largest, CGRect(x: 300, y: 25, width: 420, height: 1092))
        // Never wider than the window is now, and never off the edge.
        let narrow = CGRect(x: 1500, y: 200, width: 500, height: 800)
        XCTAssertEqual(WatchFit.larger.frame(for: narrow, in: area)!, CGRect(x: 1228, y: 25, width: 500, height: 1092))
        XCTAssertEqual(WatchFit.largest.frame(for: narrow, in: area)!, CGRect(x: 1308, y: 25, width: 420, height: 1092))
        XCTAssertEqual(WatchFit.larger.title, "Larger")
        XCTAssertEqual(WatchFit.largest.explanation(appName: "Claude"), "Claude's window is as narrow as it goes, so its text reads largest here")
    }
}

/// The encoder and decoder against each other, on this Mac (the phone's decoder is the same code).
final class VideoCodecTests: XCTestCase {
    private func picture(_ w: Int, _ h: Int, words: String) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        // "Text": a row of small boxes whose count depends on the words.
        for i in 0..<words.count { ctx.fill(CGRect(x: 20 + i * 14, y: h / 2, width: 8, height: 12)) }
        return ctx.makeImage()!
    }

    private func pixel(_ b: CVPixelBuffer, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(b) + x * 4
        return (p[0], p[1], p[2]) // BGRA
    }

    func testAFrameSurvivesTheWire() throws {
        // In software, so the count of keyframes is the encoder's own doing — a busy hardware
        // encoder (this Mac's, most days) switches to software mid-run and starts on a keyframe.
        let w = 640, h = 400
        let encoder = try VideoEncoder(width: w, height: h, software: true)
        let decoder = VideoDecoder()
        var sizes: [Int] = []
        var keyframes = 0
        for (i, words) in ["one line", "one line, two", "one line, two, three"].enumerated() {
            let pb = try XCTUnwrap(VideoEncoder.pixelBuffer(from: picture(w, h, words: words)))
            let e = try XCTUnwrap(encoder.encode(pb))
            if i == 0 { XCTAssertTrue(e.keyframe, "the first frame stands on its own"); XCTAssertNotNil(e.parameterSets) }
            if e.keyframe { keyframes += 1 }
            sizes.append(e.data.count)
            let frame = WatchVideoFrame(seq: i + 1, data: e.data, parameterSets: e.parameterSets, keyframe: e.keyframe,
                                        width: w, height: h, appName: "Demo", bundleID: nil, focus: nil)
            let data = try WireCoding.encoder.encode(Message.watchVideo(frame))
            guard case let .watchVideo(back) = try WireCoding.decoder.decode(Message.self, from: data) else { return XCTFail() }
            let out = try decoder.decode(back)
            XCTAssertEqual(CVPixelBufferGetWidth(out), w)
            XCTAssertEqual(CVPixelBufferGetHeight(out), h)
            // The ground and the "text" come back as drawn (within a codec's tolerance).
            let ground = pixel(out, x: 5, y: 5)
            XCTAssertLessThan(abs(Int(ground.0) - 33), 12)
            // Rows count from the top; the box was drawn from the bottom-left.
            let ink = pixel(out, x: 24, y: h / 2 - 6)
            XCTAssertGreaterThan(ink.0, 180)
        }
        XCTAssertEqual(keyframes, 1)
        // A keyframe asked for comes as one, with its parameter sets.
        encoder.requestKeyframe()
        let pb = try XCTUnwrap(VideoEncoder.pixelBuffer(from: picture(w, h, words: "again")))
        let e = try XCTUnwrap(encoder.encode(pb))
        XCTAssertTrue(e.keyframe)
        XCTAssertNotNil(e.parameterSets)
        print("[video] frames \(sizes) bytes, keyframe \(e.data.count) bytes, \(encoder.software ? "software" : "hardware")")
    }

    func testTheHardwareEncoderEncodesToo() throws {
        // The Mac's own path (it may fall back to software when the hardware is busy; either way
        // every frame decodes).
        let w = 640, h = 400
        let encoder = try VideoEncoder(width: w, height: h)
        let decoder = VideoDecoder()
        for i in 0..<3 {
            let pb = try XCTUnwrap(VideoEncoder.pixelBuffer(from: picture(w, h, words: String(repeating: "x", count: i + 3))))
            let e = try XCTUnwrap(encoder.encode(pb))
            if i == 0 { XCTAssertTrue(e.keyframe) }
            if e.keyframe { XCTAssertNotNil(e.parameterSets) }
            let out = try decoder.decode(WatchVideoFrame(seq: i + 1, data: e.data, parameterSets: e.parameterSets, keyframe: e.keyframe, width: w, height: h, appName: "", bundleID: nil, focus: nil))
            XCTAssertEqual(CVPixelBufferGetWidth(out), w)
        }
        print("[video] hardware test ended in \(encoder.software ? "software" : "hardware")")
    }

    func testADecoderWithoutAKeyframeSaysSo() {
        let decoder = VideoDecoder()
        let frame = WatchVideoFrame(seq: 4, data: Data([0, 0, 0, 1, 2]), parameterSets: nil, keyframe: false, width: 2, height: 2, appName: "", bundleID: nil, focus: nil)
        XCTAssertThrowsError(try decoder.decode(frame)) { XCTAssertEqual($0 as? VideoError, .noKeyframe) }
    }
}
