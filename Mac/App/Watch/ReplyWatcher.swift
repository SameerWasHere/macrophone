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
///     still for nine seconds. New content again takes the mark back (it was still working).
/// The mark goes to the phone (`.needsYou`) until you look at that window on the phone or send
/// it more. Looks only while some chat awaits its answer, and never past twelve hours.
///
/// Pictures are read here and never leave the Mac; nothing about them is logged.
@MainActor
final class ReplyWatcher {
    private unowned let app: AppModel
    private var chats: [CGWindowID: Chat] = [:]
    private var task: Task<Void, Never>?
    private var content: SCShareableContent?
    private var contentAt = Date.distantPast
    private var sent: [NeedsYou] = []

    static let interval: UInt64 = 3_000_000_000
    /// Your own message landing, the first seconds after you wrote: not the answer.
    static let ownMessage: TimeInterval = 4
    /// More than a spinner, a timer or a caret: words arrived.
    static let content = 0.006
    /// Looks in a row without new content before it counts as done talking.
    static let settle = 3
    static let expiry: TimeInterval = 12 * 3600
    static let maxChats = 8

    private struct Chat {
        var bundleID: String
        var engagedAt: Date
        var last: [UInt32]?
        var contentSeen = false
        var still = 0
        var answeredAt: Date?
        var asking = false
    }

    init(app: AppModel) { self.app = app }

    var needs: [NeedsYou] {
        chats.compactMap { id, c in
            c.answeredAt.map { NeedsYou(bundleID: c.bundleID, windowKey: String(id), since: $0, asking: c.asking) }
        }
        .sorted { $0.since > $1.since }
    }

    // MARK: You wrote

    /// You sent this window something: it's a chat now, waiting for its answer (any mark it had
    /// is gone — you answered it).
    func engaged(windowID: CGWindowID, bundleID: String?) {
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        chats[windowID] = Chat(bundleID: bundleID, engagedAt: Date())
        if chats.count > Self.maxChats, let oldest = chats.min(by: { $0.value.engagedAt < $1.value.engagedAt })?.key {
            chats.removeValue(forKey: oldest)
        }
        publish()
        start()
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
                if self.chats.isEmpty { self.task = nil; return }
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
                // he stops looking is an answer again.
                c = Chat(bundleID: c.bundleID, engagedAt: now)
            } else if let agent = app.agents.state(of: wid) {
                // It tells the Mac itself (a reply as fast as the send's own confirmation counts).
                let answered = agent.since > c.engagedAt.addingTimeInterval(-2) && agent.state != .working
                c.answeredAt = answered ? (c.answeredAt ?? agent.since) : nil
                c.asking = agent.state == .waiting
            } else if pictures, let scw = await scWindow(wid), let img = await AttentionWatcher.capture(scw) {
                let sample = await Task.detached(priority: .utility) { WatchChange.sample(img) }.value
                let share = c.last.map { WatchChange.changedShare($0, sample) } ?? 0
                c.last = sample
                if now.timeIntervalSince(c.engagedAt) > Self.ownMessage, share >= Self.content {
                    c.contentSeen = true
                    c.still = 0
                    c.answeredAt = nil
                } else {
                    c.still += 1
                }
                if c.contentSeen, c.still >= Self.settle, c.answeredAt == nil { c.answeredAt = now }
                c.asking = false
            }
            chats[wid] = c
        }
        publish()
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
