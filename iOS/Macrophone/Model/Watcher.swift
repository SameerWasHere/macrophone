import MacrophoneKit
import SwiftUI
import UIKit
import Vision

/// Watching (Oct 14 2026): the picked app's window on the Mac, live, in the area above the
/// Thread — with scroll, Return, Esc and Copy. It opens after a dictation is sent into an app
/// (Settings › Show the app after sending) or from the Watch button by Send to; it pauses after
/// two idle minutes or when the app leaves the screen, and Done closes it.
@MainActor
final class Watcher: ObservableObject {
    enum Phase: Equatable {
        /// Asked the Mac; no picture yet.
        case starting
        case live
        /// Stopped to save battery (idle, or the app left the screen); the last picture stays.
        case paused
        /// Screen Recording is off for Macrophone on the Mac.
        case needsPermission
        /// Nothing to show, and why ("Claude isn't open on your Mac").
        case unavailable(String, canReveal: Bool)
        /// The Mac isn't connected.
        case offline
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

    /// The part of the picture on screen (fractions of it), for Copy.
    var visibleRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Sends the watch request to the Mac; false when it isn't connected.
    var sendWatch: (TargetRef?) -> Bool = { _ in false }
    var sendAction: (WatchAction) -> Void = { _ in }
    var log: DiagnosticLog?

    private var idleTask: Task<Void, Never>?
    private var newestSeq = 0
    static let idleLimit: TimeInterval = 120

    /// Terminals and agent apps: Return approves, Esc stops.
    var agentLike: Bool { WatchApps.isAgentLike(bundleID ?? target?.bundleID) }

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
        if switching {
            image = nil
            appName = ""
            bundleID = target.bundleID
            focus = nil
            newestSeq = 0
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
        phase = image == nil ? .starting : phase == .live ? .live : .starting
        if !sendWatch(target) { phase = .offline }
        touch()
    }

    func pause() {
        guard isOpen, phase != .paused else { return }
        idleTask?.cancel()
        _ = sendWatch(nil)
        phase = .paused
        log?.add("watching paused")
    }

    func resume() {
        guard isOpen else { return }
        Haptics.tick()
        start()
    }

    /// Something the person did here: keeps it live for another two minutes.
    func touch() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleLimit * 1e9))
            guard !Task.isCancelled else { return }
            self?.pause()
        }
    }

    func perform(_ action: WatchAction) {
        touch()
        Haptics.tick()
        sendAction(action)
        if action == .scrollDown || action == .returnKey || action == .escape { recenter &+= 1 }
    }

    // MARK: From the Mac

    func received(_ state: WatchState) {
        guard isOpen, phase != .paused else { return }
        switch state {
        case .live(let name):
            appName = name
            if image != nil { phase = .live }
        case .needsPermission: phase = .needsPermission
        case let .unavailable(why, canReveal): phase = .unavailable(why, canReveal: canReveal)
        case .stopped:
            // Stopped from the Mac's menu: the picture stays, paused.
            idleTask?.cancel()
            phase = .paused
        }
    }

    func received(_ frame: WatchFrame) {
        guard isOpen, phase != .paused, frame.seq > newestSeq || frame.seq == 1 else { return }
        newestSeq = frame.seq
        let data = frame.jpeg
        Task {
            // Decoded off the main thread so the mic and the Thread never stutter.
            let img = await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
            guard let img, self.isOpen, self.phase != .paused, frame.seq >= self.newestSeq || frame.seq == 1 else { return }
            self.image = img
            self.appName = frame.appName
            self.bundleID = frame.bundleID
            self.focus = frame.focus
            self.phase = .live
        }
    }

    /// The link came or went.
    func linkChanged(connected: Bool) {
        guard isOpen else { return }
        if connected {
            if phase == .offline { start() }
        } else if phase != .paused {
            phase = .offline
        }
    }

    /// After a dictation lands somewhere else, the view follows it.
    func follow(_ target: TargetRef) {
        if isOpen, self.target == target, phase != .paused { recenter &+= 1; return }
        open(target)
    }

    // MARK: Copy

    /// The words in the part of the window on screen, read here on the iPhone. Returns the number
    /// of lines copied (0 = nothing readable).
    func copyVisibleText() async -> Int {
        touch()
        guard let cg = image?.cgImage else { return 0 }
        let r = visibleRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let crop = CGRect(x: r.minX * CGFloat(cg.width), y: r.minY * CGFloat(cg.height),
                          width: r.width * CGFloat(cg.width), height: r.height * CGFloat(cg.height)).integral
        let part = cg.cropping(to: crop) ?? cg
        let lines: [String] = await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: part).perform([request])
            let observations = request.results ?? []
            // Top to bottom (Vision's origin is bottom-left).
            return observations.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                .compactMap { $0.topCandidates(1).first?.string }
        }.value
        guard !lines.isEmpty else { return 0 }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        return lines.count
    }
}
