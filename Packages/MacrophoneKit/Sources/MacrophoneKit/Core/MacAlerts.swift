import Foundation

/// Alerts from the Mac (Nov 6 2026). Sameer: "have the app watch any window and alert me with a
/// notification and an image of the window for any significant state change", then "you should
/// have agent alerts work through this new way now. So it's all consistent and uniform".
///
/// Any window can be put on watch from the phone (or the Mac's menu); the Mac looks at it every
/// few seconds and, on a change of state — it was busy and went still, something new appeared and
/// settled, a dialog or a question came up, it closed — tells the phone, with a picture of the
/// window as it is. An agent asking (AgentHub, the lookout) is the same alert. While the app is
/// closed it goes through the person's own iCloud (CloudAlerts on the Mac, the phone's
/// notification extension), the picture deleted as soon as the phone has it.
public enum MacAlerts {
    /// Named in hello / welcome: a phone that names it gets `.macAlert` (an older one keeps
    /// getting `.attention` for a question); a Mac that names it takes `.alertWatch`.
    public static let feature = "macAlerts"
    /// The phone has its notification extension (it can show a picture that came through iCloud):
    /// only then does the Mac put the picture in the iCloud record.
    public static let cloudPictureFeature = "macAlerts-cloudPicture"
    /// Windows on watch at once, at most (each is looked at every few seconds).
    public static let maxWatches = 8
    /// A watch nothing happened in for this long turns itself off.
    public static let quietExpiry: TimeInterval = 12 * 3600
    /// The picture: its long side and its size at most (it rides an iCloud record's field).
    public static let pictureSide: CGFloat = 1100
    public static let pictureBytes = 150_000
}

/// Mac → phone: something happened in a window.
public struct MacAlert: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The window, to watch it from the notification.
    public var ref: TargetRef
    /// "Terminal", "Final Cut Pro".
    public var appName: String
    /// The window's title ("npm run build — ~/web"); the app's name when it has none.
    public var title: String
    /// What happened, as `Kind`'s raw value (a string, so a newer kind never breaks an older phone).
    public var kind: String
    /// The notification's title: "Build finished", "Claude Code is asking you something".
    public var headline: String
    /// A line under it: the question, the last thing the window said. Nil when there's nothing.
    public var detail: String?
    /// A question's id (the window's answers on the phone match it).
    public var promptID: String?
    public var at: Date
    /// The window as it looked, a JPEG (nil: no picture — closed, or Screen Recording off).
    public var jpeg: Data?
    /// From a chat the phone wrote to, not a window on watch (ChatAnswers, Nov 8 2026): the phone
    /// lets it through by its "When a chat answers you" switch. Nil from a Mac from before, and
    /// an older phone ignores it.
    public var chat: Bool?
    /// A question's answers as the window words them, in order ("Yes", "Yes, and don't ask
    /// again", "No…") — the notification's buttons (Nov 9 2026). Nil: none read, or a Mac from before.
    public var answers: [String]?

    public enum Kind: String, Sendable, CaseIterable {
        /// It was busy a while and went still.
        case finished
        /// Something new appeared and settled (a reply, a line of output).
        case updated
        /// A question (an agent, a prompt in a terminal).
        case asking
        /// A chat you wrote to from the phone answered (ReplyWatcher's word, Nov 7 2026; a phone
        /// from before reads it as `updated`).
        case answered
        /// A dialog or a sheet came up over it.
        case dialog
        /// It closed (the watch ends).
        case closed
        /// It keeps changing: from now on only when it stops.
        case calmed
    }

    public var knownKind: Kind { Kind(rawValue: kind) ?? .updated }

    public init(id: UUID = UUID(), ref: TargetRef, appName: String, title: String, kind: Kind, headline: String,
                detail: String? = nil, promptID: String? = nil, at: Date = Date(), jpeg: Data? = nil, chat: Bool? = nil) {
        self.id = id
        self.ref = ref
        self.appName = appName
        self.title = title
        self.kind = kind.rawValue
        self.headline = headline
        self.detail = detail
        self.promptID = promptID
        self.at = at
        self.jpeg = jpeg
        self.chat = chat
    }

    /// One notification per window: a newer alert replaces the older one on the Lock Screen.
    public var notificationID: String { "alert-" + MacAlert.windowKey(ref) }

    /// A short stable name for a window (FNV-1a of its ref).
    public static func windowKey(_ ref: TargetRef) -> String {
        let data = (try? JSONEncoder.sorted.encode(ref)) ?? Data()
        var h: UInt64 = 1469598103934665603
        for b in data { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }

    /// For a phone from before (it understands `.attention` only): a question, the same way.
    public var attention: Attention? {
        guard knownKind == .asking else { return nil }
        return Attention(ref: ref, appName: appName, title: title, question: detail, promptID: promptID ?? id.uuidString)
    }
}

