import AVFoundation
import CoreMedia
import MacrophoneKit
import UIKit

/// The watched window's video, drawn by the system (Oct 17 2026, after Sill's HEVCDisplayView):
/// a view whose layer is an `AVSampleBufferDisplayLayer`, which decodes each HEVC frame in
/// hardware and puts it on screen itself — no decode into an image, no image into a view, nothing
/// through SwiftUI per frame. One for the watch, hosted by whichever viewer is on screen (the
/// window, or the strip while the mic is open); the Watcher owns it.
final class VideoCanvas: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    private var format: CMVideoFormatDescription?
    private var lastSets: [Data]?
    /// The frame's size, from the last parameter sets; zero before any.
    private(set) var frameSize = CGSize.zero
    /// A frame has been put on screen since the last clear.
    private(set) var hasFrame = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // Never stretched (Nov 9 2026, Sameer: "it ends up getting scrunched up"): a frame whose
        // size isn't the canvas's yet — the moment of a reshape — is fitted inside it, never
        // squeezed to it. In step, the canvas is the frame's own shape and this is the same.
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A keyframe's parameter sets make the decoder. Only a change (a new window, a resize) makes
    /// a new one and blanks the picture; the same sets again (every keyframe carries them) don't.
    private func apply(_ sets: [Data]) -> Bool {
        if sets == lastSets, format != nil { return true }
        var desc: CMVideoFormatDescription?
        let copies = sets.map { [UInt8]($0) }
        let sizes = copies.map(\.count)
        var pointers: [UnsafePointer<UInt8>] = []
        var status: OSStatus = noErr
        func collect(_ i: Int) {
            if i == copies.count {
                status = pointers.withUnsafeBufferPointer { pp in
                    sizes.withUnsafeBufferPointer { sp in
                        CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: copies.count, parameterSetPointers: pp.baseAddress!,
                                                                            parameterSetSizes: sp.baseAddress!, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
                    }
                }
                return
            }
            copies[i].withUnsafeBufferPointer { p in pointers.append(p.baseAddress!); collect(i + 1) }
        }
        collect(0)
        guard status == noErr, let desc else { return false }
        format = desc
        lastSets = sets
        let d = CMVideoFormatDescriptionGetDimensions(desc)
        let size = CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
        // A new size with a picture on screen (the Mac reshaped the window — Nov 8 2026, round 3):
        // the old frame stays up and the new one is held until the viewer has taken the new size
        // (`release`). Flushed at once, the layer went blank and then drew the new frame in the old
        // canvas — a bare pane with a small copy of the picture in it, and the still the viewer makes
        // of "the old picture" was made of the new frame stretched into the old frame's rect.
        if hasFrame, size != frameSize {
            holding = true
            frameSize = size
            displayLayer.sampleBufferRenderer.flush()
            return true
        }
        frameSize = size
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        hasFrame = false
        return true
    }

    /// A frame at a new size waits for the viewer (`apply`); the viewer lets it through once it
    /// has laid out for the new size — or it goes through by itself after a moment, if no viewer
    /// is there to.
    private var holding = false
    /// Every frame since the new size's keyframe, in order: each frame of a stream builds on the
    /// ones before it, so dropping all but the newest (as this did) left the decoder unable to show
    /// any of them — the old frame stayed up, stretched into the new canvas, until the next
    /// keyframe (the scrunched window of Nov 9 2026, with a real window that redraws all the time).
    private var held: [CMSampleBuffer] = []
    private var holdRelease: DispatchWorkItem?

    func release() {
        guard holding else { return }
        holding = false
        holdRelease?.cancel()
        holdRelease = nil
        let frames = held
        held = []
        for s in frames { displayLayer.sampleBufferRenderer.enqueue(s) }
        if !frames.isEmpty { hasFrame = true }
    }

    /// Puts a frame on screen as soon as it decodes. False when it can't be shown (no parameter
    /// sets yet, or the decoder failed): the caller then waits for a keyframe.
    func enqueue(_ frame: WatchVideoFrame) -> Bool {
        if let sets = frame.parameterSets, !apply(sets) { return false }
        guard let format else { return false }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            // iOS fails the decoder when the app leaves the screen. Reset it — and a keyframe still
            // goes in now (it was dropped here before, and the picture then waited seconds for the
            // next one).
            renderer.flush()
            guard frame.keyframe else { return false }
        }
        let n = frame.data.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: n, flags: 0, blockBufferOut: &block) == noErr, let block,
              CMBlockBufferAssureBlockMemory(block) == noErr,
              frame.data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: n) }) == noErr
        else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var size = n
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return false }
        // Shown the moment it decodes, not scheduled by a clock.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? NSArray,
           let first = attachments.firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately as String] = true
        }
        if holding {
            // A keyframe starts the run over; a run that grows long is cut back to its keyframe.
            if frame.keyframe { held = [] }
            held.append(sample)
            if held.count > 90 { held.removeFirst(held.count - 90) }
            if holdRelease == nil {
                let item = DispatchWorkItem { [weak self] in self?.release() }
                holdRelease = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
            }
            return true
        }
        renderer.enqueue(sample)
        hasFrame = true
        return true
    }

    /// A new watch, or pictures instead: the picture goes and the next keyframe starts over.
    /// A watch starting: a decoder iOS failed while the app was away is reset before frames come.
    func ready() {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
    }

    /// The frame on screen now, as the decoder left it (nil before any).
    func displayedFrame() -> CVPixelBuffer? {
        guard hasFrame, #available(iOS 17.4, *) else { return nil }
        return displayLayer.sampleBufferRenderer.displayedPixelBuffer()
    }

    func clear() {
        format = nil
        lastSets = nil
        frameSize = .zero
        hasFrame = false
        holding = false
        held = []
        holdRelease?.cancel()
        holdRelease = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}
