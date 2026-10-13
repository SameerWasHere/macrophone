import AppKit
import Foundation
import MacrophoneKit

/// What happens to a dictation when it arrives (docs/TARGETS.md):
///   1. where it goes — the dictation's own Send to target (the phone's choice, or an app named
///      first: "Messages, …"); from an older phone, an automation it picked, else this Mac's
///      Send to choice;
///   2. snippets expand inside the text (always);
///   3. Clipboard → copied; Where I'm typing / an app → pasted after a 2.5-second countdown, and
///      sent if the phone said "Paste & send"; an automation → its format, template, destination
///      and actions (docs/AUTOMATIONS.md).
/// Safety: a countdown before any paste, never into a password field, never automatically for
/// a delayed item (those are only copied).
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
        case automation(Profile)
        /// The phone picked an automation this Mac no longer has.
        case missingAutomation(name: String)

        var name: String {
            switch self {
            case .clipboard: return "Clipboard"
            case .paste(_, _, let name): return name
            case .automation(let p): return p.name
            case .missingAutomation(let name): return name
            }
        }
    }

    func route(for d: Dictation) -> Route {
        if let t = d.target { return route(t, send: d.send ?? false) }
        // An older phone (no Send to target): an automation it picked by profile, else this
        // Mac's own Send to choice.
        if let a = app.automations.automation(d.profileID) ?? app.automations.automation(named: d.profileName) {
            return .automation(a)
        }
        let s = settings.selection
        return route(s.target, send: s.send)
    }

    func route(_ t: TargetRef, send: Bool) -> Route {
        switch AppModel.named(t) {
        case .clipboard: return .clipboard
        case .frontApp: return .paste(.front, send: send, name: TargetRef.frontApp.displayName)
        case let .app(bundleID, windowKey, name): return .paste(.app(bundleID: bundleID, windowKey: windowKey, name: name), send: send, name: name)
        case let .automation(id, name): return app.automations.automation(id).map(Route.automation) ?? .missingAutomation(name: name)
        }
    }

    /// Returns the ack for the phone right away; the rest finishes on its own.
    func handle(_ incoming: Dictation, delayed: Bool, from peer: PairedPeer) -> (DeliveryOutcome, String?) {
        var d = incoming
        // A name given on this Mac wins everywhere: the popup, History, the API's source_device.
        if let named = app.customName(peer) { d.sourceDevice = named }
        let source = d.sourceDevice.isEmpty ? app.displayName(peer) : d.sourceDevice
        let route = route(for: d)
        if case .automation(let a) = route { return handleAutomation(d, a, delayed: delayed, source: source) }

        // Snippet variables ({{clipboard}}, {{selection}}…) are read before anything moves.
        let needed = ContextGatherer.needed(template: nil, snippets: settings.snippets, text: d.text)
        let arrival = ContextGatherer.arrival(needed: needed)
        d.profileName = route.name
        let item = HistoryItem(dictation: d, receivedAt: Date(), delayed: delayed, profileName: route.name, outcome: .pending, detail: "")
        app.record(item)
        let kind: String
        switch route {
        case .clipboard: kind = "clipboard"
        case .paste(let t, let send, _): kind = (t == .front ? "where typing" : "an app") + (send ? ", send" : "")
        case .missingAutomation: kind = "a missing automation"
        case .automation: kind = "automation"
        }
        log.add("dictation received (\(d.text.count) chars, \(delayed ? "delayed, " : "")\(d.target == nil ? "no target from phone, " : "")to \(kind)\(d.targetSpoken == true ? ", named by voice" : ""))")

        // Gone before we start: say so now rather than after a countdown.
        var early: PasteFailure?
        if !delayed, case .paste(let t, _, _) = route { early = Paster.precheck(t) }
        Task { await self.runTarget(d, route: route, item: item, needed: needed, arrival: arrival, delayed: delayed, source: source, early: early) }
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
        case .automation(let a): return a.name
        case .missingAutomation(let name): return "“\(name)” isn't on this Mac — copied instead"
        }
    }

    // MARK: Clipboard, Where I'm typing, an app

    private func runTarget(_ d: Dictation, route: Route, item: HistoryItem, needed: Set<String>, arrival: ContextGatherer.Arrival,
                           delayed: Bool, source: String, early: PasteFailure?) async {
        let ctx = await ContextGatherer.context(needed: needed, arrival: arrival, dictation: d, name: route.name, tmuxTarget: nil)
        let text = SnippetExpander.expand(d.text, snippets: settings.snippets, context: ctx.values)
        var item = item
        var card: PopupCard?

        if delayed {
            // From the phone's offline queue: clipboard only, never pasted or sent on its own.
            Paster.copy(text)
            item.outcome = .copied
            item.detail = "Copied — delayed items are never pasted automatically"
            app.update(item)
            let c = PopupCard(text: text, source: source, delayed: true, phase: .copied, status: "Copied · delayed")
            card = c
            popup.show(c)
            notifyIfAway(title: "Delayed dictation copied", body: text, id: d.id)
        } else {
            switch route {
            case .clipboard:
                Paster.copy(text)
                item.outcome = .copied
                item.detail = "Copied to clipboard"
                app.update(item)
                if settings.clipboardNotification {
                    let c = PopupCard(text: text, source: source, delayed: false, phase: .copied, status: "Copied")
                    card = c
                    popup.show(c)
                    notifyIfAway(title: "Copied", body: text, id: d.id)
                } else {
                    app.flashStatusItem()
                }
            case .missingAutomation(let name):
                Paster.copy(text)
                app.updateOutcome(d.id, .copied, "Copied — the automation “\(name)” isn't on this Mac")
                let c = PopupCard(text: text, source: source, delayed: false, phase: .failed, status: "Copied instead")
                c.headline = "“\(name)” isn't on this Mac — copied instead"
                c.note = "It may have been deleted. Pick another place under Send to."
                card = c
                popup.show(c)
            case let .paste(target, send, name):
                let req = Paster.Request(text: text, target: target, send: send)
                let c = PopupCard(text: text, source: source, delayed: false, phase: .countdown, status: "")
                card = c
                popup.show(c)
                if let early {
                    failed(c, early, req: req, name: name, itemID: d.id)
                } else if !Paster.isTrusted {
                    failed(c, .accessibilityMissing, req: req, name: name, itemID: d.id)
                    log.add("paste skipped: Accessibility not granted")
                } else {
                    startCountdown(c, req, name: name, itemID: d.id)
                }
            case .automation:
                break
            }
        }
        if !ctx.notes.isEmpty, let card {
            card.note = ([card.note].compactMap { $0 } + ctx.notes).joined(separator: "\n")
            popup.refresh(card)
        }
    }

    /// "Sending to Claude", "Pasting where you're typing".
    private func doing(_ req: Paster.Request, name: String) -> String {
        if req.target == .front { return req.send ? "Sending where you're typing" : "Pasting where you're typing" }
        return req.send ? "Sending to \(name)" : "Pasting into \(name)"
    }

    func startCountdown(_ c: PopupCard, _ req: Paster.Request, name: String, itemID: UUID, kicker: String = "") {
        c.phase = .countdown
        c.remaining = 1
        c.headline = nil
        c.caution = false
        c.showsSettingsButton = false
        c.canRetry = false
        c.status = kicker + doing(req, name: name)
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
            self.fire(c, req, name: name, itemID: itemID, kicker: kicker)
        }
        c.onCancel = { [weak self, weak c] in
            guard let self, let c, !fired, c.phase == .countdown else { return }
            fired = true
            self.cancelled(c, itemID: itemID, kicker: kicker)
        }
        popup.refresh(c)
    }

    private func cancelled(_ c: PopupCard, itemID: UUID, kicker: String) {
        c.phase = .cancelled
        c.status = kicker + "Not pasted"
        c.note = "Cancelled. It's in History if you want it."
        popup.refresh(c)
        app.updateOutcome(itemID, .cancelled, "Paste cancelled")
        log.add("paste cancelled")
    }

    private func fire(_ c: PopupCard, _ req: Paster.Request, name: String, itemID: UUID, kicker: String) {
        c.phase = .working
        c.status = kicker + (req.target == .front ? "Pasting" : "Opening \(Paster.appName(fromTitle: name))")
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
                    c.status = kicker + "Pasted into \(r.appName)"
                    c.caution = true
                    c.note = "Pressed \(r.sendKey.title), but it's still in the message box — \(r.appName) may still be answering. Press \(r.sendKey.title) when it's ready."
                    outcome = "Pasted into \(r.appName) — still in the message box after \(r.sendKey.title)"
                } else if r.pressedSend && (r.confirmedSent || AppQuirks.isTerminal(r.bundleID) || r.landed == nil) {
                    c.status = kicker + "Sent to \(r.appName)"
                    c.note = nil
                    outcome = "Sent to \(r.appName)"
                } else if r.pressedSend {
                    c.status = kicker + "Pasted into \(r.appName) · pressed \(r.sendKey.title)"
                    c.note = nil
                    outcome = "Pasted into \(r.appName), then pressed \(r.sendKey.title)"
                } else {
                    c.status = kicker + "Pasted into \(r.appName)"
                    c.note = nil
                    outcome = "Pasted into \(r.appName)"
                }
                self.popup.refresh(c)
                self.app.updateOutcome(itemID, .pasted, outcome)
                let how = r.pressedSend ? (r.confirmedSent ? "sent, confirmed" : (r.stillInBox ? "send key pressed, box not cleared" : "sent")) : "pasted"
                self.log.add("delivered: \(how)\(r.landed == true ? ", landed" : (r.landed == nil ? ", not readable" : ""))")
            } catch let f as PasteFailure {
                self.failed(c, f, req: req, name: name, itemID: itemID, kicker: kicker)
                self.log.add("paste failed: \(String(describing: f).prefix(40))")
            } catch {
                c.phase = .cancelled
                self.popup.refresh(c)
            }
        }
    }

    private func failed(_ c: PopupCard, _ f: PasteFailure, req: Paster.Request, name: String, itemID: UUID, kicker: String = "") {
        Paster.copy(req.text)
        c.phase = .failed
        c.caution = false
        switch f {
        case .accessibilityMissing: c.status = kicker + "Copied, not pasted"
        case .notLanded: c.status = kicker + "Not sent"
        default: c.status = kicker + (f.copiedInstead ? "Copied instead" : "Not pasted")
        }
        c.headline = f.title
        c.note = f.detail
        c.showsSettingsButton = f.opensAccessibilitySettings
        c.settingsURL = nil
        c.canRetry = true
        c.onRetry = { [weak self, weak c] in
            guard let self, let c else { return }
            if f == .accessibilityMissing && !Paster.isTrusted {
                Paster.requestTrust()
                return
            }
            self.startCountdown(c, req, name: name, itemID: itemID, kicker: kicker)
        }
        popup.refresh(c)
        app.updateOutcome(itemID, f.copiedInstead ? .copied : .failed, f.title)
        notifyIfAway(title: f.title, body: req.text, id: itemID)
    }

    // MARK: Automations

    enum Plan {
        case copy
        case paste(Paster.Request)
        case tmux(target: String, enter: Bool)
        /// Only the automation's actions run.
        case nothing
    }

    private func handleAutomation(_ incoming: Dictation, _ a: Profile, delayed: Bool, source: String) -> (DeliveryOutcome, String?) {
        var d = incoming
        d.profileID = a.id
        d.profileName = a.name
        let plan: Plan
        if delayed {
            plan = .copy
        } else {
            switch a.destination {
            case .clipboard: plan = .copy
            case .focusedApp: plan = .paste(Paster.Request(text: "", target: .front, send: a.pressEnter))
            case let .app(bundleID, name): plan = .paste(Paster.Request(text: "", target: .app(bundleID: bundleID, windowKey: nil, name: name), send: a.pressEnter))
            case .tmux(let target): plan = .tmux(target: target, enter: a.pressEnter)
            case .none: plan = .nothing
            }
        }
        // What the template and snippets need, read before anything moves.
        let needed = ContextGatherer.needed(template: a.template, snippets: settings.snippets, text: d.text)
        let arrival = ContextGatherer.arrival(needed: needed)
        let item = HistoryItem(dictation: d, receivedAt: Date(), delayed: delayed, profileName: a.name, outcome: .pending, detail: "")
        app.record(item)
        log.add("dictation received (\(d.text.count) chars, \(delayed ? "delayed, " : "")automation)")
        Task { await self.runAutomation(d, a, plan: plan, item: item, needed: needed, arrival: arrival, delayed: delayed, source: source) }
        let ackLine: String
        switch plan {
        case .copy: ackLine = delayed ? "Copied (delayed)" : "\(a.name) · copied"
        case .paste: ackLine = "\(a.name) · pasting where you're typing"
        case .tmux(let t, _): ackLine = "\(a.name) · typing into tmux \(t)"
        case .nothing: ackLine = a.name
        }
        return (.delivered, ackLine)
    }

    private func runAutomation(_ d: Dictation, _ a: Profile, plan: Plan, item: HistoryItem, needed: Set<String>,
                               arrival: ContextGatherer.Arrival, delayed: Bool, source: String) async {
        let tmuxTarget: String? = { if case .tmux(let t) = a.destination { return t }; return nil }()
        let ctx = await ContextGatherer.context(needed: needed, arrival: arrival, dictation: d, name: a.name, tmuxTarget: tmuxTarget)
        // Snippets, format, template.
        var text = SnippetExpander.expand(d.text, snippets: settings.snippets, context: ctx.values)
        text = (a.outputFormat ?? .plain).apply(text)
        text = TemplateRenderer.render(template: a.template, text: text, context: ctx.values)

        var item = item
        let kicker = "\(a.name) · "
        var card: PopupCard?
        switch plan {
        case .copy:
            Paster.copy(text)
            item.outcome = .copied
            item.detail = delayed ? "Copied — delayed items are never pasted automatically" : "Copied to clipboard"
            app.update(item)
            let c = PopupCard(text: text, source: source, delayed: delayed, phase: .copied, status: kicker + (delayed ? "Copied · delayed" : "Copied"))
            card = c
            popup.show(c)
            if delayed { notifyIfAway(title: "Delayed dictation copied", body: text, id: d.id) }
        case .paste(var req):
            req.text = text
            let c = PopupCard(text: text, source: source, delayed: false, phase: .countdown, status: "")
            card = c
            popup.show(c)
            if !Paster.isTrusted {
                failed(c, .accessibilityMissing, req: req, name: "Where I'm typing", itemID: d.id, kicker: kicker)
            } else {
                startCountdown(c, req, name: "Where I'm typing", itemID: d.id, kicker: kicker)
            }
        case let .tmux(target, enter):
            let c = PopupCard(text: text, source: source, delayed: false, phase: .countdown, status: "")
            card = c
            popup.show(c)
            startTmuxCountdown(c, text: text, target: target, enter: enter, kicker: kicker, itemID: d.id)
        case .nothing:
            item.outcome = .copied
            item.detail = "Not pasted — the automation's actions ran"
            app.update(item)
            let c = PopupCard(text: text, source: source, delayed: delayed, phase: .copied, status: kicker + "Received")
            card = c
            popup.show(c)
        }
        if !ctx.notes.isEmpty, let card {
            card.note = ([card.note].compactMap { $0 } + ctx.notes).joined(separator: "\n")
            popup.refresh(card)
        }
        runActions(a, dictation: d, text: text, delayed: delayed, card: card, source: source)
    }

    // MARK: tmux

    private func startTmuxCountdown(_ c: PopupCard, text: String, target: String, enter: Bool, kicker: String, itemID: UUID) {
        c.phase = .countdown
        c.remaining = 1
        c.headline = nil
        c.canRetry = false
        c.status = kicker + (enter ? "Sending to tmux \(target)" : "Typing into tmux \(target)")
        c.note = enter ? "Types it into the pane, then presses Return." : "Types it into the pane."
        var fired = false
        c.onFire = { [weak self, weak c] in
            guard let self, let c, !fired, c.phase == .countdown else { return }
            fired = true
            c.phase = .working
            c.status = kicker + "Typing"
            self.popup.refresh(c)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await Tmux.send(text, to: target, enter: enter)
                    c.phase = .done
                    c.status = kicker + (enter ? "Sent to tmux \(target)" : "Typed into tmux \(target)")
                    c.note = nil
                    self.app.updateOutcome(itemID, .pasted, enter ? "Sent to tmux \(target)" : "Typed into tmux \(target)")
                    self.log.add("tmux \(enter ? "sent" : "typed")")
                } catch {
                    Paster.copy(text)
                    let msg = (error as? Tmux.Failure)?.message ?? "tmux failed"
                    c.phase = .failed
                    c.status = "Not sent"
                    c.headline = msg
                    c.note = "It's on your clipboard. Pick a pane that's open in the automation, or try again."
                    c.canRetry = true
                    c.onRetry = { [weak self, weak c] in
                        guard let self, let c else { return }
                        self.startTmuxCountdown(c, text: text, target: target, enter: enter, kicker: kicker, itemID: itemID)
                    }
                    self.app.updateOutcome(itemID, .failed, msg)
                    self.log.add("tmux failed")
                }
                self.popup.refresh(c)
            }
        }
        c.onCancel = { [weak self, weak c] in
            guard let self, let c, !fired, c.phase == .countdown else { return }
            fired = true
            self.cancelled(c, itemID: itemID, kicker: kicker)
        }
        popup.refresh(c)
    }

    // MARK: Actions (Obsidian, Notes, Reminders, Claude, script, webhook)

    private func runActions(_ profile: Profile, dictation d: Dictation, text: String, delayed: Bool, card: PopupCard?, source: String) {
        var jobs: [(String, () async throws -> String?)] = []
        for a in profile.actions ?? [] {
            switch a.kind {
            case let .obsidian(vault, note, daily, heading):
                jobs.append(("Obsidian", {
                    let path = try NoteActions.appendToObsidian(text, vaultPath: vault, notePath: note, dailyFolder: daily, heading: heading)
                    return "Saved to \(path)"
                }))
            case let .appleNote(folder, appendTo):
                jobs.append(("Notes", { try await NoteActions.saveToNotes(text, folder: folder, appendTo: appendTo) }))
            case let .reminder(list, detect):
                jobs.append(("Reminders", { try await NoteActions.addReminder(text, list: list, detectDates: detect) }))
            case let .claude(model, system, deliver):
                askClaude(text, model: model, system: system, deliverReply: deliver, itemID: d.id, card: card, source: source)
            }
        }
        if let url = profile.webhookURL {
            let body = Automations.body(for: d, text: text, profile: profile.name, delayed: delayed)
            jobs.append(("Webhook", { try await Automations.postWebhook(url, body: body); return nil }))
        }
        if let script = profile.script?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty {
            jobs.append(("Script", { try await Automations.runScript(script, text: text, raw: d.raw, profile: profile.name, id: d.id); return nil }))
        }
        guard !jobs.isEmpty else { return }
        if let card {
            card.automations += jobs.map { PopupCard.Automation(name: $0.0, state: .running) }
            popup.refresh(card)
        }
        for (name, job) in jobs { run(name, job, card: card, text: text, source: source) }
    }

    private func run(_ name: String, _ job: @escaping () async throws -> String?, card: PopupCard?, text: String, source: String) {
        Task { [weak self] in
            do {
                let line = try await job()
                guard let self else { return }
                self.setAutomation(name, .ok, on: card)
                if let line, let card, card.phase == .copied || card.phase == .done {
                    card.note = [card.note, line].compactMap { $0 }.joined(separator: "\n")
                    self.popup.refresh(card)
                }
                self.log.add("\(name.lowercased()) ok")
            } catch {
                guard let self else { return }
                var message = "\(name) failed"
                var settingsURL: URL?
                if let f = error as? Automations.Failure { message = f.message }
                if let f = error as? NoteActions.Failure { message = f.message; settingsURL = f.opensSettings }
                self.log.add("\(name.lowercased()) failed")
                self.setAutomation(name, .failed, on: card)
                // A card of its own, so the failure is seen even if the first card has gone.
                let c = PopupCard(text: text, source: source, delayed: false, phase: .failed, status: name)
                c.headline = message
                switch name {
                case "Webhook": c.note = "The text didn't reach the URL in this automation."
                case "Script": c.note = "Check the command in the automation."
                default: c.note = settingsURL != nil ? "Allow it in System Settings, then try again." : "Check the action in the automation."
                }
                c.settingsURL = settingsURL
                c.showsSettingsButton = settingsURL != nil
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

    // MARK: Ask Claude

    /// Sends the text to Claude with the person's key and streams the answer into the card.
    private func askClaude(_ text: String, model: String, system: String?, deliverReply: Bool, itemID: UUID,
                           card: PopupCard?, source: String) {
        let c = card ?? PopupCard(text: text, source: source, delayed: false, phase: .copied, status: "Asked Claude")
        if card == nil { popup.show(c) }
        c.replyModel = ClaudeClient.name(of: model)
        c.replyState = .waiting
        c.reply = nil
        c.replyNote = nil
        popup.refresh(c)
        guard let key = ClaudeKey.load() else {
            c.replyState = .failed
            c.replyNote = ClaudeClient.Failure.noKey.title + ". " + ClaudeClient.Failure.noKey.detail
            popup.refresh(c)
            log.add("claude: no key")
            return
        }
        let client = ClaudeClient(key: key, model: model, system: system, session: Self.claudeSession)
        log.add("claude: asking (\(model))")
        Task { [weak self] in
            do {
                let reply = try await client.stream(text) { [weak c] so_far in
                    guard let c else { return }
                    c.reply = so_far
                    if c.replyState != .streaming { c.replyState = .streaming }
                }
                guard let self else { return }
                c.reply = reply
                c.replyState = .done
                c.onCopyReply = { Clipboard.copyPlain(reply) }
                if deliverReply {
                    // Wait for a paste in flight to put the clipboard back first.
                    await self.pasteChain?.value
                    Clipboard.copyPlain(reply)
                    c.replyNote = "Copied to your clipboard"
                }
                self.popup.refresh(c)
                self.saveReply(reply, model: model, itemID: itemID)
                self.log.add("claude: replied (\(reply.count) chars)")
            } catch {
                guard let self else { return }
                let f = (error as? ClaudeClient.Failure) ?? .offline
                c.replyState = .failed
                c.replyNote = f.title + ". " + f.detail
                c.canRetry = true
                c.onRetry = { [weak self, weak c] in
                    guard let self, let c else { return }
                    c.canRetry = false
                    self.askClaude(text, model: model, system: system, deliverReply: deliverReply, itemID: itemID, card: c, source: source)
                }
                self.popup.refresh(c)
                self.log.add("claude failed: \(String(describing: f).prefix(30))")
            }
        }
    }

    /// Tests swap this for a mocked transport (DEBUG: MACROPHONE_CLAUDE_MOCK).
    static var claudeSession: URLSession = .shared

    private func saveReply(_ reply: String, model: String, itemID: UUID) {
        guard var item = app.history.first(where: { $0.id == itemID }) ?? app.historyStore.latest.flatMap({ $0.id == itemID ? $0 : nil }) else { return }
        item.reply = reply
        item.replyModel = model
        app.update(item)
    }

    // MARK: Notification Center

    /// When the person is away from the Mac (locked, asleep, idle), what arrived waits in
    /// Notification Center.
    private func notifyIfAway(title: String, body: String, id: UUID) {
        Notifier.shared.askAfterDelivery(popup)
        if Notifier.personIsAway { Notifier.shared.post(title: title, body: body, id: id.uuidString) }
    }
}
