import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MacrophoneKit

/// Type as I speak (Nov 10 2026, MacrophoneKit `Core/LiveTyping.swift` has the rules): the phone's
/// settled words typed into the dictation's place while he talks, then put right when the final
/// (cleaned) dictation arrives, and only then the send key.
///
/// One dictation at a time per id, everything on one chain (pieces, a cancel, the end), in the
/// pieces' own order. The Mac counts exactly what it typed for each dictation and never takes back
/// more — or anything at all once the place stopped being the one it typed into
/// (`LiveFocusRule`): then it stops typing and the end goes the usual way.
@MainActor
final class LiveTyper {
    private unowned let app: AppModel
    private unowned let engine: DeliveryEngine

    init(app: AppModel, engine: DeliveryEngine) {
        self.app = app
        self.engine = engine
    }

    private var log: DiagnosticLog { app.log }

    enum State: Equatable {
        case typing
        /// It typed, then something else took the place (the reason, for the log).
        case stopped(String)
        /// It never started (someone at the Mac, a password field, nowhere to type…).
        case refused(String)
    }

    final class Session {
        let id: UUID
        let target: TargetRef
        var state: State = .typing
        var started = Date()
        var last = Date()
        var nextSeq = 1
        var waiting: [Int: LivePiece] = [:]
        /// Exactly what this Mac typed for the dictation and hasn't taken back.
        var typed = ""
        var counts = LiveCounts()
        var place: Paster.Located?
        var anchorPID: pid_t = 0
        var anchorWindow: CGWindowID?
        var anchorField: AXUIElement?
        var ownKeyAt: Date?
        var begun = false
        var done = false
        init(id: UUID, target: TargetRef) { self.id = id; self.target = target }
    }

    private var sessions: [UUID: Session] = [:]
    /// Dictations whose end has arrived (or was cancelled): a piece still on its way is dropped.
    private var closed: [UUID: Date] = [:]
    private var chain: Task<Void, Never>?

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    // MARK: Pieces

    func piece(_ p: LivePiece, from peer: UUID) {
        forgetOld()
        guard closed[p.id] == nil || p.isCancel else { return }
        let s = sessions[p.id] ?? {
            let n = Session(id: p.id, target: p.target)
            sessions[p.id] = n
            return n
        }()
        s.last = Date()
        s.waiting[p.seq] = p
        enqueue { [weak self] in await self?.drain(s) }
    }

    private func drain(_ s: Session) async {
        while let p = s.waiting.removeValue(forKey: s.nextSeq) {
            s.nextSeq += 1
            await apply(p, to: s)
        }
    }

    private func apply(_ p: LivePiece, to s: Session) async {
        if p.isCancel {
            closed[s.id] = Date()
            await takeBack(s)
            s.done = true
            return
        }
        guard !s.done else { return }
        if !s.begun {
            s.begun = true
            await start(s)
        } else if s.state == .typing, let stop = LiveFocusRule.check(look(s)) {
            s.state = .stopped(stop.rawValue)
            log.add("live: stopped typing — \(stop.rawValue) (\(s.counts.line))")
        }
        guard s.state == .typing else { return }
        let delete = min(p.delete, s.typed.count)
        // Never a Return or a Tab typed live (a chat would send half a sentence).
        let text = p.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard delete > 0 || !text.isEmpty else { return }
        await LiveKeys.run { LiveKeys.backspace(delete); LiveKeys.type(text) }
        s.ownKeyAt = Date()
        s.typed = String(s.typed.dropLast(delete)) + text
        s.counts.pieces += 1
        s.counts.typed += text.count
        s.counts.deleted += delete
    }

    /// The first piece: the place brought forward and its place to type focused (the paste's own
    /// steps 1–3), and what it looks like now remembered — or nothing typed at all.
    private func start(_ s: Session) async {
        func refuse(_ why: String) {
            s.state = .refused(why)
            log.add("live: not typing — \(why)")
        }
        guard case let .paste(target, _, _) = engine.route(s.target, send: false) else { return refuse("the clipboard") }
        if StayAwake.isLocked { return refuse("the Mac is locked") }
        if !Paster.isTrusted { return refuse("Accessibility is off") }
        // Someone at the Mac: their typing and ours would mix (the usual paste waits a moment for them).
        if DeliveryEngine.someoneAtMac { return refuse("someone is using the Mac") }
        if Paster.precheck(target) != nil { return refuse("the place isn't open") }
        do {
            let place = try await Paster.locate(target, scanner: app.scanner)
            s.place = place
            s.anchorPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? place.running.processIdentifier
            s.anchorWindow = AX.element(place.ax, kAXFocusedWindowAttribute).flatMap(AX.windowID)
            s.anchorField = place.terminal ? nil : AX.focused(in: place.ax)
            s.started = Date()
            if s.anchorPID != place.running.processIdentifier { return refuse("another app is in front") }
            log.add("live: typing into \(place.terminal ? "a terminal" : (place.box == nil ? "an app" : "its text box"))")
        } catch let f as PasteFailure {
            refuse(String(describing: f).components(separatedBy: "(").first ?? "it can't paste there")
        } catch {
            refuse("it can't paste there")
        }
    }

