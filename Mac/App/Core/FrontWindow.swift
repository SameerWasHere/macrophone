import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacrophoneKit

/// What's in front on your Mac (Nov 7 2026): the window in front, told to every connected phone
/// that shows it (`FrontWindow`, MacrophoneKit), so "Now on your Mac · Claude — Fix the login
/// bug" is one tap away on the iPhone. Lifted from the Handoff try (that branch's
/// `HandoffOffer`): the same read, the same never-offered rules, no NSUserActivity — macOS only
/// advertises the active app's activity, and a menu bar app is almost never active.
///
/// What it reads: the frontmost app (NSWorkspace) and its front window from the window server
/// (its number, and its title — Screen Recording gives the title; else Accessibility's focused
/// window). It looks at once when the front app changes, then every 2 s while the front window
/// keeps changing, every 6 s after a quiet minute — only while a phone that shows it is connected.
/// Macrophone itself in front changes nothing (the last real app's window stays). Nothing is
/// offered (nil) for a password manager or the keychain (`FrontWindow.neverShown`), an app that
/// isn't a regular one (a system dialog), a window its app keeps out of screen capture, a password
/// field holding Secure Input in the front app, a locked screen or the session switched away.
/// Sent through `FrontWindowPacer`: a change waits half a second to stay put, never more than two
/// a second. The log has counts only — never a window's title.
@MainActor
final class FrontWindowWatcher {
    private unowned let app: AppModel
    /// The window in front as last read (nil: nothing safe to offer, or not read yet).
    private(set) var current: FrontWindow?
    private var readAt: Date?
    private var pacer = FrontWindowPacer()
    private var sendTimer: Timer?
    private var lookTimer: Timer?
    private var lastChange = Date()
    private var tokens: [NSObjectProtocol] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let readQueue = DispatchQueue(label: "macrophone.frontwindow", qos: .utility)
    private var reading = false
    private var isOn = false
    /// Told to the phones since they started listening (the log's count).
    private var told = 0

