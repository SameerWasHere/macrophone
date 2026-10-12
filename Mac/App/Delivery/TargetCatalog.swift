import AppKit
import Foundation
import MacrophoneKit

/// Which key submits a message in the target.
enum SendKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case `return`, commandReturn
    var id: String { rawValue }
    var title: String { self == .return ? "Return" : "⌘ Return" }
    var symbol: String { self == .return ? "return" : "command" }
}

/// Mac-only settings a profile carries next to the shared `Profile` (stored in the same
/// profiles.json under "mac"). Nil fields fall back to the target catalog's defaults.
struct ProfileOptions: Codable, Hashable, Sendable {
    /// Which key sends. Nil = the target's default (Return for almost everything).
    var sendKey: SendKey?
    /// After sending, bring back the app that was in front.
    var returnToPrevious: Bool = false

    static let none = ProfileOptions()
}

/// How Macrophone makes sure the text lands in the right box after bringing an app forward.
enum ComposerStrategy: Sendable {
    /// A chat app: find the message box in the front window (the editable text area lowest in
    /// the window) and focus it if focus is somewhere else.
    case chatInput
    /// A terminal: the window/tab is the input; nothing to focus inside it.
    case terminal
    /// An editor or any other app: paste where the focus already is.
    case focused
}

/// How a window match ("claude") picks a window or tab.
enum WindowMatching: Sendable {
    /// Terminal.app: AppleScript over every tab — custom title, window name, or a process
    /// running in it (so "claude" finds the tab running Claude Code). Falls back to window
    /// and tab titles through Accessibility.
    case terminalApp
    /// iTerm2: AppleScript over every session's name. Falls back to titles.
    case iTerm
    /// Window titles and native tab titles through Accessibility.
    case titles
}

/// One app Macrophone knows how to drive well.
struct TargetSpec: Identifiable, Sendable {
    enum Kind: String, Sendable { case chat, terminal, editor, messaging }

    let id: String
    let name: String
    /// The first installed one wins (Codex has shipped under more than one).
    let bundleIDs: [String]
    let kind: Kind
    /// One line for the gallery.
    let blurb: String
    /// Press the send key after pasting, out of the box.
    let sendsByDefault: Bool
    let sendKey: SendKey
    let composer: ComposerStrategy
    let windowMatching: WindowMatching
    /// Time to let a freshly activated window take keyboard focus (ms).
    let activationSettle: UInt64
    /// Time between ⌘V and the send key, so the app has taken the paste (ms).
    let pasteSettle: UInt64
    /// Words hinting a text area is the message box (description / placeholder / title).
    let composerHints: [String]
    /// Reaches other people: never sends by default, says so in the editor.
    var reachesPeople: Bool { kind == .messaging }
    /// A suggested window match for a ready-made profile ("claude" for Claude Code).
    var suggestedWindowMatch: String? = nil

    var installedBundleID: String? {
        bundleIDs.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
    var isInstalled: Bool { installedBundleID != nil }
    var primaryBundleID: String { installedBundleID ?? bundleIDs[0] }
    var icon: NSImage? { InstalledApp.icon(for: primaryBundleID) }
}

enum TargetCatalog {
    static let claude = TargetSpec(
        id: "claude", name: "Claude", bundleIDs: ["com.anthropic.claudefordesktop"], kind: .chat,
        blurb: "Pastes into the message box and sends it.",
        sendsByDefault: true, sendKey: .return, composer: .chatInput, windowMatching: .titles,
        activationSettle: 260, pasteSettle: 380, composerHints: ["prompt", "message", "reply", "ask", "write"])

    static let chatGPT = TargetSpec(
        id: "chatgpt", name: "ChatGPT", bundleIDs: ["com.openai.chat"], kind: .chat,
        blurb: "Pastes into the message box and sends it.",
        sendsByDefault: true, sendKey: .return, composer: .chatInput, windowMatching: .titles,
        activationSettle: 220, pasteSettle: 320, composerHints: ["message", "ask", "prompt", "chatgpt"])

    static let codex = TargetSpec(
        id: "codex", name: "Codex", bundleIDs: ["com.openai.codex", "com.openai.codex.desktop"], kind: .chat,
        blurb: "Pastes into the task box and sends it.",
        sendsByDefault: true, sendKey: .return, composer: .chatInput, windowMatching: .titles,
        activationSettle: 260, pasteSettle: 380, composerHints: ["ask", "task", "message", "prompt", "describe"])

    static let cursor = TargetSpec(
        id: "cursor", name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"], kind: .chat,
        blurb: "Pastes into the Agent box and sends it. Name a window to pick a project.",
        sendsByDefault: true, sendKey: .return, composer: .chatInput, windowMatching: .titles,
        activationSettle: 300, pasteSettle: 420, composerHints: ["plan", "build", "agent", "ask", "message", "context"])

    static let vsCode = TargetSpec(
        id: "vscode", name: "VS Code", bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"], kind: .editor,
        blurb: "Pastes where your cursor is — an editor or the chat box. Doesn't send.",
        sendsByDefault: false, sendKey: .return, composer: .focused, windowMatching: .titles,
        activationSettle: 300, pasteSettle: 380, composerHints: [])

