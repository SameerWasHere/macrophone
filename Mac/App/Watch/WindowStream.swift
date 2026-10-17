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
    /// is sent is three a second; more only costs the window server).
    static let maxRate: Int32 = 6

    init(window: SCWindow, maxWidth: CGFloat) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        scale = CGFloat(filter.pointPixelScale)
        let (cfg, size) = Self.configuration(for: window.frame.size, scale: scale, maxWidth: maxWidth)
        self.size = size
        windowSize = window.frame.size
        stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        super.init()
    }

    private static func configuration(for window: CGSize, scale: CGFloat, maxWidth: CGFloat) -> (SCStreamConfiguration, (Int, Int)) {
        let cfg = SCStreamConfiguration()
        let pxW = max(1, window.width * scale), pxH = max(1, window.height * scale)
        let k = min(1, maxWidth / pxW)
        cfg.width = Int(pxW * k)
        cfg.height = Int(pxH * k)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: maxRate)
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

    /// The window was resized: pictures follow its new shape.
    func resize(to window: CGSize, maxWidth: CGFloat) async {
        guard window != windowSize else { return }
        let (cfg, size) = Self.configuration(for: window, scale: scale, maxWidth: maxWidth)
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
        // How much changed: the frame's own list of changed rectangles when it says a sliver (a
        // caret), else measured from a sample of the pixels — an Electron app redraws its whole
        // window for a caret, and the list says so. Read in place: no copy for a frame that won't go.
        let share: Double
        if let bound = Self.dirtyShare(info, width: width, height: height), bound < WatchPacing.sliver, previous != nil {
            share = bound
        } else {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let sample = CVPixelBufferGetBaseAddress(buffer).map {
                WatchChange.sample(base: UnsafeRawPointer($0), width: width, height: height,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), bytesPerPixel: 4)
            } ?? []
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            share = previous.map { WatchChange.changedShare($0, sample) } ?? 1
            previous = sample
        }
        onFrame(buffer, share)
    }

    /// The picture, for a frame that goes out.
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

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
