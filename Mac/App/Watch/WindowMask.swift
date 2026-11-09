import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import MacrophoneKit
import ScreenCaptureKit

/// The watched window's real corners, read once per picture size (Nov 9 2026, Sameer: "I still
/// see black in the corners"). The stream is 420f HEVC and carries no alpha, so the Mac takes ONE
/// BGRA frame of the window with alpha, reads the corners off it (`WindowMaskReader`,
/// MacrophoneKit) and sends them to the phone as a 9-slice mask. Off the main thread; a few tens
/// of milliseconds, once per size.
///
/// Three ways to a frame with alpha, tried in turn — `SCScreenshotManager.captureImage` of the
/// single window (its shadow left out), a one-frame BGRA `SCStream` of it, and the window
/// server's own picture (`CGWindowListCreateImage`, deprecated) — because what each gives back
/// differs by macOS: the log says which one read a corner.
enum WindowMaskCapture {
    /// The mask for `window` as the stream pictures it (`size` in pixels), how long it took and
    /// which way gave it. Nil when no way gave a frame whose corners read (the phone then keeps
    /// its own guess).
    static func read(filter: SCContentFilter, source: CGRect?, windowID: CGWindowID?, size: (width: Int, height: Int)) async -> (mask: WatchWindowMask?, ms: Int, how: String) {
        let t = Date()
        var tried: [String] = []
        // 1. A screenshot of what the stream shows, at the stream's size.
        if let image = await screenshot(filter, source: source, size: size) {
            tried.append("screenshot(\(alphaWord(image)))")
            #if DEBUG
            // MACROPHONE_MASK_DUMP=<dir>: the frame as a PNG and its top-left diagonal's alpha, for a look.
            if let dir = ProcessInfo.processInfo.environment["MACROPHONE_MASK_DUMP"] { dump(image, to: dir) }
            #endif
            if let m = await Task.detached(priority: .userInitiated, operation: { WindowMaskReader.make(from: image) }).value, m.radius > 0 {
                return (m, Int(Date().timeIntervalSince(t) * 1000), tried.joined(separator: " → "))
            }
        } else { tried.append("screenshot(none)") }
        // 2. One frame of a BGRA stream of the single window (what the window's own stream would
        // carry if it were BGRA): its corners are transparent where the screenshot's may be filled.
        if let (m, word) = await oneFrame(filter, source: source, size: size) {
            tried.append("stream(\(word))")
            if let m, m.radius > 0 { return (m, Int(Date().timeIntervalSince(t) * 1000), tried.joined(separator: " → ")) }
        } else { tried.append("stream(none)") }
        // 3. The window server's picture (the display's scale, not the stream's — the radius is
        // scaled to the stream's size, the PNG left out).
        if let windowID, let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) {
            tried.append("window list(\(alphaWord(image)))")
            if var m = await Task.detached(priority: .userInitiated, operation: { WindowMaskReader.make(from: image) }).value, m.radius > 0 {
                if m.width != size.width || m.height != size.height {
                    m.radius = m.radius(forWidth: size.width)
                    m.width = size.width
                    m.height = size.height
                    m.corners = nil
                }
                return (m, Int(Date().timeIntervalSince(t) * 1000), tried.joined(separator: " → "))
            }
        } else { tried.append("window list(none)") }
        // Every way read square (or nothing): a square window, or no alpha anywhere — square it is
        // only when a frame was read at all.
        let square = tried.contains { $0.contains("alpha") } ? WatchWindowMask(width: size.width, height: size.height, radius: 0) : nil
        return (square, Int(Date().timeIntervalSince(t) * 1000), tried.joined(separator: " → "))
    }

    private static func screenshot(_ filter: SCContentFilter, source: CGRect?, size: (width: Int, height: Int)) async -> CGImage? {
        let cfg = SCStreamConfiguration()
        if let source { cfg.sourceRect = source }
        cfg.width = max(2, size.width)
        cfg.height = max(2, size.height)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// One BGRA frame of the window, read for its corners straight off the pixel buffer; nil when
    /// none came within a moment. The word says whether the corner pixel was transparent.
    private static func oneFrame(_ filter: SCContentFilter, source: CGRect?, size: (width: Int, height: Int)) async -> (WatchWindowMask?, String)? {
        let cfg = SCStreamConfiguration()
        if let source { cfg.sourceRect = source }
        cfg.width = max(2, size.width)
        cfg.height = max(2, size.height)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.queueDepth = 3
        let grab = FrameGrab()
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        do {
            try stream.addStreamOutput(grab, type: .screen, sampleHandlerQueue: grab.queue)
            try await stream.startCapture()
        } catch { return nil }
        let result = await grab.first(within: 1.5)
        try? await stream.stopCapture()
        return result
    }

    #if DEBUG
    private static func dump(_ image: CGImage, to dir: String) {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("mask-capture-\(image.width)x\(image.height).png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.assumingMemoryBound(to: UInt8.self), stride = ctx.bytesPerRow
        let diagonal = (0..<min(60, w, h)).map { String(p[$0 * stride + $0 * 4 + 3]) }.joined(separator: " ")
        let edge = (0..<min(60, w)).map { String(p[$0 * 4 + 3]) }.joined(separator: " ")
        try? "diagonal alpha: \(diagonal)\ntop row alpha: \(edge)\n".write(to: URL(fileURLWithPath: dir).appendingPathComponent("mask-capture-\(w)x\(h).txt"), atomically: true, encoding: .utf8)
    }
    #endif

    private static func alphaWord(_ image: CGImage) -> String {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return "no alpha"
        default: return "alpha"
        }
    }

    /// Takes the first complete frame a stream gives and reads the mask off it there and then.
    private final class FrameGrab: NSObject, SCStreamOutput {
        let queue = DispatchQueue(label: "macrophone.window-mask", qos: .userInitiated)
        private var continuation: CheckedContinuation<(WatchWindowMask?, String)?, Never>?
        private var done = false

        func first(within seconds: Double) async -> (WatchWindowMask?, String)? {
            await withCheckedContinuation { c in
                queue.async {
                    if self.done { c.resume(returning: nil); return }
                    self.continuation = c
                    self.queue.asyncAfter(deadline: .now() + seconds) { self.finish(nil) }
                }
            }
        }

        private func finish(_ r: (WatchWindowMask?, String)?) {
            guard !done else { return }
            done = true
            continuation?.resume(returning: r)
            continuation = nil
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, !done, sb.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let info = attachments.first, let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
            let corner = base.assumingMemoryBound(to: UInt8.self)[3]
            let mask = WindowMaskReader.make(bgra: UnsafeRawPointer(base), width: w, height: h, bytesPerRow: stride)
            finish((mask, corner < WindowMaskReader.edge ? "alpha" : "opaque corner"))
        }
    }
}
