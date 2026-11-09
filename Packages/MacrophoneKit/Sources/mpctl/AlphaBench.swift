import CoreMedia
import CoreVideo
import Foundation
import MacrophoneKit
import VideoToolbox

/// `mpctl alpha-bench [--frames 60] [--width 1400 --height 900]` (Nov 9 2026): what sending the
/// window's transparent corners as HEVC WITH alpha would cost, against plain HEVC — the demo window
/// drawn with transparent corners, scrolling (`--busy`'s drift) so every frame differs, each frame
/// handed to `VideoEncoder` as BGRA and waited on. Median and slowest-tenth encode time, median and
/// total bytes, for both codecs. The decision it informed: the corners go as a mask once per size
/// (`WatchWindowMask`); the stream stays 420f HEVC.
enum AlphaBench {
    static func run() async -> Int32 {
        let frames = Int(flag("--frames") ?? "") ?? 60
        let width = Int(flag("--width") ?? "") ?? 1400, height = Int(flag("--height") ?? "") ?? 900
        // What this Mac's encoders say they support (VideoToolbox lists one per codec).
        var encoders: CFArray?
        VTCopyVideoEncoderList(nil, &encoders)
        let list = (encoders as? [[CFString: Any]]) ?? []
        func codec(_ d: [CFString: Any]) -> UInt32? { (d[kVTVideoEncoderList_CodecType] as? NSNumber)?.uint32Value }
        let hevc = list.filter { codec($0) == kCMVideoCodecType_HEVC }
        let withAlpha = list.filter { codec($0) == kCMVideoCodecType_HEVCWithAlpha }
        stdout("encoders: HEVC ×\(hevc.count) (\(hevc.compactMap { $0[kVTVideoEncoderList_EncoderName] as? String }.joined(separator: ", "))) · HEVC with alpha ×\(withAlpha.count) (\(withAlpha.compactMap { $0[kVTVideoEncoderList_EncoderName] as? String }.joined(separator: ", ")))")

        let demo = DemoWindow()
        demo.cornerRadius = 52
        demo.finish()
        // The frames: the window scrolling a few pixels each, as `--busy` does, so none repeats.
        var buffers: [CVPixelBuffer] = []
        for _ in 0..<frames {
            demo.driftStep()
            guard let image = demo.image(), let pb = VideoEncoder.pixelBuffer(from: image) else { stdout("couldn't draw the demo window"); return 1 }
            // The demo window draws at its own size; the bench's size is the stream's.
            buffers.append(width == image.width && height == image.height ? pb : (scaled(image, to: width, height) ?? pb))
        }
        let mask = demo.mask()
        stdout("frames: \(buffers.count) at \(CVPixelBufferGetWidth(buffers[0]))×\(CVPixelBufferGetHeight(buffers[0])) BGRA · the mask instead: \(mask.map { "\(Int($0.radius)) px, \($0.corners?.count ?? 0) bytes once" } ?? "none")")

        for alpha in [false, true] {
            let name = alpha ? "HEVC with alpha" : "HEVC"
            let encoder: VideoEncoder
            do { encoder = try VideoEncoder(width: width, height: height, rate: 30, alpha: alpha) } catch {
                stdout("\(name): the encoder didn't start (\(error))")
                continue
            }
            // What the encoder for this codec supports, asked before any session (the alpha mode
            // among them when it's HEVC with alpha).
            var encoderID: CFString?, supported: CFDictionary?
            VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height), codecType: alpha ? kCMVideoCodecType_HEVCWithAlpha : kCMVideoCodecType_HEVC,
                                                        encoderSpecification: nil, encoderIDOut: &encoderID, supportedPropertiesOut: &supported)
            let props = (supported as? [CFString: Any]) ?? [:]
            let keys = props.count
            if alpha { stdout("HEVC with alpha: encoder \(encoderID.map { $0 as String } ?? "?") · alpha mode supported: \(props[kVTCompressionPropertyKey_AlphaChannelMode] != nil)") }
            var ms: [Double] = [], bytes: [Int] = []
            var keyframes = 0
            for pb in buffers {
                let t = Date()
                guard let e = encoder.encode(pb) else { stdout("\(name): a frame came back empty"); break }
                ms.append(Date().timeIntervalSince(t) * 1000)
                bytes.append(e.data.count)
                if e.keyframe { keyframes += 1 }
            }
            guard !ms.isEmpty else { continue }
            let sm = ms.sorted(), sb = bytes.sorted()
            stdout(String(format: "%@: %d frames · encode median %.1f ms, slowest tenth %.1f ms · %d KB a frame median, %d KB in all (%d keyframes) · %d supported properties",
                          name, ms.count, sm[sm.count / 2], sm[min(sm.count - 1, sm.count * 9 / 10)], sb[sb.count / 2] / 1024, bytes.reduce(0, +) / 1024, keyframes, keys))
        }
        return 0
    }

    /// The picture redrawn at another size, as BGRA.
    private static func scaled(_ image: CGImage, to w: Int, _ h: Int) -> CVPixelBuffer? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap(VideoEncoder.pixelBuffer(from:))
    }
}
