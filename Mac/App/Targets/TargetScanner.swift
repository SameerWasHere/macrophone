import AppKit
import ApplicationServices
import Foundation
import MacrophoneKit

/// Knows every app (and window) open on this Mac that has somewhere to type, newest first —
/// the list the iPhone picks from under Send to — and after them every other open app with a
/// window (`canType: false`, Oct 18 2026: the words go wherever he tapped into a text box there).
/// docs/TARGETS.md has the rules.
///
/// Cost: it only runs while someone could look at the list (a phone is connected, or a
/// Macrophone window or the menu is open). Then it's driven by events — apps launching, quitting
/// and coming forward, windows opening, closing and being renamed — coalesced, and every
/// Accessibility walk is bounded and runs on its own queue. Idle, it does nothing at all.
final class TargetScanner: @unchecked Sendable {
    /// The list changed (main thread).
    var onChange: (@MainActor ([LiveTarget]) -> Void)?
    @MainActor private(set) var targets: [LiveTarget] = []

    private let queue = DispatchQueue(label: "macrophone.targets", qos: .utility)
    private let ownBundleID = Bundle.main.bundleIdentifier ?? ""

    // Everything below is confined to `queue`.
    private var active = false
    private var apps: [pid_t: AppEntry] = [:]
    /// Windows seen through Accessibility, kept so a window on another desktop stays listed.
    private var windowCache: [CGWindowID: WindowEntry] = [:]
    private var lastActive: [String: Date] = [:]
    /// The input the person last typed in, per app (captured when they leave the app).
    private var remembered: [pid_t: Remembered] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var watched: [pid_t: Set<CGWindowID>] = [:]
    private var pending: [pid_t: DispatchWorkItem] = [:]
    private var fullScanWork: DispatchWorkItem?
    private var woke: Set<pid_t> = []
    private var icons: [String: Data] = [:]
    private var published: [LiveTarget] = []
    private var lastPublish = Date.distantPast
    private var publishWork: DispatchWorkItem?
    private var forcePublish = false
    private var seeded = false
    private var tokens: [NSObjectProtocol] = []

    struct AppInfo: Sendable {
        let pid: pid_t
        let bundleID: String
        let name: String
        let url: URL?
    }

    private struct AppEntry {
        let info: AppInfo
        /// Composer windows, front to back.
        var windows: [ScannedWindow]
        /// No window seen yet, but it's an app that always has somewhere to type (a terminal) and
        /// it has a window on another desktop.
        var appLevel: Bool
        /// Somewhere to type was found. False: an open app listed after the others, as one entry.
        var canType = true
    }

    struct ScannedWindow: Sendable {
        let id: CGWindowID
        let title: String
        let z: Int
    }

    private struct WindowEntry {
        let pid: pid_t
        var title: String
        var composer: Bool
    }

    private struct Remembered {
        let windowID: CGWindowID
        let element: AXUIElement
    }

    /// What delivery needs to know about an app.
    struct Hints {
        /// Composer windows, most recently used first.
        var windows: [ScannedWindow] = []
        /// The window the person last used in this app.
        var lastWindow: CGWindowID?
        var rememberedWindow: CGWindowID?
        var rememberedElement: AXUIElement?
    }

    #if DEBUG
    private let debugLog = ProcessInfo.processInfo.environment["MACROPHONE_TARGETS_DEBUG"] == "1"
    #else
    private let debugLog = false
    #endif