    /// What the Mac sees now against what it saw at the first piece.
    private func look(_ s: Session) -> LiveFocusRule.Look {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var sameWindow: Bool?
        var sameField: Bool?
        if let place = s.place {
            if let anchor = s.anchorWindow {
                sameWindow = AX.element(place.ax, kAXFocusedWindowAttribute).flatMap(AX.windowID).map { $0 == anchor } ?? false
            }
            if let anchor = s.anchorField {
                // A field that can't be read now counts as another one: never type blind.
                sameField = AX.focused(in: place.ax).map { CFEqual($0, anchor) } ?? false
            }
        }
        let mouse = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        return LiveFocusRule.Look(
            sameApp: front == s.anchorPID,
            sameWindow: sameWindow, sameField: sameField,
            secure: SecureInput.isActive(frontPID: front) || SecureInput.focusedElementIsSecure(),
            locked: StayAwake.isLocked,
            sinceMouseDown: mouse,
            sinceKeyDown: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown),
            sinceOwnKey: s.ownKeyAt.map { Date().timeIntervalSince($0) } ?? .infinity,
            sinceStart: Date().timeIntervalSince(s.started))
    }

    /// The field the cursor is in, read (nil for a terminal or a field that can't be read).
    private func field(_ place: Paster.Located) -> (AXUIElement, LiveReconcile.Field)? {
        guard !place.terminal, let box = AX.focused(in: place.ax), let value = AX.value(box),
              let raw = AX.attr(box, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return (box, LiveReconcile.Field(value: value, caret: range.location, selection: range.length))
    }

    /// Selects this range of the field and checks it took.
    private func select(_ box: AXUIElement, location: Int, length: Int) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let v = AXValueCreate(.cfRange, &range), AX.set(box, kAXSelectedTextRangeAttribute, v),
              let back = AX.attr(box, kAXSelectedTextRangeAttribute), CFGetTypeID(back) == AXValueGetTypeID() else { return false }
        var got = CFRange()
        return AXValueGetValue(back as! AXValue, .cfRange, &got) && got.location == location && got.length == length
    }

    // MARK: Cancel

    /// The phone threw the dictation away: exactly what was typed comes out — if the place is
    /// still the one it typed into. Otherwise it's left (said in the log).
    private func takeBack(_ s: Session) async {
        guard !s.typed.isEmpty, let place = s.place else {
            log.add("live: cancelled, nothing was typed")
            return
        }
        let untouched = s.state == .typing && LiveFocusRule.check(look(s)) == nil
        guard untouched else {
            log.add("live: cancelled — \(s.typed.count) characters left where they were (the place changed)")
            return
        }
        let read = field(place)
        let plan = LiveReconcile.plan(typed: s.typed, final: "", field: read?.1, untouched: true)
        switch plan {
        case let .replace(location, length, _):
            if let box = read?.0, select(box, location: location, length: length) {
                await LiveKeys.run { LiveKeys.backspace(1) }
            } else {
                log.add("live: cancelled — couldn't select what was typed, \(s.typed.count) characters left")
                return
            }
        case let .backspace(delete, _):
            await LiveKeys.run { LiveKeys.backspace(delete) }
        case .nothing, .deliverNormally:
            log.add("live: cancelled — what was typed isn't where it was left, \(s.typed.count) characters left")
            return
        }
        log.add("live: cancelled, took back \(s.typed.count) characters (\(s.counts.line))")
        s.typed = ""
    }

    // MARK: The end

    /// The dictation ended without being typed live here (the clipboard, the app gone): a piece
    /// still on its way is dropped.
    func close(_ id: UUID) {
        closed[id] = Date()
        sessions[id] = nil
    }

    /// The dictation that ends a live one. Waits for pieces still on their way, then puts what was
    /// typed right; anything it can't do safely goes the usual way (`deliverNow`).
    func finish(_ d: Dictation, pieces: Int, route: DeliveryEngine.Route, delayed: Bool, source: String) {
        closed[d.id] = Date()
        enqueue { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(LiveTyping.piecesWait)
            while Date() < deadline {
                if let s = self.sessions[d.id], s.nextSeq > pieces { break }
                if pieces == 0 { break }
                try? await Task.sleep(nanoseconds: 40_000_000)
                if let s = self.sessions[d.id] { await self.drain(s) }
            }
            await self.end(d, route: route, delayed: delayed, source: source)
        }
    }

    private func end(_ d: Dictation, route: DeliveryEngine.Route, delayed: Bool, source: String) async {
        let s = sessions.removeValue(forKey: d.id)
        s?.done = true
        guard let s, !s.typed.isEmpty, case let .paste(target, send, _) = route else {
            log.add("live: nothing typed\(s.map { if case let .refused(w) = $0.state { return " (\(w))" } else { return "" } } ?? "") — the usual paste")
            engine.deliverNow(d.text, id: d.id, route: route, delayed: delayed, source: source, early: nil)
            return
        }
        let untouched = s.state == .typing && LiveFocusRule.check(look(s)) == nil
        let card = PopupCard(text: d.text, source: source, delayed: delayed, phase: .working, status: "Finishing")
        app.popup.show(card)
        guard !StayAwake.isLocked, Paster.isTrusted else {
            log.add("live: the end can't touch the Mac (\(s.counts.line)) — the usual way")
            engine.deliverNow(d.text, id: d.id, route: route, delayed: delayed, source: source, early: nil)
            return
        }
        let place: Paster.Located
        do {
            // Usually already in front; if something else came forward it's brought back (the same
            // place it typed into — never typed blind into whatever's there now).
            place = try await Paster.locate(target, scanner: app.scanner)
        } catch {
            log.add("live: the place is gone at the end (\(s.counts.line)) — the usual way")
            engine.deliverNow(d.text, id: d.id, route: route, delayed: delayed, source: source, early: nil)
            return
        }
        let read = field(place)
        var plan = LiveReconcile.plan(typed: s.typed, final: d.text, field: read?.1, untouched: untouched)
        var how: String
        switch plan {
        case .nothing:
            how = "nothing to correct"
        case let .replace(location, length, text):
            if let box = read?.0, select(box, location: location, length: length) {
                if text.isEmpty { await LiveKeys.run { LiveKeys.backspace(1) } } else { await Paster.pasteText(text) }
                how = "\(length) characters replaced"
            } else if untouched {
                // The field wouldn't take the selection: Delete, inside what was typed.
                let step = TypingDiff.diff(old: s.typed, new: d.text)
                await LiveKeys.run { LiveKeys.backspace(step.delete) }
                if !step.text.isEmpty { await Paster.pasteText(step.text) }
                how = "\(step.delete) taken back with Delete (the field wouldn't select)"
                plan = .backspace(delete: step.delete, text: step.text)
            } else {
                plan = .deliverNormally
                how = ""
            }
        case let .backspace(delete, text):
            await LiveKeys.run { LiveKeys.backspace(delete) }
            if !text.isEmpty { await Paster.pasteText(text) }
            how = "\(delete) taken back with Delete"
        case .deliverNormally:
            how = ""
        }
        if plan == .deliverNormally {
            log.add("live: \(s.counts.line); what was typed couldn't be found safely\(Self.why(s.state)) — left, the final words pasted the usual way")
            engine.deliverNow(d.text, id: d.id, route: route, delayed: delayed, source: source, early: nil)
            return
        }
        // The app takes the paste before the send key (as the usual paste waits for it).
        try? await Task.sleep(nanoseconds: AppQuirks.pasteSettle(place.bundleID) * 1_000_000)
        LandingGlow.show(app: place.ax, box: place.box)
        let sending = send && !delayed
        if sending { Paster.pressSend(for: place.bundleID) }
        let outcome = sending ? "Sent to \(place.appName)" : "Pasted into \(place.appName)"
        card.phase = .done
        card.status = outcome
        app.popup.refresh(card)
        app.updateOutcome(d.id, .pasted, outcome)
        app.statusItemCue(.landed(d.id))
        // Many keystrokes, one ⌘Z can't take them back: no Undo for a dictation typed live.
        engine.forgetLastPaste()
        if sending, let wid = (place.window ?? AX.element(place.ax, kAXFocusedWindowAttribute)).flatMap(AX.windowID) {
            app.replies.engaged(windowID: wid, bundleID: place.bundleID)
        }
        log.add("live: \(s.counts.line); at the end \(how)\(Self.why(s.state))\(sending ? ", sent" : "")")
    }

    private static func why(_ s: State) -> String {
        if case let .stopped(w) = s { return " (stopped: \(w))" }
        return ""
    }

    private func forgetOld() {
        let now = Date()
        for (id, s) in sessions where now.timeIntervalSince(s.last) > LiveTyping.sessionLife {
            sessions[id] = nil
            if !s.typed.isEmpty { log.add("live: no end arrived — \(s.typed.count) characters left as typed") }
        }
        closed = closed.filter { now.timeIntervalSince($0.value) < LiveTyping.sessionLife }
    }
}

/// The keystrokes typing live posts, off the main thread: Delete, and text as unicode events a few
/// characters at a time (TypingPlan) — a Return or Tab in it typed as a space.
enum LiveKeys {
    static func run(_ work: @escaping @Sendable () -> Void) async {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    static func backspace(_ n: Int) {
        guard n > 0 else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<n {
            let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
            down?.flags = []
            up?.flags = []
            down?.post(tap: .cghidEventTap)
            usleep(1_500)
            up?.post(tap: .cghidEventTap)
            usleep(1_500)
        }
    }

    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for step in TypingPlan.steps(for: text) {
            let piece: String
            switch step {
            case .text(let t): piece = t
            case .key: piece = " "
            }
            let units = Array(piece.utf16)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down?.flags = []
            up?.flags = []
            down?.post(tap: .cghidEventTap)
            usleep(2_000)
            up?.post(tap: .cghidEventTap)
            usleep(3_000)
        }
    }
}
