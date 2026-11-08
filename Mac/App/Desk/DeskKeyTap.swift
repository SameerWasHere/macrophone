import AppKit
import Carbon.HIToolbox
import CoreGraphics
import MacrophoneKit

/// Hears the desk key anywhere on the Mac (Nov 7 2026): a session event tap on key presses and
/// modifier changes, fed into `DeskHotkey` (the pure state machine). It lets every event through
/// — a modifier is never swallowed, so no app ever sees a stuck key — except Esc while a dictation
/// is listening, which cancels it and goes no further. An active tap needs Accessibility (which
/// Macrophone has for pasting); if macOS still refuses it, Input Monitoring is asked for.
@MainActor
final class DeskKeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var machine = DeskHotkey(key: .fn)
    private var key: DeskKey = .fn
    private var keyDown = false
    private var timer: Timer?
    private let clock = ProcessInfo.processInfo
    /// What the machine decided.
    var onEffect: (DeskHotkey.Effect) -> Void = { _ in }

    var isRunning: Bool { tap != nil }
    var isListening: Bool { machine.isListening }

    /// Starts (or retargets) the tap for `key`. Returns false when macOS refused it.
    @discardableResult
    func start(_ key: DeskKey) -> Bool {
        if key != self.key || tap == nil {
            self.key = key
            machine = DeskHotkey(key: key)
            keyDown = false
        }
        guard key != .off else { stop(); return true }
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: deskTapCallback, userInfo: me) else {
            return false
        }
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
        return true
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        machine.reset()
        keyDown = false
    }

    /// The controller ended the dictation on its own (the mic failed, a permission is missing).
    func reset() {
        machine.reset(keyDown: keyDown)
        schedule()
    }

    /// Called on the main run loop for every key event. Returns false to swallow it.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        guard let code = key.keyCode else { return true }
        let now = clock.systemUptime
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        var r: (effects: [DeskHotkey.Effect], swallow: Bool) = ([], false)
        switch type {
        case .flagsChanged:
            // Some keyboards report the 🌐 key as 179 rather than kVK_Function.
            if keycode == code || (key == .fn && keycode == 179) {
                let down = event.flags.rawValue & key.downMask != 0
                guard down != keyDown else { return true }
                keyDown = down
                r = machine.handle(down ? .down : .up, at: now)
            } else if keyDown {
                // Another modifier while the trigger is down: a shortcut in the making.
                r = machine.handle(.otherKey, at: now)
            }
        case .keyDown:
            if keycode == UInt16(kVK_Escape) {
                r = machine.handle(.escape, at: now)
            } else if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                r = machine.handle(.otherKey, at: now)
            }
        default:
            break
        }
        for e in r.effects { onEffect(e) }
        schedule()
        return !r.swallow
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard let deadline = machine.nextDeadline else { return }
        let wait = max(0, deadline - clock.systemUptime)
        let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let r = self.machine.handle(.tick, at: max(deadline, self.clock.systemUptime))
                for e in r.effects { self.onEffect(e) }
                self.schedule()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// For tests and the debug hook: what the machine would do with this event now.
    func feed(_ e: DeskHotkey.Event) {
        if e == .down { keyDown = true } else if e == .up { keyDown = false }
        let r = machine.handle(e, at: clock.systemUptime)
        for x in r.effects { onEffect(x) }
        schedule()
    }
}

/// The C callback: on the main run loop (the source is added there), so the actor hop is safe.
private func deskTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<DeskKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    let pass = MainActor.assumeIsolated { tap.handle(type: type, event: event) }
    return pass ? Unmanaged.passUnretained(event) : nil
}
