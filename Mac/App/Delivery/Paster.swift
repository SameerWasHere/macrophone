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

    var title: String {
        switch self {
        case .accessibilityMissing: return "Macrophone needs Accessibility to paste"
        case .secureField: return "Not pasted — a password field is active"
        case .appUnavailable(let n): return "Couldn't find \(n)"
        case .appDidNotActivate(let n): return "\(n) didn't come to the front"
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
    }

    enum Target: Equatable {
        case focused
        case app(bundleID: String, name: String)
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

    static func paste(_ text: String, target: Target, pressEnter: Bool, allowsEnter: (String?) -> Bool) async throws -> Result {
        guard isTrusted else { throw PasteFailure.accessibilityMissing }

        // 1. The right app in front.
        if case let .app(bundleID, name) = target {
            try await bringToFront(bundleID: bundleID, name: name)
        }
        let front = NSWorkspace.shared.frontmostApplication
        let appName = front?.localizedName ?? "the app"

        // 2. Never into a password field.
        if SecureInput.isActive(frontPID: front?.processIdentifier) || SecureInput.focusedElementIsSecure() {
            throw PasteFailure.secureField(app: appName)
        }

        // 3. Our words on the clipboard, the old contents kept aside.
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot(pb)
        let ours = writeTransient(text, to: pb)

        // 4. ⌘V, then Return if asked and allowed.
        try await Task.sleep(nanoseconds: 40_000_000)
        Keys.press(Keys.code(for: "v") ?? CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        var pressedEnter = false
        var note: String?
        if pressEnter {
            if allowsEnter(front?.bundleIdentifier) {
                // Give the app time to take the paste before the Return arrives.
                try await Task.sleep(nanoseconds: 320_000_000)
                Keys.press(CGKeyCode(kVK_Return), flags: [])
                pressedEnter = true
            } else {
                note = "Return skipped — \(appName) isn't on your Return list"
            }
        }

        // 5. Put the clipboard back once the paste has landed — unless the person (or the
        //    app) put something new there in the meantime.
        try await Task.sleep(nanoseconds: pressedEnter ? 700_000_000 : 900_000_000)
        if pb.changeCount == ours { saved.restore(to: pb) }

        return Result(appName: appName, bundleID: front?.bundleIdentifier, pressedEnter: pressedEnter, enterNote: note)
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

    private static func bringToFront(bundleID: String, name: String) async throws {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw PasteFailure.appUnavailable(name: name)
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            // macOS 14's cooperative activation ignores activate() from an app in the
            // background; Accessibility's "frontmost" (we already have it) is honoured.
            let el = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetAttributeValue(el, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            running.activate()
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
                try await Task.sleep(nanoseconds: 280_000_000)
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