extension TargetRef {
    /// The window of a place (nil: the app's front window, or not an app).
    public var windowKey: String? {
        if case let .app(_, key, _) = self { return key }
        return nil
    }
}

extension JSONEncoder {
    static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
}

/// A window on watch, as the phone lists it (Mac → phone, the whole list on each change).
public struct AlertWatch: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var ref: TargetRef
    public var bundleID: String
    /// The window (a CGWindowID as text); nil for the app's front window.
    public var windowKey: String?
    public var appName: String
    public var title: String
    public var since: Date
    /// It kept changing: it alerts only when it stops now.
    public var calm: Bool

    public var id: String { MacAlert.windowKey(ref) }

    public init(ref: TargetRef, bundleID: String, windowKey: String?, appName: String, title: String, since: Date, calm: Bool = false) {
        self.ref = ref
        self.bundleID = bundleID
        self.windowKey = windowKey
        self.appName = appName
        self.title = title
        self.since = since
        self.calm = calm
    }

    /// Whether this is about that place (its window, or the app's front window).
    public func concerns(_ t: LiveTarget) -> Bool {
        t.bundleID == bundleID && (windowKey == nil || t.windowKey == nil || t.windowKey == windowKey)
    }
}

/// Phone → Mac: put a window on watch, or take it off.
public struct AlertWatchRequest: Codable, Sendable, Equatable {
    public var ref: TargetRef
    public var on: Bool

    public init(ref: TargetRef, on: Bool) {
        self.ref = ref
        self.on = on
    }
}

/// Did the window change state? The rule the Mac applies to each window on watch, look by look
/// (pure, so the tests can walk it).
///
/// A window is **busy** while its picture keeps changing by more than a caret, or while it says
/// it's working (a Stop button, "esc to interrupt"); it **settles** once it has been still for a
/// while — a tenth of how long it was busy, between 8 and 30 seconds, so a long export isn't
/// called done in a pause and a quick reply isn't kept waiting. A short settle is an alert only
/// when the window ended up meaningfully different from where it started (a spinner that came and
/// went isn't news); a long run (20 s or more) always is, even ending as it began (a rerun). A
/// dialog coming up is an alert at once.
///
/// It never floods: past three alerts in ten minutes the window is **calm** — from then on only a
/// stillness of two minutes counts ("tell me when it stops"), until half an hour passes with no
/// alert.
///
/// **Animations aren't activity (Nov 7 2026).** Sameer put the Claude app's window on watch, its
/// reply came, and no alert ever did: measured on that window at rest, 0.01–0.11% of the picture
/// changed between every two looks — a spinner, the composer's caret, a live preview pane — which
/// straddles `activity`, so the window read as busy for most of every minute and was never still
/// for the eight seconds a settle needs (`ReplyWatcher`, whose still threshold is 0.6%, marked
/// the same reply answered). Now each sample carries a **heat**: up by two when it changed since
/// the last look, down by one when it didn't. A sample at `animated` heat or more has been
/// changing look after look — an animation — and its changes don't count as activity, as long as
/// the animated samples together are a small part of the picture (`liveArea`): a column of text
/// scrolling as a reply streams in is far larger, and that is activity until it stops. At a settle
/// the comparison with the picture from before leaves out what is still animating right now
/// (`heatCap` − 1 or more: changing on nearly every look), so a spinner turning in both pictures
/// never makes a settle news — a reply that stopped three looks ago has cooled below that and
/// counts whole.
public struct WindowChangeDetector: Sendable {
    public enum Event: Equatable, Sendable {
        /// It settled after `ran` seconds of change; `changed` is the share of the picture that
        /// differs from before.
        case settled(ran: TimeInterval, changed: Double)
        /// A dialog or a sheet came up.
        case dialog
    }

