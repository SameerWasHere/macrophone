import CoreMedia
import CoreVideo
import Foundation
import MacrophoneKit
import ScreenCaptureKit
import VideoToolbox

/// One window, streamed (Oct 16 2026): the window server hands over a picture only when the window
/// changed, with the part that changed, so a still window costs nothing and a change shows in a
/// tenth of a second — where a screenshot per look cost ~150 ms each and ran all the time.
/// Frames arrive on the stream's own queue.
final class WindowStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private let stream: SCStream
    private let queue = DispatchQueue(label: "macrophone.window-stream", qos: .userInitiated)
    /// A new picture (its pixels, to turn into an image only if it's sent) and the share of it
    /// that changed since the one before (0…1).
    var onFrame: (@Sendable (CVPixelBuffer, Double) -> Void)?
    /// The last picture, sampled, to measure the next change against (on the stream's queue).
    private var previous: [UInt32]?
    /// The stream ended on its own (the window closed, the permission went).
    var onStop: (@Sendable (Error?) -> Void)?
    /// The picture's size, in pixels.
    private(set) var size: (width: Int, height: Int)
    /// The window's size the stream was set up for, in points.
    private(set) var windowSize: CGSize
    private let scale: CGFloat
    /// At most this many pictures a second, when the window keeps changing (the fastest a picture
    /// is sent is three a second; more only costs the window server) — ten over the home network;
    /// and frames of video, which cost little each, at the rate a window scrolls (thirty a second;
    /// twelve away from home, where every frame crosses a slower path).
    static let pictureRate = 6
    static let quickPictureRate = 10
    static let videoRate = 60
    static let remoteVideoRate = 24
    private let maxRate: Int
    /// Frames for a video encoder come as the chip takes them (Y′CbCr planes, full range): no
    /// conversion before the encode, and the change sample reads the brightness plane. Pictures
    /// come as BGRA, which a JPEG is made from.
    let video: Bool

    init(window: SCWindow, maxWidth: CGFloat, maxRate: Int = pictureRate, video: Bool = false) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        scale = CGFloat(filter.pointPixelScale)
        self.maxRate = maxRate
        self.video = video
        let (cfg, size) = Self.configuration(for: window.frame.size, scale: scale, maxWidth: maxWidth, maxRate: maxRate, video: video)
        self.size = size
        windowSize = window.frame.size
        stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        super.init()
    }

    private static func configuration(for window: CGSize, scale: CGFloat, maxWidth: CGFloat, maxRate: Int, video: Bool) -> (SCStreamConfiguration, (Int, Int)) {
        let cfg = SCStreamConfiguration()
        let pxW = max(1, window.width * scale), pxH = max(1, window.height * scale)
        let k = min(1, maxWidth / pxW)
        // Even sizes: what a video encoder takes whole.
        cfg.width = max(2, Int(pxW * k) & ~1)
        cfg.height = max(2, Int(pxH * k) & ~1)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.pixelFormat = video ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
        if video { cfg.colorSpaceName = CGColorSpace.sRGB }
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: Int32(maxRate))
        cfg.queueDepth = 5
        return (cfg, (cfg.width, cfg.height))
    }

    func start() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stop() async {
        onFrame = nil
        onStop = nil
        try? await stream.stopCapture()
    }

    /// The whole main display (DesktopWatch), leaving out `excluding` (Macrophone's own popup).
    init(display: SCDisplay, excluding: [SCWindow], maxWidth: CGFloat, maxRate: Int = pictureRate, video: Bool = false) {
        let filter = SCContentFilter(display: display, excludingWindows: excluding)
        scale = CGFloat(filter.pointPixelScale)
        self.maxRate = maxRate
        self.video = video
        let points = CGSize(width: display.width, height: display.height)
        let (cfg, size) = Self.configuration(for: points, scale: scale, maxWidth: maxWidth, maxRate: maxRate, video: video)
        self.size = size
        windowSize = points
        stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        super.init()
    }

    /// The window was resized: pictures follow its new shape.
    func resize(to window: CGSize, maxWidth: CGFloat) async {
        guard window != windowSize else { return }
        let (cfg, size) = Self.configuration(for: window, scale: scale, maxWidth: maxWidth, maxRate: maxRate, video: video)
        windowSize = window
        self.size = size
        try? await stream.updateConfiguration(cfg)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let onFrame,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sb) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        #if DEBUG
        if Self.timing {
            frameCount += 1
            if let d = Self.dirtyShare(info, width: width, height: height) { dirtyCount += 1; dirtyMax = max(dirtyMax, d) }
            if Date().timeIntervalSince(countedAt) >= 1 {
                print("[stream] \(frameCount) frames this second, \(dirtyCount) with changed rectangles (largest \(String(format: "%.4f", dirtyMax))), \(video ? "planar" : "BGRA")"); fflush(stdout)
                frameCount = 0; dirtyCount = 0; dirtyMax = 0; countedAt = Date()
            }
        }
        #endif
        // How much changed: the frame's own list of changed rectangles when it says a sliver (a
        // caret), else measured from a sample of the pixels — an Electron app redraws its whole
        // window for a caret, and the list says so. Read in place: no copy for a frame that won't go.
        let share: Double
        if let bound = Self.dirtyShare(info, width: width, height: height), bound < WatchPacing.sliver, previous != nil {
            share = bound
        } else {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            // A video frame's first plane is its brightness, one byte a pixel.
            let planar = CVPixelBufferIsPlanar(buffer)
            let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
            let bytesPerRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
            // The window server says the whole window changed on every frame it gives, thirty a
            // second for video (TextEdit, Electron apps, on macOS 27) — the sample is the real
            // gate, and a coarser one on the brightness plane keeps a still window cheap.
            let sample = base.map {
                WatchChange.sample(base: UnsafeRawPointer($0), width: width, height: height, bytesPerRow: bytesPerRow, bytesPerPixel: planar ? 1 : 4, step: planar ? 8 : 4)
            } ?? []
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            share = previous.map { WatchChange.changedShare($0, sample) } ?? 1
            previous = sample
        }
        onFrame(buffer, share)
    }

    /// The picture, for a frame that goes out as a JPEG, or one the question is read off (a video
    /// frame's planes are converted here, which VideoToolbox does for any of its formats).
    nonisolated static func image(_ buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image
    }

    /// How much of the picture the frame says changed (its rectangles are in the frame's pixels);
    /// nil when it doesn't say.
    private static func dirtyShare(_ info: [SCStreamFrameInfo: Any], width: Int, height: Int) -> Double? {
        guard let rects = info[.dirtyRects] as? [Any], !rects.isEmpty, width > 0, height > 0 else { return nil }
        var dirty: CGFloat = 0
        for r in rects {
            guard let d = r as? NSDictionary, let rect = CGRect(dictionaryRepresentation: d) else { return nil }
            dirty += rect.width * rect.height
        }
        return min(1, max(0, Double(dirty) / Double(width * height)))
    }

    #if DEBUG
    /// MACROPHONE_WATCH_TIMING=1: how many frames the window server gives a second (numbers only).
    private static let timing = ProcessInfo.processInfo.environment["MACROPHONE_WATCH_TIMING"] == "1"
    private var frameCount = 0, dirtyCount = 0, dirtyMax = 0.0, countedAt = Date()
    #endif

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
