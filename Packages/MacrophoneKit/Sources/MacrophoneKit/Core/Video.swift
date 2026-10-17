import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// Video instead of still pictures (Oct 17 2026): the watched window goes as HEVC — the Mac's
// hardware encoder, real time, no B-frames — and the phone decodes it. A frame still goes only
// when the window changed (the same pacing as the pictures), so a still window costs nothing;
// what changes is the size of each one: a scrolling terminal that cost a 200 KB JPEG per picture
// costs a few KB per frame, and the picture is sharper, because text is what HEVC keeps.
//
// Gated by the hello: a phone that names "video" in its features gets `watchVideo` frames; any
// other phone keeps getting `watchFrame` JPEGs (an unknown message ends a session, so an App
// Store phone from before must never see one). The Mac names its own features in the welcome
// ("video", "fit"), so a new phone never sends an old Mac a keyframe request or a fit.

/// What the two sides name in their hello / welcome.
public enum WatchVideo {
    /// The phone decodes HEVC (`watchVideo`) and asks for keyframes (`watchKeyframe`).
    public static let feature = "video"
    /// The Mac resizes the watched window for readable text (`watchFit`).
    public static let fitFeature = "fit"
}

/// One frame of the watched window as video. Sent only when the window changed.
public struct WatchVideoFrame: Codable, Sendable {
    public var seq: Int
    /// HEVC NAL units, each after a 4-byte big-endian length (as VideoToolbox gives them). Empty
    /// when only the words changed (the question, the place to type): nothing to decode.
    public var data: Data
    /// VPS, SPS and PPS — with every keyframe (the decoder is made from them).
    public var parameterSets: [Data]?
    /// The frame stands on its own; every other one needs the frames before it.
    public var keyframe: Bool
    public var width: Int
    public var height: Int
    public var appName: String
    public var bundleID: String?
    /// Where the place to type is, as a fraction of the window (`WatchFrame.focus`).
    public var focus: CGRect?
    /// The question the window is asking, read off the window on the Mac (`WatchFrame.prompt`).
    public var prompt: WatchPrompt?

    public init(seq: Int, data: Data, parameterSets: [Data]?, keyframe: Bool, width: Int, height: Int,
                appName: String, bundleID: String?, focus: CGRect?, prompt: WatchPrompt? = nil) {
        self.seq = seq
        self.data = data
        self.parameterSets = parameterSets
        self.keyframe = keyframe
        self.width = width
        self.height = height
        self.appName = appName
        self.bundleID = bundleID
        self.focus = focus
        self.prompt = prompt
    }

    /// Only the words changed: nothing to decode, the picture on screen stays.
    public var isWordsOnly: Bool { data.isEmpty }
}

/// How the Mac's window is sized for the phone (Oct 17 2026, "Aa"): as it is, or narrower and
/// taller — about the phone's shape — so its text reads larger on the phone (the phone fits the
/// window's width across its screen: fewer columns means bigger letters; a window 420 points wide
/// shows its text on the phone at nearly the size it has on the Mac). The Mac keeps the window
/// that way while it's watched and puts it back when watching stops, unless someone moved or
/// resized it on the Mac meanwhile.
public enum WatchFit: String, Codable, Sendable, CaseIterable {
    case normal
    case larger
    case largest

    /// The word on the phone's menu.
    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .larger: return "Larger"
        case .largest: return "Largest"
        }
    }

    /// The window's width, in points: nil leaves it as it is. A phone's watch view is about 370
    /// points wide, so a 560-point window shows at two thirds of its size and a 420-point one at
    /// nearly full size (about 70 and 52 columns of a terminal's text).
    public var width: CGFloat? {
        switch self {
        case .normal: return nil
        case .larger: return 560
        case .largest: return 420
        }
    }

    /// What the Mac does for it, as a line for the phone: "Claude's window is narrower, so its
    /// text reads larger here".
    public func explanation(appName: String) -> String {
        switch self {
        case .normal: return "\(appName)'s window is back to its own size"
        case .larger: return "\(appName)'s window is narrower, so its text reads larger here"
        case .largest: return "\(appName)'s window is as narrow as it goes, so its text reads largest here"
        }
    }

    /// The frame for a window of `frame` under `fit`, kept inside `area` (the display's visible
    /// frame, top-left origin): the full height, the width from the fit, the top-left corner
    /// where it was (nudged in if it would hang off the edge), never wider than the window is now.
    public func frame(for frame: CGRect, in area: CGRect) -> CGRect? {
        guard let wanted = width else { return nil }
        let height = area.height
        let width = min(frame.width, wanted, area.width)
        let x = min(max(frame.minX, area.minX), area.maxX - width)
        return CGRect(x: x, y: area.minY, width: width, height: height)
    }
}

