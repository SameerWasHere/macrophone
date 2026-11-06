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
    /// The iPhone Duo's glance (Oct 25 2026, the second pass): Done on the inner screen keeps the
    /// pictures coming but puts the controls away — the picked app's window stays live and big,
    /// not a placeholder, with Show it here to take it in hand again. Never on the cover or a
    /// regular iPhone, where Done closes as ever.
    @Published private(set) var glancing = false
    /// Done glances instead of closing (set by the pose: the inner screen).
    var glanceOnDone = false
    /// The window is in hand: open, with its controls (not the glance).
    var isShowing: Bool { isOpen && !glancing }
    /// A folded Duo's Mac half (Oct 25 2026): the picture fills the half (aspect-fill, scrolling)
    /// rather than letterboxing, and a window the Mac can reshape is quietly given the half's
    /// shape as the pose settles.
    @Published private(set) var fillsView = false
    /// The three ways in (Oct 19 2026): the keyboard, the mic, the trackpad — the page, the sticky
    /// modifiers, the pointer.
    let input = MacInput()

    init() {
        input.watcher = self
        input.macFeatures = { [weak self] in self?.macFeatures() ?? [] }
    }
    /// The last picture (a JPEG): the first of a video watch, and every one from a Mac that sends
    /// pictures.
    @Published private(set) var image: UIImage?
    /// The video, drawn by the system; `videoSize` is set (and published) once it has a frame, so
    /// the viewer shows the canvas over the picture — and changes only with the frame's size.
    let video = VideoCanvas()
    @Published private(set) var videoSize: CGSize?
    /// Something to show: a picture, or video.
    var hasPicture: Bool { image != nil || videoSize != nil }
    /// This window's picture from the last time it showed (Nov 3 2026, `WindowSnapshots`): drawn,
    /// dimmed, until this watch's first frame — never an empty plate while it opens.
    @Published private(set) var lastPicture: UIImage?
    /// The Mac the pictures come from (the snapshots are kept per Mac).
    var macID: () -> UUID? = { nil }
    private var keepTask: Task<Void, Never>?

    /// Keeps what's on screen now as this window's last picture.
    func keepPicture() {
        guard let target, hasPicture, !stale, let key = WindowSnapshots.key(mac: macID(), target: target) else { return }
        if videoSize != nil, let frame = video.displayedFrame() { WindowSnapshots.save(frame, key: key) }
        else if let image { WindowSnapshots.save(image, key: key) }
        WindowSnapshots.keep(focus: focus, key: key)
    }

    /// The first frame of a watch: the kept picture gives way, and a fresh one is kept every 30 s.
    private func cameLive() {
        keepTask?.cancel()
        keepTask = Task { @MainActor [weak self] in
            // A beat for the decoder to draw the first frame over it, then it goes.
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.lastPicture = nil
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled, self.isOpen, self.phase == .live else { return }
                self.keepPicture()
            }
        }
    }
    /// The picture on screen is the window before this one (a switch): it stays, dimmed, until
    /// the new window's first frame lands, so a flip never drops to an empty plate.
    @Published private(set) var stale = false
    /// Bumped on every switch to another window: the viewer starts that window's view fresh.
    @Published private(set) var windowSeq = 0
    /// Bumped when something was sent to the Mac that has no mark of its own on the picture (a
    /// key, an answer, a Window command): the bezel's rim answers at once, so input never feels
    /// lost while the Mac catches up.
    @Published private(set) var inputSeq = 0
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
    /// A moment of words over the window: what just changed, in a sentence, with a symbol for it.
    @Published private(set) var noteSeq = 0
    private(set) var noteWords = ""
    private(set) var noteSymbol = "info.circle"
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
    /// How the pictures come, for the log (numbers only): frames, bytes, the busiest second
    /// (a one-second window kept as frames arrive) and the main thread's time per frame.
    private var videoFrames = 0
    private var videoBytes = 0
    private var recentFrames: [CFTimeInterval] = []
    private var peakPerSecond = 0
    /// Microseconds the main thread spent handing each frame to the canvas (DEBUG, for the
    /// log's "frame path" line — the one place the frame path touches the main thread).
    private var framePathMicros: [Int] = []

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
        // The window it leaves keeps its picture for next time.
        if switching, isOpen { keepPicture() }
        self.target = target
        if !isOpen { drag = .pan; wholeWindow = false }
        // A window fitted to the phone shows whole: one finger scrolls it (nothing to pan to).
        if Self.isFitted(target), (switching || !isOpen) { drag = .scroll }
        // The whole screen opens fitted: all of it at once (pinch in for detail).
        // (A folded Duo's half fills with it instead: the middle of the screen, scrolling.)
        if DesktopWatch.isDesktop(target), switching || !isOpen { wholeWindow = !fillsView }
        if switching { front = nil }
        // The window this view gave its shape to by itself goes back as it was (before the Mac
        // hears of the next one).
        if switching || !isOpen { putBackAutoFit() }
        if switching {
            // The last window's picture stays on screen, dimmed, until the new one's first frame:
            // the viewer never tears down to an empty plate between two windows.
            stale = hasPicture
            windowSeq &+= 1
            appName = ""
            bundleID = target.bundleID
            focus = nil
            prompt = nil
            keysInstead = false
            fit = Self.rememberedFit(for: target)
            // Another window: what was sent for the last one says nothing about this one's shape.
            shapeSent = nil
        }
        let opening = !isOpen || glancing
        if switching || !isOpen {
            let key = WindowSnapshots.key(mac: macID(), target: target)
            lastPicture = WindowSnapshots.cached(key)
            // Where you type in it, as it was: the view opens framed on it at once (the kept
            // picture and the live one alike) instead of gliding there when the Mac says so.
            if focus == nil, lastPicture != nil { focus = WindowSnapshots.focus(key) }
            // A new window takes this view's shape once it's live (Oct 31 2026).
            sizedByHand = false
            askedForFit = false
            wantsAutoFit = true
        }
        isOpen = true
        if glancing { glancing = false; wantsAutoFit = true }
        start()
        if wantsAutoFit { shapeAhead() }
        // The mic, every time the window view opens (a switch keeps the page).
        if opening { input.opened() }
        log?.add("watching opened")
    }

    /// Done: on the Duo's inner screen the glance (the pictures stay, the controls go); anywhere
    /// else, closed.
    func done() {
        if glanceOnDone, isOpen { glance() } else { close() }
    }

    /// The glance: the window stays live but out of hand — its pointer, keys and pages put away.
    func glance() {
        guard isOpen, !glancing else { return }
        glancing = true
        fullScreen = false
        input.closed()
        touch()
        log?.add("watching: the glance")
    }

    /// A folded pose (the laptop, the book) or not: the picture fills its half (the pose change
    /// that comes with it gives the window the half's shape — `poseSettled`).
    func setFillsView(_ on: Bool) {
        guard on != fillsView else { return }
        fillsView = on
    }

    // MARK: Full screen (the Duo's inner screen on its side)

    // Nov 3 2026, Sameer: "a full screen button … the window take up the entirety, edge to edge,
    // of the full screen. And then the window should resize to fill the screen. And then if it's
    // the Mac display, it should just fill the screen in its entirety."

    /// The window in hand takes the whole inner screen: no deck, no bar.
    @Published private(set) var fullScreen = false

    /// The poses with room for it: the inner screen on its side (flat, or the book).
    static func allowsFullScreen(_ pose: FoldPose) -> Bool { pose.isInner && !pose.foldAcross }

    /// Into or out of full screen. A window takes the new view's shape (as on a pose change); the
    /// whole screen fills the display rather than showing whole. The pages go back to the mic
    /// (no pointer or keyboard without the deck) and the deck picks its own on the way back.
    func setFullScreen(_ on: Bool) {
        guard on != fullScreen, !on || isShowing else { return }
        fullScreen = on
        if isDesktop { wholeWindow = on ? false : !fillsView }
        if on, input.page != .mic { input.show(.mic, quiet: true) }
        log?.add("watching: full screen \(on ? "on" : "off")")
        poseSettled()
    }

    func close() {
        guard isOpen else { return }
        keepPicture()
        keepTask?.cancel()
        putBackAutoFit()
        isOpen = false
        glancing = false
        fullScreen = false
        wantsAutoFit = false
        shapeSent = nil
        autoFitTask?.cancel()
        input.closed()
        idleTask?.cancel()
        _ = sendWatch(nil)
        if videoFrames > 0 {
            var line = "watching: \(videoFrames) video frames, \(videoBytes / 1024) KB, peak \(peakPerSecond) a second"
            if !framePathMicros.isEmpty {
                let sorted = framePathMicros.sorted()
                line += " · main thread per frame: median \(sorted[sorted.count / 2]) µs, p95 \(sorted[min(sorted.count - 1, sorted.count * 95 / 100)]) µs, max \(sorted.last!) µs"
            }
            log?.add(line)
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
        recentFrames = []
        peakPerSecond = 0
        framePathMicros = []
        awaitingFirstPicture = true
        askedAt = Date()
        video.ready()
        macCanFit = macFeatures().contains(WatchVideo.fitFeature)
        macCanScroll = macFeatures().contains(WatchScroll.feature)
        phase = !hasPicture || stale ? .starting : phase == .live ? .live : .starting
        if !sendWatch(target) { phase = .offline; return }
        // A frame that stands on its own first (a Mac that sends pictures never hears this).
        askKeyframe()
        // The size this app's window is remembered at: the Mac applies it once it finds the window.
        if fit != .normal { _ = sendFit(fit) }
        touch()
    }

    func pause(_ reason: PauseReason = .idle) {
        guard isOpen, !phase.isPaused else { return }
        keepPicture()
        idleTask?.cancel()
        _ = sendWatch(nil)
        phase = .paused(reason)
        log?.add("watching paused (\(reason))")
    }

    func resume() {
        guard isOpen else { return }
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
        Haptics.press()
        sendAction(action)
        inputSeq &+= 1
        // The answer to a key shows at the bottom of the window: go back there.
        recenter &+= 1
    }

    /// A tap on the picture: click there on the Mac — the second tap within a moment is a
    /// double-click's second click (`count` 2), the third a triple's; any modifier waiting on the
    /// keyboard page goes with it. A Mac from before "mouse" gets the plain click.
    func click(_ p: CGPoint, count: Int = 1) {
        touch()
        Haptics.press()
        if !input.windowClick(p, count: count, right: false) { sendClick(p) }
        if count > 1 { log?.add("watching: click ×\(count)") }
    }

    /// A press and hold (or a two-finger tap): a right-click there. False when the Mac can't.
    @discardableResult
    func rightClick(_ p: CGPoint) -> Bool {
        touch()
        if !input.windowClick(p, count: 1, right: true) {
            guard sendRightClick(p) else { return false }
        }
        Haptics.rightClick()
        log?.add("watching: right-click")
        return true
    }

    /// A drag on the picture — a tap, then a hold that moves (Oct 19 2026): the button pressed
    /// there, moved, released. Only a Mac naming "mouse" takes it.
    func windowDrag(_ kind: WatchMouseEvent.Kind, at p: CGPoint) {
        touch()
        input.windowDrag(kind, at: p)
    }

    /// The Mac takes drags, double-clicks and the pointer (it named "mouse").
    var canMouse: Bool { input.canMouse }

    /// Something went to the Mac with no mark of its own on the picture (a key, typing, a drag's
    /// end): the bezel's rim answers; `recenter` goes to the newest output too.
    func inputSent(recenter: Bool = false) {
        inputSeq &+= 1
        if recenter { self.recenter &+= 1 }
    }

    /// The Mac takes Window menu commands (sizes, minimize, close).
    var canWindowCommands: Bool { macFeatures().contains(WatchWindowCommand.feature) }
    var sendWindow: (WatchWindowCommand) -> Bool = { _ in false }

    /// The size of this phone's view of the window, in points (Fit to iPhone sends its shape).
    /// Set through `viewerMeasured`, which also says whether the view is a folded half's.
    private(set) var viewerSize: CGSize = .zero
    /// The view reporting now is a folded Duo half's (the picture fills it).
    private var viewerFills = false
    var canFitToPhone: Bool { macFeatures().contains(WatchShape.feature) }
    var sendShape: (CGSize) -> Bool = { _ in false }

    /// The pose the view was last measured in: its size stands for the next window's there only.
    private var viewerPose: FoldPose?

    /// A view of the window has its size. `fill`: it is a folded half's (the half's shape is what
    /// the Mac is given, never the phone layout's that may still be on screen as the poses
    /// cross-fade). Only the window in hand measures: the strip over the live words and the
    /// glance are other sizes for a moment.
    func viewerMeasured(_ size: CGSize, fill: Bool = false, interactive: Bool = true) {
        guard interactive, size != viewerSize || fill != viewerFills || viewerPose != input.pose else { return }
        viewerSize = size
        viewerFills = fill
        viewerPose = input.pose
        autoFitSoon()
    }

    // MARK: The window takes the view's shape (Oct 31 2026)

    // Sameer: "when an app is opened or the view window dimensions is changed the app should
    // default to resize to fill the view window. This should not be true for temp view window
    // changes such as when the keyboard or trackpad are opened." Every window the view opens, and
    // every pose change (the Duo folding, opening, turning), gives the Mac's window this view's
    // shape — measured only at rest, so the keyboard, the cover's trackpad or the mic never
    // reshape it. A window he sized himself (a Window menu size, a text size) is left as he
    // made it until the next window; Back to How It Was or a text size keeps that app's own size
    // from then on. A window shaped by itself goes back as it was when the view leaves it (one he
    // asked Fit to iPhone for stays, like any size he picked).

    /// The shape last sent to the Mac, to tell a real change of shape from a jitter.
    private var shapeSent: CGSize?
    private var autoFitTask: Task<Void, Never>?
    /// This window's shape is still to be given (a new window, a pose change).
    private var wantsAutoFit = false
    /// He picked a size for this window himself: nothing reshapes it until the next window.
    private var sizedByHand = false
    /// He asked for Fit to iPhone on this window: its shape stays when the view leaves.
    private var askedForFit = false
    /// The Mac's window has the view's shape because this view gave it, unasked.
    private var autoFitted = false

    /// The input page changed: back at rest, a shape still owed goes now.
    func inputPageChanged() { autoFitSoon() }

    /// The Duo's pose changed (the laptop, the book, flat, turned): the window takes the new
    /// layout's shape once the view settles.
    func poseSettled() {
        guard isOpen else { return }
        wantsAutoFit = true
        autoFitSoon()
    }

    /// The view at rest: the window in hand with nothing up that's only there for a moment — not
    /// the keyboard, not the trackpad where it takes the window's room (the cover, a regular
    /// iPhone; the inner screen's deck is a trackpad all the time).
    private var viewAtRest: Bool {
        switch input.page {
        case .keyboard: return false
        case .trackpad: return input.pose.isInner
        case .mic: return true
        }
    }

    /// Apps whose own size is kept (Back to How It Was, or a text size, picked for it).
    private static func ownSizeKey(_ t: TargetRef) -> String? { t.bundleID.map { "watch.ownSize." + $0 } }
    private static func keepsOwnSize(_ t: TargetRef) -> Bool {
        ownSizeKey(t).map { UserDefaults.standard.bool(forKey: $0) } ?? false || rememberedFit(for: t) != .normal
    }
    private static func setKeepsOwnSize(_ t: TargetRef, _ on: Bool) {
        guard let k = ownSizeKey(t) else { return }
        if on { UserDefaults.standard.set(true, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
    }

    /// A moment after the view stops changing, give the window its shape if it still wants one.
    private func autoFitSoon() {
        autoFitTask?.cancel()
        guard wantsAutoFit, isOpen, !glancing, !sizedByHand, let target, !isDesktop,
              canFitToPhone, !Self.keepsOwnSize(target) else { return }
        autoFitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.applyAutoFit()
        }
    }

    private func applyAutoFit() {
        guard wantsAutoFit, isOpen, !glancing, !sizedByHand, phase == .live, viewAtRest, let target, !isDesktop,
              canFitToPhone, !Self.keepsOwnSize(target) else { return }
        // Folded, the half's own measure, never the phone layout's still fading out.
        guard !fillsView || viewerFills, viewerSize.width > 40, viewerSize.height > 40 else { return }
        let size = viewerSize
        wantsAutoFit = false
        if let was = shapeSent {
            let aspect = size.width / size.height, before = was.width / was.height
            guard abs(aspect - before) / before > 0.04 else { return }
        }
        guard sendShape(size) else { return }
        shapeSent = size
        if !askedForFit { autoFitted = true }
        if wholeWindow { wholeWindow = false }
        if let viewKey { UserDefaults.standard.removeObject(forKey: viewKey) }
        // All of it shows: one finger scrolls the Mac's window (nothing to pan to).
        Self.setFitted(target, true)
        drag = .scroll
        log?.add("watching: the window takes the view's shape (\(Int(size.width))×\(Int(size.height)))")
    }

    /// The view's shape goes with the window's request when it's known already — the view was
    /// measured in this pose before (Nov 4 2026, Sameer: "still pretty stuttery with window
    /// resizes as you open the app"): the Mac gives the window that shape before its first
    /// picture, so it opens at its final shape, with no picture at the old one and no jump to
    /// the new half a second in. The view's own measure still checks it once it's live (a shape
    /// off by more than 4% is sent again).
    private func shapeAhead() {
        guard macFeatures().contains(WatchShape.aheadFeature),
              !glancing, !sizedByHand, let target, !isDesktop, canFitToPhone, !Self.keepsOwnSize(target),
              !fullScreen, viewerPose == input.pose, viewerFills == fillsView,
              viewerSize.width > 40, viewerSize.height > 40, sendShape(viewerSize) else { return }
        shapeSent = viewerSize
        if !askedForFit { autoFitted = true }
        if wholeWindow { wholeWindow = false }
        if let viewKey { UserDefaults.standard.removeObject(forKey: viewKey) }
        Self.setFitted(target, true)
        drag = .scroll
        log?.add("watching: the window opens at the view's shape (\(Int(viewerSize.width))×\(Int(viewerSize.height)))")
    }

    /// The view leaves a window it shaped by itself: the Mac puts it back as it was.
    private func putBackAutoFit() {
        defer { autoFitted = false }
        guard autoFitted, !sizedByHand, !askedForFit, canWindowCommands else { return }
        _ = sendWindow(.restore)
        log?.add("watching: the window goes back to its own size")
    }

    /// Fit to iPhone: the Mac gives the window this view's shape, as big as its screen allows, so
    /// the whole window fills the view. Takes over from Aa, like the Window menu's sizes, and
    /// stays when the view leaves (it was asked for); it follows the view's shape as the pose
    /// changes, as every window does.
    func fitToPhone() {
        touch()
        guard viewerSize.width > 40, viewerSize.height > 40, sendShape(viewerSize) else { return }
        shapeSent = viewerSize
        wantsAutoFit = false
        sizedByHand = false
        askedForFit = true
        autoFitted = false
        Haptics.press()
        if fit != .normal { setFitLocally(.normal) }
        if wholeWindow { toggleWholeWindow() }
        // Start from the whole window, not a zoom kept from its old shape.
        if let viewKey { UserDefaults.standard.removeObject(forKey: viewKey) }
        // All of it shows, so there's nothing to pan to: one finger scrolls the Mac's window, now
        // and whenever this app's window opens while it keeps this shape.
        if let target { Self.setFitted(target, true); Self.setKeepsOwnSize(target, false) }
        drag = .scroll
        say("\(name)'s window now has your iPhone's shape — all of it fits here, and one finger scrolls it", symbol: "iphone.gen3")
        log?.add("watching: fit to iPhone")
    }

    /// The Mac confirmed the window is gone: this view closes as Done does, and the main screen
    /// hears which window (its status line, and Send to no longer pointing at it).
    var onClosed: (String, TargetRef?) -> Void = { _, _ in }
    private func windowClosed() {
        let n = name, t = target
        log?.add("watching: the window closed — back to the main screen")
        close()
        Haptics.arrived()
        onClosed(n, t)
    }

    /// Apps whose window was fitted to the phone (and not sized since): they open in Scroll.
    private static func fittedKey(_ t: TargetRef) -> String? { t.bundleID.map { "watch.fitted." + $0 } }
    static func isFitted(_ t: TargetRef) -> Bool { fittedKey(t).map { UserDefaults.standard.bool(forKey: $0) } ?? false }
    static func setFitted(_ t: TargetRef, _ on: Bool) {
        guard let k = fittedKey(t) else { return }
        if on { UserDefaults.standard.set(true, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
    }

    /// The whole screen (DesktopWatch): a Mac that can show it, and whether it's what's shown.
    var canWatchDesktop: Bool { macFeatures().contains(DesktopWatch.feature) }
    var isDesktop: Bool { DesktopWatch.isDesktop(target) }
    /// On the whole screen: the app in front, from the Mac's frames.
    @Published private(set) var front: FrontApp?

    /// The Mac presses keys beyond Esc, the arrows and Return (⌃C, Tab, ⌘Return…).
    var canPressKeys: Bool { macFeatures().contains(WatchKey.feature) }
    var sendKey: (WatchKey) -> Bool = { _ in false }

    /// A key from the More Keys menu, pressed in the window; the view goes to where it answers.
    func press(_ k: WatchKey) {
        touch()
        guard sendKey(k) else { return }
        Haptics.press()
        inputSeq &+= 1
        recenter &+= 1
        log?.add("watching: key")
    }

    /// A Window menu command. A size picked there takes over from Aa's text size.
    func window(_ c: WatchWindowCommand) {
        touch()
        guard sendWindow(c) else { return }
        Haptics.press()
        inputSeq &+= 1
        if c.frame(in: .zero) != nil || c == .restore, fit != .normal { setFitLocally(.normal) }
        // Another size: no longer the phone's shape, and nothing reshapes it by itself until the
        // next window — Back to How It Was keeps this app's own size from now on.
        if c.frame(in: .zero) != nil || c == .restore, let target {
            Self.setFitted(target, false)
            sizedByHand = true
            autoFitted = false
            wantsAutoFit = false
            if c == .restore { Self.setKeepsOwnSize(target, true) }
        }
        log?.add("watching: window \(c.rawValue)")
    }

    /// The zoom-out button: the whole window, or back to the column you type in.
    func toggleWholeWindow() {
        touch()
        Haptics.pick()
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

    /// Scroll that the zoom chose, not him: zooming back in returns to Pan.
    private var autoScroll = false

    /// The whole window is on screen (fully zoomed out): nothing to pan to, so one finger scrolls
    /// the Mac's window; zoomed back in, it pans again — unless he picked the mode himself.
    func wholeShown(_ whole: Bool) {
        if whole, drag == .pan {
            drag = .scroll
            autoScroll = true
            log?.add("watching: whole window — scroll")
        } else if !whole, autoScroll, drag == .scroll {
            drag = .pan
            autoScroll = false
        }
    }

    func setDrag(_ d: Drag) {
        autoScroll = false
        guard d != drag else { return }
        touch()
        Haptics.pick()
        drag = d
        log?.add("watching: one finger \(d == .pan ? "moves the picture" : "scrolls the window")")
        say(d == .pan ? "One finger moves the picture" : "One finger scrolls your Mac's window", symbol: d == .pan ? "hand.draw" : "arrow.up.and.down")
    }

    /// An answer tapped: the Mac presses the keys that give it, if the question is still up.
    func choose(_ index: Int) {
        guard let p = answers, p.choices.indices.contains(index) else { return }
        touch()
        Haptics.press()
        answeredID = p.id
        objectWillChange.send()
        sendChoose(p, index)
        inputSeq &+= 1
        recenter &+= 1
        log?.add("watching: answered a prompt")
    }

    /// Esc · ↑ · ↓ · Return for this prompt, instead of its answers (no haptic: nothing happens
    /// on the Mac).
    func showKeys() {
        touch()
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
        Haptics.pick()
        fit = f
        if let target { Self.remember(f, for: target); Self.setFitted(target, false) }
        sizedByHand = true
        autoFitted = false
        wantsAutoFit = false
        // A new text size reshapes the window: start from its fit, not the old zoom.
        if let viewKey { UserDefaults.standard.removeObject(forKey: viewKey) }
        if sendFit(f) {
            say(f.explanation(appName: name), symbol: "textformat.size")
            recenter &+= 1
        } else {
            say("Your Mac can't resize windows yet — update Macrophone there", symbol: "exclamationmark.triangle")
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

    /// A sentence over the window for a moment, with the symbol of what changed.
    func say(_ words: String, symbol: String) {
        noteWords = words
        noteSymbol = symbol
        noteSeq &+= 1
    }

    // MARK: From the Mac

    func received(_ state: WatchState) {
        guard isOpen, !phase.isPaused else { return }
        switch state {
        case .live(let name):
            appName = name
            if hasPicture, !stale { phase = .live }
        case .needsPermission: phase = .needsPermission
        case let .unavailable(why, canReveal, closed):
            // The window is gone for good (the Mac waited a beat and confirmed): the window view
            // closes by itself and the main screen is back (Oct 19 2026, Sameer: "when I close a
            // window, the app should just go back to the selector screen"). Never the whole screen.
            if closed, !isDesktop { windowClosed(); return }
            phase = .unavailable(why, canReveal: canReveal)
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
            self.show(img, appName: frame.appName, bundleID: frame.bundleID, focus: frame.focus, prompt: frame.prompt, bytes: data.count, how: "picture", points: frame.points, cursor: frame.cursor)
        }
    }

    /// The window's size in points as the Mac last said it (nil from a Mac that doesn't).
    private var lastPoints: CGSize?

    /// Counts a frame put on screen: the busiest second so far, kept as they arrive.
    private func countFrame() {
        videoFrames += 1
        let now = CACurrentMediaTime()
        recentFrames.append(now)
        if recentFrames.count > 1, let first = recentFrames.first, now - first >= 1 {
            recentFrames.removeFirst(recentFrames.firstIndex { now - $0 < 1 } ?? recentFrames.count)
        }
        peakPerSecond = max(peakPerSecond, recentFrames.count)
    }

    /// A frame of video, handed to the canvas in order (the system decodes and draws it). Only
    /// the words (the question, the place to type) when there's nothing to decode.
    func received(_ frame: WatchVideoFrame) {
        guard isOpen, !phase.isPaused else { return }
        // One count for pictures, frames and words: the first picture of a video watch is a JPEG.
        if isDesktop, front != frame.front { front = frame.front }
        if frame.isWordsOnly {
            newestSeq = frame.seq
            words(appName: frame.appName, bundleID: frame.bundleID, focus: frame.focus, prompt: frame.prompt, cursor: frame.cursor)
            return
        }
        guard WatchVideoFrame.canDecode(seq: frame.seq, keyframe: frame.keyframe, newest: newestSeq, waitingForKeyframe: waitingForKeyframe) else {
            if !waitingForKeyframe { log?.add("watching: a frame was missed — asking for a keyframe") }
            waitingForKeyframe = true
            askKeyframe()
            return
        }
        newestSeq = frame.seq
        #if DEBUG
        let t0 = Self.timing ? CACurrentMediaTime() : 0
        #endif
        guard video.enqueue(frame) else {
            log?.add("watching: a frame didn't decode — asking for a keyframe")
            waitingForKeyframe = true
            askKeyframe()
            return
        }
        waitingForKeyframe = false
        countFrame()
        videoBytes += frame.data.count
        // The first frame of a new window (a switch, a resize): the stale picture goes, the
        // picture under the video with it.
        if stale { stale = false; image = nil }
        if videoSize != video.frameSize || frame.points != lastPoints {
            lastPoints = frame.points
            videoSize = video.frameSize
            notePictureSize(video.frameSize, points: frame.points)
        }
        words(appName: frame.appName, bundleID: frame.bundleID, focus: frame.focus, prompt: frame.prompt, cursor: frame.cursor)
        if phase != .live { phase = .live }
        #if DEBUG
        if Self.timing, framePathMicros.count < 20_000 { framePathMicros.append(Int((CACurrentMediaTime() - t0) * 1_000_000)) }
        #endif
        if awaitingFirstPicture {
            awaitingFirstPicture = false
            cameAlive &+= 1
            cameLive()
            log?.add("watching: first \(frame.keyframe ? "keyframe" : "frame") \(Int(Date().timeIntervalSince(askedAt) * 1000)) ms after asking, \(frame.data.count / 1024) KB")
            autoFitSoon()
        }
    }

    #if DEBUG
    /// MACROPHONE_WATCH_TIMING=1: the main thread's time per frame goes in the log at the end.
    private static let timing = ProcessInfo.processInfo.environment["MACROPHONE_WATCH_TIMING"] == "1"
    #endif

    /// Asks the Mac for a frame that stands on its own, at most once a second — and never drops
    /// the ask: one within the second goes when it's up, and it's asked again each second until a
    /// frame that stands on its own arrives (Oct 18 2026: a dropped ask on a still window, which
    /// sends nothing new, left the window black for 4–6 seconds).
    private func askKeyframe() {
        let wait = 1 - Date().timeIntervalSince(keyframeAskedAt)
        if wait <= 0 {
            keyframeAskedAt = Date()
            _ = sendKeyframe()
        }
        keyframeRetry?.cancel()
        keyframeRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(wait, 1) * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isOpen, !self.phase.isPaused, self.waitingForKeyframe else { return }
            self.askKeyframe()
        }
    }
    private var keyframeRetry: Task<Void, Never>?

    /// Each published change re-renders every view watching this; only what changed is set.
    private func show(_ img: UIImage, appName: String, bundleID: String?, focus: CGRect?, prompt: WatchPrompt?, bytes: Int, how: String, points: CGSize? = nil, cursor: CGPoint? = nil) {
        if image?.size != img.size || points != lastPoints { lastPoints = points; notePictureSize(img.size, points: points) }
        image = img
        if stale { stale = false }
        countFrame()
        words(appName: appName, bundleID: bundleID, focus: focus, prompt: prompt, cursor: cursor)
        if phase != .live { phase = .live }
        if awaitingFirstPicture {
            awaitingFirstPicture = false
            cameAlive &+= 1
            cameLive()
            log?.add("watching: first \(how) \(Int(Date().timeIntervalSince(askedAt) * 1000)) ms after asking, \(bytes / 1024) KB")
            autoFitSoon()
        }
    }

    private func words(appName: String, bundleID: String?, focus: CGRect?, prompt: WatchPrompt?, cursor: CGPoint? = nil) {
        // Where the Mac's own pointer is: the trackpad's pointer starts there (Oct 19 2026).
        if let cursor { input.macCursor(cursor) }
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

    /// The window's size in points — the trackpad moves the pointer in those. A Mac that says it
    /// (`points`, Oct 19 2026, the polish pass) is believed: a 1× display, or a picture narrowed
    /// for a remote link, is no longer taken for a Retina window at full size. From a Mac that
    /// doesn't, the picture's pixels halved (a Retina Mac at home).
    private func notePictureSize(_ s: CGSize, points: CGSize? = nil) {
        if let points, points.width > 0, points.height > 0 { input.windowPoints = points; return }
        guard s.width > 0, s.height > 0 else { return }
        input.windowPoints = CGSize(width: s.width / 2, height: s.height / 2)
    }

    /// The link came or went.
    func linkChanged(connected: Bool) {
        guard isOpen else { return }
        input.linkChanged(connected: connected)
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
