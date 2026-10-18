import MacrophoneKit
import SwiftUI
import UIKit

/// Watching (Oct 14 2026): the picked app's window on the Mac, live, in the area above the
/// Thread — a tap clicks there, and a key row sends Esc, ↑, ↓ and Return. It opens after a dictation is sent into an app
/// (Settings › Show the app after sending) or from the Watch button by Send to; it pauses after
/// two idle minutes or when the app leaves the screen, and Done closes it.
///
/// The window comes as video from a Mac that can (Oct 17 2026): HEVC frames handed in order to
/// `VideoCanvas`, a view the system decodes into and draws itself (nothing per frame goes through
/// SwiftUI) — a frame that can't be shown asks the Mac for one that stands on its own. A Mac from
/// before sends pictures, as before, and so does one whose video chip is busy. And "Aa": the Mac's
/// window narrower, so its text reads larger here, remembered per app.
@MainActor
final class Watcher: ObservableObject {
    /// Why the pictures stopped (the note over the picture says which).
    enum PauseReason: Equatable {
        /// Two minutes with no touch: stopped to save battery.
        case idle
        /// The app left the screen; it picks up again by itself when the app comes back.
        case leftScreen
        /// Stopped from the Mac's menu bar.
        case mac
    }

    enum Phase: Equatable {
        /// Asked the Mac; no picture yet.
        case starting
        case live
        /// Stopped (the last picture stays).
        case paused(PauseReason)
        /// Screen Recording is off for Macrophone on the Mac.
        case needsPermission
        /// Nothing to show, and why ("Claude isn't open on your Mac").
        case unavailable(String, canReveal: Bool)
        /// The Mac isn't connected.
        case offline

        var isPaused: Bool { if case .paused = self { return true }; return false }
    }

    @Published private(set) var isOpen = false
    @Published private(set) var phase: Phase = .starting
    /// The last picture (a JPEG): the first of a video watch, and every one from a Mac that sends
    /// pictures.
    @Published private(set) var image: UIImage?
    /// The video, drawn by the system; `videoSize` is set (and published) once it has a frame, so
    /// the viewer shows the canvas over the picture — and changes only with the frame's size.
    let video = VideoCanvas()
    @Published private(set) var videoSize: CGSize?
    /// Something to show: a picture, or video.
    var hasPicture: Bool { image != nil || videoSize != nil }
    /// The window's own name for itself ("Claude"), from the Mac.
    @Published private(set) var appName = ""
    @Published private(set) var bundleID: String?
    /// The place to type, as a fraction of the window: the view centres on that column.
    @Published private(set) var focus: CGRect?
    @Published private(set) var target: TargetRef?
    /// Bumped when the person asks for the view to go back to the newest output.
    @Published private(set) var recenter = 0
    /// Bumped when the window comes alive: the first picture after opening or resuming.
    @Published private(set) var cameAlive = 0
    /// What one finger does on the window (Sameer, Oct 16 2026: one-handed, "pan mode as the
    /// default"): move around the picture, or scroll the Mac's window. Each watch opens on pan.
    enum Drag: String { case pan, scroll }
    @Published private(set) var drag: Drag = .pan
    /// The question the window is asking, read off the picture on the Mac (Oct 16 2026): its
    /// answers replace Esc · ↑ · ↓ · Return while it's up. Nil from a Mac that doesn't read them.
    @Published private(set) var prompt: WatchPrompt?
    /// The person asked for the keys instead of this prompt's answers ("Keys").
    @Published private(set) var keysInstead = false
    /// Answered here: its buttons go at once, without waiting for the next picture.
    private var answeredID: String?
    /// The answers to show now, if any.
    var answers: WatchPrompt? {
        guard let prompt, prompt.id != answeredID, !keysInstead else { return nil }
        return prompt
    }
    var sendChoose: (WatchPrompt, Int) -> Void = { _, _ in }