/// Frames are not pictures: an older one can't be skipped (the next needs it), and a decode that
/// fails means waiting for the next keyframe.
public extension WatchVideoFrame {
    /// Whether this frame can be decoded now: the first after a keyframe was asked for must be
    /// one; otherwise the next in sequence (a watch the Mac started over begins again at 1).
    static func canDecode(seq: Int, keyframe: Bool, newest: Int, waitingForKeyframe: Bool) -> Bool {
        if keyframe { return true }
        if waitingForKeyframe { return false }
        return seq == newest + 1
    }
}

// MARK: Encoding (the Mac, mpctl)

/// HEVC, hardware, real time, no B-frames: one frame in, its bytes out, on the caller's thread.
/// Made per watch; a new one starts on a keyframe. When the hardware encoder runs slow (another
/// app has it — screen sharing, a call — and a frame takes a third of a second or more) the rest
/// of the watch is encoded in software, which keeps up at these sizes and rates.
/// One caller at a time (the watch's own loop); hence Sendable by hand.
public final class VideoEncoder: @unchecked Sendable {
    public struct Encoded: Sendable {
        public var data: Data
        public var parameterSets: [Data]?
        public var keyframe: Bool
    }

    public let width: Int
    public let height: Int
    private let rate: Int
    private var session: VTCompressionSession
    /// Encoding in software (asked for).
    public private(set) var software: Bool
    /// The hardware can't keep up (Oct 17 2026): most of the recent encodes were slow, or it stalled
    /// twice. The watch then goes on as pictures — a JPEG takes a few milliseconds, while software
    /// video takes fifty, too slow for a window scrolling at ten frames a second. The first few
    /// encodes, while the encoder settles in, and a lone spike don't count: switching on those made
    /// a whole session slow.
    public private(set) var struggling = false
    private var recent: [Double] = []
    private var stalls = 0
    private var frames = 0
    private var lastParameterSets: [Data]?
    /// The next frame is a keyframe (asked for, or the first).
    private var keyframeWanted = true
    /// A hardware encode this long (seconds — a free one takes a few milliseconds) is the encoder
    /// busy elsewhere.
    public static let slowEncode = 0.06
    /// One this long is a stall.
    public static let stalledEncode = 0.5
    /// Encodes not judged while the encoder settles in.
    public static let settling = 4

    /// Bits a second for the picture's size: enough that text stays crisp — about 2 bits a pixel at
    /// the rate the window's stream runs (ten a second at most; most of the time far fewer go, and
    /// a frame that goes alone gets the whole budget).
    public static func bitrate(width: Int, height: Int, rate: Int) -> Int {
        max(2_000_000, min(40_000_000, width * height * 2 * rate / 10))
    }

    public init(width: Int, height: Int, rate: Int = 10, software: Bool = false) throws {
        // HEVC wants even sizes.
        self.width = width & ~1
        self.height = height & ~1
        self.rate = rate
        self.software = software
        session = try Self.makeSession(width: self.width, height: self.height, rate: rate, software: software)
    }

    private static func makeSession(width: Int, height: Int, rate: Int, software: Bool) throws -> VTCompressionSession {
        var s: VTCompressionSession?
        // The choice of encoder is the Mac's (the phone only decodes); the key is macOS's.
        var spec: [CFString: Any] = [:]
        #if os(macOS)
        spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = !software
        #endif
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec.isEmpty ? nil : spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let session = s else { throw VideoError.encoder(status) }
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(session, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // A keyframe every few seconds of frames, besides the ones asked for. Frames are stamped
        // by count, not the clock: a window that changes once a minute isn't paying a keyframe
        // each time, and a lost frame is never silent — the phone asks for a keyframe.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (rate * 4) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 4 as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, rate as CFNumber)
        let bitrate = Self.bitrate(width: width, height: height, rate: rate)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8 * 3 / 2, 1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// The next frame stands on its own (a phone asked, or came back).
    public func requestKeyframe() { keyframeWanted = true }

    /// Encodes one frame and waits for its bytes. Nil when the encoder gave nothing (it's then
    /// best to make a new one).
    public func encode(_ buffer: CVPixelBuffer) -> Encoded? {
        let key = keyframeWanted
        keyframeWanted = false
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let pts = CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
        let box = Box()
        let started = Date()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                                     frameProperties: props, infoFlagsOut: nil) { status, _, sb in
            guard status == noErr, let sb else { box.signal(); return }
            box.set(sb)
        }
        guard status == noErr else { return nil }
        box.wait()
        guard let sb = box.take() else { return nil }
        frames += 1
        let took = Date().timeIntervalSince(started)
        if !software, frames > Self.settling {
            recent.append(took)
            if recent.count > 8 { recent.removeFirst() }
            if took >= Self.stalledEncode { stalls += 1 }
            let slow = recent.filter { $0 >= Self.slowEncode }.count
            if (recent.count >= 6 && slow * 2 > recent.count) || stalls >= 2 { struggling = true }
        }
        return Self.encoded(sb, repeatSets: lastParameterSets, remember: &lastParameterSets)
    }

    /// The encoded frame, handed from VideoToolbox's thread to the caller's.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var sb: CMSampleBuffer?
        func set(_ s: CMSampleBuffer) { lock.lock(); sb = s; lock.unlock(); done.signal() }
        func signal() { done.signal() }
        /// A frame that never comes back (a wedged encoder) is given up on after a while.
        func wait() { _ = done.wait(timeout: .now() + 5) }
        func take() -> CMSampleBuffer? { lock.lock(); defer { lock.unlock() }; return sb }
    }