    static let terminal = TargetSpec(
        id: "terminal", name: "Terminal", bundleIDs: ["com.apple.Terminal"], kind: .terminal,
        blurb: "Types into a tab and presses Return. Name what's running in it, like “claude”.",
        sendsByDefault: true, sendKey: .return, composer: .terminal, windowMatching: .terminalApp,
        activationSettle: 160, pasteSettle: 260, composerHints: [], suggestedWindowMatch: "claude")

    static let iTerm = TargetSpec(
        id: "iterm", name: "iTerm2", bundleIDs: ["com.googlecode.iterm2"], kind: .terminal,
        blurb: "Types into a session and presses Return. Name what's running in it, like “claude”.",
        sendsByDefault: true, sendKey: .return, composer: .terminal, windowMatching: .iTerm,
        activationSettle: 160, pasteSettle: 260, composerHints: [], suggestedWindowMatch: "claude")

    static let ghostty = TargetSpec(
        id: "ghostty", name: "Ghostty", bundleIDs: ["com.mitchellh.ghostty"], kind: .terminal,
        blurb: "Types into the front window and presses Return.",
        sendsByDefault: true, sendKey: .return, composer: .terminal, windowMatching: .titles,
        activationSettle: 160, pasteSettle: 260, composerHints: [], suggestedWindowMatch: "claude")

    static let warp = TargetSpec(
        id: "warp", name: "Warp", bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp"], kind: .terminal,
        blurb: "Types into the front window and presses Return.",
        sendsByDefault: true, sendKey: .return, composer: .terminal, windowMatching: .titles,
        activationSettle: 220, pasteSettle: 320, composerHints: [], suggestedWindowMatch: "claude")

    static let slack = TargetSpec(
        id: "slack", name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"], kind: .messaging,
        blurb: "Pastes into the message box. Doesn't send — it reaches people.",
        sendsByDefault: false, sendKey: .return, composer: .chatInput, windowMatching: .titles,
        activationSettle: 280, pasteSettle: 380, composerHints: ["message", "reply"])

    /// Gallery order.
    static let all: [TargetSpec] = [claude, chatGPT, codex, cursor, vsCode, terminal, iTerm, ghostty, warp, slack]

    static func spec(for bundleID: String?) -> TargetSpec? {
        guard let bundleID else { return nil }
        return all.first { $0.bundleIDs.contains(bundleID) }
    }

    /// Apps where Return is allowed out of the box: every target that sends by default.
    static var defaultSendApps: [AllowedApp] {
        all.filter(\.sendsByDefault).flatMap { s in s.bundleIDs.map { AllowedApp(bundleID: $0, name: s.name) } }
    }

    /// The key that sends in this app unless a profile says otherwise.
    static func defaultSendKey(for bundleID: String?) -> SendKey {
        spec(for: bundleID)?.sendKey ?? .return
    }

    /// Generic behaviour for an app outside the catalog.
    static func generic(bundleID: String, name: String) -> TargetSpec {
        TargetSpec(id: "app:\(bundleID)", name: name, bundleIDs: [bundleID], kind: .editor, blurb: "",
                   sendsByDefault: false, sendKey: .return, composer: .focused, windowMatching: .titles,
                   activationSettle: 280, pasteSettle: 320, composerHints: [])
    }
}

/// A ready-made profile for a catalog target.
enum ReadyMade {
    struct Item: Identifiable {
        let id: String
        let name: String
        let spec: TargetSpec
        let windowMatch: String?
        let voicePrefixes: [String]
        let template: String?
        let format: OutputFormat?

        var line: String {
            var s = spec.sendsByDefault ? "Pastes into \(spec.name) and sends" : "Pastes into \(spec.name)"
            if let windowMatch { s += " — the \(spec.kind == .terminal ? "tab" : "window") running “\(windowMatch)”" }
            return s + "."
        }
    }

    static let items: [Item] = [
        Item(id: "claude", name: "Claude", spec: TargetCatalog.claude, windowMatch: nil, voicePrefixes: ["Claude"], template: nil, format: nil),
        Item(id: "claude-code", name: "Claude Code (Terminal)", spec: TargetCatalog.terminal, windowMatch: "claude",
             voicePrefixes: ["Claude Code"], template: nil, format: nil),
        Item(id: "chatgpt", name: "ChatGPT", spec: TargetCatalog.chatGPT, windowMatch: nil, voicePrefixes: ["ChatGPT"], template: nil, format: nil),
        Item(id: "cursor", name: "Cursor", spec: TargetCatalog.cursor, windowMatch: nil, voicePrefixes: ["Cursor"], template: nil, format: nil),
    ]

    /// A new profile for a catalog target (its default send behaviour, window match, prefix).
    static func profile(for spec: TargetSpec, name: String? = nil, windowMatch: String? = nil,
                        voicePrefixes: [String]? = nil, format: OutputFormat? = nil) -> Profile {
        var p = Profile(name: name ?? spec.name,
                        destination: .app(bundleID: spec.primaryBundleID, name: spec.name),
                        pressEnter: spec.sendsByDefault,
                        outputFormat: format,
                        voicePrefixes: voicePrefixes)
        p.windowMatch = windowMatch
        return p
    }

    static func profile(for item: Item) -> Profile {
        profile(for: item.spec, name: item.name, windowMatch: item.windowMatch, voicePrefixes: item.voicePrefixes, format: item.format)
    }
}
