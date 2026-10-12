import AppKit
import ApplicationServices
import Foundation

/// Small, careful Accessibility helpers: every call has a short messaging timeout so a hung
/// app can't hang Macrophone, and nothing here walks more of a tree than it has to.
enum AX {
    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.6)
        return el
    }

    static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }
    static func bool(_ e: AXUIElement, _ name: String) -> Bool { (attr(e, name) as? Bool) ?? false }

    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ e: AXUIElement, _ name: String) -> [AXUIElement] {
        (attr(e, name) as? [AXUIElement]) ?? []
    }

    static func role(_ e: AXUIElement) -> String { string(e, kAXRoleAttribute) ?? "" }
    static func subrole(_ e: AXUIElement) -> String { string(e, kAXSubroleAttribute) ?? "" }
    static func title(_ e: AXUIElement) -> String { string(e, kAXTitleAttribute) ?? "" }

    static func frame(_ e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    static func set(_ e: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(e, name as CFString, value) == .success
    }

    static func isSettable(_ e: AXUIElement, _ name: String) -> Bool {
        var s: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(e, name as CFString, &s) == .success && s.boolValue
    }

    static func pid(of e: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        return pid
    }

    /// Electron/Chromium apps (Claude, Cursor, VS Code, Slack) only build their tree when asked.
    static func wakeWebContent(_ app: AXUIElement) {
        set(app, "AXManualAccessibility", kCFBooleanTrue)
    }

    // MARK: Focus

    static func systemFocused() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        return element(system, kAXFocusedUIElementAttribute)
    }

    static func focused(in app: AXUIElement) -> AXUIElement? { element(app, kAXFocusedUIElementAttribute) }

    /// A text input: a text role, or something web content marks editable.
    static func isTextInput(_ e: AXUIElement) -> Bool {
        let r = role(e)
        if r == "AXSecureTextField" || subrole(e) == (kAXSecureTextFieldSubrole as String) { return false }
        if textRoles.contains(r) { return true }
        return attr(e, "AXEditableAncestor") != nil && r != "AXStaticText"
    }

    /// The text of an input (nil when the app doesn't expose it).
    static func value(_ e: AXUIElement) -> String? { string(e, kAXValueAttribute) }

    /// The selected text in the app in front (for {{selection}}).
    static func selectedText(pid: pid_t) -> String? {
        let a = app(pid)
        guard let f = focused(in: a) ?? systemFocused() else { return nil }
        if let s = string(f, kAXSelectedTextAttribute), !s.isEmpty { return s }
        return nil
    }

    /// The front window's title (for {{window}}).
    static func frontWindowTitle(pid: pid_t) -> String? {
        let a = app(pid)
        guard let w = element(a, kAXFocusedWindowAttribute) ?? element(a, kAXMainWindowAttribute) else { return nil }
        let t = title(w)
        return t.isEmpty ? nil : t
    }

    // MARK: Walking

    /// Depth-first over a window, bounded, collecting text inputs.
    static func textInputs(in root: AXUIElement, limit: Int = 6000) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            visited += 1
            guard visited < limit, depth < 70 else { return }
            if isTextInput(e) && textRoles.contains(role(e)) { out.append(e); return }
            for c in elements(e, kAXChildrenAttribute) { walk(c, depth + 1) }
        }
        walk(root, 0)
        return out
    }

    // MARK: Windows

    static func windows(_ app: AXUIElement) -> [AXUIElement] { elements(app, kAXWindowsAttribute) }

    /// Raises the window whose title (or one of whose native tabs) contains `needle`, selecting
    /// the tab. Windows on another Space aren't visible to Accessibility.
    static func raiseWindow(in app: AXUIElement, matching needle: String) -> Bool {
        let n = needle.lowercased()
        let wins = windows(app)
        // Tabs first: a tab's title is the precise match; the window title only shows the selected tab.
        for w in wins {
            for button in tabButtons(in: w) where title(button).lowercased().contains(n) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
                raise(w, app: app)
                return true
            }
        }
        for w in wins where title(w).lowercased().contains(n) {
            raise(w, app: app)
            return true
        }
        return false
    }

    static func raise(_ w: AXUIElement, app: AXUIElement) {
        if bool(w, kAXMinimizedAttribute) { set(w, kAXMinimizedAttribute, kCFBooleanFalse) }
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        set(w, kAXMainAttribute, kCFBooleanTrue)
        set(w, kAXFocusedAttribute, kCFBooleanTrue)
    }

    /// The native tab bar's buttons (Terminal, Finder, any NSWindow tabbing).
    static func tabButtons(in window: AXUIElement) -> [AXUIElement] {
        for child in elements(window, kAXChildrenAttribute) where role(child) == "AXTabGroup" {
            return elements(child, kAXTabsAttribute).isEmpty
                ? elements(child, kAXChildrenAttribute).filter { role($0) == "AXRadioButton" }
                : elements(child, kAXTabsAttribute)
        }
        return []
    }

    static func focusedWindowTitle(_ app: AXUIElement) -> String {
        element(app, kAXFocusedWindowAttribute).map(title) ?? ""
    }

    /// Makes `pid` frontmost. macOS 14's cooperative activation ignores activate() from an app
    /// in the background; Accessibility's "frontmost" is honoured.
    static func bringToFront(_ running: NSRunningApplication) {
        let el = app(running.processIdentifier)
        set(el, kAXFrontmostAttribute, kCFBooleanTrue)
        running.activate()
    }
}

/// Finds and focuses the message box of a chat app.
enum Composer {
    /// The best message box in the app's focused window: a text area whose description or
    /// placeholder sounds like one, else the editable area lowest in the window (chat apps
    /// put the composer at the bottom), preferring wider ones.
    static func find(in app: AXUIElement, hints: [String]) -> AXUIElement? {
        guard let window = AX.element(app, kAXFocusedWindowAttribute) ?? AX.element(app, kAXMainWindowAttribute) else { return nil }
        let inputs = AX.textInputs(in: window).filter { AX.frame($0).width > 120 }
        guard !inputs.isEmpty else { return nil }
        func hinted(_ e: AXUIElement) -> Bool {
            let words = [AX.string(e, kAXDescriptionAttribute), AX.string(e, "AXPlaceholderValue"), AX.title(e),
                         AX.string(e, kAXHelpAttribute)].compactMap { $0?.lowercased() }.joined(separator: " ")
            return hints.contains { words.contains($0) }
        }
        let byHint = inputs.filter(hinted)
        let pool = byHint.isEmpty ? inputs : byHint
        return pool.max { a, b in
            let fa = AX.frame(a), fb = AX.frame(b)
            if abs(fa.maxY - fb.maxY) > 8 { return fa.maxY < fb.maxY }
            return fa.width < fb.width
        }
    }

    /// Focuses `composer` unless focus is already inside it. Returns true when the app's
    /// focused element is now a text input.
    static func focus(_ composer: AXUIElement, in app: AXUIElement) async -> Bool {
        if let f = AX.focused(in: app), CFEqual(f, composer) { return true }
        AX.set(composer, kAXFocusedAttribute, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 140_000_000)
        if let f = AX.focused(in: app) {
            return CFEqual(f, composer) || AX.isTextInput(f)
        }
        return false
    }

    /// Letters and digits only, lowercased — for comparing what we pasted with what an app
    /// shows (rich editors reflow whitespace and punctuation).
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// A short, distinctive piece of what we pasted, to look for in the box.
    static func probe(_ text: String) -> String {
        String(normalize(text).prefix(24))
    }
}
