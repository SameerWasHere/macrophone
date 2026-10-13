import AppKit
import ApplicationServices
import Foundation

/// Finds the place to type in a window — the message box of a chat app, a terminal, a note's
/// body — through Accessibility. The rules (docs/TARGETS.md):
///   - a text area, text field or combo box that is visible, enabled, editable and not a
///     password field;
///   - not a search, filter or address box, and nothing in a toolbar (a lone search field
///     doesn't make an app a target);
///   - in a window with web content (Electron apps, browsers), only inputs inside the page
///     count — the browser's own address bar doesn't;
///   - the best one is the one the person last typed in, else one that says it's for messages
///     ("Message", "Prompt", "Reply"…), else the lowest and widest — chat apps keep the
///     composer at the bottom.
/// Every walk is bounded by a node count and a deadline.
enum ComposerFinder {
    struct Candidate {
        let element: AXUIElement
        let role: String
        let frame: CGRect
        let inWeb: Bool
        let hinted: Bool
        let score: Double
        /// It fills most of the window — an editor or a document, not a message box. Return
        /// there makes a new line, so "sent" can't be checked by the box emptying.
        let isDocument: Bool
        /// Counts as a reason to list the app: a multi-line area, a box that says it's for
        /// messages, or a wide field low in the window. A lone single-line field near the top
        /// (a name, a form) doesn't.
        let isComposer: Bool
    }

    struct Scan {
        var candidates: [Candidate] = []
        var nodes = 0
        var sawWebArea = false
        var ranOut = false
        var best: Candidate? { candidates.max { $0.score < $1.score } }
        var composer: Candidate? { candidates.filter(\.isComposer).max { $0.score < $1.score } }
    }

    static let hintWords = ["message", "prompt", "reply", "ask", "write", "chat", "compose", "comment", "send",
                            "type here", "talk", "imessage", "say something", "what's on your mind", "describe"]
    static let searchWords = ["search", "find", "filter", "jump to", "quick open", "go to", "command palette"]
    static let addressWords = ["address", "url", "location", "website name"]

    /// Roles whose subtrees never hold a composer (lists of messages, menus, tables, controls).
    private static let skipRoles: Set<String> = [
        "AXMenuBar", "AXMenu", "AXMenuItem", "AXTable", "AXOutline", "AXList", "AXBrowser", "AXRuler", "AXImage",
        "AXStaticText", "AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXScrollBar", "AXValueIndicator",
        "AXPopUpButton", "AXMenuButton", "AXLink", "AXIncrementor", "AXDisclosureTriangle", "AXSplitter",
        "AXProgressIndicator", "AXBusyIndicator", "AXLevelIndicator", "AXColorWell", "AXHeading", "AXCell", "AXRow",
    ]
    private static let skipSubroles: Set<String> = ["AXApplicationLog", "AXContentList"]

    /// Looks through one window. `focused` is the app's focused element (it scores higher);
    /// `remembered` is the input the person last typed in here (higher still).
    static func scan(window: AXUIElement, bundleID: String?, focused: AXUIElement? = nil,
                     remembered: AXUIElement? = nil, nodeLimit: Int = 2500, timeLimit: TimeInterval = 0.15) -> Scan {
        var out = Scan()
        let winFrame = AX.frame(window)
        guard winFrame.width > 40, winFrame.height > 40 else { return out }
        let deadline = Date().addingTimeInterval(timeLimit)
        var found: [(AXUIElement, String, Bool, Bool)] = [] // element, role, inWeb, inToolbar

        // Depth-first, bounded.
        var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
        while let (e, depth, inToolbar) = stack.popLast() {
            out.nodes += 1
            if out.nodes > nodeLimit || (out.nodes % 64 == 0 && Date() > deadline) { out.ranOut = true; break }
            let role = AX.role(e)
            if role == "AXWebArea" {
                out.sawWebArea = true
                if let inputs = webInputs(e) {
                    for i in inputs { found.append((i, AX.role(i), true, false)) }
                    continue
                }
                // No search support: fall through and walk it (bounded like the rest).
            }
            if AX.textRoles.contains(role) || role == "AXSecureTextField" {
                found.append((e, role, false, inToolbar))
                continue
            }
            if skipRoles.contains(role) || depth > 60 { continue }
            if skipSubroles.contains(AX.subrole(e)) { continue }
            let toolbar = inToolbar || role == "AXToolbar"
            let kids = AX.elements(e, kAXChildrenAttribute)
            for k in kids.reversed() { stack.append((k, depth + 1, toolbar)) }
        }

        let terminal = AppQuirks.isTerminal(bundleID)
        for (e, role, inWeb, inToolbar) in found {
            guard let c = evaluate(e, role: role, inWeb: inWeb, inToolbar: inToolbar, window: winFrame, terminal: terminal,
                                   focused: focused, remembered: remembered) else { continue }
            out.candidates.append(c)
        }
        // A window with web content: the browser's own fields (address bar, find bar) aren't
        // places to dictate into — only the page's are, plus any box that says it's for messages.
        if out.sawWebArea {
            out.candidates.removeAll { !$0.inWeb && !$0.hinted }
        }
        return out
    }

