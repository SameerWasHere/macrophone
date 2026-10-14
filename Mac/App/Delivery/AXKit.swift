import AppKit
import ApplicationServices
import Foundation

/// Small, careful Accessibility helpers: every call has a short messaging timeout so a hung
/// app can't hang Macrophone, every value is type-checked before it's used (some apps put
/// things that aren't AX elements in their child lists), and nothing here walks more of a tree
/// than it has to. Safe to call from any thread.
enum AX {
    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    /// Process-wide default: no single Accessibility request may take longer than this.
    static func setGlobalTimeout(_ seconds: Float = 0.4) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.6)
        return el
    }

    static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? {
        guard let v = attr(e, name), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return v as? String
    }

    static func bool(_ e: AXUIElement, _ name: String) -> Bool { optionalBool(e, name) ?? false }

    static func optionalBool(_ e: AXUIElement, _ name: String) -> Bool? {
        guard let v = attr(e, name) else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return CFBooleanGetValue((v as! CFBoolean)) }
        if CFGetTypeID(v) == CFNumberGetTypeID() { return (v as? NSNumber)?.boolValue }
        return nil
    }

    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// An attribute holding a list of elements. Anything in the list that isn't an AX element is
    /// skipped (a bridged cast would trap on it).
    static func elements(_ e: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let v = attr(e, name) else { return [] }
        return elementList(v)
    }

    static func elementList(_ v: CFTypeRef) -> [AXUIElement] {
        guard CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        let arr = v as! CFArray
        let n = CFArrayGetCount(arr)
        var out: [AXUIElement] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let p = CFArrayGetValueAtIndex(arr, i) else { continue }
            let o = Unmanaged<CFTypeRef>.fromOpaque(p).takeUnretainedValue()
            if CFGetTypeID(o) == AXUIElementGetTypeID() { out.append(o as! AXUIElement) }
        }
        return out
    }

    static func role(_ e: AXUIElement) -> String { string(e, kAXRoleAttribute) ?? "" }
    static func subrole(_ e: AXUIElement) -> String { string(e, kAXSubroleAttribute) ?? "" }
    static func title(_ e: AXUIElement) -> String { string(e, kAXTitleAttribute) ?? "" }

    static func frame(_ e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = attr(e, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = attr(e, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgSize, &s) }
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

    /// Still there? (A destroyed element answers nothing.)
    static func isAlive(_ e: AXUIElement) -> Bool {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v)
        return err == .success
    }

    /// Electron/Chromium apps (Claude, Cursor, VS Code, Slack, Chrome) only build their tree when
    /// asked. Returns true when the app took the request (it's a Chromium app).
    @discardableResult
    static func wakeWebContent(_ app: AXUIElement) -> Bool {
        set(app, "AXManualAccessibility", kCFBooleanTrue)
    }

    // MARK: Focus

    static func focused(in app: AXUIElement) -> AXUIElement? { element(app, kAXFocusedUIElementAttribute) }

    static func isSecure(_ e: AXUIElement) -> Bool {
        role(e) == "AXSecureTextField" || subrole(e) == (kAXSecureTextFieldSubrole as String)
    }

    /// A text input: a text role, or something web content marks editable.
    static func isTextInput(_ e: AXUIElement) -> Bool {
        if isSecure(e) { return false }
        let r = role(e)
        if textRoles.contains(r) { return true }
        if r == "AXStaticText" || r == "AXImage" || r == "AXButton" { return false }
        return element(e, "AXEditableAncestor") != nil
    }

    /// The text of an input (nil when the app doesn't expose it).
    static func value(_ e: AXUIElement) -> String? { string(e, kAXValueAttribute) }

    // MARK: Windows

    static func windows(_ app: AXUIElement) -> [AXUIElement] { elements(app, kAXWindowsAttribute) }

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindowFn: GetWindowFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    /// The window server's id for an AX window — stable for the window's life, and the same id
    /// `CGWindowListCopyWindowInfo` reports (so a window on another desktop can still be found).
    static func windowID(_ w: AXUIElement) -> CGWindowID? {
        guard let f = getWindowFn else { return nil }
        var id: CGWindowID = 0
        return f(w, &id) == .success && id != 0 ? id : nil
    }

    /// The AX window with this window-server id, among the app's windows on this desktop.
    static func window(in app: AXUIElement, id: CGWindowID) -> AXUIElement? {
        windows(app).first { windowID($0) == id }
    }

    /// The window an element sits in.
    static func window(of e: AXUIElement) -> AXUIElement? {
        element(e, kAXWindowAttribute) ?? element(e, kAXTopLevelUIElementAttribute)
    }

    static func raise(_ w: AXUIElement, app: AXUIElement) {
        if bool(w, kAXMinimizedAttribute) { set(w, kAXMinimizedAttribute, kCFBooleanFalse) }
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        set(w, kAXMainAttribute, kCFBooleanTrue)
        set(w, kAXFocusedAttribute, kCFBooleanTrue)
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

/// Comparing what was pasted with what an app shows.
enum Composer {
    /// Letters and digits only, lowercased — rich editors reflow whitespace and punctuation.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// A short, distinctive piece of what we pasted, to look for in the box.
    static func probe(_ text: String) -> String {
        String(normalize(text).prefix(24))
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
}
