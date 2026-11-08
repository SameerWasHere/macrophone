import MacrophoneKit
import UIKit

// What's in front on your Mac, one tap away (Nov 7 2026, Sameer: "pick up where the Mac is").
// The Mac tells this phone its front window (`FrontWindow`, MacrophoneKit; Mac/App/Core/
// FrontWindow.swift) after the welcome and on each change. Where it shows:
// - the desktop card's line, "Now on your Mac · Claude — Fix the login bug" (`FrontWindowLine`,
//   the regular iPhone and the Duo's cover), and the same line under the Duo glance's bar;
// - the Home Screen quick action, the Control Center / Lock Screen control and the App Intent
//   "Watch What's in Front" (`watchWhatsInFront`), which work from cold: open, wait for the Mac,
//   watch what's in front at that moment.
// A tap only looks, like a flip (CLAUDE.md, "Flipping windows … only looks"): Send to stays what
// it was, and a dictation while the window shows goes to it for that recording alone
// (`watchedPlace`). On the Duo's inner screen the flip picks (the glance follows the pick), so the
// line does too.

/// The Mac's last word on its front window, and which Mac said it.
struct MacFront: Equatable {
    var window: FrontWindow?
    var mac: UUID
}

extension AppModel: LinkClientFrontWindowDelegate {
    func linkClient(_ client: LinkClient, frontWindow: FrontWindow?, macID: UUID) {
        guard client === self.client else { return }
        macFront = MacFront(window: frontWindow, mac: macID)
        resolveFront()
    }

    /// The window in front on the connected Mac (nil: not connected, an older Mac, or nothing safe
    /// to show).
    var frontNow: FrontWindow? {
        guard isConnected, let f = macFront, f.mac == pairedMac?.id else { return nil }
        return f.window
    }

    /// The line's offer: what's in front, when it isn't already the pick (nor Where I'm typing —
    /// the pick's own card watches the app in front then).
    var frontOffer: FrontWindow? {
        guard let w = frontNow else { return nil }
        let pick = settings.selection.target
        if pick == .frontApp || w.isSame(as: pick) { return nil }
        return w
    }

    /// The place to watch for it: the Mac's list's own entry when it knows that window (its name),
    /// else the app's window by its number.
    func frontTarget(_ w: FrontWindow) -> TargetRef {
        if let key = w.windowKey, let live = liveTargets.first(where: { $0.bundleID == w.bundleID && $0.windowKey == key }) { return live.ref }
        if w.window == nil, let live = liveTargets.first(where: { $0.bundleID == w.bundleID && $0.windowKey == nil }) { return live.ref }
        return w.target
    }

    /// The line's tap: watch that window — a look, not a new pick (on the inner screen it picks,
    /// as a flip does there).
    func watchFront(_ w: FrontWindow) {
        let target = frontTarget(w)
        log.add("front window: watching what's in front (\(isConnected ? "connected" : "once connected"))")
        if lastPose.isInner { pick(target) }
        watchWhenConnected(target)
    }

    /// The quick action, the control and the App Intent: open, wait for the Mac, and watch what's
    /// in front on it at that moment. A Mac that tells the phone (feature `frontWindow`) gives the
    /// exact window; one from before is asked for `.frontApp` (it adopts the app in front, as
    /// every Mac has). The Mac saying nothing's safe to show (a password manager in front): said,
    /// nothing opened.
    func watchWhatsInFront() {
        guard isPaired, !showOnboarding else { log.add("front window: asked, nothing paired"); return }
        sheet = nil
        waitingFront = true
        frontTimeout?.cancel(); frontTimeout = nil
        log.add("front window: asked for what's in front (\(isConnected ? "connected" : "once connected"))")
        resolveFront()
    }

    /// Runs on the connect and on each word from the Mac while a request waits.
    func resolveFront(timedOut: Bool = false) {
        guard waitingFront else { return }
        guard isPaired else { waitingFront = false; return }
        guard isConnected else { return }   // the connect runs this again
        if let f = macFront, f.mac == pairedMac?.id {
            waitingFront = false
            frontTimeout?.cancel(); frontTimeout = nil
            guard let w = f.window else {
                log.add("front window: nothing safe to show")
                explain("Nothing in front on \(macName) to show right now")
                return
            }
            let target = frontTarget(w)
            if lastPose.isInner { pick(target) }
            watcher.open(target)
        } else if !client.macSendsFrontWindow || timedOut {
            waitingFront = false
            frontTimeout?.cancel(); frontTimeout = nil
            log.add("front window: \(timedOut ? "no word from the Mac" : "a Mac from before") — the app in front")
            watcher.open(.frontApp)
        } else if frontTimeout == nil {
            // Its word comes right behind the welcome.
            frontTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                self.frontTimeout = nil
                self.resolveFront(timedOut: true)
            }
        }
    }

    /// The link dropped or went to another Mac: its word on the front window goes with it.
    func frontLinkChanged(connected: Bool) {
        if !connected { macFront = nil } else { UserDefaults.standard.set(client.macSendsFrontWindow, forKey: "bar.had.front") }
        resolveFront()
    }
}
