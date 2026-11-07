import AppKit
import Foundation
import MacrophoneKit
import ScreenCaptureKit

/// Every alert the phone gets, one way (Nov 6 2026 — Sameer: "have agent alerts work through this
/// new way now. So it's all consistent and uniform"): a window on watch that changed state, an
/// agent asking (AgentHub), a question the lookout read (AttentionWatcher). Each goes with a
/// picture of the window — to a connected phone over the link (`.macAlert`; a phone from before
/// gets `.attention` for a question), else through the person's own iCloud (CloudAlerts), where
/// the phone's notification extension takes the picture and deletes the record.
@MainActor
final class AlertCenter {
    private unowned let app: AppModel
    /// When each window last asked something (its `MacAlert.windowKey`), so one question isn't told
    /// twice — an agent asking (AgentHub, the lookout) and the same window on watch settling with
    /// the question on it a moment later.
    private var lastAsked: [String: Date] = [:]
    static let quietAfterAsk: TimeInterval = 20

    init(app: AppModel) { self.app = app }

    /// A phone set up for alerts through iCloud has connected once (it said so in its hello).
    var cloudWanted: Bool { UserDefaults.standard.bool(forKey: "attention.cloud") }

    /// A phone that shows pictures from iCloud has connected (it said so in its hello).
    var cloudPictures: Bool {
        get { UserDefaults.standard.bool(forKey: "alerts.cloud.pictures") }
        set { UserDefaults.standard.set(newValue, forKey: "alerts.cloud.pictures") }
    }

    /// This window asked something a moment ago.
    func recentlyAsked(_ ref: TargetRef) -> Bool {
        lastAsked[MacAlert.windowKey(ref)].map { Date().timeIntervalSince($0) < Self.quietAfterAsk } ?? false
    }

