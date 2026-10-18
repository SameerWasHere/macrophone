import AppKit
import Foundation
import MacrophoneKit

/// What happens to a dictation when it arrives (docs/TARGETS.md):
///   1. where it goes — the dictation's own Send to target (the phone's choice, or an app named
///      first: "Messages, …"); from an older phone that sends none, this Mac's Send to choice;
///   2. Clipboard → copied; Where I'm typing / an app → pasted after a 2.5-second countdown you
///      can cancel, then sent when "Send after pasting" is on.
/// Safety: a countdown before any paste, never into a password field, never automatically for
/// a delayed item (those are only copied), and an app that isn't open is copied instead.
@MainActor
final class DeliveryEngine {
    private unowned let app: AppModel
    /// Pastes run one at a time, in arrival order.
    private var pasteChain: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    private var settings: Settings { app.settings }
    private var popup: PopupController { app.popup }
    private var log: DiagnosticLog { app.log }

    /// Where one dictation goes.
    enum Route {
        case clipboard
        case paste(Paster.Target, send: Bool, name: String)

        var name: String {
            switch self {
            case .clipboard: return "Clipboard"
            case .paste(_, _, let name): return name
            }
        }
    }

    func route(for d: Dictation) -> Route {
        if let t = d.target { return route(t, send: d.send ?? false) }
        // An older phone (no Send to target): this Mac's own Send to choice.
        let s = settings.selection
        return route(s.target, send: s.send)
    }

    func route(_ t: TargetRef, send: Bool) -> Route {
        switch AppModel.named(t) {
        case .clipboard: return .clipboard
        case .frontApp: return .paste(.front, send: send, name: TargetRef.frontApp.displayName)
        case let .app(bundleID, windowKey, name): return .paste(.app(bundleID: bundleID, windowKey: windowKey, name: name), send: send, name: name)
        }
    }

    /// Returns the ack for the phone right away; the rest finishes on its own.
    func handle(_ incoming: Dictation, delayed: Bool, from peer: PairedPeer) -> (DeliveryOutcome, String?) {
        var d = incoming
        // A name given on this Mac wins everywhere: the popup, History, the API's source_device.
        if let named = app.customName(peer) { d.sourceDevice = named }
        let source = d.sourceDevice.isEmpty ? app.displayName(peer) : d.sourceDevice
        let route = route(for: d)
        d.profileName = route.name
        let item = HistoryItem(dictation: d, receivedAt: Date(), delayed: delayed, profileName: route.name, outcome: .pending, detail: "")
        app.record(item)
        app.noteSender(d.id, peer: peer.id)
        let kind: String
        switch route {
        case .clipboard: kind = "clipboard"
        case .paste(let t, let send, _): kind = (t == .front ? "where typing" : "an app") + (send ? ", send" : "")
        }
        log.add("dictation received (\(d.text.count) chars, \(delayed ? "delayed, " : "")\(d.target == nil ? "no target from phone, " : "")to \(kind)\(d.targetSpoken == true ? ", named by voice" : ""))")

        // Gone before we start: say so now rather than after a countdown.
        var early: PasteFailure?
        if !delayed, case .paste(let t, _, _) = route { early = Paster.precheck(t) }
        deliver(d.text, id: d.id, route: route, delayed: delayed, source: source, early: early)
        return (.delivered, ack(route, delayed: delayed, early: early))
    }

    private func ack(_ route: Route, delayed: Bool, early: PasteFailure?) -> String {
        if delayed { return "Copied (delayed)" }
        if let early { return early.title }
        switch route {
        case .clipboard: return "Copied to clipboard"
        case let .paste(t, send, name):
            if t == .front { return send ? "Sending where you're typing" : "Pasting where you're typing" }
            return send ? "Sending to \(name)" : "Pasting into \(name)"
        }
    }

    // MARK: Clipboard, Where I'm typing, an app

    private func deliver(_ text: String, id: UUID, route: Route, delayed: Bool, source: String, early: PasteFailure?) {
        if delayed {
            // From the phone's offline queue: clipboard only, never pasted or sent on its own.
            Paster.copy(text)
            app.updateOutcome(id, .copied, "Copied — delayed dictations are never pasted automatically")
            popup.show(PopupCard(text: text, source: source, delayed: true, phase: .copied, status: "Copied · delayed"))
            notifyIfAway(title: "Delayed dictation copied", body: text, id: id)
            return
        }
        switch route {
        case .clipboard:
            Paster.copy(text)
            app.updateOutcome(id, .copied, "Copied to clipboard")
            if settings.clipboardNotification {
                popup.show(PopupCard(text: text, source: source, delayed: false, phase: .copied, status: "Copied"))
                notifyIfAway(title: "Copied", body: text, id: id)
            } else {
                app.flashStatusItem()
            }
        case let .paste(target, send, name):
            let req = Paster.Request(text: text, target: target, send: send)
            let c = PopupCard(text: text, source: source, delayed: false, phase: .countdown, status: "")
            popup.show(c)
            if let early {
                failed(c, early, req: req, name: name, itemID: id)
            } else if StayAwake.isLocked {
                // Never typed into the lock screen's password field.
                failed(c, .macLocked, req: req, name: name, itemID: id)
                log.add("paste skipped: the Mac is locked")
            } else if !Paster.isTrusted {
                failed(c, .accessibilityMissing, req: req, name: name, itemID: id)
                log.add("paste skipped: Accessibility not granted")
            } else {
                startCountdown(c, req, name: name, itemID: id)
            }
        }
    }

