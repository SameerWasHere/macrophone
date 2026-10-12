import AppKit
import Foundation
import MacrophoneKit

/// What happens to a dictation when it arrives: the profile decides the words and where they
/// go, the delivery mode decides how loudly, and the safety rules decide what may fire on its
/// own (a countdown before any paste, Return only in allowlisted apps, never into a password
/// field, never automatically for a delayed item).
@MainActor
final class DeliveryEngine {
    private unowned let app: AppModel
    /// Pastes run one at a time, in arrival order.
    private var pasteChain: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    private var settings: Settings { app.settings }
    private var popup: PopupController { app.popup }
    private var log: DiagnosticLog { app.log }

    enum Plan {
        case copy(loud: Bool)
        case paste(Paster.Target, enter: Bool)
    }

    /// Returns the ack for the phone right away; the paste (if any) finishes on its own.
    func handle(_ incoming: Dictation, delayed: Bool, from peer: PairedPeer) -> (DeliveryOutcome, String?) {
        let profile = app.profiles.resolve(incoming)
        var d = incoming
        d.profileID = profile.id
        d.profileName = profile.name
        let text = profile.render(d.text)
        let source = d.sourceDevice.isEmpty ? peer.name : d.sourceDevice
        let mode = settings.deliveryMode

        let plan: Plan
        if delayed {
            // From the phone's offline queue: clipboard only, never pasted or sent on its own.
            plan = .copy(loud: true)
        } else {
            switch profile.destination {
            case .clipboard:
                plan = mode == .autoPaste ? .paste(.focused, enter: profile.pressEnter) : .copy(loud: mode == .clipboardNotify)
            case .focusedApp:
                plan = .paste(.focused, enter: profile.pressEnter)
            case let .app(bundleID, name):
                plan = .paste(.app(bundleID: bundleID, name: name), enter: profile.pressEnter)
            }
        }

        var item = HistoryItem(dictation: d, receivedAt: Date(), delayed: delayed, profileName: profile.name,
                               outcome: .pending, detail: "")
        app.record(item)
        log.add("dictation received (\(d.text.count) chars, \(delayed ? "delayed, " : "")profile \(profile.isDefault ? "default" : "custom"))")

        var card: PopupCard?
        let ack: String
        switch plan {
        case .copy(let loud):
            Paster.copy(text)
            item.outcome = .copied
            item.detail = delayed ? "Copied — delayed items are never pasted automatically" : "Copied to clipboard"
            app.update(item)
            ack = delayed ? "Copied (delayed)" : "Copied to clipboard"
            if loud || !profile.automationNames.isEmpty {
                let c = PopupCard(text: text, source: source, delayed: delayed, phase: .copied,
                                  status: delayed ? "Copied · delayed" : "Copied")
                if !profile.isDefault { c.status += " · \(profile.name)" }
                card = c
                popup.show(c)
            } else {
                app.flashStatusItem()
            }
            if mode == .clipboardNotify || delayed { notifyIfAway(title: delayed ? "Delayed dictation copied" : "Copied", body: text, id: d.id) }

        case let .paste(target, enter):
            let c = PopupCard(text: text, source: source, delayed: false, phase: .countdown, status: "")
            card = c
            if !Paster.isTrusted {
                // Fallback: clipboard + notification, and say what's missing.
                Paster.copy(text)
                item.outcome = .copied
                item.detail = "Copied — Accessibility is off, so it wasn't pasted"
                app.update(item)
                fail(c, .accessibilityMissing, retry: { [weak self] in self?.startCountdown(c, text: text, target: target, enter: enter, itemID: d.id) })
                popup.show(c)
                notifyIfAway(title: "Copied — not pasted", body: text, id: d.id)
                ack = "Copied to clipboard"
                log.add("paste skipped: Accessibility not granted")
            } else {
                popup.show(c)
                startCountdown(c, text: text, target: target, enter: enter, itemID: d.id)
                if case let .app(_, name) = target { ack = "Pasting into \(name)" } else { ack = "Pasting into the app in front" }
            }
        }

        runAutomations(profile, dictation: d, text: text, delayed: delayed, card: card, source: source)
        return (.delivered, ack)
    }

    // MARK: Paste

    private func targetName(_ target: Paster.Target) -> String {
        switch target {
        case .app(_, let name): return name
        case .focused: return NSWorkspace.shared.frontmostApplication?.localizedName ?? "the app in front"
        }
    }

