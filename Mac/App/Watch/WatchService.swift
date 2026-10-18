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
/// To a phone that named "video" in its hello the frames go as HEVC (Oct 17 2026, `VideoPipe`:
/// the window's stream, the pacing, the encoder's mailbox and the wire on their own queue — no
/// frame touches the main actor; a chip that can't keep up turns the watch to pictures), at
/// thirty a second while the window scrolls. Any other phone keeps getting pictures, from here.
/// Swipes go the same way (`ScrollPoster`: the link hands each step straight to it). A phone that
/// asks (Aa) gets the window sized for readable text (`WindowFit`), put back when the watch ends.
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
        /// Milliseconds each picture took to make, for the line the log gets when the watch ends
        /// — numbers only; and when each went, for the peak a second. (Video's are the pipe's.)
        var frameMs: [Int] = []
        var sentAt: [Date] = []
        /// Video, off the main thread: made with the stream, gone with it.
        var pipe: VideoPipe?
        /// The question being read off the latest frame (one read at a time, off the send path).
        var reading: Task<Void, Never>?
        /// Swipes, off the main thread.
        let poster: ScrollPoster
        /// When the window was last seen in front: a swipe's steps skip the check for a moment
        /// (each one listed every window on the Mac, thirty times a second, on the thread that
        /// sends the pictures).
        var inFrontAt = Date.distantPast
        /// The window sized for readable text (Aa), to put back when the watch ends — and the
        /// size the phone asked for, applied once the window is found.
        var fit: WindowFit.Record?
        var wantedFit: WatchFit = .normal
        /// The window's frame before the first Window menu size (Back to How It Was).
        var beforeWindowChanges: CGRect?
        /// The wait between looks, so an action can cut it short.
        private var waiting: CheckedContinuation<Void, Never>?
        private var waitTimer: Task<Void, Never>?
        /// The wait before the next picture is due (pacing), cut short by an action.
        private var pacing: Task<Void, Never>?
        init(peer: UUID, target: TargetRef, timing: Bool) { self.peer = peer; self.target = target; poster = ScrollPoster(timing: timing) }

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
            pipe?.hurry()
        }

        @MainActor func dropStream() {
            pipe?.stop()
            pipe = nil
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
    /// The swipe posters by phone, for the link's receive loop (no main actor between): guarded
    /// by the lock, not the actor.
    private nonisolated let postersLock = NSLock()
    private nonisolated(unsafe) var posters: [UUID: ScrollPoster] = [:]
    private var content: SCShareableContent?
    private var contentAt = Date.distantPast
    private var askedForPermission = false
    /// The widest picture sent, in pixels — narrower over a remote link (away from home), where
    /// every picture crosses a slower path.
    static let maxWidth: CGFloat = 1500
    static let remoteMaxWidth: CGFloat = 1000
    /// Video at the window's own Retina sharpness (Oct 18 2026, "high fidelity"): text holds up
    /// when you zoom in; HEVC carries it easily at home, a little less away.
    static let videoMaxWidth: CGFloat = 2560
    static let remoteVideoMaxWidth: CGFloat = 1600
    private func maxWidth(for w: Watch) -> CGFloat {
        if w.wantsVideo { return app.isRemote(w.peer) ? Self.remoteVideoMaxWidth : Self.videoMaxWidth }
        return app.isRemote(w.peer) ? Self.remoteMaxWidth : Self.maxWidth
    }

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
        let w = Watch(peer: peer, target: target, timing: timing)
        // Video to a phone that decodes it (Oct 17 2026) — a busy chip turns a watch to pictures
        // by itself. `defaults write com.sameer.macrophone.mac watch.video -bool NO` keeps pictures.
        w.wantsVideo = app.server.phones(with: WatchVideo.feature).contains(peer) && (AppPaths.defaults.object(forKey: "watch.video") as? Bool ?? true)
        // A swipe's start: the window is brought forward only when another covers the spot; the
        // steps don't wait for that.
        w.poster.onBegan = { [weak self, weak w] spot in
            Task { @MainActor in
                guard let self, let w, let wid = w.windowID, !WindowServer.isOnTop(wid, at: spot) else { return }
                self.act(on: w.peer, what: "scroll", quiet: true) { _ in }
            }
        }
        postersLock.lock(); posters[peer] = w.poster; postersLock.unlock()
        watches[peer] = w
        app.log.add("watching started (\(AppModel.kind(SendSelection(target: target))), \(w.wantsVideo ? "video" : "pictures"))")
        w.task = Task { [weak self] in await self?.run(w) }
    }

    func stop(_ peer: UUID) {
        guard let w = watches.removeValue(forKey: peer) else { return }
        w.task?.cancel()
        w.sendTask?.cancel()
        w.reading?.cancel()
        postersLock.lock(); posters[peer] = nil; postersLock.unlock()
        w.poster.stop()
        if w.fit != nil { app.log.add("watch fit: the window goes back to its own size") }
        let v = w.pipe?.snapshot() ?? VideoPipe.Stats()
        let ms = (w.frameMs + v.frameMs).sorted()
        if !ms.isEmpty {
            func median(_ a: [Int]) -> Int { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
            app.log.add("watching: \(ms.count) frames (\(v.videoFrames) video) · median \(ms[ms.count / 2]) ms · slowest tenth \(ms[ms.count * 9 / 10]) ms to make · peak \(Self.peakPerSecond(w.sentAt + v.sentAt)) a second · \(w.poster.steps) scroll steps in \(w.poster.gestures) swipes · window gave \(v.given) (\(v.givenChanged) changed), held \(v.heldForPace) for pace, \(v.heldForWire) for the wire, sending median \(median(v.sendMs)) ms")
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
        // Locked: the window can't be shown or used until he unlocks it.
        if StayAwake.isLocked {
            w.dropStream()
            return .unavailable("Your Mac is locked — unlock it to see and use its windows", canReveal: false)
        }
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
            let s = WindowStream(window: scw, maxWidth: maxWidth(for: w), maxRate: rate(w), video: w.wantsVideo)
            if w.wantsVideo {
                let pipe = VideoPipe(peer: w.peer, server: app.server, rate: rate(w), timing: timing)
                pipe.onFallback = { [weak self, weak w] why in
                    Task { @MainActor in
                        guard let self, let w else { return }
                        self.app.log.add("watching: \(why) — pictures instead")
                        self.pictures(w)
                    }
                }
                pipe.onSettled = { [weak self, weak w] pixels in
                    Task { @MainActor in
                        guard let self, let w, w.reading == nil else { return }
                        w.reading = Task { [weak self, weak w] in
                            defer { w?.reading = nil }
                            guard let self, let w, let image = await Task.detached(priority: .utility, operation: { WindowStream.image(pixels) }).value else { return }
                            let changed = await self.readPrompt(w, image)
                            w.pipe?.readDone()
                            if changed { self.tellPipe(w); w.pipe?.sendWords() }
                        }
                    }
                }
                w.pipe = pipe
                pipe.set(words(w))
                w.poster.onInput = { [weak pipe] in pipe?.swiped() }
            }
            s.onFrame = { [weak self, weak w, weak s] pixels, changed in
                // Video: straight to the pipe, off the main thread. Pictures: the main actor's loop.
                if let pipe = w?.pipe { pipe.arrived(pixels, changed: changed); return }
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
            tellPipe(w)
        }
        if w.poster.window != wid { w.poster.window = wid }
        return .live(appName: w.appName)
    }

    /// What each video frame carries, as of now.
    private func words(_ w: Watch) -> VideoPipe.Words { .init(appName: w.appName, bundleID: w.bundleID, focus: w.focus, prompt: w.prompt) }
    private func tellPipe(_ w: Watch) { w.pipe?.set(words(w)) }

    // MARK: Pictures

    /// A new picture from the stream: the newest wins; it goes when the pacing allows.
    private func arrived(_ pixels: CVPixelBuffer, changed: Double, _ w: Watch) {
        if timing, Date().timeIntervalSince(w.hurriedAt) < 3, changed >= WatchPacing.sliver { print("[watch] frame from the window \(Int(Date().timeIntervalSince(w.hurriedAt) * 1000)) ms after the action, \(String(format: "%.3f", changed)) changed\(w.latest == nil ? "" : ", one waiting")"); fflush(stdout) }
        w.latest = pixels
        w.latestSeq &+= 1
        w.changedSince = min(1, w.changedSince + changed)
        w.changedSinceRead = max(w.changedSinceRead, changed)
        if w.sendTask == nil { w.sendTask = Task { [weak self] in await self?.drain(w) } }
    }

    /// Frames at the quick pace: video at thirty a second while the window changes a lot (twelve
    /// away from home), or pictures over the home network at ten — a JPEG is a few milliseconds
    /// to make and ~200 KB, easy for Wi-Fi; away from home, pictures keep the slower pace.
    private func quick(_ w: Watch) -> Bool { w.wantsVideo || !app.isRemote(w.peer) }
    private func rate(_ w: Watch) -> Int {
        if w.wantsVideo { return app.isRemote(w.peer) ? WindowStream.remoteVideoRate : WindowStream.videoRate }
        return app.isRemote(w.peer) ? WindowStream.pictureRate : WindowStream.quickPictureRate
    }

    /// The most frames that went in any one second.
    private static func peakPerSecond(_ times: [Date]) -> Int {
        var best = 0
        for (i, t) in times.enumerated() { best = max(best, times[i...].prefix { $0.timeIntervalSince(t) < 1 }.count) }
        return best
    }

    /// Sends pictures as they're due, newest first, until none is waiting.
    private func drain(_ w: Watch) async {
        while watches[w.peer] === w, !Task.isCancelled, let pixels = w.latest {
            let seq = w.latestSeq
            let interval = Date() < w.forceUntil ? 0 : WatchPacing.minimumInterval(changed: w.changedSince, quick: quick(w), rate: rate(w))
            if interval == .infinity { w.latest = nil; continue }
            let due = w.lastSentAt.addingTimeInterval(interval)
            if Date() < due { await w.pause(due.timeIntervalSinceNow); continue }
            // Only a picture that goes is made into an image (a copy of the window's pixels).
            guard let image = await Task.detached(priority: .utility, operation: { WindowStream.image(pixels) }).value else { w.latest = nil; continue }
            // The question it's asking: read after the picture is out (about once a second at most),
            // and the picture sent again with it when it changed.
            await send(image, w)
            if w.latestSeq == seq { w.latest = nil }
            if w.latest == nil, await readPrompt(w, image) { await send(image, w) }
        }
        w.sendTask = nil
    }

    /// Pictures from here on (this watch only): the chip is busy elsewhere or gave up. The stream
    /// gives BGRA for pictures: made again.
    private func pictures(_ w: Watch) {
        guard w.wantsVideo else { return }
        w.wantsVideo = false
        w.dropStream()
        w.wake()
    }

    /// The phone wants a frame that stands on its own (it started, came back, or lost one): the
    /// next frame is a keyframe — the last one again, when the window hasn't changed since.
    func keyframe(for peer: UUID) {
        watches[peer]?.pipe?.requestKeyframe()
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
        tellPipe(w)
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
        w.sentAt.append(Date())
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
        } else if let id = Self.minimizedWindow(of: r, preferring: hints.lastWindow) {
            // Only minimized windows (the phone's Window › Minimize, or the yellow button): keep
            // that one, so the phone says so and "Show it on my Mac" brings it back up.
            w.windowID = id
        } else {
            return .unavailable("\(name) has no window open", canReveal: true)
        }
        return nil
    }

    /// The app's minimized window (the one last typed in, when it's among them), which the
    /// window list leaves out.
    private static func minimizedWindow(of r: NSRunningApplication, preferring last: CGWindowID?) -> CGWindowID? {
        guard Paster.isTrusted else { return nil }
        let ids = AX.windows(AX.app(r.processIdentifier))
            .filter { AX.bool($0, kAXMinimizedAttribute) }
            .compactMap { AX.windowID($0) }
        if let last, ids.contains(last) { return last }
        return ids.first
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

    /// A key beyond Esc, the arrows and Return (⌃C, Tab, ⌘Return…), in the watched window. A key
    /// it doesn't know is ignored.
    func press(_ k: WatchKey, for peer: UUID) {
        guard let code = Self.keyCode(k.key) else { return }
        var flags: CGEventFlags = []
        if k.command { flags.insert(.maskCommand) }
        if k.shift { flags.insert(.maskShift) }
        if k.control { flags.insert(.maskControl) }
        if k.option { flags.insert(.maskAlternate) }
        // Arrows and the page keys carry the flags a real keyboard gives them.
        if ["left", "right", "up", "down"].contains(k.key) { flags.formUnion([.maskNumericPad, .maskSecondaryFn]) }
        if ["pageup", "pagedown", "home", "end", "forwarddelete"].contains(k.key) { flags.insert(.maskSecondaryFn) }
        act(on: peer, what: k.key == "return" ? "key-return" : "key") { _ in Keys.press(code, flags: flags) }
    }

    private static func keyCode(_ key: String) -> CGKeyCode? {
        switch key {
        case "tab": return CGKeyCode(kVK_Tab)
        case "return": return CGKeyCode(kVK_Return)
        case "space": return CGKeyCode(kVK_Space)
        case "delete": return CGKeyCode(kVK_Delete)
        case "escape": return CGKeyCode(kVK_Escape)
        case "forwarddelete": return CGKeyCode(kVK_ForwardDelete)
        case "left": return CGKeyCode(kVK_LeftArrow)
        case "right": return CGKeyCode(kVK_RightArrow)
        case "up": return CGKeyCode(kVK_UpArrow)
        case "down": return CGKeyCode(kVK_DownArrow)
        case "pageup": return CGKeyCode(kVK_PageUp)
        case "pagedown": return CGKeyCode(kVK_PageDown)
        case "home": return CGKeyCode(kVK_Home)
        case "end": return CGKeyCode(kVK_End)
        case "a": return CGKeyCode(kVK_ANSI_A)
        case "c": return CGKeyCode(kVK_ANSI_C)
        case "l": return CGKeyCode(kVK_ANSI_L)
        case "v": return CGKeyCode(kVK_ANSI_V)
        case "z": return CGKeyCode(kVK_ANSI_Z)
        case "1": return CGKeyCode(kVK_ANSI_1)
        case "2": return CGKeyCode(kVK_ANSI_2)
        case "3": return CGKeyCode(kVK_ANSI_3)
        case "4": return CGKeyCode(kVK_ANSI_4)
        case "5": return CGKeyCode(kVK_ANSI_5)
        case "6": return CGKeyCode(kVK_ANSI_6)
        case "7": return CGKeyCode(kVK_ANSI_7)
        case "8": return CGKeyCode(kVK_ANSI_8)
        case "9": return CGKeyCode(kVK_ANSI_9)
        default: return nil
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

    /// A swipe's steps and phases, straight from the link's receive loop (no main actor): to the
    /// watch's poster, which posts them from its own queue.
    nonisolated func scrollInput(_ peer: UUID, _ input: WatchInput) {
        postersLock.lock(); let poster = posters[peer]; postersLock.unlock()
        switch input {
        case let .scroll(p, d): poster?.scroll(at: p, by: d)
        case let .phase(phase, p): poster?.phase(phase, at: p)
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

    /// The Window menu: a size laid out on the window's own screen (it stays when watching stops —
    /// it was asked for), back to how it was, or the window's own minimize and close buttons.
    func windowCommand(_ c: WatchWindowCommand, for peer: UUID) {
        guard let w = watches[peer], let wid = w.windowID else { return }
        guard Paster.isTrusted else { app.log.add("watch window skipped: Accessibility not granted"); return }
        guard let win = AX.window(in: AX.app(w.pid), id: wid), AX.isAlive(win) else {
            app.log.add("watch window \(c.rawValue): the window isn't answering")
            return
        }
        switch c {
        case .minimize:
            _ = AX.set(win, kAXMinimizedAttribute, kCFBooleanTrue)
        case .close:
            if let b = AX.element(win, kAXCloseButtonAttribute) { _ = AXUIElementPerformAction(b, kAXPressAction as CFString) }
        case .restore:
            if let f = w.beforeWindowChanges, !AX.bool(win, "AXFullScreen") { _ = WindowFit.set(win, frame: f) }
            w.beforeWindowChanges = nil
        case .fill, .leftHalf, .rightHalf, .middle:
            guard !AX.bool(win, "AXFullScreen") else { app.log.add("watch window: it's full screen"); return }
            let now = AX.frame(win)
            if w.beforeWindowChanges == nil { w.beforeWindowChanges = w.fit?.original ?? now }
            // A size picked here takes over from Aa's, and isn't undone when watching stops.
            w.fit = nil
            w.wantedFit = .normal
            guard let area = WindowFit.visibleArea(around: now), let target = c.frame(in: area) else { return }
            _ = WindowFit.set(win, frame: target)
        }
        app.log.add("watch window \(c.rawValue)")
        w.wake()
    }

    /// Fit to iPhone: the window takes the phone's view's shape, as tall as the screen allows. Like
    /// the Window menu's sizes, it takes over from Aa and Back to How It Was undoes it.
    func fitToPhone(aspect: CGFloat, for peer: UUID) {
        guard let w = watches[peer], let wid = w.windowID else { return }
        guard Paster.isTrusted else { app.log.add("watch fit to iPhone skipped: Accessibility not granted"); return }
        guard let win = AX.window(in: AX.app(w.pid), id: wid), AX.isAlive(win), !AX.bool(win, "AXFullScreen") else {
            app.log.add("watch fit to iPhone: the window isn't answering")
            return
        }
        let now = AX.frame(win)
        if w.beforeWindowChanges == nil { w.beforeWindowChanges = w.fit?.original ?? now }
        w.fit = nil
        w.wantedFit = .normal
        guard let area = WindowFit.visibleArea(around: now),
              let target = WatchShape.frame(aspect: aspect, window: now, in: area) else { return }
        _ = WindowFit.set(win, frame: target)
        app.log.add("watch fit to iPhone: \(Int(now.width))×\(Int(now.height)) → \(Int(target.width))×\(Int(target.height))")
        w.focusAt = .distantPast
        w.hurry()
        w.wake()
    }

    /// A press and hold (or a two-finger tap) on the phone's picture: a right-click there.
    func rightClick(_ p: CGPoint, for peer: UUID) {
        act(on: peer, what: "right click") { wid in
            guard let b = WindowServer.bounds(of: wid) else { return }
            await Self.click(at: CGPoint(x: b.minX + p.x * b.width, y: b.minY + p.y * b.height), right: true)
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
        // A locked Mac: a key or a click would land on the lock screen.
        guard !StayAwake.isLocked else {
            app.log.add("watch \(what) skipped: the Mac is locked")
            return
        }
        let name = w.appName
        Task { [weak self] in
            let recently = quiet && Date().timeIntervalSince(w.inFrontAt) < 1
            let inFront = recently || (NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier
                && WindowServer.appWindows().first { $0.z == 0 }?.id == wid)
            if inFront { w.inFrontAt = Date() }
            if !inFront || what == WatchAction.reveal.rawValue {
                do { _ = try await Paster.bringToFront(running, windowID: wid, required: true, name: name) } catch {
                    self?.app.log.add("watch \(what): window didn't come forward")
                    return
                }
            }
            if !quiet { w.hurry() }
            await body(wid)
            // An answer or a Return from the phone: this window is a chat waiting for its answer.
            if ["returnKey", "choose", "key-return"].contains(what) { self?.app.replies.engaged(windowID: wid, bundleID: w.bundleID) }
            if !quiet { self?.app.log.add("watch \(what)") }
            w.wake()
        }
    }

    /// A left click at a fraction of the window. The pointer goes there for the click and is put back.
    private static func click(window id: CGWindowID, at p: CGPoint) async {
        guard let b = WindowServer.appWindows().first(where: { $0.id == id })?.bounds else { return }
        await click(at: CGPoint(x: b.minX + p.x * b.width, y: b.minY + p.y * b.height))
    }

    /// A click at a point on screen (the right button for a right-click); the pointer goes back
    /// where it was.
    private static func click(at pt: CGPoint, right: Bool = false) async {
        let original = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 40_000_000)
        let down = CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: pt, mouseButton: right ? .right : .left)
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        down?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let up = CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: pt, mouseButton: right ? .right : .left)
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
