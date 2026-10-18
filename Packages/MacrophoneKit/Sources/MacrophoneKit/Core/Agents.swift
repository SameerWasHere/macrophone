import Foundation

/// Your agents, by what they say themselves (Oct 17 2026). Claude Code and Codex tell the Mac
/// when they start working, ask for permission, finish a turn or end — through `mp hook`, which
/// they run on their own events — so the phone knows exactly which one waits on you, with no
/// guessing from the window's picture. A window whose agent isn't connected still shows here
/// while the Mac reads it asking a question on screen (`fromScreen`).
public struct AgentSession: Codable, Sendable, Identifiable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Running a turn: thinking, editing, running tools.
        case working
        /// Asking you something: a permission, a question.
        case waiting
        /// Finished its turn: your move.
        case yourTurn
    }

    /// The agent's own session id ("screen:<window>" for one read from the screen).
    public var id: String
    /// "Claude Code", "Codex".
    public var agent: String
    /// The folder it works in ("Macrophone"), when it said.
    public var project: String?
    /// Its window, to watch it; nil when the Mac couldn't tell which window it is.
    public var ref: TargetRef?
    /// The app it runs in: "Terminal", "Claude".
    public var appName: String
    /// Kept as words, so a newer Mac's state never breaks an older phone: unknown reads as working.
    public var stateName: String
    /// The question it asks, or the last thing it said (one or two lines).
    public var detail: String?
    /// When it got to this state.
    public var since: Date
    /// Read from the window's picture, not told by the agent.
    public var fromScreen: Bool

    public var state: State { State(rawValue: stateName) ?? .working }

    public init(id: String, agent: String, project: String?, ref: TargetRef?, appName: String,
                state: State, detail: String?, since: Date, fromScreen: Bool = false) {
        self.id = id
        self.agent = agent
        self.project = project
        self.ref = ref
        self.appName = appName
        self.stateName = state.rawValue
        self.detail = detail
        self.since = since
        self.fromScreen = fromScreen
    }

    /// "Claude Code · Macrophone", or "Terminal" for one read off the screen.
    public var name: String {
        if let project, !project.isEmpty { return "\(agent) · \(project)" }
        return agent
    }

    /// The phone understands `.agents`, sent in its hello.
    public static let feature = "agents"
}

/// One event from an agent, as `mp hook` posts it to the Mac's local API (`POST /v1/agent`).
public struct AgentEvent: Codable, Sendable, Equatable {
    /// "claude" or "codex".
    public var agent: String
    /// Claude Code's hook event ("UserPromptSubmit", "PermissionRequest", "Stop", …), or Codex's
    /// notify type ("agent-turn-complete").
    public var event: String
    public var session: String
    public var cwd: String?
    /// The notification's own words ("Claude needs your permission to use Bash").
    public var message: String?
    /// The notification's kind ("permission_prompt", "idle_prompt", "elicitation_dialog").
    public var kind: String?
    /// The tool and what it's about ("Bash", "git push origin main").
    public var tool: String?
    public var toolDetail: String?
    /// The last thing the agent said (a finished turn).
    public var lastMessage: String?
    /// The hook's ancestors, nearest first: the Mac finds the app (and so the window) the agent
    /// runs in among them.
    public var pids: [Int32]

    public init(agent: String, event: String, session: String, cwd: String? = nil, message: String? = nil,
                kind: String? = nil, tool: String? = nil, toolDetail: String? = nil, lastMessage: String? = nil,
                pids: [Int32] = []) {
        self.agent = agent
        self.event = event
        self.session = session
        self.cwd = cwd
        self.message = message
        self.kind = kind
        self.tool = tool
        self.toolDetail = toolDetail
        self.lastMessage = lastMessage
        self.pids = pids
    }

    public var agentName: String { agent == "codex" ? "Codex" : "Claude Code" }

    /// What this event does to its session: a new state (with the question or the last thing
    /// said), the end of it, or nothing.
    public enum Effect: Equatable { case state(AgentSession.State, detail: String?), ends, nothing }