    private func targetBundle(_ target: Paster.Target) -> String? {
        switch target {
        case .app(let id, _): return id
        case .focused: return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    }

    func startCountdown(_ c: PopupCard, text: String, target: Paster.Target, enter: Bool, itemID: UUID) {
        let name = targetName(target)
        c.phase = .countdown
        c.remaining = 1
        c.headline = nil
        c.showsSettingsButton = false
        c.canRetry = false
        c.status = enter ? "Sending to \(name)" : "Pasting into \(name)"
        if enter && !settings.allowsEnter(in: targetBundle(target)) {
            c.status = "Pasting into \(name)"
            c.note = "Return won't be pressed — \(name) isn't on your Return list."
        } else {
            c.note = enter ? "Pastes, then presses Return." : nil
        }
        var fired = false
        c.onFire = { [weak self, weak c] in
            guard let self, let c, !fired, c.phase == .countdown else { return }
            fired = true
            self.fire(c, text: text, target: target, enter: enter, itemID: itemID)
        }
        c.onCancel = { [weak self, weak c] in
            guard let self, let c, !fired, c.phase == .countdown else { return }
            fired = true
            c.phase = .cancelled
            c.status = "Not pasted"
            c.note = "Cancelled. It's in History if you want it."
            self.popup.refresh(c)
            self.app.updateOutcome(itemID, .cancelled, "Paste cancelled")
            self.log.add("paste cancelled")
        }
        popup.refresh(c)
    }

    private func fire(_ c: PopupCard, text: String, target: Paster.Target, enter: Bool, itemID: UUID) {
        c.phase = .working
        c.status = "Pasting"
        popup.refresh(c)
        let previous = pasteChain
        pasteChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let r = try await Paster.paste(text, target: target, pressEnter: enter, allowsEnter: { self.settings.allowsEnter(in: $0) })
                c.phase = .done
                c.status = r.pressedEnter ? "Sent to \(r.appName)" : "Pasted into \(r.appName)"
                c.note = r.enterNote
                self.popup.refresh(c)
                self.app.updateOutcome(itemID, .pasted, r.pressedEnter ? "Pasted into \(r.appName) and sent" : "Pasted into \(r.appName)")
                self.log.add("pasted\(r.pressedEnter ? " + Return" : "")\(r.enterNote != nil ? " (Return not allowed here)" : "")")
            } catch let f as PasteFailure {
                Paster.copy(text)
                self.fail(c, f, retry: { [weak self] in self?.startCountdown(c, text: text, target: target, enter: enter, itemID: itemID) })
                self.popup.refresh(c)
                self.app.updateOutcome(itemID, .failed, f.title)
                self.notifyIfAway(title: f.title, body: text, id: itemID)
                self.log.add("paste failed: \(String(describing: f).prefix(40))")
            } catch {
                c.phase = .cancelled
                self.popup.refresh(c)
            }
        }
    }

    private func fail(_ c: PopupCard, _ f: PasteFailure, retry: @escaping () -> Void) {
        c.phase = .failed
        c.status = f == .accessibilityMissing ? "Copied, not pasted" : "Not pasted"
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
            retry()
            self.popup.refresh(c)
        }
    }

    // MARK: Script and webhook (they send text off this Mac)

    private func runAutomations(_ profile: Profile, dictation d: Dictation, text: String, delayed: Bool, card: PopupCard?, source: String) {
        var jobs: [(String, () async throws -> Void)] = []
        if let url = profile.webhookURL {
            let body = Automations.body(for: d, text: text, profile: profile.name, delayed: delayed)
            jobs.append(("Webhook", { try await Automations.postWebhook(url, body: body) }))
        }
        if let script = profile.script?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty {
            jobs.append(("Script", { try await Automations.runScript(script, text: text, raw: d.raw, profile: profile.name, id: d.id) }))
        }
        guard !jobs.isEmpty else { return }
        card?.automations = jobs.map { PopupCard.Automation(name: $0.0, state: .running) }
        if let card { popup.refresh(card) }
        for (name, job) in jobs {
            run(name, job, card: card, text: text, source: source)
        }
    }

    private func run(_ name: String, _ job: @escaping () async throws -> Void, card: PopupCard?, text: String, source: String) {
        Task { [weak self] in
            do {
                try await job()
                guard let self else { return }
                self.setAutomation(name, .ok, on: card)
                self.log.add("\(name.lowercased()) ok")
            } catch {
                guard let self else { return }
                let message = (error as? Automations.Failure)?.message ?? "\(name) failed"
                self.log.add("\(name.lowercased()) failed")
                self.setAutomation(name, .failed, on: card)
                // A card of its own, so the failure is seen even if the first card has gone.
                let c = PopupCard(text: text, source: source, delayed: false, phase: .failed, status: name)
                c.headline = message
                c.note = name == "Webhook" ? "The text didn't reach the URL in this profile." : "Check the command in the profile."
                c.canRetry = true
                c.onRetry = { [weak self, weak c] in
                    guard let self, let c else { return }
                    self.popup.dismiss(c)
                    self.run(name, job, card: nil, text: text, source: source)
                }
                self.popup.show(c)
            }
        }
    }

    private func setAutomation(_ name: String, _ state: PopupCard.Automation.State, on card: PopupCard?) {
        guard let card, let i = card.automations.firstIndex(where: { $0.name == name }) else { return }
        card.automations[i].state = state
        popup.refresh(card)
    }

    // MARK: Notification Center

    private func notifyIfAway(title: String, body: String, id: UUID) {
        guard settings.deliveryMode == .clipboardNotify || settings.deliveryMode == .autoPaste else { return }
        Notifier.shared.requestIfNeeded()
        if Notifier.personIsAway { Notifier.shared.post(title: title, body: body, id: id.uuidString) }
    }
}

extension Profile {
    var automationNames: [String] {
        var n: [String] = []
        if webhookURL != nil { n.append("Webhook") }
        if let s = script, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { n.append("Script") }
        return n
    }
}
