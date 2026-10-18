import AppKit
import Foundation
import MacrophoneKit

/// Every agent session on this Mac, by what the agents say themselves (Oct 17 2026). Claude Code
/// and Codex run `mp hook` on their own events; the hook posts each to the local API, and this
/// keeps one row per session — working, waiting on you, or your turn — with the window it runs
/// in. A session that starts waiting tells the phone at once (no looking at pictures, so no
/// false alarm and no five-second wait), and the phone's list of agents follows every change.
///
/// Windows whose agent isn't connected still show while the attention watcher reads them asking
/// a question on screen (`screenAsks`).
///
/// What an agent says (its question, its last words) goes only to the phone, never to the log.
@MainActor
final class AgentHub {
    private unowned let app: AppModel
    private var sessions: [String: Entry] = [:]
    /// Windows the attention watcher reads asking, keyed by the window: shown until they stop.
    private var screenAsks: [String: AgentSession] = [:]
    private var broadcast: Task<Void, Never>?
    private var sweeper: Task<Void, Never>?
    /// A session nobody heard from in this long is gone (a terminal closed mid-turn).
    static let stale: TimeInterval = 12 * 3600

    private struct Entry {
        var session: AgentSession
        var pid: pid_t?
        var windowID: CGWindowID?
        var heardAt: Date
    }

    init(app: AppModel) { self.app = app }

    /// The list for the phone: waiting first, then your turn, then working; newest first in each.
    var list: [AgentSession] {
        let order: [AgentSession.State: Int] = [.waiting: 0, .yourTurn: 1, .working: 2]
        let screen = screenAsks.values.filter { s in !sessions.values.contains { $0.session.ref == s.ref && s.ref != nil } }
        return (sessions.values.map(\.session) + screen).sorted {
            let a = order[$0.state] ?? 3, b = order[$1.state] ?? 3
            return a != b ? a < b : $0.since > $1.since
        }
    }

    /// Where the agent in this window is, when one told the Mac (the newest, if several).
    func state(of window: CGWindowID) -> (state: AgentSession.State, since: Date)? {
        sessions.values.filter { $0.windowID == window }.max { $0.heardAt < $1.heardAt }
            .map { ($0.session.state, $0.session.since) }
    }

    /// Windows an agent told about: the attention watcher leaves them to the agent.
    var claimedWindows: Set<CGWindowID> { Set(sessions.values.compactMap(\.windowID)) }

    // MARK: Events

    func handle(_ e: AgentEvent) {
        let key = "\(e.agent):\(e.session)"
        switch e.effect {
        case .nothing:
            if var entry = sessions[key] { entry.heardAt = Date(); sessions[key] = entry }
            return
        case .ends:
            guard sessions.removeValue(forKey: key) != nil else { return }
            app.log.add("agents: a session ended")
            changed()
            return
        case let .state(state, detail):
            let now = Date()
            var entry = sessions[key] ?? Entry(
                session: AgentSession(id: key, agent: e.agentName, project: Self.project(e.cwd), ref: nil,
                                      appName: e.agentName, state: state, detail: nil, since: now),
                pid: nil, windowID: nil, heardAt: now)
            let was = sessions[key]?.session.state
            entry.heardAt = now
            if let p = Self.project(e.cwd) { entry.session.project = p }
            place(&entry, event: e)
            // A tool running after a permission is the answer: waiting is over. A tool running
            // while working keeps whatever it last said.
            if state != entry.session.state || detail != nil || state == .waiting {
                if state != entry.session.state { entry.session.since = now }
                entry.session.stateName = state.rawValue
                entry.session.detail = detail ?? (state == .working ? nil : entry.session.detail)
            }
            let isNew = sessions[key] == nil
            sessions[key] = entry
            if isNew { app.log.add("agents: \(e.agentName) session started (\(sessions.count) now)") }
            if state == .waiting, was != .waiting || detail != nil { alert(entry.session) }
            if state != was || isNew || detail != nil { changed() }
        }
        sweep()
    }

    /// The attention watcher reads a window asking (`question` nil: it stopped).
    func screen(_ t: LiveTarget, question: String?, promptID: String?) {
        let key = "screen:\(t.id)"
        if let question = question ?? promptID.map({ _ in "\(t.appName) is asking" }) {
            let s = AgentSession(id: key, agent: t.appName, project: t.windowTitle.flatMap(Self.titleProject),
                                 ref: t.ref, appName: t.appName, state: .waiting, detail: question,
                                 since: screenAsks[key]?.since ?? Date(), fromScreen: true)
            guard screenAsks[key] != s else { return }
            screenAsks[key] = s
        } else {
            guard screenAsks.removeValue(forKey: key) != nil else { return }
        }
        changed()
    }

