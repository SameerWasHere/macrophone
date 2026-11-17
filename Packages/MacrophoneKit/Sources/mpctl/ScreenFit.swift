import Foundation
import MacrophoneKit

// The Whole Screen fitted to the iPhone (Nov 16 2026) in the protocol proof: `serve` names the
// feature and answers a request by redrawing its demo desktop at the asked shape (the Mac app
// makes a display that shape), printing `SCREEN FIT 1004×1426` / `SCREEN FIT off`.
// `--no-screen-fit` is a Mac from before; `--screen-fit-cant` answers that it can't;
// `--screen-fit-delay <ms>` is how long a change mid-watch takes (600: the Mac makes the display
// and moves the windows). A request right behind the watch is applied before the first frame.

enum ScreenFitDemo {
    nonisolated(unsafe) static var size: FittedScreenSize?
    static let key = "demo-fitted"
    static func isDesktop(_ key: String) -> Bool { key.hasPrefix(DesktopWatch.bundleID + "#") }
}

extension ServeDelegate: LinkServerFittedScreenDelegate {
    func linkServer(_ server: LinkServer, screenFit request: FittedScreenRequest, from peerID: UUID) {
        if has("--screen-fit-cant") {
            stdout("SCREEN FIT refused")
            Task { await server.sendScreenFit(FittedScreenState(on: false, reason: "This Mac can't make a screen that shape"), to: peerID) }
            return
        }
        guard request.on else {
            guard ScreenFitDemo.size != nil else { return }
            applyScreenFit(nil)
            stdout("SCREEN FIT off")
            Task { await server.sendScreenFit(.off, to: peerID) }
            return
        }
        guard let size = request.size else {
            stdout("SCREEN FIT not a screen's shape (\(Int(request.width))×\(Int(request.height)))")
            Task { await server.sendScreenFit(FittedScreenState(on: false, reason: "That isn't a screen's shape"), to: peerID) }
            return
        }
        if let now = ScreenFitDemo.size, !FittedScreen.differs(now, size) {
            stdout("SCREEN FIT \(now.width)×\(now.height) (kept)")
            Task { await server.sendScreenFit(FittedScreenState(on: true, key: ScreenFitDemo.key, width: now.width, height: now.height), to: peerID) }
            return
        }
        let started = lock.sync { watchStarted[peerID] ?? .distantPast }
        let ahead = Date().timeIntervalSince(started) < 1
        let delay = Double(flag("--screen-fit-delay") ?? "") ?? 600
        Task {
            if !ahead, delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e6)) }
            self.applyScreenFit(size)
            stdout("SCREEN FIT \(size.width)×\(size.height)\(ahead ? " (ahead)" : "")")
            await server.sendScreenFit(FittedScreenState(on: true, key: ScreenFitDemo.key, width: size.width, height: size.height), to: peerID)
        }
    }

    /// The demo desktop at that size (its own 1400 × 900 for nil), now and for one drawn later.
    func applyScreenFit(_ size: FittedScreenSize?) {
        ScreenFitDemo.size = size
        let desks = lock.sync { demos.filter { ScreenFitDemo.isDesktop($0.key) }.map(\.value) }
        for d in desks { d.setSize(size.map { ($0.width, $0.height) }) }
    }

    /// The watch stopped: as the Mac app, the fitted screen stays for the grace, then goes back.
    func screenFitWatchStopped(_ peerID: UUID) {
        guard ScreenFitDemo.size != nil, screenFitGrace == nil else { return }
        let grace = Double(flag("--restore-grace") ?? "") ?? 45
        screenFitGrace = Task {
            try? await Task.sleep(nanoseconds: UInt64(grace * 1e9))
            guard !Task.isCancelled else { return }
            self.applyScreenFit(nil)
            self.screenFitGrace = nil
            stdout("SCREEN FIT off after \(Int(grace)) s")
        }
    }
}

extension PhoneDelegate: LinkClientFittedScreenDelegate {
    func linkClient(_ client: LinkClient, screenFit state: FittedScreenState, macID: UUID) {
        stdout("SCREEN FIT STATE \(state.on ? "on \(state.width)×\(state.height)" : "off")\(state.reason.map { " — " + $0 } ?? "")")
    }
}