    /// A change this big between two looks is activity (a caret blinking is less).
    public static let activity = 0.0003
    /// A settle counts when this much of the picture differs from before the activity.
    public static let meaningful = 0.002
    public static let settleMin: TimeInterval = 8
    public static let settleMax: TimeInterval = 30
    /// Busy at least this long: "finished" rather than "something new".
    public static let longRun: TimeInterval = 20
    /// Calm: more than `burst` alerts within `burstWindow`.
    public static let burst = 3
    public static let burstWindow: TimeInterval = 600
    public static let calmSettle: TimeInterval = 120
    public static let calmLasts: TimeInterval = 1800
    /// A sample this hot has changed on look after look: an animation, not activity.
    public static let animated: UInt8 = 3
    public static let heatCap: UInt8 = 6
    /// Animated samples are left out of the activity only while they're this small a share of
    /// the picture together: a spinner, a caret, a clock, a small live preview — not a column of
    /// text scrolling as a reply streams in.
    public static let liveArea = 0.02
    /// Told of by another path (a chat answered): the next settle within this long isn't news.
    public static let toldFor: TimeInterval = 30

    public private(set) var last: [UInt32]?
    /// The picture before the current activity (or when last settled).
    public private(set) var reference: [UInt32]?
    /// Per sample: how lately it has kept changing (see above).
    public private(set) var heat: [UInt8] = []
    public private(set) var busySince: Date?
    public private(set) var lastChange: Date?
    public private(set) var dialogUp = false
    public private(set) var alerts: [Date] = []
    public private(set) var calm = false
    /// It just became calm (the alert that made it so says so); read and cleared by the caller.
    public var becameCalm = false
    /// The last time anything happened (activity or an alert), for the watch's expiry.
    public private(set) var lastEvent: Date
    /// What the last look saw, for the log: the activity share, the share of the picture that's
    /// animating, and — at a settle — the change against the picture from before.
    public private(set) var lastShare = 0.0
    public private(set) var animatedShare = 0.0
    public private(set) var lastSettle: (ran: TimeInterval, changed: Double)?

    public init(at now: Date = Date()) { lastEvent = now }

    public var isBusy: Bool { busySince != nil }