    private static func evaluate(_ e: AXUIElement, role: String, inWeb: Bool, inToolbar: Bool, window: CGRect, terminal: Bool,
                                 focused: AXUIElement?, remembered: AXUIElement?) -> Candidate? {
        if AX.isSecure(e) { return nil }
        let sub = AX.subrole(e)
        if role == "AXSearchField" || sub == "AXSearchField" { return nil }
        let f = AX.frame(e)
        guard f.width >= 40, f.height >= 10 else { return nil }
        let visible = f.intersection(window)
        guard !visible.isNull, visible.height >= 8, visible.width >= 30 else { return nil }
        if AX.optionalBool(e, kAXEnabledAttribute) == false { return nil }
        if AX.bool(e, "AXHidden") { return nil }

        let words = [AX.string(e, kAXDescriptionAttribute), AX.string(e, "AXPlaceholderValue"), AX.title(e),
                     AX.string(e, kAXHelpAttribute), AX.string(e, kAXIdentifierAttribute)]
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        let hinted = hintWords.contains { words.contains($0) }
        if addressWords.contains(where: { words.contains($0) }) { return nil }
        if searchWords.contains(where: { words.contains($0) }) && !hinted { return nil }
        if inToolbar && !hinted { return nil }

        // Editable? Web inputs found by the page's own search are; native ones must take a value
        // (a read-only text view, a label drawn as a field, doesn't). A terminal's screen counts.
        if !inWeb {
            let settable = AX.isSettable(e, kAXValueAttribute)
            if !settable && !(terminal && role == "AXTextArea") { return nil }
        }

        let isFocused = focused.map { CFEqual($0, e) } ?? false
        let isRemembered = remembered.map { CFEqual($0, e) } ?? false
        let rel = window.height > 0 ? Double((f.midY - window.minY) / window.height) : 0.5 // 0 top … 1 bottom
        let widthShare = window.width > 0 ? Double(f.width / window.width) : 0
        var score: Double = role == "AXTextArea" ? 3 : (role == "AXComboBox" ? 1 : 1.5)
        if hinted { score += 3 }
        if isFocused { score += 1.5 }
        if isRemembered { score += 5 }
        score += 2 * min(max(rel, 0), 1)
        score += min(1.5, widthShare * 1.5)
        let isDocument = f.height > window.height * 0.45 || (f.height * f.width) > window.height * window.width * 0.35
        let isComposer = role == "AXTextArea" || hinted || isRemembered || (widthShare >= 0.35 && rel >= 0.6)
        return Candidate(element: e, role: role, frame: f, inWeb: inWeb, hinted: hinted, score: score,
                         isDocument: isDocument, isComposer: isComposer)
    }

    /// Text inputs inside a web page, using the page's own search (WebKit and Chromium both
    /// answer it) — no walking thousands of nodes. Nil when the web area doesn't support it.
    static func webInputs(_ web: AXUIElement) -> [AXUIElement]? {
        let query: [String: Any] = ["AXSearchKey": "AXTextFieldSearchKey", "AXResultsLimit": 40,
                                    "AXDirection": "AXDirectionNext", "AXVisibleOnly": false]
        var res: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(web, "AXUIElementsForSearchPredicate" as CFString, query as CFTypeRef, &res)
        guard err == .success, let res else { return nil }
        return AX.elementList(res)
    }
}