    /// Readable text ("Aa", Oct 17 2026): how the Mac's window is sized for this phone.
    @Published private(set) var fit: WatchFit = .normal
    /// The connected Mac can size windows (it named "fit" in its welcome).
    @Published private(set) var macCanFit = false
    /// A moment of words over the window: what just changed, in a sentence.
    @Published private(set) var noteSeq = 0
    private(set) var noteWords = ""
    var sendFit: (WatchFit) -> Bool = { _ in false }
    var macFeatures: () -> Set<String> = { [] }

    /// The person zoomed or moved the picture away from the newest output (Newest shows).
    @Published private(set) var movedAway = false
    func setMovedAway(_ b: Bool) { if b != movedAway { movedAway = b } }
    /// Sends the watch request to the Mac; false when it isn't connected.
    var sendWatch: (TargetRef?) -> Bool = { _ in false }
    var sendAction: (WatchAction) -> Void = { _ in }
    var sendClick: (CGPoint) -> Void = { _ in }
    /// Right-click there; false when the Mac can't (it predates right-clicks).
    var sendRightClick: (CGPoint) -> Bool = { _ in false }
    /// The Mac takes right-clicks (a press and hold, or a two-finger tap).
    var canRightClick: Bool { macFeatures().contains(WatchRightClick.feature) }
    /// The whole window on screen instead of the zoomed-in column (the zoom-out button).
    @Published private(set) var wholeWindow = false
    var sendScroll: (CGPoint, CGVector) -> Void = { _, _ in }
    var sendScrollPhase: (WatchScrollPhase, CGPoint) -> Void = { _, _ in }
    /// The connected Mac takes a swipe as a trackpad gesture (it named "scroll" in its welcome):
    /// the finger's phases go with the deltas, and a flick coasts.
    @Published private(set) var macCanScroll = false
    /// Asks the Mac for a video frame that stands on its own; false when it can't be sent.
    var sendKeyframe: () -> Bool = { false }
    var log: DiagnosticLog?

    private var idleTask: Task<Void, Never>?
    private var newestSeq = 0
    /// When the Mac was asked, for the log's "first picture N ms after asking".
    private var askedAt = Date.distantPast
    /// No picture has arrived since the last open or resume.
    private var awaitingFirstPicture = true
    static let idleLimit: TimeInterval = 120

    /// Video: frames in order; one out of order or that fails waits for a keyframe.
    private var waitingForKeyframe = true
    private var keyframeAskedAt = Date.distantPast
    /// How the pictures come, for the log (numbers only): frames, bytes, and when each came.
    private var videoFrames = 0
    private var videoBytes = 0
    private var frameTimes: [Date] = []

    /// "Claude" — what the header calls it before the Mac has answered.
    var name: String {
        if !appName.isEmpty { return appName }
        guard let target else { return "your Mac" }
        if case .frontApp = target { return "the app in front" }
        return target.displayName.components(separatedBy: " — ").first ?? target.displayName
    }

    // MARK: Open / close

    func open(_ target: TargetRef) {
        guard target != .clipboard else { return }
        let switching = self.target != target
        self.target = target
        if !isOpen { drag = .pan; wholeWindow = false }
        if switching {
            image = nil
            video.clear()
            videoSize = nil
            appName = ""
            bundleID = target.bundleID
            focus = nil
            prompt = nil
            keysInstead = false
            fit = Self.rememberedFit(for: target)
        }
        isOpen = true
        start()
        log?.add("watching opened")
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        idleTask?.cancel()
        _ = sendWatch(nil)
        if videoFrames > 0 {
            var peak = 0
            for (i, t) in frameTimes.enumerated() { peak = max(peak, frameTimes[i...].prefix { $0.timeIntervalSince(t) < 1 }.count) }
            log?.add("watching: \(videoFrames) video frames, \(videoBytes / 1024) KB, peak \(peak) a second")
        }
        log?.add("watching closed")
    }

    /// Ask the Mac again (open, resume, reconnect).
    private func start() {
        guard let target else { return }
        // The Mac starts a fresh watch (its pictures count from 1 again), so does the phone.
        newestSeq = 0
        waitingForKeyframe = true
        videoFrames = 0
        videoBytes = 0
        frameTimes = []
        awaitingFirstPicture = true
        askedAt = Date()
        macCanFit = macFeatures().contains(WatchVideo.fitFeature)
        macCanScroll = macFeatures().contains(WatchScroll.feature)
        phase = image == nil ? .starting : phase == .live ? .live : .starting
        if !sendWatch(target) { phase = .offline; return }
        // A frame that stands on its own first (a Mac that sends pictures never hears this).
        askKeyframe()
        // The size this app's window is remembered at: the Mac applies it once it finds the window.
        if fit != .normal { _ = sendFit(fit) }
        touch()
    }

