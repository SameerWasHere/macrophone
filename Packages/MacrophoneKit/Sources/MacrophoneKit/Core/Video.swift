import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
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
    /// Watching the whole screen (DesktopWatch): the app in front, so the phone can go to its
    /// window. Nil otherwise (an older Mac never sends it).
    public var front: FrontApp?
    /// The window's size in points on the Mac (Oct 19 2026): the phone's trackpad moves the pointer
    /// in those, so a 1× display or a picture narrowed for a remote link moves it right. Nil from a
    /// Mac from before (the phone then takes the picture as a Retina window at full size).
    public var points: CGSize?

    public init(seq: Int, data: Data, parameterSets: [Data]?, keyframe: Bool, width: Int, height: Int,
                appName: String, bundleID: String?, focus: CGRect?, prompt: WatchPrompt? = nil, front: FrontApp? = nil, points: CGSize? = nil) {
        self.front = front
        self.points = points
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

/// HEVC, hardware, real time, no B-frames — and never waited on (Oct 17 2026, after Sill's
/// HEVCEncoder). A frame is handed in (`submit`) and the call returns at once: one frame is inside
/// VideoToolbox at a time, the next waits in a one-slot mailbox where a newer frame replaces it,
/// so the loop that sends frames is never behind an encode and a slow encoder drops frames
/// instead of queueing them. Each encoded frame comes back on `onEncoded`, in order, with how long
/// it took. A watchdog gives up on a session that holds a frame for `hangAfter` seconds
/// (`onHung`; the Mac then sends pictures). Made per watch; a new one starts on a keyframe.
public final class VideoEncoder: @unchecked Sendable {
    public struct Encoded: Sendable {
        public var data: Data
        public var parameterSets: [Data]?
        public var keyframe: Bool
    }

    /// What became of a frame handed in.
    public enum Admission: Equatable, Sendable {
        /// Into VideoToolbox now.
        case goesIn
        /// The encoder is busy: it waits, and `replaced` says it pushed out an older waiting frame.
        case waits(replaced: Bool)
        /// The encoder is dead (the watchdog gave up on it): dropped.
        case dropped
    }

    public let width: Int
    public let height: Int
    private let rate: Int
    private let session: VTCompressionSession
    /// Encoding in software (asked for — a proof, a test).
    public let software: Bool
    /// Called on VideoToolbox's thread with each frame's bytes, in the order the frames went in,
    /// and the seconds from hand-over to output.
    public var onEncoded: (@Sendable (Encoded, TimeInterval) -> Void)?
    /// Called once, on the watchdog's queue, when a frame has been inside VideoToolbox for
    /// `hangAfter` seconds with no output. The encoder is dead afterwards: it drops every frame.
    public var onHung: (@Sendable () -> Void)?

    private let lock = NSLock()
    /// The frame inside VideoToolbox: when it went in. Nil while the place is free.
    private var insideSince: TimeInterval?
    /// The newest frame that found the place taken.
    private var waiting: CVPixelBuffer?
    private var dead = false
    private var keyframeWanted = true
    private var frames = 0
    private var lastParameterSets: [Data]?
    private var health = EncoderHealth()
    private let encodeQueue = DispatchQueue(label: "macrophone.video-encode", qos: .userInteractive)
    /// Its own queue: a hung VideoToolbox hangs inside the encode call on `encodeQueue`, and a timer
    /// queued behind it would never fire.
    private let watchdogQueue = DispatchQueue(label: "macrophone.video-watchdog", qos: .utility)
    private var watchdog: DispatchSourceTimer?
    /// A frame inside this long with no output: the session is given up on.
    public static let hangAfter: TimeInterval = 1.5

    /// Bits a second for the picture's size: enough that text stays crisp — about 2 bits a pixel at
    /// the rate the window's stream runs (most of the time far fewer frames go, and a frame that
    /// goes alone gets the whole budget).
    public static func bitrate(width: Int, height: Int, rate: Int) -> Int {
        max(2_000_000, min(40_000_000, width * height * 2 * rate / 10))
    }

    public init(width: Int, height: Int, rate: Int = 30, software: Bool = false) throws {
        // HEVC wants even sizes.
        self.width = width & ~1
        self.height = height & ~1
        self.rate = rate
        self.software = software
        session = try Self.makeSession(width: self.width, height: self.height, rate: rate, software: software)
        let t = DispatchSource.makeTimerSource(queue: watchdogQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.checkWatchdog() }
        t.resume()
        watchdog = t
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
        // Latency over polish: a frame out sooner beats a slightly smaller one.
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
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
        watchdog?.cancel()
        lock.lock()
        let stalled = dead && insideSince != nil
        lock.unlock()
        // Never tear a live session down with a frame still inside the hardware encoder (Sill saw
        // that wedge the chip for every later session until a reboot): a live one is drained
        // first, which can take a frame's time; a dead one is never waited on, since a stuck
        // encoder never lets go — so none of this runs on the caller's thread.
        let session = self.session
        DispatchQueue.global(qos: .utility).async {
            if !stalled { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
            VTCompressionSessionInvalidate(session)
        }
    }

    /// The next frame stands on its own (a phone asked, or came back).
    public func requestKeyframe() { lock.lock(); keyframeWanted = true; lock.unlock() }

    /// The watchdog gave up on this session.
    public var isDead: Bool { lock.lock(); defer { lock.unlock() }; return dead }

    /// The chip can't keep up (`EncoderHealth`): most recent frames were slow, or it stalled
    /// twice. The watch then goes on as pictures.
    public var struggling: Bool { lock.lock(); defer { lock.unlock() }; return health.struggling }

    /// Hands a frame in and returns at once; its bytes come back on `onEncoded`.
    @discardableResult
    public func submit(_ buffer: CVPixelBuffer) -> Admission {
        lock.lock()
        guard !dead else { lock.unlock(); return .dropped }
        if insideSince != nil {
            let replaced = waiting != nil
            waiting = buffer
            lock.unlock()
            return .waits(replaced: replaced)
        }
        insideSince = CACurrentMediaTime()
        lock.unlock()
        encodeQueue.async { [weak self] in self?.encodeNow(buffer) }
        return .goesIn
    }

    /// Encodes one frame and waits for its bytes — a proof or a test; the Mac submits. Nil when
    /// the encoder gave nothing within a few seconds.
    public func encode(_ buffer: CVPixelBuffer) -> Encoded? {
        let box = Box()
        let was = onEncoded
        onEncoded = { e, _ in box.set(e) }
        submit(buffer)
        box.wait()
        onEncoded = was
        return box.take()
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var e: Encoded?
        func set(_ v: Encoded) { lock.lock(); e = v; lock.unlock(); done.signal() }
        func wait() { _ = done.wait(timeout: .now() + 5) }
        func take() -> Encoded? { lock.lock(); defer { lock.unlock() }; return e }
    }

    /// encodeQueue: the frame goes into VideoToolbox; its handler frees the place and lets the
    /// waiting frame in.
    private func encodeNow(_ buffer: CVPixelBuffer) {
        lock.lock()
        guard !dead else { lock.unlock(); return }
        let key = keyframeWanted
        keyframeWanted = false
        let pts = CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
        frames += 1
        insideSince = CACurrentMediaTime()
        lock.unlock()
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                                     frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard let self else { return }
            let encoded: Encoded? = status == noErr && sb != nil ? self.encoded(sb!) : nil
            // The forced keyframe was dropped (real time over the data-rate cap): ask again, or a
            // phone waiting for one would wait for good on a still window.
            self.returned(encoded, keyframeLost: key && encoded == nil)
        }
        if status != noErr { returned(nil, keyframeLost: key) }
    }

    /// VideoToolbox's thread (or `encodeNow`, on a refusal): the place is free, the frame's bytes
    /// go out, and the waiting frame goes in.
    private func returned(_ e: Encoded?, keyframeLost: Bool) {
        lock.lock()
        guard !dead, let since = insideSince else { lock.unlock(); return }
        let took = CACurrentMediaTime() - since
        insideSince = nil
        if keyframeLost { keyframeWanted = true }
        if !software, e != nil { health.record(took: took) }
        let next = waiting
        waiting = nil
        if next != nil { insideSince = CACurrentMediaTime() }
        lock.unlock()
        if let e { onEncoded?(e, took) }
        if let next { encodeQueue.async { [weak self] in self?.encodeNow(next) } }
    }

    /// watchdogQueue, every 0.5 s.
    private func checkWatchdog() {
        lock.lock()
        let hung = !dead && insideSince.map { CACurrentMediaTime() - $0 > Self.hangAfter } ?? false
        if hung { dead = true; waiting = nil }
        lock.unlock()
        guard hung else { return }
        watchdog?.cancel()
        onHung?()
    }

    private func encoded(_ sb: CMSampleBuffer) -> Encoded? {
        lock.lock()
        let repeatSets = lastParameterSets
        lock.unlock()
        var remember = repeatSets
        let e = Self.encoded(sb, repeatSets: repeatSets, remember: &remember)
        if e?.keyframe == true { lock.lock(); lastParameterSets = remember; lock.unlock() }
        return e
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

/// Whether the hardware encoder is keeping up, from how long its frames take (pure). The first
/// few encodes, while the encoder settles in, and a lone spike don't count — switching on those
/// made a whole session slow. Most of the last eight slow, or two stalls, and the chip is busy
/// elsewhere (screen sharing, a call, a recording): the watch goes on as pictures, which take a
/// few milliseconds on any Mac — never software video, which takes fifty, too slow to scroll.
public struct EncoderHealth: Sendable, Equatable {
    /// A hardware encode this long (seconds — a free one takes a few milliseconds) is the encoder
    /// busy elsewhere; at thirty frames a second the budget is a thirtieth.
    public static let slowEncode = 0.05
    /// One this long is a stall.
    public static let stalledEncode = 0.5
    /// Encodes not judged while the encoder settles in.
    public static let settling = 4
    public static let window = 8

    private var seen = 0
    private var recent: [Double] = []
    private var stalls = 0
    public private(set) var struggling = false

    public init() {}

    /// One frame came back after `took` seconds.
    public mutating func record(took: TimeInterval) {
        seen += 1
        guard seen > Self.settling else { return }
        recent.append(took)
        if recent.count > Self.window { recent.removeFirst() }
        if took >= Self.stalledEncode { stalls += 1 }
        let slow = recent.filter { $0 >= Self.slowEncode }.count
        if (recent.count >= 6 && slow * 2 > recent.count) || stalls >= 2 { struggling = true }
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
