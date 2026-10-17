import MacrophoneKit
import SwiftUI
import UIKit

/// Watching (Oct 14 2026): the picked app's window on the Mac, live, in the area above the
/// Thread — a tap clicks there, and a key row sends Esc, ↑, ↓ and Return. It opens after a dictation is sent into an app
/// (Settings › Show the app after sending) or from the Watch button by Send to; it pauses after
/// two idle minutes or when the app leaves the screen, and Done closes it.
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
    @Published private(set) var image: UIImage?
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

    /// The person zoomed or moved the picture away from the newest output (Newest shows).
    @Published private(set) var movedAway = false
    func setMovedAway(_ b: Bool) { if b != movedAway { movedAway = b } }
    /// Sends the watch request to the Mac; false when it isn't connected.
    var sendWatch: (TargetRef?) -> Bool = { _ in false }
    var sendAction: (WatchAction) -> Void = { _ in }
    var sendClick: (CGPoint) -> Void = { _ in }
    var sendScroll: (CGPoint, CGVector) -> Void = { _, _ in }
    var log: DiagnosticLog?

    private var idleTask: Task<Void, Never>?
    private var newestSeq = 0
    /// No picture has arrived since the last open or resume.
    private var awaitingFirstPicture = true
    static let idleLimit: TimeInterval = 120

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
        if !isOpen { drag = .pan }
        if switching {
            image = nil
            appName = ""
            bundleID = target.bundleID
            focus = nil
            prompt = nil
            keysInstead = false
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
        log?.add("watching closed")
    }

    /// Ask the Mac again (open, resume, reconnect).
    private func start() {
        guard let target else { return }
        // The Mac starts a fresh watch (its pictures count from 1 again), so does the phone.
        newestSeq = 0
        awaitingFirstPicture = true
        phase = image == nil ? .starting : phase == .live ? .live : .starting
        if !sendWatch(target) { phase = .offline }
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

    /// A swipe on the picture: scroll the Mac's window there (no haptic — it's continuous).
    func scroll(at p: CGPoint, by d: CGVector) {
        touch()
        sendScroll(p, d)
    }

    func setDrag(_ d: Drag) {
        guard d != drag else { return }
        touch()
        Haptics.tick()
        drag = d
        log?.add("watching: one finger \(d == .pan ? "moves the picture" : "scrolls the window")")
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
            self.image = img
            self.appName = frame.appName
            self.bundleID = frame.bundleID
            // Only a real move re-centres the view; the frame jitters as the window redraws.
            if WatchFrame.focusMoved(from: self.focus, to: frame.focus) { self.focus = frame.focus }
            if frame.prompt?.id != self.prompt?.id {
                // A new question (or none): its answers show, and "Keys" applies to one prompt only.
                self.keysInstead = false
                if frame.prompt != nil { self.answeredID = nil }
            }
            self.prompt = frame.prompt
            self.phase = .live
            if self.awaitingFirstPicture {
                self.awaitingFirstPicture = false
                self.cameAlive &+= 1
            }
        }
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
