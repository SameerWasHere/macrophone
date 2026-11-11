import CoreMedia
import CoreVideo
import Foundation
import MacrophoneKit
import QuartzCore
import VideoToolbox

/// `mpctl encode-bench [--frames 120] [--widths 2560,1600,1000] [--tunings standard,zeroDelay,lowLatency]`
/// (Nov 10 2026, the latency pass): the watched window's encoder under each tuning — the demo window
/// drawn as the Mac's stream gives it (420f, full range), at each width, through three runs:
/// *typing* (one more character a frame: a sliver changes), *scroll* (the page drifts 6 px a frame)
/// and *60 Hz* (the scroll's frames handed in every 16.7 ms without waiting, as the pipe does — the
/// encoder's throughput and each frame's time from hand-in to bytes). Prints the session's making
/// time (a new size's cost before its keyframe), encode median / slowest tenth, KB a frame, and
/// the properties a session refused.
enum EncodeBench {
    static func run() async -> Int32 {
        let frames = Int(flag("--frames") ?? "") ?? 120
        let widths = (flag("--widths") ?? "2560,1600,1000").split(separator: ",").compactMap { Int($0) }
        let tunings = (flag("--tunings") ?? "standard,zeroDelay,lowLatency").split(separator: ",").compactMap { VideoEncoder.Tuning(rawValue: String($0)) }
        let rate = Int(flag("--rate") ?? "") ?? 60

        let demo = DemoWindow()
        demo.finish()
        guard let first = demo.image() else { stdout("couldn't draw the demo window"); return 1 }
        let aspect = Double(first.height) / Double(first.width)

        for width in widths {
            let height = Int(Double(width) * aspect) & ~1
            // The frames for this size, made once: typing, then scrolling.
            var typing: [CVPixelBuffer] = [], scroll: [CVPixelBuffer] = []
            let d1 = DemoWindow(); d1.finish()
            for _ in 0..<frames {
                d1.typed(WatchTyping(text: "a"))
                guard let img = d1.image(), let pb = planar(img, width, height) else { stdout("couldn't draw"); return 1 }
                typing.append(pb)
            }
            let d2 = DemoWindow(); d2.finish()
            for _ in 0..<frames {
                d2.driftStep()
                guard let img = d2.image(), let pb = planar(img, width, height) else { stdout("couldn't draw"); return 1 }
                scroll.append(pb)
            }
            stdout("— \(width)×\(height) 420f, \(frames) frames a run, rate \(rate)")
            for tuning in tunings {
                // Making a session, three times (the first warms the chip).
                var made: [Double] = []
                var real = tuning
                for _ in 0..<3 {
                    guard let e = try? VideoEncoder(width: width, height: height, rate: rate, tuning: tuning) else { stdout("  \(tuning): no encoder"); break }
                    made.append(e.madeIn * 1000)
                    real = e.tuning
                }
                let refused = VideoEncoder.lastRefusedProperties
                let label = real == tuning ? tuning.rawValue : "\(tuning.rawValue) (refused → \(real.rawValue))"
                stdout(String(format: "  %@: session made in %.1f ms (then %.1f)%@", label, made.first ?? 0, made.last ?? 0, refused.isEmpty ? "" : " · refused: \(refused.joined(separator: ", "))"))
                for (name, set) in [("typing", typing), ("scroll", scroll)] {
                    guard let enc = try? VideoEncoder(width: width, height: height, rate: rate, tuning: tuning) else { continue }
                    var ms: [Double] = [], bytes: [Int] = [], keys = 0
                    for pb in set {
                        let t = CACurrentMediaTime()
                        guard let e = enc.encode(pb) else { stdout("    \(name): a frame came back empty"); break }
                        ms.append((CACurrentMediaTime() - t) * 1000)
                        bytes.append(e.data.count)
                        if e.keyframe { keys += 1 }
                    }
                    report("    \(name)", ms: Array(ms.dropFirst()), bytes: Array(bytes.dropFirst()), firstKB: (bytes.first ?? 0) / 1024, keys: keys)
                }
                // 60 Hz without waiting: what comes out, and how long each took.
                guard let enc = try? VideoEncoder(width: width, height: height, rate: rate, tuning: tuning) else { continue }
                let box = Collector()
                enc.onEncoded = { e, took in box.add(took * 1000, e.data.count) }
                let t0 = CACurrentMediaTime()
                var dropped = 0
                for (i, pb) in scroll.enumerated() {
                    let due = t0 + Double(i) / Double(rate)
                    let wait = due - CACurrentMediaTime()
                    if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
                    if case .waits(let replaced) = enc.submit(pb), replaced { dropped += 1 }
                }
                usleep(300_000)
                let (ms, bytes) = box.take()
                let seconds = Double(scroll.count) / Double(rate)
                report(String(format: "    60 Hz: %d of %d out (%.0f a second, %d replaced waiting)", ms.count, scroll.count, Double(ms.count) / seconds, dropped),
                       ms: Array(ms.dropFirst()), bytes: Array(bytes.dropFirst()), firstKB: (bytes.first ?? 0) / 1024, keys: nil)
            }
        }
        return 0
    }

    private static func report(_ name: String, ms: [Double], bytes: [Int], firstKB: Int, keys: Int?) {
        guard !ms.isEmpty else { stdout("\(name): nothing"); return }
        let sm = ms.sorted(), sb = bytes.sorted()
        stdout(String(format: "%@ · encode median %.1f ms, slowest tenth %.1f ms · %.1f KB a frame median (first %d KB)%@",
                      name, sm[sm.count / 2], sm[min(sm.count - 1, sm.count * 9 / 10)], Double(sb[sb.count / 2]) / 1024, firstKB, keys.map { " · \($0) keyframes" } ?? ""))
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var ms: [Double] = [], bytes: [Int] = []
        func add(_ m: Double, _ b: Int) { lock.lock(); ms.append(m); bytes.append(b); lock.unlock() }
        func take() -> ([Double], [Int]) { lock.lock(); defer { lock.unlock() }; return (ms, bytes) }
    }

    /// The picture at `w`×`h` as the stream gives it: 420f, full range.
    private static func planar(_ image: CGImage, _ w: Int, _ h: Int) -> CVPixelBuffer? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage(), let bgra = VideoEncoder.pixelBuffer(from: scaled) else { return nil }
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &out) == kCVReturnSuccess, let out else { return nil }
        var transfer: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr, let transfer else { return nil }
        defer { VTPixelTransferSessionInvalidate(transfer) }
        return VTPixelTransferSessionTransferImage(transfer, from: bgra, to: out) == noErr ? out : nil
    }
}