    // MARK: Which window

    /// The app the agent runs in (the nearest of its ancestors that is one), and its window: the
    /// one it had, while it lasts; the app's only window; the one whose title names the project;
    /// or, when he just typed to it (a new prompt), the app's front window.
    private func place(_ entry: inout Entry, event e: AgentEvent) {
        if entry.pid == nil || NSRunningApplication(processIdentifier: entry.pid!)?.isTerminated != false {
            entry.pid = e.pids.first { pid in
                guard let r = NSRunningApplication(processIdentifier: pid) else { return false }
                return r.activationPolicy == .regular && r.bundleIdentifier != Bundle.main.bundleIdentifier
            }
        }
        guard let pid = entry.pid, let running = NSRunningApplication(processIdentifier: pid),
              let bid = running.bundleIdentifier else { return }
        let appName = running.localizedName ?? entry.session.agent
        entry.session.appName = appName
        let windows = WindowServer.appWindows().filter { $0.pid == pid }
        if let id = entry.windowID, windows.contains(where: { $0.id == id }) {
            // Keep it.
        } else if windows.count == 1 {
            entry.windowID = windows[0].id
        } else if let p = entry.session.project?.lowercased(), !p.isEmpty,
                  let t = app.targets.first(where: { t in
                      t.bundleID == bid && (t.windowTitle ?? "").lowercased().contains(p)
                          && windows.contains { String($0.id) == t.windowKey }
                  }), let k = t.windowKey, let id = CGWindowID(k) {
            entry.windowID = id
        } else if e.event == "UserPromptSubmit" || e.event == "SessionStart",
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let front = windows.min(by: { $0.z < $1.z }) {
            entry.windowID = front.id
        }
        let key = entry.windowID.map(String.init)
        if let live = app.targets.first(where: { $0.bundleID == bid && $0.windowKey == key }) {
            entry.session.ref = live.ref
        } else {
            entry.session.ref = .app(bundleID: bid, windowKey: key, name: appName)
        }
    }

    // MARK: Telling the phone

    private func alert(_ s: AgentSession) {
        guard let ref = s.ref else { return }
        let phones = app.server.phones(with: Attention.feature)
        let a = Attention(ref: ref, appName: s.agent, title: s.project ?? s.appName,
                          question: s.detail, promptID: Self.promptID(s))
        Task {
            if phones.isEmpty {
                guard CloudAlerts.available, UserDefaults.standard.bool(forKey: "attention.cloud") else { return }
                let ok = await CloudAlerts.post(a)
                app.log.add(ok ? "agents: \(s.agent) is asking — sent through iCloud" : "agents: \(s.agent) is asking — iCloud didn't take it")
            } else {
                for p in phones { await app.server.send(.attention(a), to: p) }
                app.log.add("agents: \(s.agent) is asking — told the phone")
            }
        }
    }

    /// Short and stable for one question of one session.
    private static func promptID(_ s: AgentSession) -> String {
        var h: UInt64 = 1469598103934665603
        for b in (s.id + (s.detail ?? "")).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "agent-" + String(h, radix: 16)
    }

    /// The phones' lists follow, a beat after a burst of events.
    private func changed() {
        broadcast?.cancel()
        broadcast = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.app.server.broadcastAgents(self.list)
        }
    }

    /// Sessions gone quiet for hours, or whose app quit, leave the list; checked every few minutes.
    private func sweep() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                guard let self else { return }
                let before = self.sessions.count
                self.sessions = self.sessions.filter { _, e in
                    guard Date().timeIntervalSince(e.heardAt) < Self.stale else { return false }
                    guard let pid = e.pid else { return true }
                    return NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
                }
                if self.sessions.count != before { self.changed() }
                if self.sessions.isEmpty { self.sweeper = nil; return }
            }
        }
    }

    private static func project(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name == "/" || name == NSUserName() ? nil : name
    }

    /// "claude ~/app" → nil; a window's title is shown as it is elsewhere, so none here.
    private static func titleProject(_ title: String) -> String? { title.isEmpty ? nil : title }
}
