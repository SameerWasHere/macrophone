import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MacrophoneKit

/// A phone's pointer, keyboard and held keys onto the Mac (Oct 19 2026), off the main thread:
/// every mouse event comes straight from the link's receive loop (`LinkServer.watchInput`, as
/// swipes do) and is posted from this poster's own serial queue, in order — a drag's moves sixty a
/// second, a double-click's two pairs, the pointer's hover — and typing and held keys go the same
/// way once the main actor has brought the window forward. One per watch; `WatchService` tells it
/// which window and hears when something was posted (the next frame goes at once).
///
/// Speed (Sameer: cut the click's waits): a click is a move, a down and an up eight milliseconds
/// apart, nothing else — the old click slept 40 ms before, 50 ms between and 150 ms after, a quarter
/// second each. The pointer is put back where it was a tenth of a second later, by a timer, never
/// in the click's way (and never while the phone's trackpad is in use: there the pointer stays
/// where it's left, which is what makes hover work). A window not on top at the spot is brought
/// forward first and the click waits for that — the one wait left, and only when it's needed.
final class InputPoster: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macrophone.watch-input", qos: .userInteractive)
    private let lock = NSLock()
    private var windowID: CGWindowID?
    private var pid: pid_t = 0
    private var bounds: CGRect?
    private var boundsAt = Date.distantPast
    private let source = CGEventSource(stateID: .hidSystemState)
    /// The left button is down (a drag is under way).
    private var dragging = false
    /// Where the pointer last went, on screen.
    private var pointer: CGPoint?
    /// The trackpad page is up: the pointer stays where it's left, shown in the picture.
    private var kept = false
    /// Where the Mac's own pointer was before a click moved it, to put it back.
    private var cursorBefore: CGPoint?
    private var putBack: DispatchWorkItem?
    private var held = HeldKeys()
    private var heldWatchdog: DispatchWorkItem?
    /// Counts for the log at the end (numbers only).
    private(set) var clicks = 0
    private(set) var moves = 0
    private(set) var typed = 0

    /// queue: the watched window isn't on top at this spot on screen (or it's the whole screen):
    /// bring what's there forward, then call back. The click waits for it, a second and a half at most.
    var onRaise: (@Sendable (CGPoint, @escaping @Sendable () -> Void) -> Void)?
    /// queue: a click, a press, a release, a key or typing was posted — the next picture goes at once.
    var onInput: (@Sendable (String) -> Void)?
    /// queue: the pointer moved or dragged — the picture follows at the stream's rate.
    var onMotion: (@Sendable () -> Void)?
    /// queue: the phone's trackpad is in use (show the pointer in the picture) or away.
    var onPointerShown: (@Sendable (Bool) -> Void)?

    /// The window the input goes to (nil while it isn't found) and its app.
    func set(window: CGWindowID?, pid: pid_t) {
        lock.lock(); windowID = window; self.pid = pid; lock.unlock()
        queue.async { self.bounds = nil }
    }

    /// The part of the screen the picture shows when the window's companions are streamed with it
    /// (Oct 19 2026, `WatchCompanions`): the phone's fractions are of that; nil = the window alone.
    private var area: CGRect?
    func set(area: CGRect?) {
        lock.lock(); self.area = area; lock.unlock()
    }

    // MARK: The pointer

    func mouse(_ e: WatchMouseEvent) {
        queue.async { self.post(e) }
    }

    private func post(_ e: WatchMouseEvent) {
        guard let kind = e.kindValue else { return }
        let flags = Self.flags(e.heldModifiers + held.modifiers)
        switch kind {
        case .show:
            kept = true
            putBack?.cancel()
            cursorBefore = nil
            onPointerShown?(true)
            return
        case .hide:
            kept = false
            onPointerShown?(false)
            return
        default: break
        }
        guard let pt = screenPoint(e.point) else { return }
        switch kind {
        case .move:
            move(to: pt, flags: flags)
            moves += 1
            onMotion?()
        case .click:
            raiseIfNeeded(at: pt)
            keepCursor()
            move(to: pt, flags: flags)
            let right = e.isRight
            let down = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: pt, mouseButton: right ? .right : .left)
            let up = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: pt, mouseButton: right ? .right : .left)
            for ev in [down, up] {
                ev?.setIntegerValueField(.mouseEventClickState, value: Int64(e.clickCount))
                ev?.flags = flags
            }
            down?.post(tap: .cghidEventTap)
            usleep(8_000)
            up?.post(tap: .cghidEventTap)
            clicks += 1
            schedulePutBack()
            onInput?(e.clickCount > 1 ? "click ×\(e.clickCount)" : right ? "right click" : "click")
        case .down:
            raiseIfNeeded(at: pt)
            keepCursor()
            move(to: pt, flags: flags)
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: 1)
            down?.flags = flags
            down?.post(tap: .cghidEventTap)
            dragging = true
            onInput?("press")
        case .drag:
            guard dragging else { move(to: pt, flags: flags); return }
            move(to: pt, flags: flags)
            moves += 1
            onMotion?()
        case .up:
            move(to: pt, flags: flags)
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)
            up?.setIntegerValueField(.mouseEventClickState, value: 1)
            up?.flags = flags
            up?.post(tap: .cghidEventTap)
            dragging = false
            schedulePutBack()
            onInput?("release")
        case .show, .hide: break
        }
    }

    /// queue: a move (or a drag, while the button is down) to a point on screen.
    private func move(to pt: CGPoint, flags: CGEventFlags) {
        let ev = CGEvent(mouseEventSource: source, mouseType: dragging ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)
        if dragging { ev?.setIntegerValueField(.mouseEventClickState, value: 1) }
        ev?.flags = flags
        ev?.post(tap: .cghidEventTap)
        pointer = pt
    }

    /// queue: the window's frame (looked up at most once a second) and the spot in it on screen.
    private func screenPoint(_ p: CGPoint) -> CGPoint? {
        let (wid, area) = lock.sync { (windowID, self.area) }
        guard let wid else { return nil }
        if let area { return WatchCompanions.point(p, in: area) }
        if bounds == nil || Date().timeIntervalSince(boundsAt) > 1 {
            bounds = WindowServer.bounds(of: wid)
            boundsAt = Date()
        }
        guard let b = bounds else { return nil }
        return CGPoint(x: b.minX + p.x * b.width, y: b.minY + p.y * b.height)
    }

    /// queue: a click on a window that isn't on top at the spot, or whose app isn't in front,
    /// waits for the main actor to bring it forward (the one wait a click keeps). The whole screen
    /// asks every time: the main actor raises only an ordinary app window that's under the spot and
    /// not already in front, and answers at once otherwise.
    private func raiseIfNeeded(at pt: CGPoint) {
        let (wid, pid) = lock.sync { (windowID, self.pid) }
        guard let wid, let onRaise else { return }
        if wid != WindowServer.desktopID {
            // A companion there (an Open panel a service draws, a menu, a sheet): straight to it,
            // no raise of the window under it, no wait.
            switch WindowServer.spot(pt, watched: wid, pid: pid) {
            case .companion: return
            case .watched where NSWorkspace.shared.frontmostApplication?.processIdentifier == pid: return
            default: break
            }
        }
        let done = DispatchSemaphore(value: 0)
        onRaise(pt) { done.signal() }
        _ = done.wait(timeout: .now() + 1.5)
        bounds = nil
    }

    /// queue: where the Mac's own pointer is before the first click moves it (kept across a
    /// double-click's taps, so it goes back to where it was, not to the first click).
    private func keepCursor() {
        guard !kept, cursorBefore == nil else { return }
        cursorBefore = CGEvent(source: nil)?.location
    }

    /// queue: a tenth of a second after the last click or release the pointer goes back — unless
    /// the trackpad is in use, or a button is still down.
    private func schedulePutBack() {
        putBack?.cancel()
        guard !kept else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.kept, !self.dragging, let c = self.cursorBefore else { return }
            self.cursorBefore = nil
            CGWarpMouseCursorPosition(c)
        }
        putBack = item
        queue.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    // MARK: Keys

    /// One key with its modifiers (and any held), by name.
    func press(_ k: WatchKey) {
        queue.async {
            guard let code = KeyCodes.code(for: k.key) else { return }
            Keys.press(code, flags: KeyCodes.flags(for: k, held: self.held.modifiers))
            self.onInput?(k.key == "return" ? "key-return" : "key")
        }
    }

    /// A key pressed down and held, or released. A modifier held this way goes on every key and
    /// click until it's released — the app switcher is ⌘ held, Tab, Tab, ⌘ let go.
    func keyState(_ k: WatchKey, down: Bool) {
        queue.async {
            guard let code = KeyCodes.code(for: k.key) else { return }
            if down {
                guard self.held.press(k.key) else { return }
                var flags = KeyCodes.flags(for: k, held: self.held.modifiers)
                if let m = WatchModifier(rawValue: k.key) { flags.insert(KeyCodes.mask(m)) }
                let ev = CGEvent(keyboardEventSource: self.source, virtualKey: code, keyDown: true)
                ev?.flags = flags
                ev?.post(tap: .cghidEventTap)
                self.rearmHeld()
            } else {
                guard self.held.release(k.key) else { return }
                let ev = CGEvent(keyboardEventSource: self.source, virtualKey: code, keyDown: false)
                ev?.flags = KeyCodes.flags(for: WatchKey(k.key), held: self.held.modifiers)
                ev?.post(tap: .cghidEventTap)
                if self.held.isEmpty { self.heldWatchdog?.cancel() }
            }
            self.onInput?(down ? "key held" : "key released")
        }
    }

    /// queue: a key held longer than `WatchKeyHold.longest` is let go by itself.
    private func rearmHeld() {
        heldWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.releaseHeld() }
        heldWatchdog = item
        queue.asyncAfter(deadline: .now() + WatchKeyHold.longest, execute: item)
    }

    /// queue: every held key let go, last pressed first.
    private func releaseHeld() {
        heldWatchdog?.cancel()
        for name in held.releaseAll() {
            guard let code = KeyCodes.code(for: name) else { continue }
            let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            ev?.flags = KeyCodes.flags(for: WatchKey(name), held: held.modifiers)
            ev?.post(tap: .cghidEventTap)
            usleep(4_000)
        }
    }

    // MARK: Typing

    /// What the phone's keyboard did: characters taken back, then typed — as unicode, straight
    /// into whatever has focus. Return and Tab are pressed as keys (most apps take a newline only
    /// from the key).
    func type(_ t: WatchTyping) {
        queue.async {
            for _ in 0..<min(t.delete, WatchTyping.maxDelete) {
                Keys.press(CGKeyCode(kVK_Delete), flags: [])
                usleep(3_000)
            }
            for step in TypingPlan.steps(for: t.text) {
                switch step {
                case .key(let name):
                    guard let code = KeyCodes.code(for: name) else { continue }
                    Keys.press(code, flags: [])
                case .text(let piece):
                    let units = Array(piece.utf16)
                    let down = CGEvent(keyboardEventSource: self.source, virtualKey: 0, keyDown: true)
                    let up = CGEvent(keyboardEventSource: self.source, virtualKey: 0, keyDown: false)
                    down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    down?.flags = []
                    up?.flags = []
                    down?.post(tap: .cghidEventTap)
                    usleep(2_000)
                    up?.post(tap: .cghidEventTap)
                }
                usleep(3_000)
            }
            self.typed += t.text.count
            self.onInput?(t.text.contains("\n") ? "key-return" : "type")
        }
    }

    /// The watch ended: every held key let go, a drag released, the pointer put back.
    func stop() {
        queue.async {
            self.releaseHeld()
            if self.dragging, let p = self.pointer {
                let up = CGEvent(mouseEventSource: self.source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
                up?.post(tap: .cghidEventTap)
                self.dragging = false
            }
            self.putBack?.cancel()
            if let c = self.cursorBefore { self.cursorBefore = nil; CGWarpMouseCursorPosition(c) }
            self.kept = false
        }
    }

    private static func flags(_ modifiers: [WatchModifier]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in modifiers { f.insert(KeyCodes.mask(m)) }
        return f
    }
}