    func pause(_ reason: PauseReason = .idle) {
        guard isOpen, !phase.isPaused else { return }
        idleTask?.cancel()
        _ = sendWatch(nil)
        phase = .paused(reason)
        log?.add("watching paused (\(reason))")
    }

    func resume() {
        guard isOpen else { return }
        Haptics.tick()
        start()
    }

    /// The app is back on screen: a watch that only stopped because it left picks up by itself.
    func sceneBecameActive() {
        guard isOpen, phase == .paused(.leftScreen) else { return }
        start()
        log?.add("watching resumed on return")
    }

    /// Something the person did here: keeps it live for another two minutes.
    func touch() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleLimit * 1e9))
            guard !Task.isCancelled else { return }
            self?.pause(.idle)
        }
    }

    func perform(_ action: WatchAction) {
        touch()
        Haptics.tick()
        sendAction(action)
        // The answer to a key shows at the bottom of the window: go back there.
        recenter &+= 1
    }

    /// A tap on the picture: click there on the Mac.
    func click(_ p: CGPoint) {
        touch()
        Haptics.tick()
        sendClick(p)
    }

    /// A press and hold (or a two-finger tap): a right-click there. False when the Mac can't.
    @discardableResult
    func rightClick(_ p: CGPoint) -> Bool {
        touch()
        guard sendRightClick(p) else { return false }
        Haptics.success()
        log?.add("watching: right-click")
        return true
    }

    /// The Mac takes Window menu commands (sizes, minimize, close).
    var canWindowCommands: Bool { macFeatures().contains(WatchWindowCommand.feature) }
    var sendWindow: (WatchWindowCommand) -> Bool = { _ in false }

    /// The size of this phone's view of the window, in points (Fit to iPhone sends its shape).
    var viewerSize: CGSize = .zero
    var canFitToPhone: Bool { macFeatures().contains(WatchShape.feature) }
    var sendShape: (CGSize) -> Bool = { _ in false }

    /// Fit to iPhone: the Mac gives the window this view's shape, as big as its screen allows, so
    /// the whole window fills the view. Takes over from Aa, like the Window menu's sizes.
    func fitToPhone() {
        touch()
        guard viewerSize.width > 40, viewerSize.height > 40, sendShape(viewerSize) else { return }
        Haptics.tick()
        if fit != .normal { setFitLocally(.normal) }
        if wholeWindow { toggleWholeWindow() }
        say("\(name)'s window now has your iPhone's shape — all of it fits here")
        log?.add("watching: fit to iPhone")
    }

    /// The Mac presses keys beyond Esc, the arrows and Return (⌃C, Tab, ⌘Return…).
    var canPressKeys: Bool { macFeatures().contains(WatchKey.feature) }
    var sendKey: (WatchKey) -> Bool = { _ in false }

    /// A key from the More Keys menu, pressed in the window; the view goes to where it answers.
    func press(_ k: WatchKey) {
        touch()
        guard sendKey(k) else { return }
        Haptics.tick()
        recenter &+= 1
        log?.add("watching: key")
    }

    /// A Window menu command. A size picked there takes over from Aa's text size.
    func window(_ c: WatchWindowCommand) {
        touch()
        guard sendWindow(c) else { return }
        Haptics.tick()
        if c.frame(in: .zero) != nil || c == .restore, fit != .normal { setFitLocally(.normal) }
        log?.add("watching: window \(c.rawValue)")
    }

    /// The zoom-out button: the whole window, or back to the column you type in.
    func toggleWholeWindow() {
        touch()
        Haptics.tick()
        wholeWindow.toggle()
    }

    /// A swipe on the picture: scroll the Mac's window there (no haptic — it's continuous).
    func scroll(at p: CGPoint, by d: CGVector) {
        touch()
        sendScroll(p, d)
    }

    /// Where the swipe is (landed, lifted, coasting): the Mac makes one gesture of the deltas.
    func scrollPhase(_ phase: WatchScrollPhase, at p: CGPoint) {
        sendScrollPhase(phase, p)
    }

    func setDrag(_ d: Drag) {
        guard d != drag else { return }
        touch()
        Haptics.tick()
        drag = d
        log?.add("watching: one finger \(d == .pan ? "moves the picture" : "scrolls the window")")
        say(d == .pan ? "One finger moves the picture" : "One finger scrolls your Mac's window")
    }

    /// An answer tapped: the Mac presses the keys that give it, if the question is still up.
    func choose(_ index: Int) {
        guard let p = answers, p.choices.indices.contains(index) else { return }
        touch()
        Haptics.success()
        answeredID = p.id
        objectWillChange.send()
        sendChoose(p, index)
        recenter &+= 1
        log?.add("watching: answered a prompt")
    }

    /// Esc · ↑ · ↓ · Return for this prompt, instead of its answers.
    func showKeys() {
        touch()
        Haptics.tick()
        keysInstead = true
    }

    func showNewest() {
        touch()
        recenter &+= 1
    }

    // MARK: Readable text (Aa)

    /// Size the Mac's window for this phone, and remember the choice for this app.
    func setFit(_ f: WatchFit) {
        guard f != fit else { return }
        touch()
        Haptics.tick()
        fit = f
        if let target { Self.remember(f, for: target) }
        // A new text size reshapes the window: start from its fit, not the old zoom.
        if let viewKey { UserDefaults.standard.removeObject(forKey: viewKey) }
        if sendFit(f) {
            say(f.explanation(appName: name))
            recenter &+= 1
        } else {
            say("Your Mac can't resize windows yet — update Macrophone there")
        }
        log?.add("watching: text \(f.rawValue)")
    }

    /// The Mac dropped Aa's size for one picked from the Window menu: the phone follows, quietly.
    private func setFitLocally(_ f: WatchFit) {
        fit = f
        if let target { Self.remember(f, for: target) }
    }

    /// The fit this app's window was last watched at.
    static func rememberedFit(for target: TargetRef) -> WatchFit {
        guard let key = fitKey(target) else { return .normal }
        return UserDefaults.standard.string(forKey: key).flatMap(WatchFit.init(rawValue:)) ?? .normal
    }

    private static func remember(_ f: WatchFit, for target: TargetRef) {
        guard let key = fitKey(target) else { return }
        if f == .normal { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(f.rawValue, forKey: key) }
    }

    /// Where the window's view keeps the zoom you left it at, per app.
    var viewKey: String? { (bundleID ?? target?.bundleID).map { "watch.view." + $0 } }

    private static func fitKey(_ target: TargetRef) -> String? { target.bundleID.map { "watch.fit." + $0 } }

    /// A sentence over the window for a moment.
    private func say(_ words: String) {
        noteWords = words
        noteSeq &+= 1
    }

    // MARK: From the Mac

    func received(_ state: WatchState) {
        guard isOpen, !phase.isPaused else { return }
        switch state {
        case .live(let name):
            appName = name
            if image != nil { phase = .live }
        case .needsPermission: phase = .needsPermission
        case let .unavailable(why, canReveal): phase = .unavailable(why, canReveal: canReveal)
        case .stopped:
            // Stopped from the Mac's menu: the picture stays, and Resume asks again.
            idleTask?.cancel()
            phase = .paused(.mac)
        }
    }

    func received(_ frame: WatchFrame) {
        guard isOpen, !phase.isPaused, WatchFrame.shouldShow(seq: frame.seq, newest: newestSeq) else { return }
        newestSeq = frame.seq
        let data = frame.jpeg
        Task {
            // Decoded off the main thread so the mic and the Thread never stutter.
            let img = await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
            // A newer picture may have been decoded first: never go back to an older one.
            guard let img, self.isOpen, !self.phase.isPaused, frame.seq == 1 || frame.seq >= self.newestSeq else { return }
            // A picture after video (the Mac's chip got busy): the picture is what shows now.
            if self.videoSize != nil { self.video.clear(); self.videoSize = nil }
            self.show(img, appName: frame.appName, bundleID: frame.bundleID, focus: frame.focus, prompt: frame.prompt, bytes: data.count, how: "picture")
        }
    }

    /// A frame of video, handed to the canvas in order (the system decodes and draws it). Only
    /// the words (the question, the place to type) when there's nothing to decode.
    func received(_ frame: WatchVideoFrame) {
        guard isOpen, !phase.isPaused else { return }
        // One count for pictures, frames and words: the first picture of a video watch is a JPEG.
        if frame.isWordsOnly {
            newestSeq = frame.seq
            words(appName: frame.appName, bundleID: frame.bundleID, focus: frame.focus, prompt: frame.prompt)
            return
        }
        guard WatchVideoFrame.canDecode(seq: frame.seq, keyframe: frame.keyframe, newest: newestSeq, waitingForKeyframe: waitingForKeyframe) else {
            if !waitingForKeyframe { log?.add("watching: a frame was missed — asking for a keyframe") }
            waitingForKeyframe = true
            askKeyframe()
            return
        }
        newestSeq = frame.seq
        guard video.enqueue(frame) else {
            log?.add("watching: a frame didn't decode — asking for a keyframe")
            waitingForKeyframe = true
            askKeyframe()
            return
        }
        waitingForKeyframe = false
        videoFrames += 1
        videoBytes += frame.data.count
        if frameTimes.count < 4000 { frameTimes.append(Date()) }
        if videoSize != video.frameSize { videoSize = video.frameSize }
        words(appName: frame.appName, bundleID: frame.bundleID, focus: frame.focus, prompt: frame.prompt)
        if phase != .live { phase = .live }
        if awaitingFirstPicture {
            awaitingFirstPicture = false
            cameAlive &+= 1
            log?.add("watching: first \(frame.keyframe ? "keyframe" : "frame") \(Int(Date().timeIntervalSince(askedAt) * 1000)) ms after asking, \(frame.data.count / 1024) KB")
        }
    }

    /// Asks the Mac for a frame that stands on its own, at most once a second.
    private func askKeyframe() {
        guard Date().timeIntervalSince(keyframeAskedAt) > 1 else { return }
        keyframeAskedAt = Date()
        _ = sendKeyframe()
    }

    /// Each published change re-renders every view watching this; only what changed is set.
    private func show(_ img: UIImage, appName: String, bundleID: String?, focus: CGRect?, prompt: WatchPrompt?, bytes: Int, how: String) {
        image = img
        words(appName: appName, bundleID: bundleID, focus: focus, prompt: prompt)
        if phase != .live { phase = .live }
        if awaitingFirstPicture {
            awaitingFirstPicture = false
            cameAlive &+= 1
            log?.add("watching: first \(how) \(Int(Date().timeIntervalSince(askedAt) * 1000)) ms after asking, \(bytes / 1024) KB")
        }
    }

    private func words(appName: String, bundleID: String?, focus: CGRect?, prompt: WatchPrompt?) {
        if self.appName != appName { self.appName = appName }
        if self.bundleID != bundleID { self.bundleID = bundleID }
        // Only a real move re-centres the view; the frame jitters as the window redraws.
        if WatchFrame.focusMoved(from: self.focus, to: focus) { self.focus = focus }
        if prompt?.id != self.prompt?.id {
            // A new question (or none): its answers show, and "Keys" applies to one prompt only.
            keysInstead = false
            if prompt != nil { answeredID = nil }
        }
        if self.prompt != prompt { self.prompt = prompt }
    }

    /// The link came or went.
    func linkChanged(connected: Bool) {
        guard isOpen else { return }
        if connected {
            if phase == .offline { start() }
        } else if !phase.isPaused {
            phase = .offline
        }
    }

    /// After a dictation lands somewhere else, the view follows it.
    func follow(_ target: TargetRef) {
        if isOpen, self.target == target, !phase.isPaused { recenter &+= 1; return }
        open(target)
    }
}