    public var effect: Effect {
        switch event {
        case "SessionStart": return .state(.yourTurn, detail: nil)
        case "UserPromptSubmit", "PostToolUse", "PreCompact": return .state(.working, detail: nil)
        case "PreToolUse": return .state(.working, detail: nil)
        case "PermissionRequest": return .state(.waiting, detail: question)
        case "Notification":
            switch kind {
            case "permission_prompt", "elicitation_dialog": return .state(.waiting, detail: question)
            case "idle_prompt": return .state(.yourTurn, detail: nil)
            case nil where (message ?? "").localizedCaseInsensitiveContains("permission"):
                return .state(.waiting, detail: question)
            default: return .nothing
            }
        case "Stop", "agent-turn-complete": return .state(.yourTurn, detail: AgentEvent.clip(lastMessage))
        case "SessionEnd": return .ends
        default: return .nothing
        }
    }

    /// The question, in a line: "Run git push origin main?", "Edit Watcher.swift?", else the
    /// notification's words.
    public var question: String {
        if let tool {
            let d = toolDetail.flatMap { AgentEvent.clip($0, to: 110) }
            switch tool {
            case "Bash": if let d { return "Run \(d)?" }
            case "Edit", "MultiEdit", "Write", "NotebookEdit": if let d { return "\(tool == "Write" ? "Write" : "Edit") \(d)?" }
            case "WebFetch": if let d { return "Fetch \(d)?" }
            default: break
            }
            if let d { return "Use \(tool): \(d)?" }
            return "Use \(tool)?"
        }
        return AgentEvent.clip(message) ?? "\(agentName) is asking"
    }

    /// One or two lines: the first paragraph, at most `n` characters, cut at a word.
    public static func clip(_ s: String?, to n: Int = 160) -> String? {
        guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if let p = t.range(of: "\n\n") { t = String(t[..<p.lowerBound]) }
        t = t.replacingOccurrences(of: "\n", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        guard t.count > n else { return t }
        var cut = String(t.prefix(n))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > n / 2 { cut = String(cut[..<space]) }
        return cut + "…"
    }
}

/// Keys beyond Esc, the arrows and Return (Oct 17 2026): ⌃C to stop a runaway command, Tab and
/// ⇧Tab, ⌘Return, ⌘Z, Space, Delete and the digits — pressed in the watched window. A key with
/// its modifiers, by name, so a newer phone's key never breaks an older Mac: one it doesn't know,
/// it ignores. Only to a Mac whose welcome names the feature.
public struct WatchKey: Codable, Sendable, Hashable, Identifiable {
    /// "c", "tab", "return", "z", "space", "delete", "1"…"9".
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var control: Bool
    public var option: Bool

    public init(_ key: String, command: Bool = false, shift: Bool = false, control: Bool = false, option: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.control = control
        self.option = option
    }

    public var id: String { (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key }

    public static let feature = "keys"

    public static let controlC = WatchKey("c", control: true)
    public static let tab = WatchKey("tab")
    public static let shiftTab = WatchKey("tab", shift: true)
    public static let commandReturn = WatchKey("return", command: true)
    public static let commandZ = WatchKey("z", command: true)
    public static let space = WatchKey("space")
    public static let delete = WatchKey("delete")
    public static func digit(_ n: Int) -> WatchKey { WatchKey(String(n)) }

    /// The phone's menu of keys, in order.
    public static let menu: [WatchKey] = [.controlC, .tab, .shiftTab, .commandReturn, .commandZ, .space, .delete,
                                          .digit(1), .digit(2), .digit(3)]

    /// What it shows on its key: "⌃C", "⇧⇥", "⌘↩".
    public var glyph: String {
        let mods = (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
        let k: String
        switch key {
        case "tab": k = "⇥"
        case "return": k = "↩"
        case "space": k = "Space"
        case "delete": k = "⌫"
        default: k = key.uppercased()
        }
        return mods + k
    }

    /// Its name in words, for the menu and VoiceOver: "Control-C", "Shift-Tab".
    public var name: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        if command { parts.append("Command") }
        let k: String
        switch key {
        case "tab": k = "Tab"
        case "return": k = "Return"
        case "space": k = "Space"
        case "delete": k = "Delete"
        default: k = key.uppercased()
        }
        parts.append(k)
        return parts.joined(separator: "-")
    }

    /// What it does, where that's worth a line in the menu.
    public var hint: String? {
        switch self {
        case .controlC: return "Stops what's running in a terminal"
        case .shiftTab: return "Switches modes in Claude Code"
        case .commandReturn: return "Sends in many chat apps"
        case .commandZ: return "Undo"
        default: return nil
        }
    }
}