/// Whether input may be posted at all, read off the main actor (the receive loop asks before every
/// pointer event): Accessibility granted and the screen not locked — the same two checks `act` makes.
enum InputGate {
    nonisolated static var allowed: Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if (d["CGSSessionScreenIsLocked"] as? Bool) == true || (d["CGSSessionScreenIsLocked"] as? Int) == 1 { return false }
        return (d["kCGSSessionOnConsoleKey"] as? Bool) != false
    }
}

/// Every key by name → its key code. Letters, digits and signs are found on the current layout
/// (Dvorak, AZERTY…), with the ANSI position as the fallback; the rest are fixed.
enum KeyCodes {
    static func code(for name: String) -> CGKeyCode? {
        if let fixed = fixed[name] { return CGKeyCode(fixed) }
        if name.count == 1, let c = name.first, c.isLetter || c.isNumber {
            return Keys.code(for: name) ?? ansi[name].map(CGKeyCode.init)
        }
        if let sign = MacKeys.signs.first(where: { $0.name == name }) {
            return Keys.code(for: sign.glyph) ?? ansi[name].map(CGKeyCode.init)
        }
        return nil
    }

    static func mask(_ m: WatchModifier) -> CGEventFlags {
        switch m {
        case .command: return .maskCommand
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        }
    }

