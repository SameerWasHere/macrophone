import AppKit
import Foundation
import MacrophoneKit
import ScreenCaptureKit

/// The chats you're in that answered you (Oct 18 2026). Sameer: "a chat where the user is
/// currently engaging. If the agent has sent them a message and requires a response, that's when
/// you would want to see some type of indication ... in the app selector."
///
/// A chat is a window you sent something to from the phone: a dictation that went out, or an
/// answer, Return or ⌘Return from the watch view. From then on, every three seconds, this looks
/// for its answer:
///   - an agent that tells the Mac itself (Claude Code, Codex: AgentHub) — exact: it finished its
///     turn or it's asking, after you wrote;
///   - any other window — by its picture: real new content arrived (more than a spinner or a
///     timer, after the first seconds, which are your own message landing), then the window kept
///     still for nine seconds — never while it shows a Stop button or "esc to interrupt"
///     (StillWorking). New content again takes the mark back (it was still working).
/// The mark goes to the phone (`.needsYou`) until you look at that window on the phone or send
/// it more. Looks only while some chat awaits its answer, and never past twelve hours.
///
/// **The answer finds you (Nov 8 2026).** An answer is also an alert — "Claude answered you", the
/// reply's last lines, a picture of the window — through the one sender (AlertCenter: a connected
/// phone, else iCloud), with no window on watch: Sameer dictates from away, pockets the phone and
/// comes back for the answer. Only while the phone's "When a chat answers you" is on (its hello
/// says, `AlertCenter.chatAnswers`; a phone from before never turned it on, so nothing changes for
/// it). Each chat is followed (`AnswerFollower`) for two hours after the phone last wrote to it and
/// for two answers; writing to it again re-arms it. Never while he's looking at that window on the
/// phone (what it says then is seen), never for a window on watch (WindowAlertWatcher tells those
/// the same moment), never an agent's question (AgentHub tells it the moment it asks).
///
/// Pictures are read here and never leave the Mac except in the alert; the log says kinds and
/// counts, never the words.
@MainActor
final class ReplyWatcher {
    private unowned let app: AppModel
    private var chats: [CGWindowID: Chat] = [:]
    private var task: Task<Void, Never>?
    private var content: SCShareableContent?
    private var contentAt = Date.distantPast
    private var sent: [NeedsYou] = []
    private var followedCount = 0

    static let interval: UInt64 = 3_000_000_000
    static let expiry: TimeInterval = 12 * 3600
    static let maxChats = 8
    /// The window's words are read this long after the phone wrote (its own message has landed and
    /// the composer is empty again): what the answer is told against.
    static let beforeAfter: UInt64 = 1_000_000_000

    private struct Chat {
        var bundleID: String
        var detector: ReplyDetector
        var last: [UInt32]?
        /// Answers told for this message from the phone (re-armed when it writes again).
        var follower: AnswerFollower
        /// The window's lines just after the phone wrote: the answer's new lines are told against them.
        var before: [String]?
        var engagedAt: Date { detector.engagedAt }

        init(bundleID: String, engagedAt: Date) {
            self.bundleID = bundleID
            self.detector = ReplyDetector(engagedAt: engagedAt)
            self.follower = AnswerFollower(engagedAt: engagedAt)
        }
    }

    init(app: AppModel) { self.app = app }

    var needs: [NeedsYou] {
        chats.compactMap { id, c in
            c.detector.answeredAt.map { NeedsYou(bundleID: c.bundleID, windowKey: String(id), since: $0, asking: c.detector.asking) }
        }
        .sorted { $0.since > $1.since }
    }

    /// This chat answered (since when, and whether it's asking) — for a window on watch, which
    /// alerts on it the same moment (WindowAlertWatcher, Nov 7 2026).
    func answered(windowID: CGWindowID) -> (since: Date, asking: Bool)? {
        guard let c = chats[windowID], let at = c.detector.answeredAt else { return nil }
        return (at, c.detector.asking)
    }

    // MARK: You wrote

    /// You sent this window something: it's a chat now, waiting for its answer (any mark it had
    /// is gone — you answered it), and its answer will be told (re-armed).
    func engaged(windowID: CGWindowID, bundleID: String?) {
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        chats[windowID] = Chat(bundleID: bundleID, engagedAt: Date())
        if chats.count > Self.maxChats, let oldest = chats.min(by: { $0.value.engagedAt < $1.value.engagedAt })?.key {
            chats.removeValue(forKey: oldest)
        }
        publish()
        start()
        readBefore(windowID)
    }