    /// The bytes of an encoded frame, with the parameter sets when it's a keyframe.
    static func encoded(_ sb: CMSampleBuffer, repeatSets: [Data]?, remember: inout [Data]?) -> Encoded? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { p in CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: p.baseAddress!) }
        guard copied == noErr else { return nil }
        let notSync = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let keyframe = !notSync
        var sets: [Data]?
        if keyframe, let desc = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                                  parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr {
                var list: [Data] = []
                for i in 0..<count {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                                                                             parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr else { break }
                    list.append(Data(bytes: ptr, count: size))
                }
                if list.count == count { sets = list }
            }
            if sets == nil { sets = repeatSets }
            remember = sets
        }
        return Encoded(data: data, parameterSets: sets, keyframe: keyframe)
    }

    /// A picture as a pixel buffer the encoder takes (BGRA). For a drawn window (`mpctl serve`).
    public static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let w = image.width & ~1, h = image.height & ~1
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }
}

// MARK: Decoding (the phone, mpctl watch)

/// The other end: parameter sets make the session, each frame comes back as BGRA pixels on the
/// caller's thread. Frames must come in order; after a failure, wait for a keyframe.
/// One caller at a time (the phone's decode queue); hence Sendable by hand.
public final class VideoDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sets: [Data]?

    public init() {}

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodes a frame. Throws when it can't (then ask for a keyframe and wait for it).
    public func decode(_ frame: WatchVideoFrame) throws -> CVPixelBuffer {
        if let ps = frame.parameterSets, ps != sets || session == nil {
            try makeSession(ps)
        }
        guard let session, let format else { throw VideoError.noKeyframe }
        let sb = try Self.sampleBuffer(frame.data, format: format)
        let box = Box()
        var flags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: &flags) { status, _, image, _, _ in
            if status == noErr, let image { box.set(image) }
        }
        guard status == noErr, let image = box.take() else { throw VideoError.decoder(status) }
        return image
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CVPixelBuffer?
        func set(_ i: CVPixelBuffer) { lock.lock(); image = i; lock.unlock() }
        func take() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return image }
    }

    private func makeSession(_ ps: [Data]) throws {
        if let session { VTDecompressionSessionInvalidate(session); self.session = nil }
        var desc: CMVideoFormatDescription?
        let status: OSStatus = ps.withPointers { pointers, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: ps.count, parameterSetPointers: pointers,
                                                                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else { throw VideoError.decoder(status) }
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        var s: VTDecompressionSession?
        let made = VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil,
                                                imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &s)
        guard made == noErr, let s else { throw VideoError.decoder(made) }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        format = desc
        sets = ps
    }

    private static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        let n = data.count
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: n, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw VideoError.decoder(status) }
        status = data.withUnsafeBytes { p in CMBlockBufferReplaceDataBytes(with: p.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: n) }
        guard status == noErr else { throw VideoError.decoder(status) }
        var sb: CMSampleBuffer?
        var size = n
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                           sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        guard status == noErr, let sb else { throw VideoError.decoder(status) }
        return sb
    }

    /// The decoded pixels as an image (for a view that draws images, or a file).
    public static func image(_ buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image
    }
}

public enum VideoError: Error, Equatable {
    case encoder(OSStatus)
    case decoder(OSStatus)
    /// No keyframe has arrived yet (or since the last failure).
    case noKeyframe
}

private extension Array where Element == Data {
    /// The parameter sets as C pointers for the one call that makes the format description.
    func withPointers<R>(_ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let copies = map { [UInt8]($0) }
        let sizes = copies.map(\.count)
        var pointers: [UnsafePointer<UInt8>] = []
        func collect(_ i: Int, _ done: () -> R) -> R {
            if i == copies.count { return done() }
            return copies[i].withUnsafeBufferPointer { p in
                pointers.append(p.baseAddress!)
                return collect(i + 1, done)
            }
        }
        return collect(0) {
            pointers.withUnsafeBufferPointer { pp in sizes.withUnsafeBufferPointer { sp in body(pp.baseAddress!, sp.baseAddress!) } }
        }
    }
}
