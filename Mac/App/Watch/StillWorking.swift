import AppKit
import ApplicationServices
import Foundation

/// Whether a window says its agent is still at it (Oct 18 2026): a chat app's Stop button while it
/// answers (the Claude app's "Stop", ChatGPT's "Stop generating"), or a terminal agent's
/// "esc to interrupt" near the end of its text (Claude Code, Codex). Read through Accessibility,
/// off the main thread; a window it can't read says no. Nothing read here is kept or logged.
enum StillWorking {
    static let stopLabels: Set<String> = ["stop", "stop response", "stop generating", "stop responding",
                                          "stop streaming", "interrupt", "stop answering"]
    static let terminalHints = ["esc to interrupt", "ctrl+c to interrupt", "esc to cancel"]

    static func check(pid: pid_t, windowID: CGWindowID) -> Bool {
        let app = AX.app(pid)
        guard let win = AX.window(in: app, id: windowID) else { return false }
        var budget = 4000
        return search(win, depth: 0, budget: &budget)
    }

    private static func search(_ e: AXUIElement, depth: Int, budget: inout Int) -> Bool {
        budget -= 1
        guard budget > 0, depth < 60 else { return false }
        let role = AX.role(e)
        if role == kAXButtonRole {
            for a in [kAXTitleAttribute, kAXDescriptionAttribute] {
                if let s = AX.string(e, a), stopLabels.contains(s.trimmingCharacters(in: .whitespaces).lowercased()) { return true }
            }
        } else if role == kAXTextAreaRole, let tail = tail(of: e, characters: 3000)?.lowercased() {
            if terminalHints.contains(where: tail.contains) { return true }
        }
        for k in AX.elements(e, kAXChildrenAttribute) where search(k, depth: depth + 1, budget: &budget) { return true }
        return false
    }

    /// The last characters of a text area (a terminal's screen and scrollback), without reading it all.
    private static func tail(of e: AXUIElement, characters n: Int) -> String? {
        var count: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
              let total = count as? Int, total > 0 else { return nil }
        var range = CFRange(location: max(0, total - n), length: min(n, total))
        guard let r = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, r, &out) == .success else { return nil }
        return out as? String
    }
}