    /// The window's words once the phone's own message has landed, to tell the answer against.
    private func readBefore(_ wid: CGWindowID) {
        guard app.alerts.chatAnswers == true, CGPreflightScreenCaptureAccess(), app.agents.state(of: wid) == nil else { return }
        let engagedAt = chats[wid]?.engagedAt
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.beforeAfter)
            guard let image = await AlertCenter.capture(windowID: wid) else { return }
            let lines = await AlertReading.lines(image)
            guard let self, self.chats[wid]?.engagedAt == engagedAt else { return }
            self.chats[wid]?.before = lines
        }
    }

    // MARK: Looking

    private func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                // Every three seconds while you wrote in the last ten minutes, every ten after.
                let recent = self?.chats.values.contains { Date().timeIntervalSince($0.engagedAt) < 600 } ?? false
                try? await Task.sleep(nanoseconds: recent ? Self.interval : Self.interval * 10 / 3)
                guard let self else { return }
                await self.look()
                if self.chats.isEmpty { self.task = nil; self.stayAwake(); return }
            }
        }
    }

    private func look() async {
        let now = Date()
        chats = chats.filter { now.timeIntervalSince($0.value.engagedAt) < Self.expiry && WindowServer.exists($0.key) }
        let pictures = CGPreflightScreenCaptureAccess()
        let watched = app.watch.watchedWindows
        for (wid, c) in chats {
            var c = c
            if watched.contains(wid) {
                // He's looking at it on the phone: whatever it says, he sees. Anything new after
                // he stops looking is an answer again — told while the phone's message is followed.
                var fresh = Chat(bundleID: c.bundleID, engagedAt: now)
                fresh.follower = c.follower
                fresh.follower.seen(answeredAt: c.detector.answeredAt)
                c = fresh
            } else if let agent = app.agents.state(of: wid) {
                // It tells the Mac itself.
                c.detector.agent(agent.state, since: agent.since)
            } else if pictures, let scw = await scWindow(wid), let img = await AttentionWatcher.capture(scw) {
                let sample = await Task.detached(priority: .utility) { WatchChange.sample(img) }.value
                let share = c.last.map { WatchChange.changedShare($0, sample) } ?? 0
                c.last = sample
                // A Stop button or "esc to interrupt": still at it, however still the picture.
                var working = false
                if Paster.isTrusted, let pid = NSRunningApplication.runningApplications(withBundleIdentifier: c.bundleID).first?.processIdentifier {
                    working = await Task.detached(priority: .utility) { StillWorking.check(pid: pid, windowID: wid) }.value
                }
                c.detector.look(changed: share, working: working, at: now)
            }
            if let at = c.detector.answeredAt { follow(wid, &c, answeredAt: at, at: now) }
            chats[wid] = c
        }
        publish()
        stayAwake()
    }

    // MARK: Telling (Nov 8 2026)

    /// A chat answered: tell the phone when this answer is news. Every answer is seen by the
    /// follower once, told or not, so one passed by (a window on watch, an agent's question) is
    /// never told later.
    private func follow(_ wid: CGWindowID, _ c: inout Chat, answeredAt at: Date, at now: Date) {
        guard app.alerts.chatAnswers == true else { c.follower.seen(answeredAt: at); return }
        // A window on watch alerts on this same answer itself (WindowAlertWatcher.signal).
        if app.windowAlerts.isWatching(wid) { c.follower.seen(answeredAt: at); return }
        // An agent asking: AgentHub told the phone the moment it asked.
        if c.detector.asking, app.agents.state(of: wid)?.state == .waiting { c.follower.seen(answeredAt: at); return }
        guard c.follower.shouldTell(answeredAt: at, at: now) else { return }
        let chat = c
        Task { await self.tell(wid, chat) }
    }

    private func tell(_ wid: CGWindowID, _ c: Chat) async {
        let live = app.targets.first { $0.bundleID == c.bundleID && $0.windowKey == String(wid) }
        let appName = live?.appName ?? NSRunningApplication.runningApplications(withBundleIdentifier: c.bundleID).first?.localizedName ?? c.bundleID
        // The same ref AgentHub and the menu use, so one window's alerts replace one another.
        let ref = live?.ref ?? .app(bundleID: c.bundleID, windowKey: String(wid), name: appName)
        let title = live?.windowTitle ?? appName
        var kind: MacAlert.Kind = c.detector.asking ? .asking : .answered
        var new: [String] = []
        var prompt: WatchPrompt?
        var jpeg: Data?
        if CGPreflightScreenCaptureAccess(), let image = await AlertCenter.capture(windowID: wid) {
            let lines = await AlertReading.lines(image)
            let tail = AlertWords.newLines(before: [], now: Array(lines.suffix(10))).filter { !AlertWords.isPrompt($0) }
            let fresh = AlertWords.newLines(before: c.before ?? [], now: tail)
            new = fresh.isEmpty ? tail : fresh
            prompt = await PromptVision.read(image)
            if prompt != nil { kind = .asking }
            jpeg = await Task.detached(priority: .utility) { AlertCenter.jpeg(image) }.value
        }
        // He opened it on the phone meanwhile: he sees it.
        guard !app.watch.watchedWindows.contains(wid) else { return }
        if kind == .asking, app.alerts.recentlyAsked(ref) {
            app.log.add("chat answers: a chat is asking, told already")
            return
        }
        let detail = prompt?.question ?? AlertWords.reply(new)
        let a = MacAlert(ref: ref, appName: appName, title: title, kind: kind,
                         headline: AlertWords.headline(kind, app: appName, newLines: new),
                         detail: detail, promptID: prompt?.id, jpeg: jpeg, chat: true)
        app.log.add("chat answers: a chat \(kind == .asking ? "is asking" : "answered") — alert \(c.follower.told) of \(ChatAnswers.maxAnswers) "
                    + "(\(new.count) new lines read\(jpeg == nil ? ", no picture" : ""))")
        await app.alerts.send(a)
    }

    /// Chats followed for their answer keep the Mac from idle sleep (the display may sleep), so a
    /// reply that comes while he's away still reaches him.
    private func stayAwake() {
        let now = Date()
        let n = app.alerts.chatAnswers == true ? chats.values.filter { $0.follower.following(at: now) }.count : 0
        guard n != followedCount else { return }
        followedCount = n
        app.stayAwake.update(followedChats: n)
    }

    private func publish() {
        let list = needs
        guard list != sent else { return }
        let added = list.count > sent.count
        sent = list
        app.server.broadcastNeeds(list)
        if added { app.log.add("needs you: a chat answered (\(list.count) waiting)") }
    }

    private func scWindow(_ id: CGWindowID) async -> SCWindow? {
        if let c = content, Date().timeIntervalSince(contentAt) < 30, let w = c.windows.first(where: { $0.windowID == id }) { return w }
        guard let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return nil }
        content = c
        contentAt = Date()
        return c.windows.first { $0.windowID == id }
    }
}
