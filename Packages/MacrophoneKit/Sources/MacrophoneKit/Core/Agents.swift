import Foundation

/// One agent session on the Mac, by what the agent says itself (Oct 17 2026). Claude Code and
/// Codex tell the Mac when they start working, ask for permission, finish a turn or end — through
/// `mp hook`, which they run on their own events — so the Mac knows exactly which one waits on
/// you, with no guessing from the window's picture. The Mac's own record (`AgentHub`): it feeds
/// the alert the moment one asks and the Answered you mark; the phone never sees the list (its
/// Agents panel was removed Oct 18 2026, and with it the `agents` message).
public struct AgentSession: Codable, Sendable, Identifiable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Running a turn: thinking, editing, running tools.
        case working
        /// Asking you something: a permission, a question.
        case waiting
        /// Finished its turn: your move.
        case yourTurn
    }

    /// The agent's own session id.
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

    public var state: State { State(rawValue: stateName) ?? .working }

    public init(id: String, agent: String, project: String?, ref: TargetRef?, appName: String,
                state: State, detail: String?, since: Date) {
        self.id = id
        self.agent = agent
        self.project = project
        self.ref = ref
        self.appName = appName
        self.stateName = state.rawValue
        self.detail = detail
        self.since = since
    }
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

/// Keys beyond Esc, the arrows and Return (Oct 17 2026; sections Oct 18 — Sameer: "redundant with
/// repeated words ... add more common key strokes"). A key with its modifiers, by name, so a newer
/// phone's key never breaks an older Mac: one it doesn't know, it ignores. The menu says what each
/// does ("Interrupt", "New line") with the keys under it (⌃C, ⇧↩). Only to a Mac whose welcome
/// names the feature.
public struct WatchKey: Codable, Sendable, Hashable, Identifiable {
    /// "c", "tab", "return", "z", "space", "delete", "left", "right", "up", "down", "pageup",
    /// "pagedown", "1"…"9" — the Mac's `WatchService.keyCode` knows each.
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

    public var id: String { glyph }

    public static let feature = "keys"

    public static let controlC = WatchKey("c", control: true)
    public static let tab = WatchKey("tab")
    public static let shiftTab = WatchKey("tab", shift: true)
    public static let commandReturn = WatchKey("return", command: true)
    public static let commandZ = WatchKey("z", command: true)
    public static let space = WatchKey("space")
    public static let delete = WatchKey("delete")
    public static func digit(_ n: Int) -> WatchKey { WatchKey(String(n)) }

    /// One section of the phone's menu.
    public struct Section: Identifiable, Sendable {
        public var title: String
        public var keys: [WatchKey]
        public var id: String { title }
    }

    /// The phone's menu, by what you're doing; the digits last, as one row.
    public static let sections: [Section] = [
        Section(title: "Agents & Terminal", keys: [.controlC, .shiftTab, .tab, WatchKey("l", control: true)]),
        Section(title: "Typing", keys: [.commandReturn, WatchKey("return", shift: true), .space, .delete, WatchKey("delete", option: true)]),
        Section(title: "Edit", keys: [.commandZ, WatchKey("z", command: true, shift: true), WatchKey("a", command: true),
                                      WatchKey("c", command: true), WatchKey("v", command: true)]),
        Section(title: "Move", keys: [WatchKey("left"), WatchKey("right"), WatchKey("pageup"), WatchKey("pagedown"),
                                      WatchKey("up", command: true), WatchKey("down", command: true)]),
    ]
    public static let digits: [WatchKey] = (1...4).map(digit)

    /// What it does, in a word or two — the menu's line.
    public var title: String {
        switch (key, command, shift, control, option) {
        case ("c", false, false, true, false): return "Interrupt"
        case ("tab", false, true, false, false): return "Switch Mode"
        case ("tab", false, false, false, false): return "Tab"
        case ("l", false, false, true, false): return "Clear Screen"
        case ("return", true, false, false, false): return "Send"
        case ("return", false, true, false, false): return "New Line"
        case ("space", _, _, _, _): return "Space"
        case ("delete", false, false, false, true): return "Delete Word"
        case ("delete", _, _, _, _): return "Delete"
        case ("z", true, false, false, false): return "Undo"
        case ("z", true, true, false, false): return "Redo"
        case ("a", true, false, false, false): return "Select All"
        case ("c", true, false, false, false): return "Copy"
        case ("v", true, false, false, false): return "Paste"
        case ("left", false, false, false, false): return "Left"
        case ("right", false, false, false, false): return "Right"
        case ("pageup", _, _, _, _): return "Page Up"
        case ("pagedown", _, _, _, _): return "Page Down"
        case ("up", true, false, false, false): return "To the Top"
        case ("down", true, false, false, false): return "To the Bottom"
        default: return name
        }
    }

