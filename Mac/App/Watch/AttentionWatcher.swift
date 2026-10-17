import AppKit
import CryptoKit
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
@MainActor
final class AttentionWatcher {
    private unowned let app: AppModel
    private var task: Task<Void, Never>?
    /// Each window's last picture (so an unchanged one isn't read again) and the question it was
    /// asking (so each question buzzes once).
    private var digests: [String: Data] = [:]
    private var asked: [String: String] = [:]
    static let interval: UInt64 = 5_000_000_000
    static let maxWindows = 6

    init(app: AppModel) { self.app = app }

    /// Runs only while a phone that wants alerts is connected.
    func update() {
        let wanted = !app.server.phones(with: Attention.feature).isEmpty
        if wanted, task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.look()
                    try? await Task.sleep(nanoseconds: Self.interval)
                }
            }
        } else if !wanted, let t = task {
            t.cancel()
            task = nil
            digests = [:]
        }
    }

    private func look() async {
        guard CGPreflightScreenCaptureAccess() else { return }
        let phones = app.server.phones(with: Attention.feature)
        guard !phones.isEmpty else { return }
        let candidates = windows()
        guard !candidates.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let watched = app.watch.watchedWindows
        for (t, wid) in candidates {
            let key = t.id
            // A window someone is looking at answers on its own screen.
            guard !watched.contains(wid), let scw = content.windows.first(where: { $0.windowID == wid }) else { continue }
            guard let image = await Self.capture(scw) else { continue }
            let digest = await Task.detached(priority: .utility) { Self.digest(image) }.value
            if digest == digests[key] { continue }
            digests[key] = digest
            guard let p = await PromptVision.read(image) else { asked[key] = nil; continue }
            guard asked[key] != p.id else { continue }
            asked[key] = p.id
            let a = Attention(ref: t.ref, appName: t.appName, title: t.title, question: p.question, promptID: p.id)
            for peer in phones { await app.server.send(.attention(a), to: peer) }
            app.log.add("attention: \(t.appName) is asking — told the phone")
        }
    }

    /// The agent windows (and the place dictations go), newest first, each with its window.
    private func windows() -> [(LiveTarget, CGWindowID)] {
        let selected = app.settings.selection.target
        let all = WindowServer.appWindows()
        var out: [(LiveTarget, CGWindowID)] = []
        for t in app.targets {
            let wanted = AppQuirks.isTerminal(t.bundleID) || AppQuirks.agentApps.contains(t.bundleID) || selected.matches(t)
            guard wanted else { continue }
            if let key = t.windowKey, let id = CGWindowID(key) {
                out.append((t, id))
            } else if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: t.bundleID).first?.processIdentifier,
                      let front = all.filter({ $0.pid == pid }).min(by: { $0.z < $1.z }) {
                out.append((t, front.id))
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

    nonisolated private static func digest(_ image: CGImage) -> Data {
        guard let data = image.dataProvider?.data as Data? else { return Data() }
        return Data(SHA256.hash(data: data))
    }
}
