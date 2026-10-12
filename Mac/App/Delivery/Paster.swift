import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Why a paste didn't happen. Each case has the words the popup shows and what fixes it.
enum PasteFailure: Error, Equatable {
    case accessibilityMissing
    case secureField(app: String)
    case appUnavailable(name: String)
    case appDidNotActivate(name: String)
    /// A profile names a window/tab ("claude") and none matches — nothing was pasted.
    case windowNotFound(app: String, match: String)
    /// The text never showed up in the app's message box (nothing was sent).
    case notLanded(app: String)

    var title: String {
        switch self {
        case .accessibilityMissing: return "Macrophone needs Accessibility to paste"
        case .secureField: return "Not pasted — a password field is active"
        case .appUnavailable(let n): return "Couldn't find \(n)"
        case .appDidNotActivate(let n): return "\(n) didn't come to the front"
        case .windowNotFound(let app, let m): return "No \(app) \(app == "Terminal" || app == "iTerm2" ? "tab" : "window") matching “\(m)”"
        case .notLanded(let app): return "Didn't send — \(app)'s message box wasn't focused"
        }
    }

    var detail: String {
        switch self {
        case .accessibilityMissing:
            return "It's on your clipboard. Allow Macrophone in Privacy & Security › Accessibility, then try again."
        case .secureField(let app):
            return "\(app) is taking a password or has Secure Keyboard Entry on. It's on your clipboard instead."
        case .appUnavailable(let n):
            return "\(n) isn't installed anymore. It's on your clipboard — pick another app in the profile."
        case .appDidNotActivate(let n):
            return "\(n) may be busy or showing a dialog. It's on your clipboard."
        case .windowNotFound(let app, _):
            return "Nothing was pasted, so nothing went anywhere unexpected. Open \(app == "Terminal" || app == "iTerm2" ? "the tab" : "the window") on this desktop and try again — it's on your clipboard."
        case .notLanded(let app):
            return "It's on your clipboard. Click in \(app)'s message box and press ⌘V, or try again."
        }
    }

    var opensAccessibilitySettings: Bool { self == .accessibilityMissing }
}

/// The paste. Puts the text on the clipboard as a transient, concealed item (clipboard
/// managers skip it), presses ⌘V, optionally Return, then puts back exactly what was on the
/// clipboard before — every item and every type — unless something else changed it meanwhile.
@MainActor
enum Paster {
    struct Result {
        var appName: String
        var bundleID: String?
        var pressedEnter: Bool
        /// Set when Return was asked for but not pressed, e.g. "Return skipped — Notes isn't on your list".
        var enterNote: String?
        /// We saw the message box empty out after the send key (or keep the text when not sending).
        var confirmed = false
        /// The send key went out but the text stayed in the box.
        var sendDidNotClear = false
    }

    enum Target: Equatable {
        case focused
        case app(bundleID: String, name: String)
    }

    /// Everything one paste needs to know.
    struct Request {
        var text: String
        var target: Target
        /// Raise the window/tab whose title (or, in Terminal, running program) contains this.
        var windowMatch: String?
        /// The profile asks for the send key after pasting.
        var send: Bool
        var sendKey: SendKey = .return
        /// Bring back the app that was in front once it's sent.
        var returnToPrevious = false
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (only call when the person turns on a pasting mode).
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let notificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    /// Kept for callers that only paste into the app in front.
    static func paste(_ text: String, target: Target, pressEnter: Bool, allowsEnter: (String?) -> Bool) async throws -> Result {
        try await deliver(Request(text: text, target: target, windowMatch: nil, send: pressEnter), allowsEnter: allowsEnter)
    }

