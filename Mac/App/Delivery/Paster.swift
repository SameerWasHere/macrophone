import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Why a paste didn't happen. Each case has the words the popup shows and what fixes it.
enum PasteFailure: Error, Equatable {
    case accessibilityMissing
    case secureField(app: String)
    /// The app picked under Send to isn't running.
    case appNotOpen(name: String)
    /// The window picked under Send to has closed.
    case windowGone(app: String, window: String?)
    case appDidNotActivate(name: String)
    /// Nothing to type into: no text field in front ("Where I'm typing"), or none found in the app.
    case nowhereToType(app: String)
    /// The words never showed up in the message box (nothing was sent).
    case notLanded(app: String)

    var title: String {
        switch self {
        case .accessibilityMissing: return "Macrophone needs Accessibility to paste"
        case .secureField: return "Not pasted — a password field is active"
        case .appNotOpen(let n): return "\(n) isn't open — copied instead"
        case let .windowGone(app, w):
            if let w, !w.isEmpty { return "That \(app) window (“\(w)”) is closed — copied instead" }
            return "That \(app) window is closed — copied instead"
        case .appDidNotActivate(let n): return "\(n) didn't come to the front"
        case .nowhereToType(let app): return "Nowhere to type in \(app) — copied instead"
        case .notLanded(let app): return "Didn't send — it didn't land in \(app)'s message box"
        }
    }

    var detail: String {
        switch self {
        case .accessibilityMissing:
            return "It's on your clipboard. Allow Macrophone in Privacy & Security › Accessibility, then try again."
        case .secureField(let app):
            return "\(app) is taking a password or has Secure Keyboard Entry on. It's on your clipboard instead."
        case .appNotOpen(let n):
            return "It's on your clipboard. Open \(n) and choose Try Again, or pick another place under Send to."
        case .windowGone:
            return "It's on your clipboard. Pick another window under Send to, or press ⌘V where you want it."
        case .appDidNotActivate(let n):
            return "\(n) may be busy or showing a dialog. It's on your clipboard."
        case .nowhereToType(let app):
            return "It's on your clipboard. Click in a text field in \(app) and choose Try Again, or press ⌘V."
        case .notLanded(let app):
            return "It's on your clipboard. Click in \(app)'s message box and press ⌘V, or try again."
        }
    }

    /// The text was copied instead of going to a place that isn't there right now.
    var copiedInstead: Bool {
        switch self {
        case .appNotOpen, .windowGone, .nowhereToType: return true
        default: return false
        }
    }

    var opensAccessibilitySettings: Bool { self == .accessibilityMissing }
}

/// The paste. Brings the target forward (its window, on any desktop), finds the place to type
/// (ComposerFinder), puts the text on the clipboard as a transient, concealed item (clipboard
/// managers skip it), presses ⌘V, checks the words arrived, optionally presses the app's send
/// key and checks the box emptied, then puts back exactly what was on the clipboard before —
/// every item and every type — unless something else changed it meanwhile.
@MainActor
enum Paster {
    struct Result {
        var appName: String
        var bundleID: String?
        var pressedSend = false
        var sendKey: SendKey = .return
        /// We saw the message box empty out after the send key.
        var confirmedSent = false
        /// The send key went out but the text stayed in the box.
        var stillInBox = false
        /// The words were seen in the box (nil = couldn't be read back, e.g. a terminal).
        var landed: Bool?
    }

    enum Target: Equatable {
        /// The app in front, where the cursor is ("Where I'm typing").
        case front
        /// A live target: an app, or one of its windows (`windowKey` = its window-server id).
        case app(bundleID: String, windowKey: String?, name: String)
    }