    /// One look: `sample` is the picture (WatchChange.sample), `working` the window says it's at
    /// it, `dialog` something's laid over it.
    public mutating func look(_ sample: [UInt32], working: Bool = false, dialog: Bool = false, at now: Date) -> Event? {
        guard let prev = last, prev.count == sample.count, !sample.isEmpty else {
            last = sample
            reference = sample
            heat = [UInt8](repeating: 0, count: sample.count)
            dialogUp = dialog
            return nil
        }
        let share = measure(prev, sample)
        last = sample
        lastSettle = nil
        if calm, let newest = alerts.last, now.timeIntervalSince(newest) > Self.calmLasts { calm = false }

        if dialog, !dialogUp {
            dialogUp = true
            busySince = nil
            reference = sample
            return admit(.dialog, at: now)
        }
        if !dialog { dialogUp = false }

        if share >= Self.activity || working {
            if busySince == nil { busySince = now }
            lastChange = now
            lastEvent = now
            return nil
        }
        guard let start = busySince, let changed = lastChange else { return nil }
        let ran = changed.timeIntervalSince(start)
        let settle = calm ? Self.calmSettle : min(Self.settleMax, max(Self.settleMin, ran * 0.1))
        guard now.timeIntervalSince(changed) >= settle else { return nil }
        busySince = nil
        let total = reference.map { settled(from: $0, to: sample) } ?? 1
        reference = sample
        lastSettle = (ran, total)
        // A blip that left the window as it was (a spinner came and went) isn't news — but a long
        // run is, even when it ends looking the same (a build or tests run again). Nor is a change
        // another path already told of (the chat answered, and said so).
        guard total >= Self.meaningful || ran >= Self.longRun else { return nil }
        if let told = toldAt, now.timeIntervalSince(told) < Self.toldFor { return nil }
        return admit(.settled(ran: ran, changed: total), at: now)
    }

    /// The share of the picture that changed since the last look, animations left out while
    /// they're small; the heat of every sample moves on.
    private mutating func measure(_ prev: [UInt32], _ sample: [UInt32]) -> Double {
        let n = sample.count
        if heat.count != n { heat = [UInt8](repeating: 0, count: n) }
        var changed = 0, active = 0, hot = 0
        heat.withUnsafeMutableBufferPointer { h in
            for i in 0..<n {
                let c = WatchChange.differs(prev[i], sample[i])
                let was = h[i]
                if was >= Self.animated { hot += 1 }
                if c {
                    changed += 1
                    if was < Self.animated { active += 1 }
                    h[i] = was >= Self.heatCap - 1 ? Self.heatCap : was + 2
                } else if was > 0 {
                    h[i] = was - 1
                }
            }
        }
        animatedShare = Double(hot) / Double(n)
        lastShare = Double(animatedShare < Self.liveArea ? active : changed) / Double(n)
        return lastShare
    }

    /// The change from the picture before the activity, leaving out what's still animating now.
    private func settled(from reference: [UInt32], to sample: [UInt32]) -> Double {
        guard reference.count == sample.count, !sample.isEmpty else { return 1 }
        var n = 0
        for i in 0..<sample.count where heat[i] < Self.heatCap - 1 && WatchChange.differs(reference[i], sample[i]) { n += 1 }
        return Double(n) / Double(sample.count)
    }

    /// He looked at it (on the phone): what's there now is seen.
    public mutating func seen() {
        reference = last
        busySince = nil
        lastChange = nil
    }

    private var toldAt: Date?

    /// Another path told him what this window did just now (its chat answered, its agent
    /// finished): what's there is as good as seen, and it counts as an alert for calm's sake.
    public mutating func told(at now: Date) {
        seen()
        toldAt = now
        _ = admit(.settled(ran: 0, changed: 0), at: now)
    }

    /// An alert went out this recently (by any path).
    public func alerted(within seconds: TimeInterval, at now: Date) -> Bool {
        alerts.last.map { now.timeIntervalSince($0) < seconds } ?? false
    }

    private mutating func admit(_ e: Event, at now: Date) -> Event {
        alerts = alerts.filter { now.timeIntervalSince($0) < Self.burstWindow } + [now]
        lastEvent = now
        if !calm, alerts.count > Self.burst {
            calm = true
            becameCalm = true
        }
        return e
    }
}

