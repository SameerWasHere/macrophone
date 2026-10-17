import AppKit
import Foundation
import MacrophoneKit
import ScreenCaptureKit

/// "Your agent needs you" (Oct 16 2026): while a phone that understands alerts is connected, every
/// five seconds this looks at the agent windows — terminals, Claude, Codex, Cursor and the like,
/// plus the place dictations go — and when one starts asking a question nobody is watching, tells
/// the phone once. The picture is read here (the same reader as watching) and never leaves the
/// Mac; only the app's name, the window's title and the question go to the phone.
///
/// Needs Screen Recording, and never asks for it: without it, it does nothing.
///
/// Cheap when nothing happens (Oct 16 2026): a window whose picture hasn't changed — a caret or a
/// spinner doesn't count — isn't read at all (no Accessibility walk, no text recognition), the
/// list of windows is fetched once a while, and the looks space out to ten seconds while every
/// window stays still.
@MainActor
final class AttentionWatcher {
    private unowned let app: AppModel
    private var task: Task<Void, Never>?
    /// Each window's last picture, sampled (so an unchanged one isn't read again) and the question
    /// it was asking (so each question buzzes once).
    private var samples: [String: [UInt32]] = [:]
    private var asked: [String: String] = [:]
    private var content: SCShareableContent?
    private var contentAt = Date.distantPast
    /// Seconds between looks: `interval` while something changes, up to `restInterval` when nothing does.
    private var pace: Double = interval
    static let interval = 5.0
    static let restInterval = 10.0
    static let maxWindows = 6

    init(app: AppModel) { self.app = app }

    /// A phone set up for alerts through iCloud has connected once (it said so in its hello):
    /// from then on the Mac keeps looking even when no phone is connected.
    private var cloudWanted: Bool {
        get { UserDefaults.standard.bool(forKey: "attention.cloud") }
        set { UserDefaults.standard.set(newValue, forKey: "attention.cloud") }
    }

    /// Runs while a phone that wants alerts is connected — or always, once a phone has set up
    /// alerts through iCloud (this build must be able to send them).
    func update() {
        if !app.server.phones(with: Attention.cloudFeature).isEmpty, !cloudWanted {
            cloudWanted = true
            app.log.add("attention: a phone gets alerts through iCloud")
        }
        let wanted = !app.server.phones(with: Attention.feature).isEmpty || (cloudWanted && CloudAlerts.available)
        if wanted, task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.look()
                    try? await Task.sleep(nanoseconds: UInt64((self?.pace ?? Self.interval) * 1e9))
                }
            }
        } else if !wanted, let t = task {
            t.cancel()
            task = nil
            samples = [:]
            content = nil
            pace = Self.interval
        }
    }

    private func look() async {
        let phones = app.server.phones(with: Attention.feature)
        guard !phones.isEmpty || (cloudWanted && CloudAlerts.available) else { return }
        let candidates = windows()
        guard !candidates.isEmpty else { return }
        let trusted = Paster.isTrusted
        let pictures = CGPreflightScreenCaptureAccess()
        let watched = app.watch.watchedWindows
        var changed = false
        for (t, wid, pid) in candidates {
            let key = t.id
            // A window someone is looking at answers on its own screen.
            guard !watched.contains(wid) else { continue }
            var found: WatchPrompt?
            var image: CGImage?
            // The picture, when it changed since the last look (a caret or a spinner doesn't count):
            // an unchanged window isn't read at all. One that can't be pictured (on another desktop)
            // still gets its controls read.
            if pictures, let scw = await scWindow(wid), let img = await Self.capture(scw) {
                let sample = await Task.detached(priority: .utility) { WatchChange.sample(img) }.value
                let share = samples[key].map { WatchChange.changedShare($0, sample) } ?? 1
                samples[key] = sample
                guard share >= WatchPacing.sliver else { continue }
                image = img
                changed = true
            }
            // Controls first (a question card, Allow / Deny: exact, and no Screen Recording needed).
            if trusted, let ax = await Task.detached(priority: .utility, operation: { AXPrompt.read(pid: pid, windowID: wid) }).value {
                found = ax.prompt
            } else if let image {
                found = await PromptVision.read(image)
            } else {
                continue
            }
            guard let p = found else { asked[key] = nil; continue }
            guard asked[key] != p.id else { continue }
            asked[key] = p.id
            let a = Attention(ref: t.ref, appName: t.appName, title: t.title, question: p.question, promptID: p.id)
            if phones.isEmpty {
                // No phone connected (the app is closed): through iCloud.
                let ok = await CloudAlerts.post(a)
                app.log.add(ok ? "attention: \(t.appName) is asking — sent through iCloud" : "attention: \(t.appName) is asking — iCloud didn't take it")
            } else {
                for peer in phones { await app.server.send(.attention(a), to: peer) }
                app.log.add("attention: \(t.appName) is asking — told the phone")
            }
        }
        // Still windows earn longer rests; a change brings the looks back to every five seconds.
        pace = changed || !pictures ? Self.interval : min(Self.restInterval, pace * 1.5)
    }

    /// The window as ScreenCaptureKit knows it, from a list fetched once a while (fetching it
    /// means every window's title: tens of milliseconds).
    private func scWindow(_ id: CGWindowID) async -> SCWindow? {
        if let c = content, Date().timeIntervalSince(contentAt) < 30, let w = c.windows.first(where: { $0.windowID == id }) { return w }
        guard let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        content = c
        contentAt = Date()
        return c.windows.first { $0.windowID == id }
    }

    /// The agent windows (and the place dictations go), newest first, each with its window.
    private func windows() -> [(LiveTarget, CGWindowID, pid_t)] {
        let selected = app.settings.selection.target
        let all = WindowServer.appWindows()
        var out: [(LiveTarget, CGWindowID, pid_t)] = []
        for t in app.targets {
            let wanted = AppQuirks.isTerminal(t.bundleID) || AppQuirks.agentApps.contains(t.bundleID) || selected.matches(t)
            guard wanted, let pid = NSRunningApplication.runningApplications(withBundleIdentifier: t.bundleID).first?.processIdentifier else { continue }
            if let key = t.windowKey, let id = CGWindowID(key) {
                out.append((t, id, pid))
            } else if let front = all.filter({ $0.pid == pid }).min(by: { $0.z < $1.z }) {
                out.append((t, front.id, pid))
            }
            if out.count == Self.maxWindows { break }
        }
        return out
    }

    private static func capture(_ w: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let pxW = max(1, w.frame.width * scale), pxH = max(1, w.frame.height * scale)
        let k = min(1, 1200 / pxW)
        cfg.width = Int(pxW * k)
        cfg.height = Int(pxH * k)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}