    /// The keys, as on a Mac's menus: "⌃C", "⇧⌘Z", "⇧↩".
    public var glyph: String {
        let mods = (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
        let k: String
        switch key {
        // U+FE0E: drawn as text, never as an emoji (iOS turns a bare ↩ into a blue box).
        case "tab": k = "⇥"
        case "return": k = "↩\u{FE0E}"
        case "space": k = "␣"
        case "delete": k = "⌫"
        case "left": k = "←\u{FE0E}"
        case "right": k = "→\u{FE0E}"
        case "up": k = "↑\u{FE0E}"
        case "down": k = "↓\u{FE0E}"
        case "pageup": k = "⇞"
        case "pagedown": k = "⇟"
        default: k = key.uppercased()
        }
        return mods + k
    }

    /// Its keys in words, for VoiceOver: "Control-C", "Shift-Command-Z".
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
        case "left": k = "Left Arrow"
        case "right": k = "Right Arrow"
        case "up": k = "Up Arrow"
        case "down": k = "Down Arrow"
        case "pageup": k = "Page Up"
        case "pagedown": k = "Page Down"
        default: k = key.uppercased()
        }
        parts.append(k)
        return parts.joined(separator: "-")
    }
}

/// A chat you're in the middle of has answered you (Oct 18 2026, Sameer: "a chat where the user is
/// currently engaging. If the agent has sent them a message and requires a response, that's when
/// you would want to see some type of indication ... in the app selector"). Only windows you sent
/// something to from the phone; gone once you look at that window on the phone or send it more.
public struct NeedsYou: Codable, Sendable, Equatable, Hashable {
    public var bundleID: String
    /// The window (a CGWindowID as text).
    public var windowKey: String
    /// When it answered.
    public var since: Date
    /// It's asking you something (a permission, a question), not only done talking.
    public var asking: Bool

    public init(bundleID: String, windowKey: String, since: Date, asking: Bool) {
        self.bundleID = bundleID
        self.windowKey = windowKey
        self.since = since
        self.asking = asking
    }

    /// Whether this is about that place: its window, or the app when the place is the app.
    public func concerns(_ t: LiveTarget) -> Bool {
        t.bundleID == bundleID && (t.windowKey == nil || t.windowKey == windowKey)
    }

    /// The phone understands `.needsYou`, sent in its hello.
    public static let feature = "needsYou"
}

/// Did the chat answer you? The rule ReplyWatcher applies to each chat, look by look (pure, so
/// the tests can walk it). By the window's picture: real content (more than a spinner, a timer
/// or a caret) after your own message has landed, then stillness for `settle` looks — but never
/// while the window says it's still working (a Stop button, "esc to interrupt": an agent running
/// a tool is still for long stretches). More content takes it back. By the agent itself
/// (hooks): done or asking, after you wrote.
public struct ReplyDetector: Equatable, Sendable {
    /// Your own message landing, the first seconds after you wrote: not the answer.
    public static let ownMessage: TimeInterval = 4
    /// A share of the window this big changed between two looks: words arrived.
    public static let content = 0.006
    /// Looks in a row without new content before it counts as done talking.
    public static let settle = 3

    public var engagedAt: Date
    public private(set) var contentSeen = false
    public private(set) var still = 0
    public private(set) var answeredAt: Date?
    public private(set) var asking = false

    public init(engagedAt: Date) { self.engagedAt = engagedAt }

    /// One look at the picture: `share` of it changed since the last look; `working`, the window
    /// shows it's still at it.
    public mutating func look(changed share: Double, working: Bool = false, at now: Date) {
        let after = now.timeIntervalSince(engagedAt) > Self.ownMessage
        if working || (after && share >= Self.content) {
            // Working counts as an answer coming, whenever it shows (a fast agent's Stop button is
            // up before your own message has finished landing).
            contentSeen = true
            still = 0
            answeredAt = nil
        } else {
            still += 1
        }
        if contentSeen, still >= Self.settle, answeredAt == nil { answeredAt = now }
        asking = false
    }

    /// What the agent in the window says it's doing (a reply as quick as the send's own
    /// confirmation counts: two seconds' grace).
    public mutating func agent(_ state: AgentSession.State, since: Date) {
        let answered = state != .working && since > engagedAt.addingTimeInterval(-2)
        answeredAt = answered ? (answeredAt ?? since) : nil
        asking = answered && state == .waiting
    }
}