    struct Request {
        var text: String
        var target: Target
        /// Press the app's send key after pasting (the phone chose "Paste & send").
        var send: Bool
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (only call when the person turns pasting on).
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let notificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    /// The app or window is gone before anything starts (so the popup says so at once).
    static func precheck(_ t: Target) -> PasteFailure? {
        guard case let .app(bundleID, windowKey, name) = t else { return nil }
        guard let r = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }) else {
            return .appNotOpen(name: installedName(bundleID) ?? appName(fromTitle: name))
        }
        if let windowKey, let id = CGWindowID(windowKey), !WindowServer.exists(id) {
            let w = name.components(separatedBy: " — ").dropFirst().joined(separator: " — ")
            return .windowGone(app: r.localizedName ?? appName(fromTitle: name), window: w.isEmpty ? nil : w)
        }
        return nil
    }

    /// The name Finder shows for an installed app ("Notes"), for a target that isn't running.
    static func installedName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        var n = FileManager.default.displayName(atPath: url.path)
        if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
        return n.isEmpty ? nil : n
    }

    /// "Terminal — claude" → "Terminal".
    static func appName(fromTitle name: String) -> String {
        name.components(separatedBy: " — ").first ?? name
    }

    /// The paste, start to finish:
    ///   1. the right app and window in front (launching nothing — a closed app is copied instead),
    ///   2. the place to type found and focused,
    ///   3. never into a password field,
    ///   4. ⌘V, then check the words showed up,
    ///   5. the send key if asked, then check the box emptied,
    ///   6. the clipboard put back.
    static func deliver(_ req: Request, scanner: TargetScanner) async throws -> Result {
        guard isTrusted else { throw PasteFailure.accessibilityMissing }

        // 1. The app (and window) in front.
        let running: NSRunningApplication
        var window: AXUIElement?
        var remembered: AXUIElement?
        switch req.target {
        case .front:
            guard let f = NSWorkspace.shared.frontmostApplication else { throw PasteFailure.nowhereToType(app: "the app in front") }
            if f.bundleIdentifier == Bundle.main.bundleIdentifier { throw PasteFailure.nowhereToType(app: "Macrophone") }
            running = f
        case let .app(bundleID, windowKey, name):
            guard let r = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }) else {
                throw PasteFailure.appNotOpen(name: installedName(bundleID) ?? appName(fromTitle: name))
            }
            running = r
            let appTitle = r.localizedName ?? appName(fromTitle: name)
            let hints = await scanner.hints(for: r.processIdentifier)
            var wid: CGWindowID?
            if let windowKey, let id = CGWindowID(windowKey) {
                guard WindowServer.exists(id) else {
                    let w = name.components(separatedBy: " — ").dropFirst().joined(separator: " — ")
                    throw PasteFailure.windowGone(app: appTitle, window: w.isEmpty ? nil : w)
                }
                wid = id
            } else {
                // The app: the window the person last typed in, else its front-most one with
                // somewhere to type.
                let ids = hints.windows.map(\.id)
                if let last = hints.lastWindow, ids.contains(last) || ids.isEmpty, WindowServer.exists(last) { wid = last }
                else { wid = ids.first }
            }
            window = try await bringToFront(r, windowID: wid, required: windowKey != nil, name: appTitle)
            if let rw = hints.rememberedWindow, rw == wid { remembered = hints.rememberedElement }
        }

        let bid = running.bundleIdentifier
        let appName = running.localizedName ?? "the app"
        let ax = AX.app(running.processIdentifier)
        let terminal = AppQuirks.isTerminal(bid)
        let hiddenComposer = bid.map(AppQuirks.hiddenComposer.contains) ?? false
        let chromium = bid.map { AppQuirks.isChromium(bundleID: $0, url: running.bundleURL) } ?? false
        if chromium { AX.wakeWebContent(ax) }

        // 2. Where to type.
        var box: AXUIElement?
        var isDocument = false
        if !terminal && !hiddenComposer {
            switch req.target {
            case .front:
                var f = AX.focused(in: ax)
                if f == nil && chromium {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    f = AX.focused(in: ax)
                }
                if let f {
                    // Something has focus and it isn't a text field (a list, the desktop, a button).
                    guard AX.isTextInput(f) else { throw PasteFailure.nowhereToType(app: appName) }
                    box = f
                }
                // Nil: the app doesn't say what has focus — paste where the cursor is.
            case .app:
                let win = window ?? AX.element(ax, kAXFocusedWindowAttribute)
                let focused = AX.focused(in: ax)
                // The input the person last typed in wins — but only while it's still a visible
                // place to type in this window (a chat app may have moved on to another view).
                let rem = remembered.flatMap { AX.isAlive($0) ? $0 : nil }
                if let win {
                    var scan = ComposerFinder.scan(window: win, bundleID: bid, focused: focused, remembered: rem, timeLimit: 0.5)
                    if scan.composer == nil && chromium {
                        try await Task.sleep(nanoseconds: 300_000_000)
                        scan = ComposerFinder.scan(window: win, bundleID: bid, focused: AX.focused(in: ax), remembered: rem, timeLimit: 0.5)
                    }
                    if let c = scan.composer { box = c.element; isDocument = c.isDocument }
                }
                if box == nil, let f = focused, AX.isTextInput(f), let win, let fw = AX.window(of: f), CFEqual(fw, win) { box = f }
                guard let b = box else { throw PasteFailure.nowhereToType(app: appName) }
                if !isDocument, let win { isDocument = isLarge(b, in: win) }
                _ = await Composer.focus(b, in: ax)
            }
        }

        // 3. Never into a password field.
        if SecureInput.isActive(frontPID: running.processIdentifier) || SecureInput.focusedElementIsSecure() {
            throw PasteFailure.secureField(app: appName)
        }

        // 4. Our words on the clipboard, the old contents kept aside; ⌘V.
        let probe = Composer.probe(req.text)
        let readBack = terminal ? nil : box
        let before = readBack.flatMap(AX.value).map(Composer.normalize) ?? ""
        func landed() -> Bool? {
            guard !probe.isEmpty, let e = readBack, let v = AX.value(e) else { return nil }
            let now = Composer.normalize(v)
            // A box that already held these words before doesn't count.
            return now.contains(probe) && (!before.contains(probe) || now.count > before.count)
        }
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot(pb)
        let ours = writeTransient(req.text, to: pb)
        try await Task.sleep(nanoseconds: 40_000_000)
        Keys.press(Keys.code(for: "v") ?? CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        try await Task.sleep(nanoseconds: AppQuirks.pasteSettle(bid) * 1_000_000)

        var didLand = landed()
        if didLand == false {
            // Rich editors can take a beat longer.
            try await Task.sleep(nanoseconds: 350_000_000)
            didLand = landed()
        }
        if didLand == false {
            // The words aren't in the box: leave them on the clipboard and send nothing.
            Paster.copy(req.text)
            throw PasteFailure.notLanded(app: appName)
        }

        // 5. The send key.
        var result = Result(appName: appName, bundleID: bid, landed: didLand)
        if req.send {
            let key = AppQuirks.sendKey(for: bid)
            result.sendKey = key
            switch key {
            case .return: Keys.press(CGKeyCode(kVK_Return), flags: [])
            case .commandReturn: Keys.press(CGKeyCode(kVK_Return), flags: .maskCommand)
            case .commandShiftD: Keys.press(Keys.code(for: "d") ?? CGKeyCode(kVK_ANSI_D), flags: [.maskCommand, .maskShift])
            }
            result.pressedSend = true
            if didLand == true, let box, !isDocument {
                // Did the box empty out? Chat apps often swap the whole view when a new
                // conversation starts, so a box that's gone counts too — then look again for
                // whichever message box is there now.
                var cleared = false
                for _ in 0..<10 {
                    try await Task.sleep(nanoseconds: 130_000_000)
                    if AX.isAlive(box), let v = AX.value(box) {
                        if !Composer.normalize(v).contains(probe) { cleared = true; break }
                        continue
                    }
                    if let win = AX.element(ax, kAXFocusedWindowAttribute),
                       let fresh = ComposerFinder.scan(window: win, bundleID: bid, timeLimit: 0.2).composer.flatMap({ AX.value($0.element) }) {
                        if !Composer.normalize(fresh).contains(probe) { cleared = true; break }
                        continue
                    }
                    cleared = true
                    break
                }
                result.confirmedSent = cleared
                result.stillInBox = !cleared
            }
        }

        // 6. Put the clipboard back once the paste has landed — unless the person (or the
        //    app) put something new there in the meantime.
        try await Task.sleep(nanoseconds: result.pressedSend ? 500_000_000 : 700_000_000)
        if pb.changeCount == ours { saved.restore(to: pb) }
        return result
    }

    /// An editor or document (most of the window), not a message box.
    private static func isLarge(_ e: AXUIElement, in window: AXUIElement) -> Bool {
        let f = AX.frame(e), w = AX.frame(window)
        guard w.height > 0 else { return false }
        return f.height > w.height * 0.45
    }

    /// Plain copy that stays on the clipboard (the Clipboard target, delayed items, fallbacks).
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

    /// Brings the app forward with this window on top (switching desktops if that's where it
    /// is) and returns the window.
    private static func bringToFront(_ running: NSRunningApplication, windowID: CGWindowID?, required: Bool, name: String) async throws -> AXUIElement? {
        let ax = AX.app(running.processIdentifier)
        let bid = running.bundleIdentifier
        // Raise the window first, so activating the app brings this one.
        if let windowID, let w = AX.window(in: ax, id: windowID) { AX.raise(w, app: ax) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier {
            AX.bringToFront(running)
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier, let url = running.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        let deadline = Date().addingTimeInterval(5)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier {
            if Date() > deadline { throw PasteFailure.appDidNotActivate(name: name) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // Let its window become key before the keystrokes arrive.
        try await Task.sleep(nanoseconds: AppQuirks.activationSettle(bid) * 1_000_000)
        guard let windowID else {
            // Running with every window closed (Messages after ⌘W): ask it to reopen one, the
            // way clicking its Dock icon does.
            if AX.element(ax, kAXFocusedWindowAttribute) == nil, let url = running.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                for _ in 0..<15 where AX.element(ax, kAXFocusedWindowAttribute) == nil {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try await Task.sleep(nanoseconds: AppQuirks.activationSettle(bid) * 1_000_000)
            }
            return AX.element(ax, kAXFocusedWindowAttribute)
        }
        // On another desktop it shows up once the switch has happened; activation may also have
        // brought a different window of the app forward.
        var w = AX.window(in: ax, id: windowID)
        var tries = 0
        while w == nil && tries < 12 {
            try await Task.sleep(nanoseconds: 100_000_000)
            w = AX.window(in: ax, id: windowID)
            tries += 1
        }
        guard let w else {
            // A window picked by name that can't be brought forward: don't paste into another one.
            if required { throw PasteFailure.windowGone(app: name, window: nil) }
            return AX.element(ax, kAXFocusedWindowAttribute)
        }
        if let focused = AX.element(ax, kAXFocusedWindowAttribute), AX.windowID(focused) != windowID {
            AX.raise(w, app: ax)
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        return w
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