    /// Tells the phone. `windowID`: the window to picture when the alert has none yet.
    func send(_ alert: MacAlert, windowID: CGWindowID? = nil) async {
        var a = alert
        if a.jpeg == nil, let windowID, CGPreflightScreenCaptureAccess() {
            a.jpeg = await Self.picture(windowID: windowID)
        }
        if a.knownKind == .asking { lastAsked[MacAlert.windowKey(a.ref)] = Date() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MACROPHONE_ALERTS_PRINT"] == "1" {
            print("ALERT \(a.kind) · \(a.headline) · \(a.detail ?? "-") · picture \((a.jpeg?.count ?? 0) / 1024) KB")
            if let jpeg = a.jpeg { try? jpeg.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macrophone-alert-\(a.kind).jpg")) }
        }
        #endif
        let modern = app.server.phones(with: MacAlerts.feature)
        let older = app.server.phones(with: Attention.feature).filter { !modern.contains($0) }
        let size = a.jpeg.map { " · picture \($0.count / 1024) KB" } ?? ""
        if !app.server.phones(with: MacAlerts.cloudPictureFeature).isEmpty { cloudPictures = true }
        if modern.isEmpty, older.isEmpty {
            // No phone connected (the usual case: an iPhone app off screen loses its link within
            // seconds). Always through iCloud: a phone that subscribed gets the push, one that
            // didn't gets nothing and the record is swept after a day. Waiting for the phone to
            // say it subscribed (`cloudWanted`) dropped alerts without a word when it never did.
            // The picture goes into iCloud only for a phone that can show it (its extension takes
            // it and deletes the record); otherwise the headline and the window alone.
            var c = a
            if !cloudPictures { c.jpeg = nil }
            let failure = await CloudAlerts.post(c)
            app.log.add("alert: \(a.kind) in \(a.appName)\(size) — " + (failure.map { "iCloud didn't take it (\($0))" } ?? "sent through iCloud\(cloudWanted ? "" : " (the phone hasn't said it subscribed)")"))
            return
        }
        for p in modern { await app.server.send(.macAlert(a), to: p) }
        if let q = a.attention { for p in older { await app.server.send(.attention(q), to: p) } }
        app.log.add("alert: \(a.kind) in \(a.appName)\(size) — told the phone")
    }

    // MARK: The picture

    /// The window as it looks now, a JPEG small enough for an iCloud record (MacAlerts.picture…):
    /// with a dialog or sheet over it when one is up.
    static func picture(windowID: CGWindowID) async -> Data? {
        guard let image = await capture(windowID: windowID) else { return nil }
        return await Task.detached(priority: .utility) { jpeg(image) }.value
    }

    static func capture(windowID: CGWindowID) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let w = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        return await capture(w, in: content)
    }

    /// The window, and what's laid over it (a sheet, an open panel) when that's on screen.
    static func capture(_ w: SCWindow, in content: SCShareableContent) async -> CGImage? {
        let over = dialogs(over: w.windowID)
        guard !over.isEmpty, let display = content.displays.first(where: { $0.frame.intersects(w.frame) }) else {
            return await AttentionWatcher.capture(w)
        }
        let extra = content.windows.filter { over.contains($0.windowID) }
        let area = extra.reduce(w.frame) { $0.union($1.frame) }.intersection(display.frame)
        let filter = SCContentFilter(display: display, including: [w] + extra)
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let k = min(1, 1200 / max(1, area.width * scale))
        cfg.sourceRect = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        cfg.width = Int(area.width * scale * k)
        cfg.height = Int(area.height * scale * k)
        cfg.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// The dialogs and sheets over a window right now (its companions at the normal level: a
    /// sheet, an open or save panel — not a menu or a tooltip).
    static func dialogs(over id: CGWindowID) -> [CGWindowID] {
        let list = WindowServer.companionList()
        guard let host = list.first(where: { $0.id == id }) else { return [] }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == host.pid
        return WatchCompanions.select(watched: id, in: list, hostInFront: front, me: ProcessInfo.processInfo.processIdentifier)
            .filter { $0.layer == 0 }
            .map { CGWindowID($0.id) }
    }

    nonisolated static func jpeg(_ image: CGImage) -> Data? { MacAlerts.jpeg(image) }
}

/// Windows on watch (Nov 6 2026): any window, put on watch from the phone or the menu bar. Every
/// few seconds each is pictured and its picture sampled; `WindowChangeDetector` says when it
/// changed state, and the alert goes through `AlertCenter` with a headline the on-device model
/// writes from the window's new lines (`AlertReading`), or plain words when there's no model.
///
/// Looks only while something is on watch. Never alerts about a window the phone is showing (he
/// sees it). A watch ends when the window closes (one last alert), when nothing happened in it
/// for twelve hours, or when he turns it off. Pictures and text are read here; only the alert —
/// its headline, one line and the picture — goes to the phone.
@MainActor
final class WindowAlertWatcher {
    private unowned let app: AppModel
    private var watches: [CGWindowID: Watch] = [:]
    private var task: Task<Void, Never>?
    private var sent: [AlertWatch] = []

    static let interval: TimeInterval = 3
    static let restInterval: TimeInterval = 6

    private struct Watch {
        var ref: TargetRef
        var bundleID: String
        var appName: String
        var title: String
        var since: Date
        var detector: WindowChangeDetector
        /// The window's lines before the current change (what's new is told).
        var lines: [String]?
        var lastImage: CGImage?
        var lastJPEG: Data?
        var missing = 0

        var item: AlertWatch {
            AlertWatch(ref: ref, bundleID: bundleID, windowKey: ref.windowKey, appName: appName, title: title, since: since, calm: detector.calm)
        }
    }

    init(app: AppModel) { self.app = app }

    var list: [AlertWatch] { watches.values.map(\.item).sorted { $0.since > $1.since } }

    func isWatching(_ windowID: CGWindowID) -> Bool { watches[windowID] != nil }

    // MARK: On and off

    /// Puts a window on watch (`ref` an app: its front window), or takes it off.
    func set(_ ref: TargetRef, on: Bool) {
        guard case let .app(bundleID, key, name) = ref,
              let wid = key.flatMap(CGWindowID.init) ?? frontWindow(of: bundleID) else {
            app.log.add("window alerts: nothing to watch for that place")
            return
        }
        if !on {
            guard watches.removeValue(forKey: wid) != nil else { return }
            app.log.add("window alerts: off (\(watches.count) on watch)")
        } else {
            guard watches[wid] == nil else { return }
            if watches.count >= MacAlerts.maxWatches, let oldest = watches.min(by: { $0.value.since < $1.value.since })?.key {
                watches.removeValue(forKey: oldest)
            }
            let live = app.targets.first { $0.bundleID == bundleID && $0.windowKey == String(wid) }
            let appName = live?.appName ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? name
            let resolved = TargetRef.app(bundleID: bundleID, windowKey: String(wid), name: appName)
            watches[wid] = Watch(ref: resolved, bundleID: bundleID, appName: appName, title: live?.windowTitle ?? appName,
                                 since: Date(), detector: WindowChangeDetector())
            app.log.add("window alerts: on (\(watches.count) on watch)")
        }
        publish()
        start()
    }

    func toggle(_ ref: TargetRef) {
        guard case let .app(bundleID, key, _) = ref, let wid = key.flatMap(CGWindowID.init) ?? frontWindow(of: bundleID) else { return }
        set(ref, on: watches[wid] == nil)
    }

    /// The app's frontmost real window — read straight off the window server, drawn or not: with
    /// the display asleep (he's away, the usual case) no window counts as on screen.
    private func frontWindow(of bundleID: String) -> CGWindowID? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return nil }
        if let id = WindowServer.appWindows().filter({ $0.pid == pid }).min(by: { $0.z < $1.z })?.id { return id }
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.first { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return false }
            return r.width >= 160 && r.height >= 90 && (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
        }?[kCGWindowNumber as String] as? CGWindowID
    }

    // MARK: Looking

    private func start() {
        guard task == nil, !watches.isEmpty else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.look()
                if self.watches.isEmpty { self.task = nil; return }
                let busy = self.watches.values.contains { $0.detector.isBusy || Date().timeIntervalSince($0.detector.lastEvent) < 600 }
                try? await Task.sleep(nanoseconds: UInt64((busy ? Self.interval : Self.restInterval) * 1e9))
            }
        }
    }

