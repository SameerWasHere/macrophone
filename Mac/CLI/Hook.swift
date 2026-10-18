import Darwin
import Foundation
import MacrophoneKit

/// `mp hook claude` / `mp hook codex <json>` (Oct 17 2026): what an agent runs on its own events
/// (Claude Code's hooks, Codex's notify), so the Mac — and the phone — know exactly when it works,
/// asks or finishes. It reads the event, adds the chain of processes it runs under (so the Mac
/// finds the app and window), posts it to the local API and exits. Silent and quick whatever
/// happens: it prints nothing (Claude Code adds some hooks' output to the conversation), always
/// exits 0, and gives up after a second and a half — an agent never waits on Macrophone.
enum Hook {
    static func run(_ args: [String]) async -> Int32 {
        guard let agent = args.first, agent == "claude" || agent == "codex" else { return 0 }
        let raw: Data?
        if agent == "codex" {
            // Codex passes the event as its last argument.
            raw = args.dropFirst().last.map { Data($0.utf8) }
        } else {
            raw = readInput(limit: 1 << 20)
        }
        guard let raw, let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let event = event(agent: agent, obj) else { return 0 }
        await post(event)
        return 0
    }

    static func event(agent: String, _ o: [String: Any]) -> AgentEvent? {
        let pids = ancestors()
        if agent == "codex" {
            guard let type = o["type"] as? String else { return nil }
            let session = (o["thread-id"] as? String) ?? (o["thread_id"] as? String) ?? (o["cwd"] as? String) ?? "codex"
            return AgentEvent(agent: "codex", event: type, session: session, cwd: o["cwd"] as? String,
                              lastMessage: (o["last-assistant-message"] as? String) ?? (o["last_assistant_message"] as? String),
                              pids: pids)
        }
        guard let name = o["hook_event_name"] as? String, let session = o["session_id"] as? String else { return nil }
        var tool = o["tool_name"] as? String
        var detail: String?
        if let input = o["tool_input"] as? [String: Any] {
            if let c = input["command"] as? String { detail = c.components(separatedBy: "\n").first }
            else if let f = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) { detail = URL(fileURLWithPath: f).lastPathComponent }
            else if let u = input["url"] as? String { detail = URL(string: u)?.host ?? u }
            else if let p = input["pattern"] as? String { detail = p }
        }
        // Tool runs are only worth the trip for the ones that change the state.
        if name == "PreToolUse" || name == "PostToolUse" { tool = nil; detail = nil }
        return AgentEvent(agent: "claude", event: name, session: session, cwd: o["cwd"] as? String,
                          message: o["message"] as? String, kind: o["notification_type"] as? String,
                          tool: tool, toolDetail: detail, lastMessage: o["last_assistant_message"] as? String,
                          pids: pids)
    }

    /// Standard input, unless it's a terminal (run by hand), up to `limit` bytes.
    private static func readInput(limit: Int) -> Data? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while data.count < limit {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    /// This process's ancestors, nearest first (the agent, its shell, the terminal app…).
    static func ancestors() -> [Int32] {
        var out: [Int32] = []
        var pid = getppid()
        while pid > 1, out.count < 24 {
            out.append(pid)
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            let parent = info.kp_eproc.e_ppid
            if parent == pid { break }
            pid = parent
        }
        return out
    }

    private static func post(_ e: AgentEvent) async {
        guard let api = try? APIClient.make(), let body = try? JSONEncoder().encode(e) else { return }
        var r = api.request("/v1/agent")
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 1.5
        c.timeoutIntervalForResource = 1.5
        c.waitsForConnectivity = false
        _ = try? await URLSession(configuration: c).data(for: r)
    }
}
