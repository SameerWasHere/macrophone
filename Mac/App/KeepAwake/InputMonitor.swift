import AppKit
import CoreGraphics

/// Keep Awake's auto-dim ear (Nov 7 2026, from On The Go): a listen-only event tap that notes the
/// time of the last PHYSICAL key, click, scroll or move. Physical = no posting process
/// (`eventSourceUnixProcessID == 0`); Macrophone's own clicks and typing from the phone, Screen
/// Sharing and AppleScript all carry a pid and never count — so steering the Mac from the iPhone
/// doesn't keep its displays on. Stores a timestamp and nothing else; never sees what's typed.
/// Key events need Accessibility, which Macrophone already has for pasting.
final class InputMonitor {
    private(set) var lastPhysicalInput: Date?
    /// On the main queue, for each counted event while `armed`, then disarmed.
    var onPhysicalInput: (() -> Void)?
    var armed = false
    var ignoreUntil = Date.distantPast

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let log: (String) -> Void
    private(set) var mode = "off"

    init(log: @escaping (String) -> Void) { self.log = log }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, info in
            if let info { Unmanaged<InputMonitor>.fromOpaque(info).takeUnretainedValue().handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        var made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                     eventsOfInterest: mask, callback: callback, userInfo: me)
        mode = "listen-only"
        if made == nil {
            made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: callback, userInfo: me)
            mode = "pass-through"
        }
        guard let t = made else {
            mode = "off"
            log("keep awake: input watch refused (Accessibility \(AXIsProcessTrusted() ? "on" : "off"))")
            return false
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        lastPhysicalInput = Date()
        log("keep awake: input watch on (\(mode))")
        return true
    }

    func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        source = nil
        tap = nil
        mode = "off"
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else { return }
        // A move with no distance is a display reconfiguring, not a hand.
        if type == .mouseMoved, event.getIntegerValueField(.mouseEventDeltaX) == 0,
           event.getIntegerValueField(.mouseEventDeltaY) == 0 { return }
        let now = Date()
        guard now >= ignoreUntil else { return }
        lastPhysicalInput = now
        if armed {
            armed = false
            DispatchQueue.main.async { [weak self] in self?.onPhysicalInput?() }
        }
    }
}
