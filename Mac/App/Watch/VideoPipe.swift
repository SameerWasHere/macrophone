import CoreGraphics
import CoreVideo
import Foundation
import MacrophoneKit

/// A video watch's frames, end to end off the main thread (Oct 17 2026, after Sill's
/// WindowCapture → HEVCEncoder → network): the window's stream hands each frame here, the pacing
/// rule runs here, a due frame goes straight into the encoder's mailbox, and what the encoder gives
/// back goes onto the wire from a task of its own, in order — nothing per frame touches the main
/// actor. Everything lives on one serial queue (`queue`); the main-actor side (`WatchService`) only
/// sets what each frame carries (the app's name, the place to type, the question), asks for a
/// keyframe or a hurry, hears about a chip that can't keep up, and reads the counters at the end.
///
/// A still window sends nothing: a frame whose change doesn't earn a frame yet waits as `pending`
/// (the newest replaces it) and goes when the pace allows, by a timer here. The wire behind (two
/// frames handed to the encoder and not yet sent) holds the newest frame the same way — an
/// encoded frame is never dropped (the decoder needs each one), so the holding happens before
/// the encode.
final class VideoPipe: @unchecked Sendable {
    /// The words each frame carries, kept current by the main-actor side.
    struct Words: Sendable {
        var appName = ""
        var bundleID: String?
        var focus: CGRect?
        var prompt: WatchPrompt?
    }

    /// Where frames went (numbers only, for the log line).
    struct Stats: Sendable {
        var given = 0, givenChanged = 0, heldForPace = 0, heldForWire = 0
        var frameMs: [Int] = []
        var sendMs: [Int] = []
        var sentAt: [Date] = []
        var videoFrames = 0
    }

    private let queue = DispatchQueue(label: "macrophone.watch-video", qos: .userInteractive)
    private let peer: UUID
    private let server: LinkServer
    private let rate: Int
    private let timing: Bool
    private var encoder: VideoEncoder?
    private var pending: (pixels: CVPixelBuffer, at: Date)?
    private var lastSent: CVPixelBuffer?
    private var lastSentAt = Date.distantPast
    private var changedSince = 0.0
    /// The biggest single change since the question was last read.
    private var changedSinceRead = 0.0
    private var readAskedAt = Date.distantPast
    private var forceUntil = Date.distantPast
    /// Until when a swipe is under way: any change bigger than a caret then goes at the stream's
    /// rate — a chat column scrolling in a big window changes a small share of it, which reads
    /// as a highlight moving (one frame a second) otherwise.
    private var inputUntil = Date.distantPast
    /// When the last action from the phone happened, for timing prints.
    private var actionAt = Date.distantPast
    private var inFlight = 0
    private var seq = 0
    private var timerArmed = false
    private var stopped = false
    private var stats = Stats()
    private let lock = NSLock()
    private var words = Words()
    /// What goes out, in order: the sender task awaits each send.
    private let outgoing: AsyncStream<WatchVideoFrame>
    private let outgoingContinuation: AsyncStream<WatchVideoFrame>.Continuation
    private var sender: Task<Void, Never>?

    /// Called on `queue`: the chip can't keep up (sustained slow encodes, a hang, no encoder) —
    /// the watch goes on as pictures.
    var onFallback: (@Sendable (String) -> Void)?
    /// Called on `queue` with the frame just sent when the window has settled and the question
    /// may have changed: read it (off this queue) and call `readDone`, then `sendWords` if it did.
    var onSettled: (@Sendable (CVPixelBuffer) -> Void)?

    init(peer: UUID, server: LinkServer, rate: Int, timing: Bool) {
        self.peer = peer
        self.server = server
        self.rate = rate
        self.timing = timing
        (outgoing, outgoingContinuation) = AsyncStream.makeStream(of: WatchVideoFrame.self, bufferingPolicy: .unbounded)
        let stream = outgoing
        sender = Task.detached(priority: .userInitiated) { [weak self] in
            for await frame in stream {
                guard let self else { return }
                let t = Date()
                await server.send(.watchVideo(frame), to: peer)
                self.sent(frame, ms: Int(Date().timeIntervalSince(t) * 1000))
            }
        }
    }

    // MARK: From the main-actor side

    /// What the next frames carry.
    func set(_ w: Words) { lock.lock(); words = w; lock.unlock() }

    /// The next frame stands on its own: the last one again when nothing has changed since.
    func requestKeyframe() {
        queue.async {
            self.encoder?.requestKeyframe()
            if self.pending == nil, let last = self.lastSent { self.pending = (last, Date()); self.changedSince = 1 }
            self.forceUntil = Date().addingTimeInterval(2)
            self.drain()
        }
    }

    /// The next frame goes at once, whatever changed (an action just happened).
    func hurry() {
        queue.async {
            self.forceUntil = Date().addingTimeInterval(2)
            self.actionAt = Date()
            self.drain()
        }
    }

    /// A swipe's step or phase just came: the window is being scrolled.
    func swiped() {
        queue.async { self.inputUntil = Date().addingTimeInterval(0.5) }
    }

    /// The question was read off the frame `onSettled` gave.
    func readDone() { queue.async { self.changedSinceRead = 0 } }

