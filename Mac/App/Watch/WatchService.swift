import AppKit
import Carbon.HIToolbox
import Foundation
import ImageIO
import MacrophoneKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Watching (Oct 14 2026): a connected phone asks to see the window of the place it sends to, and
/// this sends it pictures of that one window — plus the phone's keys (Esc, ↑, ↓, Return) and
/// clicks where it's tapped. Never the whole screen, never another window; it stops when the
/// phone stops looking or goes away.
///
/// The pictures come from a stream of the window (Oct 16 2026, `WindowStream`): the window server
/// hands one over only when the window changed, so a still window costs nothing, and a change
/// shows on the phone in a fraction of a second. How much changed decides how soon the next
/// picture goes (`WatchPacing`): a caret or a spinner every few seconds, new output at once.
/// A loop every 1.5 s only checks the window is still there and on screen.
///
/// To a phone that named "video" in its hello the frames go as HEVC (Oct 17 2026, `VideoEncoder`:
/// hardware, real time, a keyframe on start, when the phone asks and every few seconds) — the
/// same gating, a frame only when the window changed, but a few KB each instead of a JPEG; any
/// other phone keeps getting pictures. A phone that asks (Aa) gets the window sized for readable
/// text (`WindowFit`), put back when the watch ends.
///
/// Needs Screen Recording for the pictures (the phone says so and can open the setting here) and
/// Accessibility for the actions (which pasting already needs).
@MainActor
final class WatchService {
    private unowned let app: AppModel

    private final class Watch {
        let peer: UUID
        var target: TargetRef
        var task: Task<Void, Never>?
        /// The window being shown, once found. Kept for the watch's life unless it goes away.
        var windowID: CGWindowID?
        var pid: pid_t = 0
        var bundleID: String?
        var appName = ""
        var focus: CGRect?
        var focusAt = Date.distantPast
        var lastState: WatchState?
        var seq = 0
        /// The stream of the window's pictures, while it's on screen.
        var stream: WindowStream?
        /// The newest picture not sent yet, and how much of the window changed since the last one sent.
        var latest: CVPixelBuffer?
        var latestSeq = 0
        var changedSince = 0.0
        /// The biggest single change since the question was last read.
        var changedSinceRead = 0.0
        var lastSentAt = Date.distantPast
        /// Until when the next picture goes at once, whatever changed (an action just happened).
        var forceUntil = Date.distantPast
        var hurriedAt = Date.distantPast
        var sendTask: Task<Void, Never>?
        /// The question the window is asking, as last read (sent with each picture).
        var prompt: WatchPrompt?
        /// When it's asked with real controls (a question card), the controls to press.
        var axPrompt: AXPrompt?
        var promptAt = Date.distantPast
        /// The phone decodes video (its hello named it); else it gets pictures.
        var wantsVideo = false
        /// Milliseconds each frame took to encode (video) or make (pictures), for the line the log
        /// gets when the watch ends — numbers only.
        var frameMs: [Int] = []
        var videoFrames = 0
        /// The window's video encoder, made with the stream (and again when the size changes).
        var video: VideoEncoder?
        /// The last frame sent, to send again as a keyframe when the phone asks and nothing changed.
        var lastSent: CVPixelBuffer?
        /// The encoder's first encode, off the first picture (a JPEG), so the second picture
        /// doesn't wait for it — the hardware's first frame can take a second.
        var warming: Task<Void, Never>?
        /// The window sized for readable text (Aa), to put back when the watch ends — and the
        /// size the phone asked for, applied once the window is found.
        var fit: WindowFit.Record?
        var wantedFit: WatchFit = .normal
        /// The wait between looks, so an action can cut it short.
        private var waiting: CheckedContinuation<Void, Never>?
        private var waitTimer: Task<Void, Never>?
        /// The wait before the next picture is due (pacing), cut short by an action.
        private var pacing: Task<Void, Never>?
        init(peer: UUID, target: TargetRef) { self.peer = peer; self.target = target }

        /// Sleeps `seconds`, or until `wake()` — one timer, no polling in between.
        @MainActor func wait(_ seconds: Double) async {
            await withCheckedContinuation { c in
                waiting = c
                waitTimer = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                    self?.wake()
                }
            }
        }