/// The words of an alert when no model writes them: from what happened and the window's new text.
public enum AlertWords {
    /// "Finished", "Something new", by kind — with the app's name.
    public static func headline(_ kind: MacAlert.Kind, app: String, newLines: [String]) -> String {
        let text = newLines.joined(separator: " ").lowercased()
        switch kind {
        case .finished, .updated:
            // The window's own words when a line says how it went, short enough to be a headline:
            // "Upload complete: report.pdf" → "Upload complete".
            if let line = newLines.last(where: { failed($0.lowercased()) || succeeded($0.lowercased()) }) {
                let head = line.components(separatedBy: CharacterSet(charactersIn: ":(—–")).first?.trimmingCharacters(in: .whitespaces) ?? ""
                // It says how it went and what did ("Build failed", "Upload complete" — not "Done in
                // 4.2s", not a file's path).
                let words = head.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 }
                let status = words.filter { w in statusWords.contains { w.hasPrefix($0) } }
                if !status.isEmpty, words.count > status.count, words.count <= 5, head.count <= 40 { return head }
            }
            if failed(text) { return "\(app): something went wrong" }
            if kind == .finished { return "\(app) finished" }
            return "\(app) has something new"
        case .asking: return "\(app) is asking you something"
        case .answered: return "\(app) answered you"
        case .dialog: return "\(app) is showing a dialog"
        case .closed: return "\(app) window closed"
        case .calmed: return "\(app) keeps changing"
        }
    }

    /// Words a headline may use that the window needn't show (how things went, what came).
    public static let statusWords: Set<String> = [
        "finish", "fail", "complete", "done", "ready", "pass", "succe", "error", "warning", "reply", "replie", "message",
        "asking", "question", "dialog", "open", "close", "stop", "start", "update", "with", "from", "save", "sent", "send",
        "something", "needs", "your", "answer", "waiting", "running",
    ]

    static func failed(_ text: String) -> Bool {
        ["error", "failed", "failure", "exception", "fatal", "denied", "crashed", "couldn’t", "couldn't", "cannot", "can't"].contains { text.contains($0) }
    }

    /// The lines in `now` that weren't in `before` (read top to bottom), the newest last. Loosely:
    /// text recognition reads the same line a little differently from one picture to the next
    /// ("compiling module 20 of 22" once, "…(80 files)" the next), so a line counts as seen when it
    /// matches one before letter for letter, ignoring case and signs, or one holds the other whole.
    public static func newLines(before: [String], now: [String]) -> [String] {
        let old = before.map(squash).filter { !$0.isEmpty }
        var seen = Dictionary(old.map { ($0, 1) }, uniquingKeysWith: +)
        var out: [String] = []
        for l in now {
            let k = squash(l)
            if let n = seen[k], n > 0 { seen[k] = n - 1; continue }
            if k.count >= 8, old.contains(where: { $0.count >= 8 && ($0.hasPrefix(k) || k.hasPrefix($0)) }) { continue }
            // A few letters read differently ("fi1es", "l error"): the same line.
            if k.count >= 6, old.contains(where: { near($0, k) }) { continue }
            out.append(l)
        }
        return out.filter { $0.count >= 3 && $0.contains(where: \.isLetter) }
    }

    /// Within a tenth of their length of each other, letter for letter (edit distance).
    static func near(_ a: String, _ b: String) -> Bool {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        let limit = max(1, max(x.count, y.count) / 10)
        guard abs(x.count - y.count) <= limit else { return false }
        var row = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var prev = row[0]
            row[0] = i
            var best = row[0]
            for j in stride(from: 1, through: y.count, by: 1) {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = cur
                best = min(best, row[j])
            }
            if best > limit { return false }
        }
        return row[y.count] <= limit
    }

    static func squash(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The notification's body when the alert has no line of its own.
    public static func body(_ kind: MacAlert.Kind) -> String {
        switch kind {
        case .asking: return "Tap to see it and answer."
        case .answered: return "Tap to read it."
        case .closed: return "It's off watch now."
        case .calmed: return "You'll hear when it stops changing."
        case .dialog: return "Tap to see it and answer."
        case .finished, .updated: return "Tap to see it live."
        }
    }

    /// The line to show under the headline: the last one that says how it went (a failure first,
    /// then a success), else the last new line — never a shell's prompt.
    public static func detail(_ newLines: [String]) -> String? {
        let lines = newLines.filter { !isPrompt($0) }
        let pick = lines.last(where: { failed($0.lowercased()) }).map { line in
            // "Build failed with 1 error" says it better than the error itself when both are there.
            lines.last(where: { l in summary(l.lowercased()) && failed(l.lowercased()) }) ?? line
        } ?? lines.last(where: { succeeded($0.lowercased()) }) ?? lines.last
        return pick.map { String($0.prefix(140)) }
    }

    /// The line under "Claude answered you" (Nov 8 2026): the reply's last lines as they read —
    /// text recognition gives a chat's wrapped lines one by one, so the last two or three together
    /// make the end of a sentence where one alone is a fragment. At most `limit` characters, cut at
    /// a word; never a shell's prompt. Nil when nothing new was read.
    public static func reply(_ newLines: [String], limit: Int = 160) -> String? {
        let lines = newLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !isPrompt($0) }
        guard let last = lines.last else { return nil }
        var picked = [last]
        for l in lines.dropLast().reversed().prefix(2) {
            guard picked.reduce(l.count, { $0 + $1.count + 1 }) <= limit else { break }
            picked.insert(l, at: 0)
        }
        let text = picked.joined(separator: " ")
        guard text.count > limit else { return text }
        let cut = text.prefix(limit - 1)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    static func succeeded(_ text: String) -> Bool {
        ["done", "finished", "complete", "passed", "success", "succeeded", "built", "✓", "✔", "saved", "exported", "uploaded"].contains { text.contains($0) }
    }

    /// A line that sums a run up ("Build failed with 1 error in 23.4s", "Tests: 3 failed, 41 passed").
    static func summary(_ text: String) -> Bool {
        ["build", "tests", "test suite", "finished", "completed", "in ", "total"].contains { text.contains($0) }
    }

    /// A shell waiting for the next command: "me@Mac ~ %", "~/web $", "❯".
    public static func isPrompt(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return true }
        return ["%", "$", "#", "❯", ">", "›"].contains(String(last)) && (t.count < 3 || t.contains("@") || t.contains("~") || t.contains(" "))
    }
}

