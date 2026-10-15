import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import ImageIO
import MacrophoneKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Watching (Oct 14 2026): a connected phone asks to see the window of the place it sends to, and
/// this sends it pictures of that one window — about two a second, and only when it changed —
/// plus the phone's keys (Esc, ↑, ↓, Return) and clicks where it's tapped. Never the whole screen,
/// never another window; it stops when the phone stops looking or goes away.
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
        var lastDigest: Data?
        var lastState: WatchState?
        var seq = 0
        /// Capture again right away (an action just happened).
        var kick = false
        init(peer: UUID, target: TargetRef) { self.peer = peer; self.target = target }
    }

    private var watches: [UUID: Watch] = [:]
    private var content: SCShareableContent?
    private var contentAt = Date.distantPast
    private var askedForPermission = false

    /// Who's watching what, for the menu ("Your iPhone is watching Claude").
    private(set) var watching: [UUID: String] = [:]
    var onChange: () -> Void = {}

    init(app: AppModel) { self.app = app }

    static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    // MARK: Start / stop

    func set(_ target: TargetRef?, for peer: UUID) {
        guard let target else { stop(peer); return }
        if let w = watches[peer] {
            if w.target != target {
                w.target = target
                w.windowID = nil
                w.lastDigest = nil
                w.focus = nil
                w.focusAt = .distantPast
            }
            w.kick = true
            return
        }
        let w = Watch(peer: peer, target: target)
        watches[peer] = w
        app.log.add("watching started (\(AppModel.kind(SendSelection(target: target))))")
        w.task = Task { [weak self] in await self?.run(w) }
    }

    func stop(_ peer: UUID) {
        guard let w = watches.removeValue(forKey: peer) else { return }
        w.task?.cancel()
        watching[peer] = nil
        onChange()
        app.log.add("watching stopped")
    }

    func stopAll() { watches.keys.forEach(stop) }

    // MARK: The loop

    private func run(_ w: Watch) async {
        while !Task.isCancelled, watches[w.peer] === w {
            let state = await captureOnce(w)
            if let state, state != w.lastState {
                w.lastState = state
                if case .live(let name) = state { watching[w.peer] = name } else { watching[w.peer] = nil }
                onChange()
                await app.server.send(.watchState(state), to: w.peer)
            }
            // About two a second; sooner after an action; slower while there's nothing to show.
            let wait = (state.map { if case .live = $0 { return 0.5 } else { return 1.5 } } ?? 0.5)
            var waited = 0.0
            while waited < wait, !Task.isCancelled, !w.kick {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 0.05
            }
            w.kick = false
        }
    }

    /// One look at the window: sends a picture if it changed, and returns how watching is going.
    private func captureOnce(_ w: Watch) async -> WatchState? {
        // Where to look.
        if let reason = await resolve(w) { return reason }
        guard let wid = w.windowID else { return .unavailable("Nothing to show", canReveal: false) }

        // Permission: asking ScreenCaptureKit for the windows shows the system prompt the first time.
        if !CGPreflightScreenCaptureAccess() {
            if !askedForPermission {
                askedForPermission = true
                CGRequestScreenCaptureAccess()
            }
            if content == nil || Date().timeIntervalSince(contentAt) > 3 {
                guard (try? await refreshContent()) != nil else { return .needsPermission }
            }
        }

        guard let scw = await scWindow(wid) else {
            w.windowID = nil
            return .unavailable("\(w.appName)'s window isn't open", canReveal: false)
        }
        guard scw.isOnScreen else {
            return .unavailable("\(w.appName)'s window is minimized or on another desktop", canReveal: true)
        }

        // Where the place to type is (every few seconds; off the main thread — it walks the window).
        if Date().timeIntervalSince(w.focusAt) > 5 {
            w.focusAt = Date()
            let pid = w.pid, bid = w.bundleID
            w.focus = await Task.detached(priority: .utility) { Self.focusRect(pid: pid, windowID: wid, bundleID: bid) }.value ?? w.focus
        }

        let filter = SCContentFilter(desktopIndependentWindow: scw)
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let pxW = max(1, scw.frame.width * scale), pxH = max(1, scw.frame.height * scale)
        let k = min(1, 1500 / pxW)
        cfg.width = Int(pxW * k)
        cfg.height = Int(pxH * k)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            if !CGPreflightScreenCaptureAccess() { return .needsPermission }
            content = nil
            return .unavailable("Couldn't see \(w.appName)'s window", canReveal: true)
        }
        guard let jpeg = Self.jpeg(image, quality: 0.6) else { return nil }
        let digest = Data(SHA256.hash(data: jpeg))
        let live = WatchState.live(appName: w.appName)
        guard digest != w.lastDigest else { return live }
        w.lastDigest = digest
        w.seq += 1
        var data = jpeg
        if data.count > 900_000, let smaller = Self.jpeg(image, quality: 0.35) { data = smaller }
        let frame = WatchFrame(seq: w.seq, jpeg: data, width: image.width, height: image.height,
                               appName: w.appName, bundleID: w.bundleID, focus: w.focus)
        // Waits until it's on the wire: a slow link gets fewer pictures, never a backlog.
        await app.server.send(.watchFrame(frame), to: w.peer)
        return live
    }

    /// Finds the window to show (once; again only when it's gone). Nil = found.
    private func resolve(_ w: Watch) async -> WatchState? {
        if let id = w.windowID, WindowServer.exists(id),
           NSRunningApplication(processIdentifier: w.pid).map({ !$0.isTerminated }) ?? false {
            return nil
        }
        w.windowID = nil
        w.lastDigest = nil
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
    func click(_ p: CGPoint, for peer: UUID) {
        act(on: peer, what: "click") { wid in await Self.click(window: wid, at: p) }
    }

    /// Brings the watched window forward if it isn't already the front one, does `body`, and
    /// shows the result: a picture right away, and another once the app has answered.
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
            await body(wid)
            if !quiet { self?.app.log.add("watch \(what)") }
            w.kick = true
            try? await Task.sleep(nanoseconds: 400_000_000)
            w.kick = true
        }
    }

    /// A left click at a fraction of the window. The pointer goes there for the click and is put back.
    private static func click(window id: CGWindowID, at p: CGPoint) async {
        guard let b = WindowServer.appWindows().first(where: { $0.id == id })?.bounds else { return }
        let pt = CGPoint(x: b.minX + p.x * b.width, y: b.minY + p.y * b.height)
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