    /// The paste, start to finish:
    ///   1. the right app (and window or tab) in front,
    ///   2. the message box focused (chat apps),
    ///   3. never into a password field,
    ///   4. ⌘V, then check the words showed up,
    ///   5. the send key — only in allowlisted apps — then check the box emptied,
    ///   6. the clipboard put back, and optionally the previous app.
    static func deliver(_ req: Request, allowsEnter: (String?) -> Bool) async throws -> Result {
        guard isTrusted else { throw PasteFailure.accessibilityMissing }
        let previous = NSWorkspace.shared.frontmostApplication

        // 1. The right app, window and tab in front.
        var spec: TargetSpec?
        if case let .app(bundleID, name) = req.target {
            spec = TargetCatalog.spec(for: bundleID) ?? TargetCatalog.generic(bundleID: bundleID, name: name)
            try await bringToFront(bundleID: bundleID, name: name, windowMatch: req.windowMatch, spec: spec!)
        } else {
            spec = TargetCatalog.spec(for: previous?.bundleIdentifier)
        }
        let front = NSWorkspace.shared.frontmostApplication
        let appName = (spec?.id.hasPrefix("app:") == false ? spec?.name : nil) ?? front?.localizedName ?? "the app"
        let axApp = front.map { AX.app($0.processIdentifier) }

        // 2. The message box (chat apps): find it and focus it.
        var box: AXUIElement?
        if let axApp, let spec, spec.composer == .chatInput {
            AX.wakeWebContent(axApp)
            box = Composer.find(in: axApp, hints: spec.composerHints)
            if box == nil {
                // Chromium builds its tree on the first request; give it a moment.
                try await Task.sleep(nanoseconds: 250_000_000)
                box = Composer.find(in: axApp, hints: spec.composerHints)
            }
            if let b = box { _ = await Composer.focus(b, in: axApp) }
        }
        let focused = axApp.flatMap { AX.focused(in: $0) }
        let probe = Composer.probe(req.text)
        // What we'll read back: the message box, else whatever has focus.
        let readBack = box ?? focused
        let before = readBack.flatMap(AX.value).map(Composer.normalize) ?? ""
        func landed() -> Bool? {
            guard !probe.isEmpty, let e = readBack ?? axApp.flatMap({ AX.focused(in: $0) }), let v = AX.value(e) else { return nil }
            let now = Composer.normalize(v)
            // A box that already held these words before doesn't count.
            return now.contains(probe) && (!before.contains(probe) || now.count > before.count)
        }

        // 3. Never into a password field.
        if SecureInput.isActive(frontPID: front?.processIdentifier) || SecureInput.focusedElementIsSecure() {
            throw PasteFailure.secureField(app: appName)
        }

        // 4. Our words on the clipboard, the old contents kept aside; ⌘V.
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot(pb)
        let ours = writeTransient(req.text, to: pb)
        try await Task.sleep(nanoseconds: 40_000_000)
        Keys.press(Keys.code(for: "v") ?? CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        try await Task.sleep(nanoseconds: (spec?.pasteSettle ?? 320) * 1_000_000)

        var didLand = landed()
        if didLand == false {
            // Rich editors can take a beat longer.
            try await Task.sleep(nanoseconds: 300_000_000)
            didLand = landed()
        }
        if spec?.composer == .chatInput, didLand == false {
            // The words aren't in the box: leave them on the clipboard and send nothing.
            Paster.copy(req.text)
            throw PasteFailure.notLanded(app: appName)
        }

        // 5. The send key, if asked and allowed.
        var result = Result(appName: appName, bundleID: front?.bundleIdentifier, pressedEnter: false)
        if req.send {
            if !allowsEnter(front?.bundleIdentifier) {
                result.enterNote = "Return skipped — \(appName) isn't on your Return list"
            } else if didLand == false && spec?.composer != .terminal {
                result.enterNote = "Didn't send — the words didn't show up where the cursor was"
            } else {
                Keys.press(CGKeyCode(kVK_Return), flags: req.sendKey == .commandReturn ? .maskCommand : [])
                result.pressedEnter = true
                if didLand == true, readBack != nil, let axApp, let spec, spec.composer == .chatInput {
                    // Did the box empty out? Chat apps often swap the whole view when a new
                    // conversation starts, so a box that's gone counts too — then look again
                    // for whichever message box is there now.
                    var cleared = false
                    for _ in 0..<10 {
                        try await Task.sleep(nanoseconds: 130_000_000)
                        // The box on screen now (a new conversation may have replaced the old one).
                        if let fresh = Composer.find(in: axApp, hints: spec.composerHints).flatMap(AX.value) {
                            if !Composer.normalize(fresh).contains(probe) { cleared = true; break }
                            continue
                        }
                        let old = readBack.flatMap(AX.value).map(Composer.normalize)
                        if old?.contains(probe) != true { cleared = true; break }
                    }
                    result.confirmed = cleared
                    result.sendDidNotClear = !cleared
                }
            }
        } else {
            result.confirmed = didLand == true
        }

        // 6. Put the clipboard back once the paste has landed — unless the person (or the
        //    app) put something new there in the meantime.
        try await Task.sleep(nanoseconds: result.pressedEnter ? 500_000_000 : 700_000_000)
        if pb.changeCount == ours { saved.restore(to: pb) }

        if req.returnToPrevious, let previous, previous.bundleIdentifier != front?.bundleIdentifier, !previous.isTerminated {
            AX.bringToFront(previous)
        }
        return result
    }

    /// Plain copy that stays on the clipboard (clipboard modes, delayed items, fallbacks).
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @discardableResult
    private static func writeTransient(_ text: String, to pb: NSPasteboard) -> Int {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org conventions: clipboard managers don't record these.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])
        return pb.changeCount
    }

    private static func bringToFront(bundleID: String, name: String, windowMatch: String?, spec: TargetSpec) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw PasteFailure.appUnavailable(name: name)
        }
        let needle = windowMatch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if running == nil {
            // A named window can't exist in an app that isn't running.
            if !needle.isEmpty { throw PasteFailure.windowNotFound(app: name, match: needle) }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            running = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            // Let a freshly launched app put up its window.
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }

        // The window or tab first, so activating the app brings the right one.
        if !needle.isEmpty, let running {
            var found = false
            var matching = spec.windowMatching
            #if DEBUG
            if ProcessInfo.processInfo.environment["MACROPHONE_NO_APPLESCRIPT"] == "1" { matching = .titles }
            #endif
            switch matching {
            case .terminalApp:
                if await Scripting.permissionAsync(bundleID, ask: false) == .granted {
                    found = (try? await Scripting.selectTerminalTab(matching: needle)) ?? false
                }
            case .iTerm:
                if await Scripting.permissionAsync(bundleID, ask: false) == .granted {
                    found = (try? await Scripting.selectITermSession(matching: needle)) ?? false
                }
            case .titles:
                break
            }
            if !found {
                let ax = AX.app(running.processIdentifier)
                AX.wakeWebContent(ax)
                found = AX.raiseWindow(in: ax, matching: needle)
            }
            if !found { throw PasteFailure.windowNotFound(app: name, match: needle) }
        }

        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID {
            if let running { AX.bringToFront(running) }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        // Wait for it to be frontmost (launching can take a few seconds).
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                // Let its window become key before the keystrokes arrive.
                try await Task.sleep(nanoseconds: spec.activationSettle * 1_000_000)
                if !needle.isEmpty, let running {
                    // Re-raise: activation can bring a different window of the app forward.
                    let ax = AX.app(running.processIdentifier)
                    if !AX.focusedWindowTitle(ax).lowercased().contains(needle.lowercased()), spec.windowMatching == .titles {
                        _ = AX.raiseWindow(in: ax, matching: needle)
                        try await Task.sleep(nanoseconds: 120_000_000)
                    }
                }
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw PasteFailure.appDidNotActivate(name: name)
    }
}

/// Everything on the clipboard, every item and type, so it can be put back exactly.
struct PasteboardSnapshot {
    private var items: [[(NSPasteboard.PasteboardType, Data)]] = []

    init(_ pb: NSPasteboard) {
        for item in pb.pasteboardItems ?? [] {
            var entry: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) { entry.append((type, data)) }
            }
            if !entry.isEmpty { items.append(entry) }
        }
    }

    var isEmpty: Bool { items.isEmpty }

    func restore(to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let objects: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(objects)
    }
}

/// Synthetic keystrokes.
enum Keys {
    static func press(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        // Set the flags explicitly so a key the person happens to be holding (⌥, ⇧) can't
        // turn ⌘V into something else.
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(8_000)
        up?.post(tap: .cghidEventTap)
    }

    /// The key that types `character` with ⌘ held on the current layout (Dvorak, AZERTY,
    /// "Dvorak – QWERTY ⌘" all differ). Nil = fall back to the ANSI position.
    static func code(for character: String) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let target = character.lowercased()
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let modifiers = UInt32((cmdKey >> 8) & 0xFF)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}

/// Password-field detection.
enum SecureInput {
    /// Secure Event Input is on and it belongs to the app in front (another app's password
    /// field — e.g. a password manager in the background — doesn't count).
    static func isActive(frontPID: pid_t?) -> Bool {
        guard IsSecureEventInputEnabled() else { return false }
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let owner = dict["kCGSSessionSecureInputPID"] as? Int, let frontPID {
            return pid_t(owner) == frontPID
        }
        return true
    }

    /// The focused element is a secure text field (AXSecureTextField).
    static func focusedElementIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        let el = element as! AXUIElement
        func attr(_ name: String) -> String? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
            return v as? String
        }
        let secure = kAXSecureTextFieldSubrole as String
        return attr(kAXSubroleAttribute) == secure || attr(kAXRoleAttribute) == secure
    }
}