/// The answer finds you (Nov 8 2026). Sameer dictates a prompt to a chat from the phone, pockets
/// it, and comes back for the answer: 47 of his last 50 dictations went to the Claude app with
/// send, almost all from away. A chat the phone wrote to (ReplyWatcher's) now alerts when it
/// answers, with no window on watch — "Claude answered you", the reply's last lines, a picture of
/// the window — through the one sender (a connected phone, else iCloud).
public enum ChatAnswers {
    /// Named in the Mac's welcome: it takes `.chatAnswers(on:)` and follows chats for answers.
    /// Named in the phone's hello: it has the "When a chat answers you" switch.
    public static let feature = "chatAnswers"
    /// The phone's hello also says how the switch stands, so a Mac hears it on every connect
    /// (the live message is for a change while connected).
    public static let onWord = "chatAnswers-on"
    public static let offWord = "chatAnswers-off"
    /// A chat is followed this long after the phone last wrote to it.
    public static let followFor: TimeInterval = 2 * 3600
    /// …and for this many answers with no new message from the phone.
    public static let maxAnswers = 2
    /// Two alerts from one chat at least this far apart (an answer that flickers — words, a
    /// pause, more words — isn't told twice).
    public static let quiet: TimeInterval = 30

    /// What a phone's hello says about the switch: on, off, or nothing (a phone from before).
    public static func choice(in features: Set<String>) -> Bool? {
        if features.contains(onWord) { return true }
        if features.contains(offWord) { return false }
        return nil
    }
}