    init() {
        AX.setGlobalTimeout(0.4)
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ body: @escaping (NSRunningApplication) -> Void) {
            tokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                body(app)
            })
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in self?.activated(app) }
        on(NSWorkspace.didDeactivateApplicationNotification) { [weak self] app in
            let pid = app.processIdentifier
            self?.queue.async { self?.captureFocus(pid) }
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in self?.launched(app) }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            let pid = app.processIdentifier
            self?.queue.async { self?.terminated(pid) }
        }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] app in self?.schedule(app.processIdentifier, after: 0.3) }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in self?.schedule(app.processIdentifier, after: 0.3) }
        tokens.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleFullScan(after: 0.6)
        })
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            queue.async { self.lastActive[front] = Date() }
        }
    }

    // MARK: On / off

    /// Turn scanning on while a phone is connected or a Macrophone window/menu is open.
    @MainActor func setActive(_ on: Bool) {
        let infos = on ? Self.runningApps() : []
        queue.async {
            guard on != self.active else { return }
            self.active = on
            if on {
                self.fullScan(infos)
            } else {
                self.detachAll()
                self.pending.values.forEach { $0.cancel() }
                self.pending = [:]
                self.fullScanWork?.cancel()
            }
        }
    }

    /// Rescan everything now and publish even if nothing changed (a phone asked).
    @MainActor func refresh() {
        let infos = Self.runningApps()
        queue.async {
            guard self.active else { self.forcePublish = true; self.publishNow(); return }
            self.forcePublish = true
            self.fullScan(infos)
        }
    }

    /// Delivery's view of an app: its composer windows and what the person last typed in.
    func hints(for pid: pid_t) async -> Hints {
        await withCheckedContinuation { c in
            queue.async {
                var h = Hints()
                h.windows = self.apps[pid]?.windows ?? []
                if let r = self.remembered[pid] {
                    h.rememberedWindow = r.windowID
                    h.rememberedElement = r.element
                    h.lastWindow = r.windowID
                }
                c.resume(returning: h)
            }
        }
    }

    // MARK: Events

    private func activated(_ app: NSRunningApplication) {
        guard let bid = app.bundleIdentifier else { return }
        let pid = app.processIdentifier
        queue.async {
            self.lastActive[bid] = Date()
            guard self.active, self.apps[pid] != nil || self.isListed(bid) else { return }
            self.scheduleLocked(pid, after: 0.35)
        }
    }

    private func launched(_ app: NSRunningApplication) {
        guard let info = Self.info(app) else { return }
        queue.async {
            guard self.active else { return }
            // Windows appear a moment after launch.
            self.scanLaterLocked(info, after: 1.0)
            self.scanLaterLocked(info, after: 3.0)
        }
    }

    private func terminated(_ pid: pid_t) {
        guard apps[pid] != nil || observers[pid] != nil || remembered[pid] != nil else { return }
        apps[pid] = nil
        remembered[pid] = nil
        woke.remove(pid)
        detach(pid)
        windowCache = windowCache.filter { $0.value.pid != pid }
        rebuild()
    }

    private func schedule(_ pid: pid_t, after delay: TimeInterval) {
        queue.async { self.scheduleLocked(pid, after: delay) }
    }

    private func scheduleLocked(_ pid: pid_t, after delay: TimeInterval) {
        guard active else { return }
        pending[pid]?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.pending[pid] = nil
            guard let app = NSRunningApplication(processIdentifier: pid), let info = Self.info(app) else {
                self.terminated(pid)
                return
            }
            self.scanOne(info)
        }
        pending[pid] = w
        queue.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func scanLaterLocked(_ info: AppInfo, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.active else { return }
            self.scanOne(info)
        }
    }

    private func scheduleFullScan(after delay: TimeInterval) {
        let infos = MainActor.assumeIsolated { Self.runningApps() }
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.fullScanWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.active else { return }
                self.fullScan(infos)
            }
            self.fullScanWork = w
            self.queue.asyncAfter(deadline: .now() + delay, execute: w)
        }
    }

    /// An Accessibility notification for one of the watched apps.
    fileprivate func axEvent(pid: pid_t, _ name: String) {
        queue.async {
            guard self.active else { return }
            if name == (kAXUIElementDestroyedNotification as String) {
                // A window closed: off the list at once, and once more after its closing
                // animation, when the window server has let it go too (Oct 19 2026, Sameer: "after
                // I close a window, it lingers … it should go away right away").
                self.scheduleLocked(pid, after: 0.1)
                if let app = NSRunningApplication(processIdentifier: pid), let info = Self.info(app) {
                    self.scanLaterLocked(info, after: 0.7)
                }
                return
            }
            // A title changing is rarely urgent (and terminals retitle constantly).
            self.scheduleLocked(pid, after: name == (kAXTitleChangedNotification as String) ? 1.5 : 0.4)
        }
    }

    // MARK: Scanning (queue)

    /// Looked through for somewhere to type.
    private func isCandidate(_ bundleID: String) -> Bool {
        isListed(bundleID) && !AppQuirks.excluded.contains(bundleID)
    }

    /// On the list at all: any app with a window, except Macrophone.
    private func isListed(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && bundleID != ownBundleID && !bundleID.hasPrefix("com.sameer.macrophone")
    }

    /// An open app with nowhere to type found: one entry, after the others.
    private func plain(_ info: AppInfo) -> AppEntry {
        AppEntry(info: info, windows: [], appLevel: false, canType: false)
    }

    @MainActor private static func runningApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { $0.activationPolicy == .regular ? info($0) : nil }
    }

    private static func info(_ app: NSRunningApplication) -> AppInfo? {
        guard let bid = app.bundleIdentifier, !app.isTerminated else { return nil }
        return AppInfo(pid: app.processIdentifier, bundleID: bid, name: app.localizedName ?? bid, url: app.bundleURL)
    }

    private func fullScan(_ infos: [AppInfo]) {
        let t0 = Date()
        let server = WindowServer.appWindows()
        let withWindows = Set(server.map(\.pid))
        if !seeded {
            // Until the person switches apps, "most recent" is the window stacking order.
            seeded = true
            let now = Date()
            var rank = 0
            for w in server {
                guard let i = infos.first(where: { $0.pid == w.pid }), lastActive[i.bundleID] == nil else { continue }
                lastActive[i.bundleID] = now.addingTimeInterval(-60 - Double(rank))
                rank += 1
            }
        }
        let live = Set(infos.map(\.pid))
        for pid in apps.keys where !live.contains(pid) { terminated(pid) }
        for info in infos where isListed(info.bundleID) {
            if !withWindows.contains(info.pid) {
                apps[info.pid] = nil
            } else if isCandidate(info.bundleID) {
                scan(info, server: server)
            } else {
                apps[info.pid] = plain(info)
                observeWindows(info.pid)
            }
        }
        rebuild()
        if debugLog {
            print("[targets] full scan \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(apps.values.filter(\.canType).count) apps with somewhere to type, \(apps.count) open")
            fflush(stdout)
        }
    }

    private func scanOne(_ info: AppInfo) {
        guard isListed(info.bundleID) else { return }
        let server = WindowServer.appWindows()
        if isCandidate(info.bundleID) {
            scan(info, server: server)
        } else {
            let open = server.contains { $0.pid == info.pid }
            apps[info.pid] = open ? plain(info) : nil
            if open { observeWindows(info.pid) }
        }
        rebuild()
    }

    private func scan(_ info: AppInfo, server: [WindowServer.Window]) {
        let t0 = Date()
        let pid = info.pid
        let bid = info.bundleID
        let ax = AX.app(pid)
        attach(pid)
        if !woke.contains(pid), AppQuirks.isChromium(bundleID: bid, url: info.url) {
            // Chromium builds its tree on request; look again once it has.
            woke.insert(pid)
            AX.wakeWebContent(ax)
            scanLaterLocked(info, after: 1.2)
        }
        let serverWins = server.filter { $0.pid == pid }
        let z = Dictionary(serverWins.map { ($0.id, $0.z) }, uniquingKeysWith: { a, _ in a })
        let terminal = AppQuirks.isTerminal(bid)
        let hidden = AppQuirks.hiddenComposer.contains(bid)
        let focused = (terminal || hidden) ? nil : AX.focused(in: ax)
        var wins: [ScannedWindow] = []
        var seen = Set<CGWindowID>()
        var debug: [String] = []

        for w in AX.windows(ax) {
            guard AX.subrole(w) == (kAXStandardWindowSubrole as String), !AX.bool(w, kAXMinimizedAttribute),
                  let id = AX.windowID(w) else { continue }
            seen.insert(id)
            let title = Self.cleanTitle(AX.title(w))
            var composer = terminal || hidden
            if !composer {
                let rem = remembered[pid].flatMap { $0.windowID == id ? $0.element : nil }
                let s = ComposerFinder.scan(window: w, bundleID: bid, focused: focused, remembered: rem)
                composer = s.composer != nil
                // Ran out of time half way: trust what we saw last time.
                if !composer && s.ranOut && windowCache[id]?.composer == true { composer = true }
                if debugLog {
                    let c = s.composer.map { "\($0.role)\($0.inWeb ? " web" : "")\($0.hinted ? " hinted" : "") \(Int($0.frame.width))×\(Int($0.frame.height))\($0.isDocument ? " doc" : "")" } ?? "none"
                    debug.append("“\(title.prefix(30))” nodes \(s.nodes)\(s.ranOut ? " (ran out)" : "")\(s.sawWebArea ? " web" : "") candidates \(s.candidates.count) → \(c)")
                }
            }
            windowCache[id] = WindowEntry(pid: pid, title: title, composer: composer)
            // Every window is watched for closing (an app whose last window closes leaves the list).
            watch(w, id: id, pid: pid)
            if composer {
                wins.append(ScannedWindow(id: id, title: title, z: z[id] ?? 1000 + wins.count))
            }
        }
        // Windows on other desktops: Accessibility can't see them, the window server can. Keep
        // the ones seen before.
        for sw in serverWins where !seen.contains(sw.id) {
            if let c = windowCache[sw.id], c.composer, c.pid == pid { wins.append(ScannedWindow(id: sw.id, title: c.title, z: sw.z)) }
        }
        let alive = Set(serverWins.map(\.id))
        windowCache = windowCache.filter { $0.value.pid != pid || alive.contains($0.key) || seen.contains($0.key) }
        wins.sort { $0.z < $1.z }
        let appLevel = wins.isEmpty && (terminal || hidden) && !serverWins.isEmpty
        if wins.isEmpty && !appLevel {
            apps[pid] = serverWins.isEmpty ? nil : plain(info)
        } else {
            apps[pid] = AppEntry(info: info, windows: wins, appLevel: appLevel)
        }
        if debugLog {
            print("[targets] \(info.name): \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(wins.count) window(s)\(appLevel ? " (on another desktop)" : "")")
            debug.forEach { print("[targets]    \($0)") }
            fflush(stdout)
        }
    }

    /// The person is leaving an app: remember the input they were typing in (and its window),
    /// so a dictation sent there goes back to the same place.
    private func captureFocus(_ pid: pid_t) {
        guard active else { return }
        let ax = AX.app(pid)
        guard let f = AX.focused(in: ax), AX.isTextInput(f), let w = AX.window(of: f), let id = AX.windowID(w) else { return }
        remembered[pid] = Remembered(windowID: id, element: f)
    }

    // MARK: The list

    private func rebuild() {
        var list: [(LiveTarget, Int)] = []
        let now = Date()
        for e in apps.values {
            let bid = e.info.bundleID
            let last = lastActive[bid] ?? now.addingTimeInterval(-3600)
            let icon = iconData(bid, url: e.info.url)
            if e.windows.count > 1 {
                var seenTitles: [String: Int] = [:]
                for w in e.windows {
                    var t = w.title.isEmpty ? "Untitled window" : w.title
                    let n = (seenTitles[t] ?? 0) + 1
                    seenTitles[t] = n
                    if n > 1 { t += " (\(n))" }
                    list.append((LiveTarget(bundleID: bid, appName: e.info.name, windowTitle: t, windowKey: String(w.id),
                                            icon: icon, lastActive: last), w.z))
                }
            } else {
                list.append((LiveTarget(bundleID: bid, appName: e.info.name, icon: icon, lastActive: last,
                                        canType: e.canType ? nil : false), e.windows.first?.z ?? 9999))
            }
        }
        list.sort { a, b in
            // The apps with somewhere to type first, then every other open app.
            if a.0.typeable != b.0.typeable { return a.0.typeable }
            let la = a.0.lastActive ?? .distantPast, lb = b.0.lastActive ?? .distantPast
            if la != lb { return la > lb }
            if a.0.bundleID != b.0.bundleID { return a.0.appName.localizedCaseInsensitiveCompare(b.0.appName) == .orderedAscending }
            return a.1 < b.1
        }
        schedulePublish(list.map(\.0))
    }

    private func schedulePublish(_ list: [LiveTarget]) {
        let key = { (l: [LiveTarget]) in l.map { "\($0.id)|\($0.title)|\($0.typeable)" } }
        let same = key(list) == key(published)
        if same && !forcePublish { return }
        let added = Set(list.map { "\($0.id)|\($0.typeable)" }) != Set(published.map { "\($0.id)|\($0.typeable)" })
        pendingList = list
        publishWork?.cancel()
        // Apps opening or closing go out quickly; a new order or a retitled window can wait.
        let removed = !Set(published.map(\.id)).isSubset(of: Set(list.map(\.id)))
        let delay = removed ? 0.05 : (added || forcePublish) ? 0.25 : max(0.5, 5 - Date().timeIntervalSince(lastPublish))
        let w = DispatchWorkItem { [weak self] in self?.publishNow() }
        publishWork = w
        queue.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private var pendingList: [LiveTarget]?

    private func publishNow() {
        let list = pendingList ?? published
        pendingList = nil
        forcePublish = false
        published = list
        lastPublish = Date()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.targets = list
                self.onChange?(list)
            }
        }
    }

    /// "✳ Claude Code — 80×24" → "Claude Code": status glyphs that terminals and agents put in
    /// front of a title come and go every second; the size suffix is noise.
    static func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = t.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first), !"~/(\"'[“".unicodeScalars.contains(first) {
            t.unicodeScalars.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        if let r = t.range(of: #"\s+[—–-]\s+\d+[×x]\d+$"#, options: .regularExpression) { t.removeSubrange(r) }
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        if t.count > 70 { t = String(t.prefix(70)).trimmingCharacters(in: .whitespaces) }
        return t
    }

    // MARK: Icons

    private func iconData(_ bundleID: String, url: URL?) -> Data? {
        if let d = icons[bundleID] { return d }
        guard let path = url?.path ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        let px = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .png, properties: [:])
        icons[bundleID] = data
        return data
    }

    // MARK: Accessibility observers (queue)

    private func attach(_ pid: pid_t) {
        guard observers[pid] == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let app = AX.app(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXWindowMiniaturizedNotification,
                  kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    private func watch(_ window: AXUIElement, id: CGWindowID, pid: pid_t) {
        guard let obs = observers[pid], watched[pid]?.contains(id) != true else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, window, kAXUIElementDestroyedNotification as CFString, refcon)
        AXObserverAddNotification(obs, window, kAXTitleChangedNotification as CFString, refcon)
        watched[pid, default: []].insert(id)
    }

    /// An app listed with nowhere to type: its windows are watched for closing all the same.
    private func observeWindows(_ pid: pid_t) {
        attach(pid)
        for w in AX.windows(AX.app(pid)) {
            guard AX.subrole(w) == (kAXStandardWindowSubrole as String), let id = AX.windowID(w) else { continue }
            watch(w, id: id, pid: pid)
        }
    }

    private func detach(_ pid: pid_t) {
        if let obs = observers[pid] {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observers[pid] = nil
        watched[pid] = nil
        pending[pid]?.cancel()
        pending[pid] = nil
    }

    private func detachAll() {
        for pid in Array(observers.keys) { detach(pid) }
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let scanner = Unmanaged<TargetScanner>.fromOpaque(refcon).takeUnretainedValue()
    scanner.axEvent(pid: AX.pid(of: element), notification as String)
}
