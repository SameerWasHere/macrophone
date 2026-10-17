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
        displayLayer.videoGravity = .resize
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
        frameSize = CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        hasFrame = false
        return true
    }

    /// Puts a frame on screen as soon as it decodes. False when it can't be shown (no parameter
    /// sets yet, or the decoder failed): the caller then waits for a keyframe.
    func enqueue(_ frame: WatchVideoFrame) -> Bool {
        if let sets = frame.parameterSets, !apply(sets) { return false }
        guard let format else { return false }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            return false
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
        renderer.enqueue(sample)
        hasFrame = true
        return true
    }

    /// A new watch, or pictures instead: the picture goes and the next keyframe starts over.
    func clear() {
        format = nil
        lastSets = nil
        frameSize = .zero
        hasFrame = false
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}
