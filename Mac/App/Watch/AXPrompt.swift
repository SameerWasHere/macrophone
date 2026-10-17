import ApplicationServices
import MacrophoneKit

/// A question an app shows as real controls (Oct 16 2026) — Claude's question card ("Option one",
/// "Option two", Skip, Submit), an Allow / Deny pair — read through Accessibility instead of off
/// the picture: exact, no Screen Recording, and answered by pressing the controls themselves, so
/// the window doesn't have to come forward. Terminals have no such controls: their menus are read
/// off the picture (PromptReader).
struct AXPrompt: @unchecked Sendable {
    var prompt: WatchPrompt
    /// What to press for each answer.
    var presses: [AXUIElement]
    /// Pressed after the answer, for a card that submits (nil: the answer is the button).
    var submit: AXUIElement?

    static let submitWords: Set<String> = ["submit", "send", "continue", "confirm", "ok", "done"]
    static let yesWords = ["allow", "always allow", "approve", "accept", "yes", "run", "proceed"]
    static let noWords = ["deny", "don't allow", "reject", "decline", "no", "cancel"]

    /// Answers `index`: press it, then submit. False if a control is gone.
    func answer(_ index: Int) async -> Bool {
        guard presses.indices.contains(index) else { return false }
        guard AXUIElementPerformAction(presses[index], kAXPressAction as CFString) == .success else { return false }
        if let submit {
            try? await Task.sleep(nanoseconds: 150_000_000)
            return AXUIElementPerformAction(submit, kAXPressAction as CFString) == .success
        }
        return true
    }

    /// The question the window shows as controls, if any. Walks the window (a few hundred nodes
    /// in an Electron app); call off the main thread.
    static func read(pid: pid_t, windowID: CGWindowID) -> AXPrompt? {
        let app = AX.app(pid)
        AX.wakeWebContent(app)
        guard let win = AX.window(in: app, id: windowID) else { return nil }

        // Every node, in order, with the path of nodes above it.
        var nodes: [(e: AXUIElement, role: String, path: [AXUIElement])] = []
        func walk(_ e: AXUIElement, _ path: [AXUIElement]) {
            guard nodes.count < 5000, path.count < 60 else { return }
            nodes.append((e, AX.role(e), path))
            for c in AX.elements(e, kAXChildrenAttribute) { walk(c, path + [e]) }
        }
        walk(win, [])

        func words(_ e: AXUIElement) -> String {
            let t = AX.title(e)
            return (t.isEmpty ? AX.string(e, kAXDescriptionAttribute) ?? "" : t).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func contains(_ ancestor: AXUIElement, _ node: (e: AXUIElement, role: String, path: [AXUIElement])) -> Bool {
            node.path.contains { CFEqual($0, ancestor) }
        }

        // 1. A card: a submit button with two or more choices (checkboxes or radio buttons) near it.
        let choiceRoles: Set<String> = ["AXCheckBox", "AXRadioButton"]
        for submit in nodes where submit.role == "AXButton" && submitWords.contains(words(submit.e).lowercased()) {
            for ancestor in submit.path.reversed().prefix(6) {
                let choices = nodes.filter { choiceRoles.contains($0.role) && contains(ancestor, $0) && !words($0.e).isEmpty }
                guard choices.count >= 2 else { continue }
                guard choices.count <= 8 else { break }
                let labels = choices.map { label(of: $0.e, fallback: words($0.e)) }
                let question = nodes.first { n in n.role == "AXStaticText" && contains(ancestor, n)
                    && !choices.contains(where: { c in contains(c.e, n) || CFEqual(c.e, n.e) }) }
                    .flatMap { AX.value($0.e) }?.trimmingCharacters(in: .whitespacesAndNewlines)
                let p = WatchPrompt(question: question?.isEmpty == false ? question : nil,
                                    choices: labels.map { .init(label: $0) }, highlighted: nil, style: .pressed)
                return AXPrompt(prompt: p, presses: choices.map(\.e), submit: submit.e)
            }
        }

        // 2. Approval buttons side by side: one that says yes, one that says no, under one parent.
        let buttons = nodes.filter { $0.role == "AXButton" && !words($0.e).isEmpty }
        func starts(_ s: String, _ list: [String]) -> Bool { let l = s.lowercased(); return list.contains { l == $0 || l.hasPrefix($0 + " ") } }
        for b in buttons where starts(words(b.e), yesWords) {
            guard let parent = b.path.last else { continue }
            let row = buttons.filter { $0.path.last.map { CFEqual($0, parent) } ?? false }
            guard row.count >= 2, row.count <= 4, row.contains(where: { starts(words($0.e), noWords) }) else { continue }
            let p = WatchPrompt(question: nil, choices: row.map { .init(label: words($0.e)) }, highlighted: nil, style: .pressed)
            return AXPrompt(prompt: p, presses: row.map(\.e), submit: nil)
        }
        return nil
    }

    /// A choice's own words: its first line of text ("Option one"), not the description under it.
    private static func label(of e: AXUIElement, fallback: String) -> String {
        var queue = AX.elements(e, kAXChildrenAttribute)
        var seen = 0
        while !queue.isEmpty, seen < 40 {
            let n = queue.removeFirst()
            seen += 1
            if AX.role(n) == "AXStaticText", let v = AX.value(n)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
            queue += AX.elements(n, kAXChildrenAttribute)
        }
        return fallback
    }
}