    /// The flags a key goes with: its own modifiers, the ones held, and what a real keyboard adds
    /// to the arrows and the keys past them.
    static func flags(for k: WatchKey, held: [WatchModifier]) -> CGEventFlags {
        var flags: CGEventFlags = []
        if k.command { flags.insert(.maskCommand) }
        if k.shift { flags.insert(.maskShift) }
        if k.control { flags.insert(.maskControl) }
        if k.option { flags.insert(.maskAlternate) }
        for m in held { flags.insert(mask(m)) }
        if ["left", "right", "up", "down"].contains(k.key) { flags.formUnion([.maskNumericPad, .maskSecondaryFn]) }
        if ["pageup", "pagedown", "home", "end", "forwarddelete", "help"].contains(k.key) || k.key.hasPrefix("f") && Int(k.key.dropFirst()) != nil { flags.insert(.maskSecondaryFn) }
        return flags
    }

    private static let fixed: [String: Int] = [
        "escape": kVK_Escape, "tab": kVK_Tab, "return": kVK_Return, "enter": kVK_ANSI_KeypadEnter, "space": kVK_Space,
        "delete": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown, "help": kVK_Help,
        "capslock": kVK_CapsLock, "fn": kVK_Function,
        "command": kVK_Command, "shift": kVK_Shift, "option": kVK_Option, "control": kVK_Control,
        "rightcommand": kVK_RightCommand, "rightshift": kVK_RightShift, "rightoption": kVK_RightOption, "rightcontrol": kVK_RightControl,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
        "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
    ]

    private static let ansi: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "leftbracket": kVK_ANSI_LeftBracket, "rightbracket": kVK_ANSI_RightBracket,
        "backslash": kVK_ANSI_Backslash, "semicolon": kVK_ANSI_Semicolon, "quote": kVK_ANSI_Quote, "comma": kVK_ANSI_Comma,
        "period": kVK_ANSI_Period, "slash": kVK_ANSI_Slash, "grave": kVK_ANSI_Grave,
    ]
}
