import Combine
import GameController
import MacrophoneKit
import UIKit

// A real keyboard types into the Mac (Nov 5 2026). With a Bluetooth keyboard, a Magic Keyboard or
// the simulator's hardware keyboard on the iPhone, while a window is in hand, what it presses goes
// straight to the Mac, Mac-style: characters typed, Esc · Return · Tab · Delete · the arrows ·
// Home/End · F-keys pressed by name, ⌘ and ⌃ held on the Mac while held here so chords are real
// (⌘C, ⌘W, ⌘←, ⌘Tab stepping the switcher until ⌘ is let go). The rule is `HardwareKeyRouter`
// (MacrophoneKit); this is the phone's half: knowing a keyboard is there, the responder that hears
// it (`HardwareKeysView`, first while the window is in hand and nothing else is typing), the key
// repeat the Mac won't do for a posted key, and letting everything go on Done, on leaving the app,
// and when another field takes the keyboard.

/// Whether a hardware keyboard is connected (GameController's coalesced keyboard; a press heard
/// from one says so too).
@MainActor
final class HardwareKeyboard: ObservableObject {
    static let shared = HardwareKeyboard()

    @Published private(set) var connected = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        connected = GCKeyboard.coalesced != nil
        observers.append(NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HardwareKeyboard.shared.set(true) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HardwareKeyboard.shared.set(false) }
        })
    }

    private func set(_ on: Bool) {
        guard on != connected else { return }
        connected = on
        AppModel.shared.log.add("hardware keyboard \(on ? "connected" : "disconnected")")
    }

    /// A key was heard from a keyboard: there is one, whatever GameController said.
    func heard() { if !connected { set(true) } }
}

extension UIKeyModifierFlags {
    /// The Mac's modifiers among these (Caps Lock and the keypad flag aren't modifiers there).
    var watchModifiers: Set<WatchModifier> {
        var out: Set<WatchModifier> = []
        if contains(.command) { out.insert(.command) }
        if contains(.shift) { out.insert(.shift) }
        if contains(.alternate) { out.insert(.option) }
        if contains(.control) { out.insert(.control) }
        return out
    }
}

// MARK: The presses, on to the Mac

extension MacInput {
    /// A key went down on a hardware keyboard. `field`: the keyboard page's hidden field heard it
    /// (it types characters, Return, Tab and Delete itself). True when it went to the Mac — the
    /// caller doesn't pass it on; false when the caller should (not ours, or the field's own).
    func hardwarePress(_ key: UIKey, field: Bool = false) -> Bool {
        HardwareKeyboard.shared.heard()
        return hardwarePress(usage: key.keyCode.rawValue, characters: key.characters, modifiers: key.modifierFlags.watchModifiers, field: field)
    }

    /// The same, from what the key is (and `MACROPHONE_WATCH_ACTIONS=hwkeys@…`, which stands in for
    /// keys XCUITest can't press).
    func hardwarePress(usage: Int, characters: String, modifiers: Set<WatchModifier>, field: Bool = false) -> Bool {
        guard watcher?.isShowing == true, canHoldKeys || canType else { return false }
        let outs = keys.press(usage: usage, characters: characters, modifiers: modifiers)
        var repeating: HardwareKeyRouter.Out?
        var sent = false, newLine = false
        for out in outs where !(field && HardwareKeyRouter.textFieldTakes(out)) {
            guard send(out) else { continue }
            sent = true
            if case let .key(k) = out, k.key == "return" || k.key == "enter" { newLine = true }
            if HardwareKeyRouter.repeats(out) { repeating = out }
        }
        // Without a field everything is ours (iOS does nothing with a ⇧ or a Caps Lock here). The
        // field keeps what it types itself, ⇧ and ⌥ (its characters need them) and Caps Lock.
        var handled = true
        if field {
            if let m = HardwareKeyNames.modifier(usage: usage) { handled = HardwareKeyRouter.chordModifiers.contains(m) }
            else if HardwareKeyNames.name(usage: usage) == "capslock" { handled = false }
            else { handled = !outs.contains(where: HardwareKeyRouter.textFieldTakes) }
        }
        stopKeyRepeat()
        if let repeating { startKeyRepeat(repeating, usage: usage) }
        if handled, HardwareKeyNames.modifier(usage: usage) == nil { lastKeyPress = Date() }
        if sent {
            watcher?.touch()
            watcher?.inputSent(recenter: newLine)
        }
        return handled
    }