    /// The words alone (the question, the place to type): a frame with nothing to decode.
    func sendWords() {
        queue.async {
            guard !self.stopped, let v = self.encoder else { return }
            self.seq += 1
            let w = self.currentWords
            self.outgoingContinuation.yield(WatchVideoFrame(seq: self.seq, data: Data(), parameterSets: nil, keyframe: false, width: v.width, height: v.height,
                                                            appName: w.appName, bundleID: w.bundleID, focus: w.focus, prompt: w.prompt))
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.pending = nil
            self.encoder = nil
            self.outgoingContinuation.finish()
        }
        sender?.cancel()
    }

    /// The counters, for the log line at the end.
    func snapshot() -> Stats { queue.sync { stats } }

    private var currentWords: Words { lock.lock(); defer { lock.unlock() }; return words }

    // MARK: From the window's stream

    /// A frame from the window, and how much of it changed since the last one given.
    func arrived(_ pixels: CVPixelBuffer, changed: Double) {
        queue.async {
            guard !self.stopped else { return }
            self.stats.given += 1
            if changed > 0 { self.stats.givenChanged += 1 }
            if self.timing, Date().timeIntervalSince(self.actionAt) < 3, changed >= WatchPacing.sliver {
                print("[watch] frame from the window \(Int(Date().timeIntervalSince(self.actionAt) * 1000)) ms after the action, \(String(format: "%.3f", changed)) changed\(self.pending == nil ? "" : ", one waiting")"); fflush(stdout)
            }
            self.pending = (pixels, Date())
            self.changedSince = min(1, self.changedSince + changed)
            self.changedSinceRead = max(self.changedSinceRead, changed)
            self.drain()
        }
    }

    /// queue: the pending frame goes into the encoder if the pace and the wire allow; else it
    /// waits here (a timer for the pace, the next send for the wire).
    private func drain() {
        guard !stopped, let (pixels, _) = pending else { return }
        let now = Date()
        let swiping = now < inputUntil && changedSince >= WatchPacing.sliver
        let interval = now < forceUntil ? 0 : WatchPacing.minimumInterval(changed: swiping ? max(changedSince, WatchPacing.small) : changedSince, quick: true, rate: rate)
        if interval == .infinity { pending = nil; return }
        let due = lastSentAt.addingTimeInterval(interval)
        if now < due {
            stats.heldForPace += 1
            if !timerArmed {
                timerArmed = true
                queue.asyncAfter(deadline: .now() + due.timeIntervalSince(now)) { self.timerArmed = false; self.drain() }
            }
            return
        }
        if inFlight >= 2 { stats.heldForWire += 1; return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        // A new size (the window was resized, Aa): a new encoder.
        if let v = encoder, v.width != width & ~1 || v.height != height & ~1 { encoder = nil }
        if encoder == nil {
            guard let v = try? VideoEncoder(width: width, height: height, rate: rate) else {
                stopped = true
                onFallback?("the video encoder didn't start")
                return
            }
            v.onEncoded = { [weak self] e, took in self?.queue.async { self?.encoded(e, took: took) } }
            v.onHung = { [weak self] in
                self?.queue.async {
                    guard let self, !self.stopped else { return }
                    self.stopped = true
                    self.onFallback?("the video encoder returned nothing for \(Int(VideoEncoder.hangAfter * 1000)) ms")
                }
            }
            encoder = v
        }
        guard let encoder else { return }
        switch encoder.submit(pixels) {
        case .goesIn: inFlight += 1
        case .waits(let replaced): if !replaced { inFlight += 1 }
        case .dropped: stopped = true; onFallback?("the video encoder gave up"); return
        }
        lastSentAt = now
        changedSince = 0
        forceUntil = .distantPast
        lastSent = pixels
        pending = nil
        // The window has settled (nothing newer waits) and something bigger than a caret changed
        // since the question was read: read it again, at most about once a second.
        if changedSinceRead >= WatchPacing.unreadable, now.timeIntervalSince(readAskedAt) > 0.8 {
            readAskedAt = now
            onSettled?(pixels)
        }
    }

    /// queue: the encoder gave a frame's bytes — onto the wire, in order.
    private func encoded(_ e: VideoEncoder.Encoded, took: TimeInterval) {
        guard !stopped, let v = encoder else { return }
        if stats.frameMs.count < 4000 { stats.frameMs.append(Int(took * 1000)) }
        stats.videoFrames += 1
        seq += 1
        stats.sentAt.append(Date())
        let w = currentWords
        outgoingContinuation.yield(WatchVideoFrame(seq: seq, data: e.data, parameterSets: e.parameterSets, keyframe: e.keyframe,
                                                   width: v.width, height: v.height, appName: w.appName, bundleID: w.bundleID, focus: w.focus, prompt: w.prompt))
        if timing { print("[watch] video encode \(Int(took * 1000)) · \(e.data.count / 1024) KB\(e.keyframe ? " key" : "")"); fflush(stdout) }
        // A video chip busy elsewhere for good: pictures from here on.
        if v.struggling {
            stopped = true
            onFallback?("the Mac's video encoder is busy")
        }
    }

    /// The sender: a frame is on the wire.
    private func sent(_ frame: WatchVideoFrame, ms: Int) {
        queue.async {
            if !frame.isWordsOnly {
                self.inFlight = max(0, self.inFlight - 1)
                if self.stats.sendMs.count < 4000 { self.stats.sendMs.append(ms) }
            }
            self.drain()
        }
    }
}