    /// "Sending to Claude", "Pasting where you're typing".
    private func doing(_ req: Paster.Request, name: String) -> String {
        if req.target == .front { return req.send ? "Sending where you're typing" : "Pasting where you're typing" }
        return req.send ? "Sending to \(name)" : "Pasting into \(name)"
    }

    func startCountdown(_ c: PopupCard, _ req: Paster.Request, name: String, itemID: UUID) {
        c.phase = .countdown
        c.remaining = 1
        c.headline = nil
        c.caution = false
        c.showsSettingsButton = false
        c.canRetry = false
        c.status = doing(req, name: name)
        if req.send {
            var bid: String?
            if case .app(let b, _, _) = req.target { bid = b } else { bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
            c.note = "Pastes, then presses \(AppQuirks.sendKey(for: bid).title)."
        } else {
            c.note = nil
        }
        var fired = false
        c.onFire = { [weak self, weak c] in
            guard let self, let c, !fired, c.phase == .countdown else { return }
            fired = true
            self.fire(c, req, name: name, itemID: itemID)
        }
        c.onCancel = { [weak self, weak c] in
            guard let self, let c, !fired, c.phase == .countdown else { return }
            fired = true
            self.cancelled(c, itemID: itemID)
        }
        popup.refresh(c)
    }

    private func cancelled(_ c: PopupCard, itemID: UUID) {
        c.phase = .cancelled
        c.status = "Not pasted"
        c.note = "Cancelled. It's in History if you want it."
        popup.refresh(c)
        app.updateOutcome(itemID, .cancelled, "Paste cancelled")
        log.add("paste cancelled")
    }

    private func fire(_ c: PopupCard, _ req: Paster.Request, name: String, itemID: UUID) {
        c.phase = .working
        c.status = (req.target == .front ? "Pasting" : "Opening \(Paster.appName(fromTitle: name))")
        popup.refresh(c)
        let previous = pasteChain
        let scanner = app.scanner
        pasteChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let r = try await Paster.deliver(req, scanner: scanner)
                c.phase = .done
                let outcome: String
                if r.pressedSend && r.stillInBox {
                    c.status = "Pasted into \(r.appName)"
                    c.caution = true
                    c.note = "Pressed \(r.sendKey.title), but it's still in the message box — \(r.appName) may still be answering. Press \(r.sendKey.title) when it's ready."
                    outcome = "Pasted into \(r.appName) — still in the message box after \(r.sendKey.title)"
                } else if r.pressedSend && (r.confirmedSent || AppQuirks.isTerminal(r.bundleID) || r.landed == nil) {
                    c.status = "Sent to \(r.appName)"
                    c.note = nil
                    outcome = "Sent to \(r.appName)"
                } else if r.pressedSend {
                    c.status = "Pasted into \(r.appName) · pressed \(r.sendKey.title)"
                    c.note = nil
                    outcome = "Pasted into \(r.appName), then pressed \(r.sendKey.title)"
                } else {
                    c.status = "Pasted into \(r.appName)"
                    c.note = nil
                    outcome = "Pasted into \(r.appName)"
                }
                self.popup.refresh(c)
                self.app.updateOutcome(itemID, .pasted, outcome)
                // Sent: a chat now, waiting for its answer.
                if r.pressedSend, let wid = r.windowID { self.app.replies.engaged(windowID: wid, bundleID: r.bundleID) }
                let how = r.pressedSend ? (r.confirmedSent ? "sent, confirmed" : (r.stillInBox ? "send key pressed, box not cleared" : "sent")) : "pasted"
                self.log.add("delivered: \(how)\(r.landed == true ? ", landed" : (r.landed == nil ? ", not readable" : ""))")
            } catch let f as PasteFailure {
                self.failed(c, f, req: req, name: name, itemID: itemID)
                self.log.add("paste failed: \(String(describing: f).prefix(40))")
            } catch {
                c.phase = .cancelled
                self.popup.refresh(c)
            }
        }
    }

    private func failed(_ c: PopupCard, _ f: PasteFailure, req: Paster.Request, name: String, itemID: UUID) {
        Paster.copy(req.text)
        c.phase = .failed
        c.caution = false
        switch f {
        case .accessibilityMissing: c.status = "Copied, not pasted"
        case .notLanded: c.status = "Not sent"
        default: c.status = (f.copiedInstead ? "Copied instead" : "Not pasted")
        }
        c.headline = f.title
        c.note = f.detail
        c.showsSettingsButton = f.opensAccessibilitySettings
        c.canRetry = true
        c.onRetry = { [weak self, weak c] in
            guard let self, let c else { return }
            if f == .accessibilityMissing && !Paster.isTrusted {
                Paster.requestTrust()
                return
            }
            self.startCountdown(c, req, name: name, itemID: itemID)
        }
        popup.refresh(c)
        app.updateOutcome(itemID, f.copiedInstead ? .copied : .failed, f.title)
        notifyIfAway(title: f.title, body: req.text, id: itemID)
    }

    // MARK: Notification Center

    /// When the person is away from the Mac (locked, asleep, idle), what arrived waits in
    /// Notification Center.
    private func notifyIfAway(title: String, body: String, id: UUID) {
        Notifier.shared.askAfterDelivery(popup)
        if Notifier.personIsAway { Notifier.shared.post(title: title, body: body, id: id.uuidString) }
    }
}