    private func look() async {
        let now = Date()
        guard CGPreflightScreenCaptureAccess() else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
        let watched = app.watch.watchedWindows
        var changedList = false
        for wid in Array(watches.keys) {
            guard var w = watches[wid] else { continue }
            // Gone: closed, or its app quit (twice in a row, so a window being re-made isn't).
            guard let scw = content.windows.first(where: { $0.windowID == wid }) else {
                w.missing += 1
                if w.missing >= 2 {
                    watches.removeValue(forKey: wid)
                    changedList = true
                    await app.alerts.send(MacAlert(ref: w.ref, appName: w.appName, title: w.title, kind: .closed,
                                                   headline: AlertWords.headline(.closed, app: w.appName, newLines: []),
                                                   detail: "It's off watch now.", jpeg: w.lastJPEG))
                } else {
                    watches[wid] = w
                }
                continue
            }
            w.missing = 0
            if let t = scw.title, !t.isEmpty, t != w.title { w.title = t; changedList = true }
            // Quiet for twelve hours: the watch ends.
            if now.timeIntervalSince(w.detector.lastEvent) > MacAlerts.quietExpiry {
                watches.removeValue(forKey: wid)
                changedList = true
                app.log.add("window alerts: one ended after twelve quiet hours")
                continue
            }
            guard let image = await AlertCenter.capture(scw, in: content) else {
                #if DEBUG
                if ProcessInfo.processInfo.environment["MACROPHONE_ALERTS_PRINT"] == "1" { print("LOOK \(wid) no picture") }
                #endif
                watches[wid] = w
                continue
            }
            let sample = await Task.detached(priority: .utility) { WatchChange.sample(image) }.value
            let dialog = !AlertCenter.dialogs(over: wid).isEmpty
            // Still picture: does the window say it's still at it (a Stop button, "esc to interrupt")?
            var working = false
            if Paster.isTrusted, let last = w.detector.last, WatchChange.changedShare(last, sample) < WindowChangeDetector.activity,
               let pid = NSRunningApplication.runningApplications(withBundleIdentifier: w.bundleID).first?.processIdentifier {
                working = await Task.detached(priority: .utility) { StillWorking.check(pid: pid, windowID: wid) }.value
            }
            let wasBusy = w.detector.isBusy
            let previous = w.lastImage
            #if DEBUG
            let debugShare = w.detector.last.map { WatchChange.changedShare($0, sample) } ?? -1
            #endif
            let event = w.detector.look(sample, working: working, dialog: dialog, at: now)
            #if DEBUG
            if ProcessInfo.processInfo.environment["MACROPHONE_ALERTS_PRINT"] == "1" {
                print("LOOK \(Int(Date().timeIntervalSince1970) % 1000) share \(String(format: "%.4f", debugShare)) \(wid) \(image.width)x\(image.height) busy \(w.detector.isBusy) working \(working) dialog \(dialog) event \(String(describing: event))")
            }
            #endif
            w.lastImage = image
            if w.lines == nil { w.lines = await AlertReading.lines(image) }
            // The change starts: what the window said before it is what's new is told against.
            if !wasBusy, w.detector.isBusy, let previous { w.lines = await AlertReading.lines(previous) }
            if watched.contains(wid) {
                // He's looking at it on the phone: whatever it says, he sees.
                w.detector.seen()
                w.lines = nil
                watches[wid] = w
                continue
            }
            if let event {
                let alert = await describe(event, w: &w, image: image)
                if let alert, !(alert.knownKind == .asking && app.alerts.recentlyAsked(w.ref)) {
                    w.lastJPEG = await Task.detached(priority: .utility) { AlertCenter.jpeg(image) }.value
                    var a = alert
                    a.jpeg = w.lastJPEG
                    await app.alerts.send(a)
                }
                if w.detector.becameCalm { w.detector.becameCalm = false; changedList = true }
            }
            watches[wid] = w
        }
        if changedList { publish() }
    }

