import AppKit
import Carbon.HIToolbox

/// A global shortcut (no Accessibility needed — Carbon hot keys).
struct Hotkey: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey | optionKey …).
    var modifiers: UInt32
    var enabled: Bool

    /// ⌥⌘M
    static let `default` = Hotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | optionKey), enabled: true)

    /// "⌥⌘M"
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Spoken-ish, for VoiceOver and sentences: "Option Command M".
    var words: String {
        var s: [String] = []
        if modifiers & UInt32(controlKey) != 0 { s.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { s.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { s.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { s.append("Command") }
        return (s + [Self.keyName(keyCode)]).joined(separator: " ")
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"; case kVK_F4: return "F4"
        case kVK_F5: return "F5"; case kVK_F6: return "F6"; case kVK_F7: return "F7"; case kVK_F8: return "F8"
        case kVK_F9: return "F9"; case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_UpArrow: return "↑"; case kVK_DownArrow: return "↓"; case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        default: break
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "?" }
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            return st == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length).uppercased() : "?"
        }
    }
}

/// Registers one global hot key and calls `action` when it's pressed.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    var action: () -> Void = {}
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// Set when the shortcut couldn't be registered (another app owns it).
    private(set) var lastError: String?

    private init() {}

    func apply(_ key: Hotkey) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        lastError = nil
        guard key.enabled else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4D50484B) /* 'MPHK' */, id: 1)
        var newRef: EventHotKeyRef?
        let st = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &newRef)
        if st == noErr { ref = newRef } else { lastError = "\(key.display) is taken by another app — pick another." }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.action() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