        /// Look again right away (an action just happened).
        @MainActor func wake() {
            waitTimer?.cancel()
            waitTimer = nil
            let c = waiting
            waiting = nil
            c?.resume()
        }

        @MainActor func pause(_ seconds: Double) async {
            let t: Task<Void, Never> = Task { _ = try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9)) }
            pacing = t
            await t.value
            pacing = nil
        }

        /// The next picture goes now, whatever changed (an action just happened).
        @MainActor func hurry() {
            forceUntil = Date().addingTimeInterval(2)
            hurriedAt = Date()
            pacing?.cancel()
            pacing = nil
        }

        @MainActor func dropStream() {
            video = nil
            warming?.cancel()
            warming = nil
            lastSent = nil
            guard let s = stream else { return }
            stream = nil
            latest = nil
            Task { await s.stop() }
        }

        /// Puts a window sized for the phone back to its own size and place.
        @MainActor func restoreFit() {
            guard let r = fit else { return }
            fit = nil
            WindowFit.restore(r)
        }
    }

    private var watches: [UUID: Watch] = [:]
    private var content: SCShareableContent?
    private var contentAt = Date.distantPast
    private var askedForPermission = false
    /// The widest picture sent, in pixels — narrower over a remote link (away from home), where
    /// every picture crosses a slower path.
    static let maxWidth: CGFloat = 1500
    static let remoteMaxWidth: CGFloat = 1000
    private func maxWidth(for w: Watch) -> CGFloat { app.isRemote(w.peer) ? Self.remoteMaxWidth : Self.maxWidth }

    /// Who's watching what, for the menu ("Your iPhone is watching Claude").
    private(set) var watching: [UUID: String] = [:]
    var onChange: () -> Void = {}

    init(app: AppModel) { self.app = app }

    #if DEBUG
    /// MACROPHONE_WATCH_TIMING=1: one line per picture with what each stage cost (numbers only).
    private let timing = ProcessInfo.processInfo.environment["MACROPHONE_WATCH_TIMING"] == "1"
    #else
    private let timing = false
    #endif
    private static func ms(_ t: DispatchTime) -> Int { Int((DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000) }

    static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    // MARK: Start / stop

    func set(_ target: TargetRef?, for peer: UUID) {
        guard let target else { stop(peer); return }
        if let w = watches[peer] {
            if w.target != target {
                w.restoreFit()
                w.wantedFit = .normal
                w.target = target
                w.windowID = nil
                w.dropStream()
                w.focus = nil
                w.focusAt = .distantPast
            }
            w.wake()
            return
        }
        let w = Watch(peer: peer, target: target)
        w.wantsVideo = app.server.phones(with: WatchVideo.feature).contains(peer)
        watches[peer] = w
        app.log.add("watching started (\(AppModel.kind(SendSelection(target: target))), \(w.wantsVideo ? "video" : "pictures"))")
        w.task = Task { [weak self] in await self?.run(w) }
    }

    func stop(_ peer: UUID) {
        guard let w = watches.removeValue(forKey: peer) else { return }
        w.task?.cancel()
        w.sendTask?.cancel()
        if w.fit != nil { app.log.add("watch fit: the window goes back to its own size") }
        if !w.frameMs.isEmpty {
            let ms = w.frameMs.sorted()
            app.log.add("watching: \(ms.count) frames (\(w.videoFrames) video) · median \(ms[ms.count / 2]) ms · slowest tenth \(ms[ms.count * 9 / 10]) ms to make")
        }
        w.restoreFit()
        w.dropStream()
        w.wake()
        watching[peer] = nil
        onChange()
        app.log.add("watching stopped")
    }

    func stopAll() { watches.keys.forEach(stop) }

    /// The windows phones are looking at now.
    var watchedWindows: Set<CGWindowID> { Set(watches.values.compactMap(\.windowID)) }

    // MARK: The loop — is the window there?

    private func run(_ w: Watch) async {
        while !Task.isCancelled, watches[w.peer] === w {
            let state = await look(w)
            if state != w.lastState {
                w.lastState = state
                if case .live(let name) = state { watching[w.peer] = name } else { watching[w.peer] = nil }
                onChange()
                await app.server.send(.watchState(state), to: w.peer)
            }
            if !Task.isCancelled { await w.wait(1.5) }
        }
    }

    /// One check: the window is there and on screen, the stream is running, and where the place
    /// to type is. Returns how watching is going.
    private func look(_ w: Watch) async -> WatchState {
        // Where to look.
        if let reason = await resolve(w) { w.dropStream(); return reason }
        guard let wid = w.windowID, let place = WindowServer.info(wid) else {
            w.windowID = nil
            w.dropStream()
            return .unavailable("\(w.appName)'s window isn't open", canReveal: false)
        }

        // Permission: ask once per launch, then only look. Touching ScreenCaptureKit while it's off
        // raises the system prompt again — every look, when the grant is stale.
        if !CGPreflightScreenCaptureAccess() {
            if !askedForPermission {
                askedForPermission = true
                app.log.add("watching: Screen Recording is off — asked once")
                CGRequestScreenCaptureAccess()
            }
            w.dropStream()
            return .needsPermission
        }
        guard place.onScreen else {
            return .unavailable("\(w.appName)'s window is minimized or on another desktop", canReveal: true)
        }
        // The size the phone asked for before the window was found (Aa).
        if w.wantedFit != .normal, w.fit == nil { applyFit(w) }

        if let s = w.stream {
            await s.resize(to: place.bounds.size, maxWidth: maxWidth(for: w))
        } else {
            guard let scw = await scWindow(wid) else {
                w.windowID = nil
                return .unavailable("\(w.appName)'s window isn't open", canReveal: false)
            }
            let s = WindowStream(window: scw, maxWidth: maxWidth(for: w), maxRate: w.wantsVideo ? WindowStream.videoRate : WindowStream.pictureRate)
            s.onFrame = { [weak self, weak w, weak s] pixels, changed in
                Task { @MainActor in
                    guard let self, let w, let s, w.stream === s else { return }
                    self.arrived(pixels, changed: changed, w)
                }
            }
            s.onStop = { [weak self, weak w, weak s] _ in
                Task { @MainActor in
                    guard let self, let w, w.stream === s else { return }
                    w.dropStream()
                    self.content = nil
                    w.wake()
                }
            }
            do { try await s.start() } catch {
                if !CGPreflightScreenCaptureAccess() { return .needsPermission }
                content = nil
                app.log.add("watching: the window's stream didn't start")
                return .unavailable("Couldn't see \(w.appName)'s window", canReveal: true)
            }
            w.stream = s
            w.forceUntil = Date().addingTimeInterval(5)
            app.log.add("watching: streaming the window")
        }

        // Where the place to type is (every few seconds; off the main thread — it walks the window).
        if Date().timeIntervalSince(w.focusAt) > 5 {
            w.focusAt = Date()
            let pid = w.pid, bid = w.bundleID
            w.focus = await Task.detached(priority: .utility) { Self.focusRect(pid: pid, windowID: wid, bundleID: bid) }.value ?? w.focus
        }
        return .live(appName: w.appName)
    }

    // MARK: Pictures

    /// A new picture from the stream: the newest wins; it goes when the pacing allows.
    private func arrived(_ pixels: CVPixelBuffer, changed: Double, _ w: Watch) {
        if timing, Date() < w.forceUntil, w.hurriedAt != .distantPast { print("[watch] picture \(Int(Date().timeIntervalSince(w.hurriedAt) * 1000)) ms after the action, \(String(format: "%.4f", changed)) changed"); fflush(stdout) }
        w.latest = pixels
        w.latestSeq &+= 1
        w.changedSince = min(1, w.changedSince + changed)
        w.changedSinceRead = max(w.changedSinceRead, changed)
        if w.sendTask == nil { w.sendTask = Task { [weak self] in await self?.drain(w) } }
    }

    /// Sends pictures as they're due, newest first, until none is waiting.
    private func drain(_ w: Watch) async {
        while watches[w.peer] === w, !Task.isCancelled, let pixels = w.latest {
            let seq = w.latestSeq
            let interval = Date() < w.forceUntil ? 0 : WatchPacing.minimumInterval(changed: w.changedSince, video: w.wantsVideo)
            if interval == .infinity { w.latest = nil; continue }
            let due = w.lastSentAt.addingTimeInterval(interval)
            if Date() < due { await w.pause(due.timeIntervalSinceNow); continue }
            // Video, from the second picture on: the first goes as a JPEG, which is on the phone in
            // tens of milliseconds, while the encoder warms up on the same pixels (its first frame
            // can take a second on a busy Mac).
            if w.wantsVideo, w.seq > 0 {
                await sendVideo(pixels, w)
                if w.latestSeq == seq { w.latest = nil }
                continue
            }
            // Only a picture that goes is made into an image (a copy of the window's pixels).
            guard let image = await Task.detached(priority: .utility, operation: { WindowStream.image(pixels) }).value else { w.latest = nil; continue }
            if w.wantsVideo { warm(pixels, w) }
            // The question it's asking: read after the picture is out (about once a second at most),
            // and the picture sent again with it when it changed.
            await send(image, w)
            if w.latestSeq == seq { w.latest = nil }
            if w.latest == nil, await readPrompt(w, image) { await send(image, w) }
        }
        w.sendTask = nil
    }

    /// The encoder, made and run once on the first picture while that picture goes as a JPEG, so
    /// its warm-up never delays a frame; the first real frame after it is a keyframe.
    private func warm(_ pixels: CVPixelBuffer, _ w: Watch) {
        guard w.video == nil, w.warming == nil, let v = try? VideoEncoder(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels), rate: WindowStream.videoRate) else { return }
        w.video = v
        w.lastSent = pixels
        w.warming = Task.detached(priority: .utility) {
            _ = v.encode(pixels)
            v.requestKeyframe()
        }
    }

    /// One frame of video: encoded (the encoder made with the stream's size, again when it changes),
    /// the question read off the same pixels when it's due, sent with the words. When the phone
    /// hasn't decoded yet (the first frame) the question is read right after and sent alone if it
    /// changed — nothing to decode, the picture stays.
    private func sendVideo(_ pixels: CVPixelBuffer, _ w: Watch) async {
        let t = DispatchTime.now()
        if let warming = w.warming { await warming.value; w.warming = nil }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        // A new size (the window was resized, Aa): a new encoder — in software still, if the last
        // one found the hardware busy.
        var software = false
        if let v = w.video, v.width != width & ~1 || v.height != height & ~1 { software = v.software; w.video = nil }
        if w.video == nil {
            guard let v = try? VideoEncoder(width: width, height: height, rate: WindowStream.videoRate, software: software) else {
                app.log.add("watching: the video encoder didn't start — pictures instead")
                w.wantsVideo = false
                return
            }
            w.video = v
        }
        guard let encoder = w.video else { return }
        let encoded = await Task.detached(priority: .userInitiated) { encoder.encode(pixels) }.value
        let encodeMs = Self.ms(t)
        if w.frameMs.count < 2000 { w.frameMs.append(encodeMs) }
        w.videoFrames += 1
        guard let encoded else {
            // The encoder gave nothing: a new one next time, starting on a keyframe.
            w.video = nil
            return
        }
        w.seq += 1
        w.lastSentAt = Date()
        w.changedSince = 0
        w.forceUntil = .distantPast
        w.lastSent = pixels
        let frame = WatchVideoFrame(seq: w.seq, data: encoded.data, parameterSets: encoded.parameterSets, keyframe: encoded.keyframe,
                                    width: encoder.width, height: encoder.height, appName: w.appName, bundleID: w.bundleID, focus: w.focus, prompt: w.prompt)
        await app.server.send(.watchVideo(frame), to: w.peer)
        if timing { print("[watch] video encode \(encodeMs)\(encoder.software ? " (software)" : "") · send \(encoded.data.count / 1024) KB\(encoded.keyframe ? " key" : "") \(Self.ms(t) - encodeMs)"); fflush(stdout) }
        // The question is read after the frame is out (a read takes 50–100 ms; a frame waiting on
        // it was a hitch every second while scrolling); its answers follow in a frame of words.
        // Not while newer frames wait (a swipe): it's read once the window settles.
        let newer = w.latest.map { $0 !== pixels } ?? false
        if !newer, promptDue(w), let image = await Task.detached(priority: .utility, operation: { WindowStream.image(pixels) }).value,
           await readPrompt(w, image) {
            await sendWords(w)
        }
        // A video chip busy elsewhere for good: pictures from here on (this watch only).
        if encoder.struggling {
            app.log.add("watching: the Mac's video encoder is busy — pictures instead")
            w.wantsVideo = false
            w.video = nil
        }
    }

    /// The words alone (the question, the place to type): a frame with nothing to decode.
    private func sendWords(_ w: Watch) async {
        guard w.wantsVideo, let v = w.video else { return }
        w.seq += 1
        let frame = WatchVideoFrame(seq: w.seq, data: Data(), parameterSets: nil, keyframe: false, width: v.width, height: v.height,
                                    appName: w.appName, bundleID: w.bundleID, focus: w.focus, prompt: w.prompt)
        await app.server.send(.watchVideo(frame), to: w.peer)
    }

    /// The phone wants a frame that stands on its own (it started, came back, or lost one): the
    /// next frame is a keyframe — the last one again, when the window hasn't changed since.
    func keyframe(for peer: UUID) {
        guard let w = watches[peer], w.wantsVideo else { return }
        w.video?.requestKeyframe()
        if w.latest == nil, let last = w.lastSent {
            w.latest = last
            w.latestSeq &+= 1
            w.changedSince = 1
        }
        w.hurry()
        if w.latest != nil, w.sendTask == nil { w.sendTask = Task { [weak self] in await self?.drain(w) } }
    }

    /// The question is worth reading again: not within a second of the last read, and only once
    /// something bigger than a caret or a spinner changed since.
    private func promptDue(_ w: Watch) -> Bool {
        w.windowID != nil && Date().timeIntervalSince(w.promptAt) > 0.8 && (w.changedSinceRead >= WatchPacing.unreadable || w.promptAt == .distantPast)
    }

    /// Reads the question off the window (controls first — exact, Claude's question card — else
    /// the picture, only the conversation's column of it, so a sidebar of chats isn't read in).
    /// Not for a caret or a spinner: only once something bigger than that changed since the last
    /// read (text recognition takes a tenth of a second). Returns whether it changed.
    private func readPrompt(_ w: Watch, _ image: CGImage) async -> Bool {
        guard let wid = w.windowID, promptDue(w) else { return false }
        w.promptAt = Date()
        w.changedSinceRead = 0
        let t = DispatchTime.now()
        let pid = w.pid
        let ax = Paster.isTrusted ? await Task.detached(priority: .utility) { AXPrompt.read(pid: pid, windowID: wid) }.value : nil
        w.axPrompt = ax
        let column = w.focus.map { max(0, Double($0.minX) - 0.04)...min(1, Double($0.maxX) + 0.02) }
        let p: WatchPrompt? = if let ax { ax.prompt } else { await PromptVision.read(image, column: column) }
        if timing { print("[watch] prompt(\(ax != nil ? "ax" : "vision")) \(Self.ms(t))"); fflush(stdout) }
        guard p != w.prompt else { return false }
        w.prompt = p
        return true
    }

    private func send(_ image: CGImage, _ w: Watch) async {
        let t = DispatchTime.now()
        // Encoding a window-sized JPEG takes a few milliseconds: off the main thread, so the menu,
        // the popup and a paste never wait on a picture.
        let remote = app.isRemote(w.peer)
        guard let data = await Task.detached(priority: .utility) { Self.encode(image, remote: remote) }.value else { return }
        let encoded = Self.ms(t)
        if w.frameMs.count < 2000 { w.frameMs.append(encoded) }
        w.seq += 1
        w.lastSentAt = Date()
        w.changedSince = 0
        w.forceUntil = .distantPast
        let frame = WatchFrame(seq: w.seq, jpeg: data, width: image.width, height: image.height,
                               appName: w.appName, bundleID: w.bundleID, focus: w.focus, prompt: w.prompt)
        // Waits until it's on the wire: a slow link gets fewer pictures, never a backlog.
        await app.server.send(.watchFrame(frame), to: w.peer)
        if timing { print("[watch] encode \(encoded) · send \(data.count / 1024) KB \(Self.ms(t) - encoded)"); fflush(stdout) }
    }

    /// Finds the window to show (once; again only when it's gone). Nil = found.
    private func resolve(_ w: Watch) async -> WatchState? {
        if let id = w.windowID, WindowServer.exists(id),
           NSRunningApplication(processIdentifier: w.pid).map({ !$0.isTerminated }) ?? false {
            return nil
        }
        w.windowID = nil
        switch w.target {
        case .clipboard:
            return .unavailable("Clipboard has no window — pick an app to watch it", canReveal: false)
        case .frontApp:
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.bundleIdentifier != Bundle.main.bundleIdentifier else {
                return .unavailable("No app is in front on your Mac", canReveal: false)
            }
            return await adopt(front, windowKey: nil, w)
        case let .app(bundleID, windowKey, name):
            guard let r = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }) else {
                let n = Paster.installedName(bundleID) ?? Paster.appName(fromTitle: name)
                return .unavailable("\(n) isn't open on your Mac", canReveal: false)
            }
            return await adopt(r, windowKey: windowKey, w)
        }
    }

    private func adopt(_ r: NSRunningApplication, windowKey: String?, _ w: Watch) async -> WatchState? {
        let name = r.localizedName ?? "The app"
        w.pid = r.processIdentifier
        w.bundleID = r.bundleIdentifier
        w.appName = name
        if let windowKey, let id = CGWindowID(windowKey) {
            guard WindowServer.exists(id) else { return .unavailable("That \(name) window is closed", canReveal: false) }
            w.windowID = id
            return nil
        }
        // The app: the window the person last typed in, else its front-most one.
        let mine = WindowServer.appWindows().filter { $0.pid == r.processIdentifier }.sorted { $0.z < $1.z }
        let hints = await app.scanner.hints(for: r.processIdentifier)
        if let last = hints.lastWindow, mine.contains(where: { $0.id == last }) {
            w.windowID = last
        } else if let composer = hints.windows.first(where: { c in mine.contains { $0.id == c.id } }) {
            w.windowID = composer.id
        } else if let first = mine.first {
            w.windowID = first.id
        } else {
            return .unavailable("\(name) has no window open", canReveal: true)
        }
        return nil
    }

    private func refreshContent() async throws -> SCShareableContent {
        let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        content = c
        contentAt = Date()
        return c
    }

    private func scWindow(_ id: CGWindowID) async -> SCWindow? {
        if let c = content, Date().timeIntervalSince(contentAt) < 3, let w = c.windows.first(where: { $0.windowID == id }) { return w }
        guard let c = try? await refreshContent() else { return nil }
        return c.windows.first { $0.windowID == id }
    }

    /// The picture for the wire. A very large one is encoded again smaller, so a frame always
    /// fits the link.
    nonisolated static func encode(_ image: CGImage, remote: Bool = false) -> Data? {
        // Away from home the link is slower: a little more compression, a lower ceiling.
        guard let data = jpeg(image, quality: remote ? 0.45 : 0.6) else { return nil }
        if data.count > (remote ? 400_000 : 900_000), let smaller = jpeg(image, quality: 0.35) { return smaller }
        return data
    }

    nonisolated static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// The place to type, as a fraction of the window (so the phone can centre on that column).
    nonisolated static func focusRect(pid: pid_t, windowID: CGWindowID, bundleID: String?) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let ax = AX.app(pid)
        guard let win = AX.window(in: ax, id: windowID) else { return nil }
        let wf = AX.frame(win)
        guard wf.width > 50, wf.height > 50 else { return nil }
        let scan = ComposerFinder.scan(window: win, bundleID: bundleID, focused: AX.focused(in: ax), timeLimit: 0.3)
        guard let c = scan.composer ?? scan.best else { return nil }
        let f = c.frame.intersection(wf)
        guard !f.isNull, f.width > 20 else { return nil }
        return CGRect(x: (f.minX - wf.minX) / wf.width, y: (f.minY - wf.minY) / wf.height,
                      width: f.width / wf.width, height: f.height / wf.height)
    }

    // MARK: Actions

    func perform(_ action: WatchAction, for peer: UUID) {
        if action == .openScreenRecordingSettings {
            NSWorkspace.shared.open(Self.screenRecordingSettingsURL)
            app.log.add("watching: opened Screen Recording settings")
            return
        }
        act(on: peer, what: action.rawValue) { wid in
            switch action {
            case .returnKey: Keys.press(CGKeyCode(kVK_Return), flags: [])
            case .escape: Keys.press(CGKeyCode(kVK_Escape), flags: [])
            case .arrowUp: Keys.press(CGKeyCode(kVK_UpArrow), flags: [.maskNumericPad, .maskSecondaryFn])
            case .arrowDown: Keys.press(CGKeyCode(kVK_DownArrow), flags: [.maskNumericPad, .maskSecondaryFn])
            case .scrollUp, .scrollDown: await Self.scroll(window: wid, up: action == .scrollUp)
            case .reveal, .openScreenRecordingSettings: break
            }
        }
    }

    /// Readable text (Aa): size the watched window for the phone, or put it back. The next picture
    /// follows the new shape, and the place to type is read again.
    func fit(_ f: WatchFit, for peer: UUID) {
        guard let w = watches[peer] else { return }
        w.wantedFit = f
        // Not found yet: applied when it is (`look`).
        if w.windowID != nil { applyFit(w) }
    }

    private func applyFit(_ w: Watch) {
        guard let wid = w.windowID else { return }
        let f = w.wantedFit
        guard Paster.isTrusted else {
            app.log.add("watch fit skipped: Accessibility not granted")
            return
        }
        let r = WindowFit.apply(f, pid: w.pid, windowID: wid, record: w.fit)
        if f == .normal {
            w.fit = nil
            app.log.add("watch fit: the window is back to its own size")
        } else if let r {
            w.fit = r
            app.log.add("watch fit \(f.rawValue): \(Int(r.original.width))×\(Int(r.original.height)) → \(Int(r.applied.width))×\(Int(r.applied.height))")
        } else {
            app.log.add("watch fit \(f.rawValue): the window didn't take the size")
        }
        w.focusAt = .distantPast
        w.hurry()
        w.wake()
    }

    /// A swipe on the phone's picture: scroll the window right there, as the finger moves.
    func scroll(at p: CGPoint, by d: CGVector, for peer: UUID) {
        act(on: peer, what: "scroll", quiet: true) { wid in Self.scroll(window: wid, at: p, by: d) }
    }

    /// Where the pointer was before a swipe moved it; put back once the swipe has paused.
    private static var cursorBeforeScroll: CGPoint?
    private static var restoreCursor: Task<Void, Never>?

    private static func scroll(window id: CGWindowID, at p: CGPoint, by d: CGVector) {
        guard let b = WindowServer.appWindows().first(where: { $0.id == id })?.bounds else { return }
        let pt = CGPoint(x: b.minX + p.x * b.width, y: b.minY + p.y * b.height)
        if cursorBeforeScroll == nil { cursorBeforeScroll = CGEvent(source: nil)?.location }
        CGWarpMouseCursorPosition(pt)
        // Content follows the finger: dragging down shows what's above (a positive wheel).
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                        wheel1: Int32((d.dy * b.height).rounded()), wheel2: Int32((d.dx * b.width).rounded()), wheel3: 0)
        e?.location = pt
        e?.post(tap: .cghidEventTap)
        restoreCursor?.cancel()
        restoreCursor = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let c = cursorBeforeScroll else { return }
            CGWarpMouseCursorPosition(c)
            cursorBeforeScroll = nil
        }
    }

    /// A tap on the phone's picture: a click at that spot in the window.
    /// An answer tapped on the phone: the keys that give it, if the window still asks that question.
    func choose(_ promptID: String, index: Int, for peer: UUID) {
        // A question card: press its controls where they are; the window stays where it is.
        if let w = watches[peer], let p = w.prompt, p.id == promptID, p.style == .pressed, let ax = w.axPrompt {
            w.promptAt = .distantPast
            act(on: peer, what: "choose") { [weak self] _ in
                guard let pt = ax.point(for: index) else { self?.app.log.add("watch choose: the card's controls are gone"); return }
                await Self.click(at: pt)
                try? await Task.sleep(nanoseconds: 150_000_000)
                if !ax.pressSubmit() { self?.app.log.add("watch choose: Submit didn't press") }
            }
            return
        }
        guard let w = watches[peer], let p = w.prompt, p.id == promptID, let keys = p.keys(for: index) else {
            app.log.add("watch choose skipped: the window moved on")
            return
        }
        w.promptAt = .distantPast
        act(on: peer, what: "choose") { _ in
            for k in keys {
                switch k {
                case .up: Keys.press(CGKeyCode(kVK_UpArrow), flags: [.maskNumericPad, .maskSecondaryFn])
                case .down: Keys.press(CGKeyCode(kVK_DownArrow), flags: [.maskNumericPad, .maskSecondaryFn])
                case .returnKey: Keys.press(CGKeyCode(kVK_Return), flags: [])
                case let .character(c):
                    let fallback = c == "y" ? kVK_ANSI_Y : c == "n" ? kVK_ANSI_N : nil
                    guard let code = Keys.code(for: c) ?? fallback.map({ CGKeyCode($0) }) else { return }
                    Keys.press(code, flags: [])
                }
                // A beat between keys, so a menu redraws before the next arrow.
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    func click(_ p: CGPoint, for peer: UUID) {
        act(on: peer, what: "click") { wid in await Self.click(window: wid, at: p) }
    }

    /// Brings the watched window forward if it isn't already the front one, does `body`, and
    /// shows the result: the next picture the window gives goes at once (a swipe's scrolling
    /// keeps its pace — ten pictures a second would swamp the link).
    private func act(on peer: UUID, what: String, quiet: Bool = false, _ body: @escaping @MainActor (CGWindowID) async -> Void) {
        guard let w = watches[peer], let wid = w.windowID,
              let running = NSRunningApplication(processIdentifier: w.pid), !running.isTerminated else { return }
        guard Paster.isTrusted else {
            app.log.add("watch \(what) skipped: Accessibility not granted")
            return
        }
        let name = w.appName
        Task { [weak self] in
            let frontWindow = WindowServer.appWindows().first { $0.z == 0 }?.id
            let inFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier && frontWindow == wid
            if !inFront || what == WatchAction.reveal.rawValue {
                do { _ = try await Paster.bringToFront(running, windowID: wid, required: true, name: name) } catch {
                    self?.app.log.add("watch \(what): window didn't come forward")
                    return
                }
            }
            if !quiet { w.hurry() }
            await body(wid)
            if !quiet { self?.app.log.add("watch \(what)") }
            w.wake()
        }
    }

    /// A left click at a fraction of the window. The pointer goes there for the click and is put back.
    private static func click(window id: CGWindowID, at p: CGPoint) async {
        guard let b = WindowServer.appWindows().first(where: { $0.id == id })?.bounds else { return }
        await click(at: CGPoint(x: b.minX + p.x * b.width, y: b.minY + p.y * b.height))
    }

    /// A left click at a point on screen; the pointer goes back where it was.
    private static func click(at pt: CGPoint) async {
        let original = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 40_000_000)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        down?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)
        up?.setIntegerValueField(.mouseEventClickState, value: 1)
        up?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 150_000_000)
        if let original { CGWarpMouseCursorPosition(original) }
    }

    /// A page of scrolling over the window's middle, as a few smooth steps. The pointer is moved
    /// there for the scroll and put back.
    private static func scroll(window id: CGWindowID, up: Bool) async {
        guard let bounds = WindowServer.appWindows().first(where: { $0.id == id })?.bounds else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let original = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(center)
        let step = Int32(max(40, bounds.height * 0.12)) * (up ? 1 : -1)
        for _ in 0..<5 {
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: step, wheel2: 0, wheel3: 0)
            e?.location = center
            e?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        if let original { CGWarpMouseCursorPosition(original) }
    }
}
