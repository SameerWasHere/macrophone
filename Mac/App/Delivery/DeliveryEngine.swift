import AppKit
import Foundation
import MacrophoneKit

/// What happens to a dictation when it arrives. The order (MacrophoneKit/Core/Automation.swift):
///   1. the profile — voice prefix > the phone's pick > the rule for the app in front > default
///   2. snippets expand inside the text
///   3. the output format shapes it
///   4. the template wraps it, with context variables filled in
///   5. the destination (clipboard / the app in front / an app / a tmux pane / nowhere) and
///      the profile's actions (Obsidian, Notes, Reminders, Claude, script, webhook)
/// The safety rules decide what may fire on its own: a countdown before any paste, the send
/// key only in allowlisted apps, never into a password field, never automatically for a
/// delayed item.
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
        case paste(Paster.Request)
        case tmux(target: String, enter: Bool)
        /// Only the profile's actions run.
        case nothing
    }

    /// Returns the ack for the phone right away; the rest finishes on its own.
    func handle(_ incoming: Dictation, delayed: Bool, from peer: PairedPeer) -> (DeliveryOutcome, String?) {
        // "The app in front" is the one in front when the dictation arrives.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let profile = app.profiles.resolve(incoming, frontmostBundleID: front, rules: settings.appRules)
        var d = incoming
        d.profileID = profile.id
        d.profileName = profile.name
        let source = d.sourceDevice.isEmpty ? peer.name : d.sourceDevice
        let options = app.profiles.options(for: profile.id)
        let plan = makePlan(profile, options: options, delayed: delayed)

        // What the template and snippets need, read before anything moves.
        let needed = ContextGatherer.needed(template: profile.template, snippets: settings.snippets, text: d.text)
        let arrival = ContextGatherer.arrival(needed: needed)

        let item = HistoryItem(dictation: d, receivedAt: Date(), delayed: delayed, profileName: profile.name,
                               outcome: .pending, detail: "")
        app.record(item)
        var how = d.profileSource == .automatic ? "automatic" : (d.profileSource == .prefix ? "prefix" : (profile.isDefault ? "default" : "chosen"))
        if d.profileSource == .automatic, settings.appRules.contains(where: { $0.bundleID == front }) { how += " rule" }
        log.add("dictation received (\(d.text.count) chars, \(delayed ? "delayed, " : "")profile \(how))")

        Task { await self.run(d, profile: profile, options: options, plan: plan, item: item, needed: needed,
                              arrival: arrival, delayed: delayed, source: source) }
        return (.delivered, ack(plan, delayed: delayed))
    }

    private func makePlan(_ profile: Profile, options: ProfileOptions, delayed: Bool) -> Plan {
        // From the phone's offline queue: clipboard only, never pasted or sent on its own.
        if delayed { return .copy(loud: true) }
        let mode = settings.deliveryMode
        func request(_ target: Paster.Target) -> Paster.Request {
            Paster.Request(text: "", target: target, windowMatch: profile.windowMatch, send: profile.pressEnter,
                           sendKey: options.sendKey ?? TargetCatalog.defaultSendKey(for: profile.targetBundleID),
                           returnToPrevious: options.returnToPrevious)
        }
        switch profile.destination {
        case .clipboard:
            return mode == .autoPaste ? .paste(request(.focused)) : .copy(loud: mode == .clipboardNotify)
        case .focusedApp:
            return .paste(request(.focused))
        case let .app(bundleID, name):
            return .paste(request(.app(bundleID: bundleID, name: name)))
        case .tmux(let target):
            return .tmux(target: target, enter: profile.pressEnter)
        case .none:
            return .nothing
        }
    }

    private func ack(_ plan: Plan, delayed: Bool) -> String {
        switch plan {
        case .copy: return delayed ? "Copied (delayed)" : "Copied to clipboard"
        case .paste(let r):
            if case let .app(_, name) = r.target { return r.send ? "Sending to \(name)" : "Pasting into \(name)" }
            return "Pasting into the app in front"
        case .tmux(let target, _): return "Typing into tmux \(target)"
        case .nothing: return "Received"
        }
    }

    // MARK: The pipeline

    private func run(_ d: Dictation, profile: Profile, options: ProfileOptions, plan: Plan, item: HistoryItem,
                     needed: Set<String>, arrival: ContextGatherer.Arrival, delayed: Bool, source: String) async {
        let ctx = await ContextGatherer.context(needed: needed, arrival: arrival, dictation: d, profile: profile)
        // 2–4: snippets, format, template.
        var text = SnippetExpander.expand(d.text, snippets: settings.snippets, context: ctx.values)
        text = (profile.outputFormat ?? .plain).apply(text)
        text = TemplateRenderer.render(template: profile.template, text: text, context: ctx.values)

        var item = item
        let kicker = d.profileSource == .prefix ? "\(profile.name) · " : ""
        var card: PopupCard?

        switch plan {
        case .copy(let loud):
            Paster.copy(text)
            item.outcome = .copied
            item.detail = delayed ? "Copied — delayed items are never pasted automatically" : "Copied to clipboard"
            app.update(item)
            if loud || profile.hasActions || !kicker.isEmpty {
                let c = PopupCard(text: text, source: source, delayed: delayed, phase: .copied,
                                  status: kicker + (delayed ? "Copied · delayed" : "Copied"))
                if !profile.isDefault && kicker.isEmpty { c.status += " · \(profile.name)" }
                card = c
                popup.show(c)
            } else {
                app.flashStatusItem()
            }
            if settings.deliveryMode == .clipboardNotify || delayed {
                notifyIfAway(title: delayed ? "Delayed dictation copied" : "Copied", body: text, id: d.id)
            }

        case .paste(var req):
            req.text = text
            let c = PopupCard(text: text, source: source, delayed: false, phase: .countdown, status: "")
            card = c
            if !Paster.isTrusted {
                // Fallback: clipboard + notification, and say what's missing.
                Paster.copy(text)
                app.updateOutcome(d.id, .copied, "Copied — Accessibility is off, so it wasn't pasted")
                fail(c, .accessibilityMissing, retry: { [weak self] in self?.startCountdown(c, req, kicker: kicker, itemID: d.id) })
                popup.show(c)
                notifyIfAway(title: "Copied — not pasted", body: text, id: d.id)
                log.add("paste skipped: Accessibility not granted")
            } else {
                popup.show(c)
                startCountdown(c, req, kicker: kicker, itemID: d.id)
            }

        case let .tmux(target, enter):
            let c = PopupCard(text: text, source: source, delayed: false, phase: .countdown, status: "")
            card = c
            popup.show(c)
            startTmuxCountdown(c, text: text, target: target, enter: enter, kicker: kicker, itemID: d.id)

        case .nothing:
            item.outcome = .copied
            item.detail = "Not pasted — the profile's actions ran"
            app.update(item)
            let c = PopupCard(text: text, source: source, delayed: delayed, phase: .copied, status: kicker + "Received")
            card = c
            popup.show(c)
        }

        if !ctx.notes.isEmpty, let card {
            card.note = ([card.note].compactMap { $0 } + ctx.notes).joined(separator: "\n")
            popup.refresh(card)
        }
        runActions(profile, dictation: d, text: text, delayed: delayed, card: card, source: source)
    }

    // MARK: Paste

    private func name(of target: Paster.Target) -> String {
        switch target {
        case .app(_, let name): return name
        case .focused: return NSWorkspace.shared.frontmostApplication?.localizedName ?? "the app in front"
        }
    }

    private func bundle(of target: Paster.Target) -> String? {
        switch target {
        case .app(let id, _): return id
        case .focused: return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    }

    func startCountdown(_ c: PopupCard, _ req: Paster.Request, kicker: String, itemID: UUID) {
        let appName = name(of: req.target)
        let where_ = req.windowMatch.map { " · “\($0)”" } ?? ""
        let sends = req.send && settings.allowsEnter(in: bundle(of: req.target))
        c.phase = .countdown
        c.remaining = 1
        c.headline = nil
        c.caution = false
        c.showsSettingsButton = false
        c.canRetry = false
        c.status = kicker + (sends ? "Sending to \(appName)" : "Pasting into \(appName)") + where_
        if req.send && !sends {
            c.note = "Return won't be pressed — \(appName) isn't on your Return list."
        } else if sends {
            let spec = TargetCatalog.spec(for: bundle(of: req.target))
            let key = req.sendKey == .commandReturn ? "⌘ Return" : "Return"
            c.note = spec?.composer == .chatInput ? "Pastes into the message box, then sends it." : "Pastes, then presses \(key)."
        } else {
            c.note = nil
        }
        var fired = false
        c.onFire = { [weak self, weak c] in
            guard let self, let c, !fired, c.phase == .countdown else { return }
            fired = true
            self.fire(c, req, kicker: kicker, itemID: itemID)
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

    private func fire(_ c: PopupCard, _ req: Paster.Request, kicker: String, itemID: UUID) {
        c.phase = .working
        c.status = kicker + (req.windowMatch != nil ? "Finding “\(req.windowMatch!)”" : "Pasting")
        popup.refresh(c)
        let previous = pasteChain
        pasteChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let r = try await Paster.deliver(req, allowsEnter: { self.settings.allowsEnter(in: $0) })
                c.phase = .done
                let outcome: String
                if r.pressedEnter && r.sendDidNotClear {
                    c.status = kicker + "Pasted into \(r.appName)"
                    c.caution = true
                    c.note = "Pressed \(req.sendKey.title), but it's still in the message box — \(r.appName) may still be answering. Press \(req.sendKey.title) when it's ready."
                    outcome = "Pasted into \(r.appName) — still in the message box after \(req.sendKey.title)"
                } else if r.pressedEnter {
                    c.status = kicker + "Sent to \(r.appName)"
                    c.note = nil
                    outcome = "Sent to \(r.appName)"
                } else {
                    c.status = kicker + "Pasted into \(r.appName)"
                    c.caution = req.send
                    c.note = r.enterNote
                    outcome = "Pasted into \(r.appName)" + (r.enterNote.map { " — \($0.prefix(1).lowercased() + $0.dropFirst())" } ?? "")
                }
                self.popup.refresh(c)
                self.app.updateOutcome(itemID, .pasted, outcome)
                self.log.add("delivered: \(r.pressedEnter ? (r.confirmed ? "sent, confirmed" : (r.sendDidNotClear ? "send key pressed, box not cleared" : "sent")) : "pasted")\(r.enterNote != nil ? " (not sent)" : "")")
            } catch let f as PasteFailure {
                Paster.copy(req.text)
                self.fail(c, f, retry: { [weak self] in self?.startCountdown(c, req, kicker: kicker, itemID: itemID) })
                self.popup.refresh(c)
                self.app.updateOutcome(itemID, .failed, f.title)
                self.notifyIfAway(title: f.title, body: req.text, id: itemID)
                self.log.add("paste failed: \(String(describing: f).prefix(40))")
            } catch {
                c.phase = .cancelled
                self.popup.refresh(c)
            }
        }
    }

    private func fail(_ c: PopupCard, _ f: PasteFailure, retry: @escaping () -> Void) {
        c.phase = .failed
        c.caution = false
        c.status = f == .accessibilityMissing ? "Copied, not pasted" : "Not pasted"
        if case .notLanded = f { c.status = "Not sent" }
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
            retry()
            self.popup.refresh(c)
        }
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
                    c.note = "It's on your clipboard. Pick a pane that's open in the profile, or try again."
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
                case "Webhook": c.note = "The text didn't reach the URL in this profile."
                case "Script": c.note = "Check the command in the profile."
                default: c.note = settingsURL != nil ? "Allow it in System Settings, then try again." : "Check the action in the profile."
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

    private func notifyIfAway(title: String, body: String, id: UUID) {
        guard settings.deliveryMode == .clipboardNotify || settings.deliveryMode == .autoPaste else { return }
        Notifier.shared.requestIfNeeded()
        if Notifier.personIsAway { Notifier.shared.post(title: title, body: body, id: id.uuidString) }
    }
}

extension Profile {
    var hasActions: Bool {
        !(actions ?? []).isEmpty || webhookURL != nil || !(script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