    /// The alert for what happened: a question the window asks, else the model's words (or plain
    /// ones) from its new lines.
    private func describe(_ event: WindowChangeDetector.Event, w: inout Watch, image: CGImage) async -> MacAlert? {
        let now = await AlertReading.lines(image)
        // What's new since the change began, and the window's last lines — where a build, a script
        // or a chat says how it went (a rerun that ends as before has nothing "new" but its end).
        // The window's last lines say how it went; of those, the new ones when there are any (a
        // reply, an upload's last word), else all of them (a rerun that ends as before).
        let tail = AlertWords.newLines(before: [], now: Array(now.suffix(8))).filter { !AlertWords.isPrompt($0) }
        let fresh = AlertWords.newLines(before: w.lines ?? [], now: tail)
        let new = fresh.isEmpty ? tail : fresh
        w.lines = now
        var kind: MacAlert.Kind
        switch event {
        case .dialog: kind = .dialog
        case let .settled(ran, _): kind = ran >= WindowChangeDetector.longRun ? .finished : .updated
        }
        if let p = await PromptVision.read(image) {
            return MacAlert(ref: w.ref, appName: w.appName, title: w.title, kind: .asking,
                            headline: AlertWords.headline(.asking, app: w.appName, newLines: []),
                            detail: p.question, promptID: p.id)
        }
        if w.detector.becameCalm {
            kind = .calmed
            let head = AlertWords.headline(.calmed, app: w.appName, newLines: new)
            return MacAlert(ref: w.ref, appName: w.appName, title: w.title, kind: kind, headline: head,
                            detail: "It's changing a lot, so you'll hear only when it stops.")
        }
        // The model's headline; the line under it straight from the window (the one that says how
        // it went), which is exact — the model's own line only when the window has none.
        if let written = await AlertReading.words(app: w.appName, title: w.title, kind: kind, newLines: new) {
            return MacAlert(ref: w.ref, appName: w.appName, title: w.title, kind: kind, headline: written.headline,
                            detail: AlertWords.detail(new) ?? written.detail)
        }
        return MacAlert(ref: w.ref, appName: w.appName, title: w.title, kind: kind,
                        headline: AlertWords.headline(kind, app: w.appName, newLines: new), detail: AlertWords.detail(new))
    }

    private func publish() {
        let l = list
        guard l != sent else { return }
        sent = l
        app.server.broadcastAlertWatches(l)
        app.alertWatchesChanged(l)
    }
}
