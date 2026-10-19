import CoreMedia
import Foundation
import MacrophoneKit
import ScreenCaptureKit

/// The Mac's sound for the phones that asked for it (Oct 19 2026): one ScreenCaptureKit stream of
/// the main display's audio — the whole system mix, Macrophone's own sounds left out — while any
/// phone has Sound on, none otherwise. Its own stream, not the watched window's: the sound goes on
/// across a flip to another window, a resize or video turning to pictures, and a window's stream
/// is never rebuilt for it. A window watch hears everything the Mac plays, not only that app.
///
/// Off for every phone until that phone turns Sound on (`watchSound(true)`, only from a phone that
/// named MacSound.feature); off again when it turns it off, stops watching or goes away. Each
/// listener has its own sender (Opus, 96 kbps at home, 40 away) and its own task sending in
/// order; the capture's buffers arrive on the stream's queue and never touch the main actor.
final class AudioPipe: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private final class Listener: @unchecked Sendable {
        let peer: UUID
        let remote: Bool
        let sender: MacAudioSender
        let continuation: AsyncStream<MacAudioPacket>.Continuation
        let task: Task<Void, Never>
        var sent = 0
        init(peer: UUID, remote: Bool, sender: MacAudioSender, server: LinkServer) {
            self.peer = peer
            self.remote = remote
            self.sender = sender
            let (stream, continuation) = AsyncStream.makeStream(of: MacAudioPacket.self, bufferingPolicy: .bufferingNewest(25))
            self.continuation = continuation
            task = Task.detached(priority: .high) {
                for await p in stream {
                    await server.send(.macAudio(p), to: peer)
                }
            }
        }
    }

    private let server: LinkServer
    private let log: DiagnosticLog
    private let queue = DispatchQueue(label: "macrophone.mac-audio", qos: .userInteractive)
    private let lock = NSLock()
    private var listeners: [UUID: Listener] = [:]
    private var stream: SCStream?
    private var starting = false
    /// Frames since the capture began, by the buffers' own clock (a jump is a gap).
    private var origin: CMTime?
    private var interleaved: [Float] = []
    /// DEBUG `MACROPHONE_SOUND_TONE=1`: the test tone instead of the capture (no Screen Recording needed).
    private var toneTimer: DispatchSourceTimer?
    private var tone = TestTone()
    private var tonePosition: Int64 = 0
    private var buffers = 0

    init(server: LinkServer, log: DiagnosticLog) {
        self.server = server
        self.log = log
    }

    #if DEBUG
    private static let useTone = ProcessInfo.processInfo.environment["MACROPHONE_SOUND_TONE"] == "1"
    #else
    private static let useTone = false
    #endif

    // MARK: Who hears it (main actor)

    /// A phone turned Sound on or off. Only a phone that named the feature and turned it on hears anything.
    @MainActor func set(_ on: Bool, for peer: UUID, remote: Bool) {
        let named = Set(server.phones(with: MacSound.feature).contains(peer) ? [MacSound.feature] : [])
        let wants = MacSound.sends(phoneFeatures: named, turnedOn: on)
        let existing = lock.sync { listeners[peer] }
        if wants, let existing, existing.remote == remote { return }
        if existing != nil { remove(peer) }
        guard wants else { return }
        guard let sender = try? MacAudioSender(remote: remote) else {
            log.add("sound: no encoder")
            return
        }
        let l = Listener(peer: peer, remote: remote, sender: sender, server: server)
        let first = lock.sync { () -> Bool in listeners[peer] = l; return listeners.count == 1 }
        log.add("sound on for a phone (\(sender.encoder.codec.rawValue), \(sender.encoder.bitrate / 1000) kbps\(remote ? ", away from home" : ""))")
        if first { start() }
    }

    /// The phone stopped watching or went away.
    @MainActor func remove(_ peer: UUID) {
        let (l, none) = lock.sync { () -> (Listener?, Bool) in
            let l = listeners.removeValue(forKey: peer)
            return (l, listeners.isEmpty)
        }
        guard let l else { return }
        l.continuation.finish()
        log.add("sound off: \(l.sent) packets, \(l.sender.gaps) gaps")
        if none { stop() }
    }

    @MainActor func removeAll() { lock.sync { Array(listeners.keys) }.forEach(remove) }

    // MARK: The capture

    @MainActor private func start() {
        guard stream == nil, !starting else { return }
        if Self.useTone { startTone(); return }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    log.add("sound: no display to capture from")
                    return
                }
                let cfg = SCStreamConfiguration()
                cfg.capturesAudio = true
                cfg.excludesCurrentProcessAudio = true
                cfg.sampleRate = MacSound.sampleRate
                cfg.channelCount = MacSound.channels
                // The picture is only the stream's price of admission: as small and as rare as it goes.
                cfg.width = 2
                cfg.height = 2
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                cfg.showsCursor = false
                cfg.queueDepth = 3
                let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                // A screen output that drops its frames: without one the stream logs every frame it drops.
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                guard lock.sync({ !listeners.isEmpty }) else { return }
                try await s.startCapture()
                stream = s
                queue.async { self.origin = nil }
                log.add("sound: capturing the Mac's audio")
            } catch {
                log.add("sound: capture didn't start (\((error as NSError).code))")
            }
        }
    }

    @MainActor private func stop() {
        toneTimer?.cancel()
        toneTimer = nil
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if self.stream === stream { self.stream = nil }
            self.log.add("sound: the capture stopped (\((error as NSError).code))")
            // Still wanted: start again (a display change ends a stream).
            if self.lock.sync({ !self.listeners.isEmpty }) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.start()
            }
        }
    }

    /// The stream's queue: a buffer of the Mac's audio, Float32 at 48 kHz.
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        // How long ago the buffer's first frame was heard: its clock is the host's.
        let age = max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds - pts.seconds)
        let now = Date().timeIntervalSince1970
        if origin == nil { origin = pts }
        let position = Int64(((pts - origin!).seconds * Double(MacSound.sampleRate)).rounded())
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
                                                                             bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2),
                                                                             blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                             flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer)
        guard status == noErr else { return }
        interleave(list, frames: frames, channels: Int(asbd.mChannelsPerFrame), nonInterleaved: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
        feed(position: position, capturedAt: now - age)
    }

    /// Two planes (the stream's way) or one interleaved buffer, to interleaved stereo.
    private func interleave(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, channels: Int, nonInterleaved: Bool) {
        interleaved = [Float](repeating: 0, count: frames * MacSound.channels)
        if nonInterleaved {
            guard let first = buffers.first else { return }
            let left = first.mData?.assumingMemoryBound(to: Float.self)
            let right = (buffers.count > 1 ? buffers[1] : first).mData?.assumingMemoryBound(to: Float.self)
            guard let left, let right else { return }
            for i in 0..<frames { interleaved[i * 2] = left[i]; interleaved[i * 2 + 1] = right[i] }
        } else if let d = buffers.first?.mData?.assumingMemoryBound(to: Float.self), channels > 0 {
            for i in 0..<frames {
                interleaved[i * 2] = d[i * channels]
                interleaved[i * 2 + 1] = d[i * channels + (channels > 1 ? 1 : 0)]
            }
        }
    }

    /// The queue: frames to every listener's sender, packets to its wire.
    private func feed(position: Int64, capturedAt: Double) {
        buffers += 1
        let all = lock.sync { Array(listeners.values) }
        let now = Date().timeIntervalSince1970
        for l in all {
            for p in l.sender.packets(interleaved, at: position, capturedAt: capturedAt, now: now) {
                l.continuation.yield(p)
                l.sent += 1
            }
        }
    }

    // MARK: The test tone (DEBUG)

    @MainActor private func startTone() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        let started = Date()
        queue.async { self.tonePosition = 0 }
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Catch up to the clock in 10 ms chunks, as a capture hands them over.
            let due = Int64(Date().timeIntervalSince(started) * Double(MacSound.sampleRate))
            while self.tonePosition + 480 <= due {
                self.interleaved = self.tone.next(frames: 480)
                let at = Date().timeIntervalSince1970 - Double(due - self.tonePosition) / Double(MacSound.sampleRate)
                self.feed(position: self.tonePosition, capturedAt: at - 0.01)
                self.tonePosition += 480
            }
        }
        t.resume()
        toneTimer = t
        log.add("sound: the test tone (MACROPHONE_SOUND_TONE)")
    }
}