    nonisolated private static var prints: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["MACROPHONE_FRONT_PRINT"] == "1"
        #else
        return false
        #endif
    }

    init(app: AppModel) {
        self.app = app
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.frontChanged() }
            })
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            tokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.offer(nil, why: "the screen is asleep or another user is in front") }
            })
        }
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.offer(nil, why: "the screen is locked") }
        })
        tokens.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontChanged() }
        })
    }

    /// A phone came or went: look while one that shows it is connected, rest otherwise.
    func phonesChanged() {
        let on = !app.server.phones(with: FrontWindow.feature).isEmpty
        guard on != isOn else { return }
        isOn = on
        if on {
            told = 0
            app.log.add("front window: telling the phones what's in front")
            frontChanged()
        } else {
            lookTimer?.invalidate(); lookTimer = nil
            sendTimer?.invalidate(); sendTimer = nil
            if told > 0 { app.log.add("front window: \(told) change\(told == 1 ? "" : "s") told") }
        }
    }

    /// For a phone that just connected: what's in front now, read at once when the last read is
    /// old (the poll only runs while a phone listens, so the first phone finds none).
    func now() -> FrontWindow? {
        if let readAt, Date().timeIntervalSince(readAt) < 3 { return current }
        if let w = Self.readNow(ownPID: ownPID) { current = w.window; readAt = Date() }
        return current
    }

    // MARK: Looking

    private func frontChanged() {
        guard isOn else { return }
        lastChange = Date()
        look()
        scheduleLook()
    }

    private func scheduleLook() {
        lookTimer?.invalidate()
        let quiet = Date().timeIntervalSince(lastChange) > 60
        lookTimer = Timer.scheduledTimer(withTimeInterval: quiet ? 6 : 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOn else { return }
                self.look()
                self.scheduleLook()
            }
        }
        lookTimer?.tolerance = 0.5
    }

    /// The outcome of one look: a window to offer (or nil), and why when nil. Nil itself: no
    /// change (Macrophone in front keeps the last real app's window).
    struct Look: Sendable {
        var window: FrontWindow?
        var why: String
    }

    /// What's in front, read off the main thread (the Accessibility fallback can take a moment).
    private func look() {
        guard isOn, !reading else { return }
        guard let front = Self.frontApp else { return }
        let pid = front.processIdentifier
        let bid = front.bundleIdentifier ?? ""
        if pid == ownPID || FrontWindow.isMacrophone(bid) { return }
        reading = true
        let own = ownPID
        readQueue.async { [weak self] in
            let look = Self.read(front: front, ownPID: own)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading = false
                    guard self.isOn, let look, Self.frontApp?.processIdentifier == pid else { return }
                    self.offer(look.window, why: look.why)
                }
            }
        }
    }

    /// One read of the app in front and its front window, anywhere (the main thread for a phone
    /// just connected, the read queue otherwise). Nil when Macrophone itself is in front.
    nonisolated static func readNow(ownPID: pid_t) -> Look? {
        guard let front = frontApp else { return nil }
        return read(front: front, ownPID: ownPID)
    }

    nonisolated private static func read(front: NSRunningApplication, ownPID: pid_t) -> Look? {
        let pid = front.processIdentifier
        let bid = front.bundleIdentifier ?? ""
        if pid == ownPID || FrontWindow.isMacrophone(bid) { return nil }
        guard FrontWindow.mayShow(bid), front.activationPolicy == .regular else { return Look(window: nil, why: "the app in front isn't offered") }
        if screenLocked { return Look(window: nil, why: "the screen is locked") }
        if SecureInput.isActive(frontPID: pid) { return Look(window: nil, why: "a password field is in front") }
        let name = front.localizedName ?? bid
        switch frontWindow(of: pid) {
        case .concealed: return Look(window: nil, why: "the window in front is kept out of screen capture")
        case let .window(id, title): return Look(window: FrontWindow(bundleID: bid, appName: name, window: id, title: title), why: "")
        case .none: return Look(window: FrontWindow(bundleID: bid, appName: name, window: nil, title: nil), why: "")
        }
    }

    enum FrontRead: Sendable {
        case window(CGWindowID, String?)
        /// Its app keeps it out of screen capture (a password manager, a DRM player).
        case concealed
        /// No window seen (the app is in front with none open).
        case none
    }

    /// The app's front-most window on this desktop: layer 0, a real size, the first in the window
    /// server's front-to-back list. Its title from the window server (with Screen Recording),
    /// else Accessibility's focused window.
    nonisolated static func frontWindow(of pid: pid_t) -> FrontRead {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return .none }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.width >= 160, rect.height >= 90,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) >= 0.05 else { continue }
            if (w[kCGWindowSharingState as String] as? Int) == 0 { return .concealed }
            var title = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if title == nil { title = axTitle(pid) }
            return .window(id, title)
        }
        return .none
    }

    nonisolated private static func axTitle(_ pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let win, CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        var t: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success else { return nil }
        return (t as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    nonisolated static var screenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (d["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        if let onConsole = d[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return true }
        return false
    }

    /// The app in front — or, DEBUG, `MACROPHONE_FRONT_FAKE=<bundle id>` taken as in front, so it
    /// can be proven without taking the focus from whatever is really in front.
    nonisolated private static var frontApp: NSRunningApplication? {
        #if DEBUG
        if let bid = ProcessInfo.processInfo.environment["MACROPHONE_FRONT_FAKE"], !bid.isEmpty {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
        }
        #endif
        return NSWorkspace.shared.frontmostApplication
    }

    // MARK: Telling

    private var lastWhy = ""

    private func offer(_ w: FrontWindow?, why: String) {
        current = w
        readAt = Date()
        if w != nil { lastWhy = "" }
        if w == nil, why != lastWhy {
            lastWhy = why
            if isOn { app.log.add("front window: nothing offered — \(why)") }
        }
        guard isOn else { return }
        pacer.saw(w, at: Date())
        scheduleSend()
    }

    private func scheduleSend() {
        sendTimer?.invalidate()
        guard let due = pacer.due else { return }
        sendTimer = Timer.scheduledTimer(withTimeInterval: max(0.02, due.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOn else { return }
                guard let w = self.pacer.take(at: Date()) else { self.scheduleSend(); return }
                self.told += 1
                self.app.server.broadcastFrontWindow(w)
                if Self.prints {
                    print("FRONT told \(w.map { "\($0.bundleID)#\($0.windowKey ?? "") · \($0.line)" } ?? "none")")
                    fflush(stdout)
                }
            }
        }
        sendTimer?.tolerance = 0.05
    }
}

extension AppModel: LinkServerFrontWindowDelegate {
    func frontWindow(_ server: LinkServer, for peerID: UUID) -> FrontWindow? { frontWindow.now() }
}