/// Is this answer one to tell? The rule ReplyWatcher applies per chat (pure, for the tests): each
/// new answer (a new `answeredAt`) while the chat is followed — within `followFor` of the phone's
/// last message, fewer than `maxAnswers` told, `quiet` since the last — is told once. The phone
/// writing to it again starts a new follower (re-armed).
public struct AnswerFollower: Equatable, Sendable {
    public let engagedAt: Date
    public private(set) var told = 0
    public private(set) var lastAnswer: Date?
    public private(set) var lastTold: Date?

    public init(engagedAt: Date) { self.engagedAt = engagedAt }

    public func following(at now: Date) -> Bool {
        told < ChatAnswers.maxAnswers && now.timeIntervalSince(engagedAt) < ChatAnswers.followFor
    }

    /// The chat answered (at `answeredAt`): true when this is news to tell now. An answer seen
    /// once is never told again, told or not.
    public mutating func shouldTell(answeredAt: Date, at now: Date) -> Bool {
        guard answeredAt != lastAnswer else { return false }
        lastAnswer = answeredAt
        guard following(at: now) else { return false }
        if let last = lastTold, now.timeIntervalSince(last) < ChatAnswers.quiet { return false }
        told += 1
        lastTold = now
        return true
    }

    /// He looked at the chat on the phone: whatever it said then is seen (not told after).
    public mutating func seen(answeredAt: Date?) {
        if let answeredAt { lastAnswer = answeredAt }
    }
}

/// An alert as an iCloud record (Nov 6 2026): CloudAlerts on the Mac writes it, the phone's
/// notification extension reads it, attaches the picture and deletes it. It rides the record type
/// the agent alerts have always used ("Ask": `line`, `window`, `ref`, `promptID`, all strings) —
/// iCloud's Production schema takes no new types or fields without a deploy in the CloudKit
/// Console — so the rest of the alert (its kind, the line under it, the picture) is a JSON
/// payload in `promptID`, which no phone ever read as anything but text. The push itself shows
/// `line` as the title and `window` under it, so an app without the extension still says what
/// happened.
public enum CloudAlertRecord {
    public static let recordType = "Ask"
    public static let namePrefix = "alert-"

    public struct Payload: Codable, Sendable, Equatable {
        public var v = 1
        public var id: UUID
        public var kind: String
        public var appName: String
        public var detail: String?
        public var promptID: String?
        public var at: Date
        /// The picture (base64 in the JSON).
        public var jpeg: Data?
        public var answers: [String]?
        public var chat: Bool?
    }

    /// The record's name for a window: one per window, overwritten.
    public static func name(_ a: MacAlert) -> String { namePrefix + MacAlert.windowKey(a.ref) }

    /// The fields to write, by name.
    public static func fields(_ a: MacAlert) -> [String: String]? {
        guard let ref = try? JSONEncoder.sorted.encode(a.ref),
              let payload = try? JSONEncoder.sorted.encode(Payload(id: a.id, kind: a.kind, appName: a.appName, detail: a.detail,
                                                                   promptID: a.promptID, at: a.at, jpeg: a.jpeg, answers: a.answers, chat: a.chat)) else { return nil }
        return ["line": a.headline, "window": a.title, "ref": String(decoding: ref, as: UTF8.self),
                "promptID": String(decoding: payload, as: UTF8.self)]
    }

    /// The alert back from a record's fields (nil for a question from a Mac from before: its
    /// `promptID` is a plain id).
    public static func alert(line: String?, window: String?, ref: String?, payload: String?) -> MacAlert? {
        guard let ref, let r = try? JSONDecoder().decode(TargetRef.self, from: Data(ref.utf8)),
              let payload, let p = try? JSONDecoder().decode(Payload.self, from: Data(payload.utf8)) else { return nil }
        var a = MacAlert(id: p.id, ref: r, appName: p.appName, title: window ?? p.appName, kind: .updated,
                         headline: line ?? p.appName, detail: p.detail, promptID: p.promptID, at: p.at, jpeg: p.jpeg)
        a.kind = p.kind
        a.answers = p.answers
        a.chat = p.chat
        return a
    }
}