    /// What iOS's text system typed into the keyboard's responder rather than as a press (nil: a
    /// delete) — a press is always taken first, so this is only what came by another way.
    func hardwareInserted(_ text: String?) {
        guard watcher?.isShowing == true else { return }
        // The press that made it already went (were UIKit ever to hand on a press it was given).
        if let at = lastKeyPress, Date().timeIntervalSince(at) < 0.1 { return }
        // As the press would have been, with the modifiers held now (⇧↩, ⌥⇥ the switcher, ⌥⌫).
        let usage: Int?
        switch text {
        case nil: usage = 0x2A
        case "\n"?, "\r"?: usage = 0x28
        case "\t"?: usage = 0x2B
        default: usage = nil
        }
        var sent = false
        if let usage {
            for out in keys.press(usage: usage, characters: text ?? "", modifiers: keys.physical) where send(out) { sent = true }
        } else if let text, HardwareKeyNames.isPrintable(text) {
            sent = sendType(WatchTyping(text: text))
        }
        if sent { watcher?.touch(); watcher?.inputSent(recenter: usage == 0x28) }
    }

    /// Tab heard as a key command (iOS never hands it on as a press), with its modifiers: what a
    /// press of it would have been — ⇥, ⇧⇥, ⌃⇥, ⌘⇥ — and ⌥⇥ the Mac's app switcher.
    func hardwareTab(_ modifiers: Set<WatchModifier>) {
        guard watcher?.isShowing == true else { return }
        var sent = false
        for out in keys.press(usage: 0x2B, characters: "\t", modifiers: modifiers) where send(out) { sent = true }
        lastKeyPress = Date()
        if sent { watcher?.touch(); watcher?.inputSent() }
    }

    /// A key went up (or the system took it: `pressesCancelled`).
    func hardwareRelease(_ key: UIKey) {
        hardwareRelease(usage: key.keyCode.rawValue, modifiers: key.modifierFlags.watchModifiers)
    }

    func hardwareRelease(usage: Int, modifiers: Set<WatchModifier>) {
        if repeatingUsage == usage { stopKeyRepeat() }
        for out in keys.release(usage: usage, modifiers: modifiers) { _ = send(out) }
    }

    /// Everything let go on the Mac: Done, the app left, another field took the keyboard.
    func hardwareReleaseAll() {
        stopKeyRepeat()
        for out in keys.releaseAll() { _ = send(out) }
    }

    /// The link went: the Mac lets go of what this session held by itself.
    func hardwareForget() {
        stopKeyRepeat()
        keys.forget()
    }

    /// ⇧ and ⌥ held on the keyboard now (they go on a click: ⇧-click, ⌥-click; ⌘ and ⌃ are held on
    /// the Mac already, which adds them to every click itself).
    var hardwareClickModifiers: Set<WatchModifier> { keys.physical.intersection([.shift, .option]) }

    private func send(_ out: HardwareKeyRouter.Out) -> Bool {
        switch out {
        case let .hold(m, down):
            return canHoldKeys && sendKeyState(WatchKey(m.keyName), down)
        case let .key(k):
            return sendKey(k)
        case let .type(text):
            return sendType(WatchTyping(text: text))
        }
    }

    // The Mac never repeats a key that was posted to it, so a held key runs on from here, as a
    // Mac's own does: after a beat, then steadily, until it's let go or another key goes down.
    private func startKeyRepeat(_ out: HardwareKeyRouter.Out, usage: Int) {
        repeatingUsage = usage
        keyRepeat = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(HardwareKeyRouter.repeatDelay * 1e9))
            while !Task.isCancelled {
                guard let self, self.watcher?.isShowing == true, self.send(out) else { return }
                self.watcher?.touch()
                try? await Task.sleep(nanoseconds: UInt64(HardwareKeyRouter.repeatInterval * 1e9))
            }
        }
    }

    func stopKeyRepeat() {
        keyRepeat?.cancel()
        keyRepeat = nil
        repeatingUsage = nil
    }

    /// Once per keyboard connected, the first time a window is in hand with it: says where its
    /// typing goes.
    func noteHardwareKeyboard() {
        guard HardwareKeyboard.shared.connected, !keyboardNoted, watcher?.isShowing == true, canHoldKeys || canType else { return }
        keyboardNoted = true
        watcher?.say("Keyboard connected — typing on your Mac", symbol: "keyboard")
        watcher?.log?.add("watching: a hardware keyboard types on the Mac")
    }

    /// Hears the keyboard come and go (from `init`).
    func listenForHardwareKeyboard() {
        keyboardWatch = HardwareKeyboard.shared.$connected.removeDuplicates().dropFirst().sink { [weak self] on in
            guard let self else { return }
            if on {
                self.noteHardwareKeyboard()
            } else {
                self.keyboardNoted = false
                self.hardwareReleaseAll()
            }
        }
    }
}
