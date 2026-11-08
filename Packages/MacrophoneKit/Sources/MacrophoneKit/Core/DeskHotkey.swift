import Foundation

/// The key that dictates at the desk (Nov 7 2026): held on the Mac itself — no phone — the mic
/// listens, let go and the words are pasted where you're typing.
public enum DeskKey: String, Codable, CaseIterable, Sendable, Identifiable {
    case fn, rightOption, rightCommand, off
    public var id: String { rawValue }

    /// The key's virtual key code (kVK_Function, kVK_RightOption, kVK_RightCommand).
    public var keyCode: UInt16? {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .off: return nil
        }
    }

    /// The device-dependent flag bit that says this one side is down (IOKit's NX_DEVICE…KEYMASK),
    /// or for Fn the secondary-fn flag. A flagsChanged event with the key's code and this bit set
    /// is the press; without it, the release.
    public var downMask: UInt64 {
        switch self {
        case .fn: return 0x0080_0000          // NX_SECONDARYFNMASK
        case .rightOption: return 0x0000_0040 // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x0000_0010 // NX_DEVICERCMDKEYMASK
        case .off: return 0
        }
    }

    /// The picker's words.
    public var title: String {
        switch self {
        case .fn: return "🌐 Fn"
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .off: return "Off"
        }
    }

    /// In a sentence: "Hold 🌐 to dictate".
    public var short: String {
        switch self {
        case .fn: return "🌐"
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        case .off: return ""
        }
    }

    /// Fn is pressed on its own: the mic opens the moment it goes down, so the first syllable is
    /// heard. Right ⌥ and Right ⌘ start most presses as part of a shortcut (⌘C, ⌥-letter), so the
    /// mic waits a moment for the hold to be a hold — no flash of the mic light on every ⌘C.
    public var opensMicAtPress: Bool { self == .fn }
}

/// What the desk key is doing, as a pure state machine (tested in `DeskHotkeyTests`). The event
/// tap feeds it the key's presses and releases, any other key while it's down, Esc, and a tick
/// at `nextDeadline`; it answers with what to do.
///   - Hold: the mic opens (at the press for Fn, after `armDelay` otherwise), the pill shows after
///     `pillDelay`; let go after `tapLimit` → the words are pasted.
///   - A quick tap (shorter than `tapLimit`): nothing — the mic, if it opened, is let go quietly.
///   - Two quick taps (the second press within `doubleTapGap` of the first release): hands-free —
///     listening until the key is tapped again (then pasted) or Esc.
///   - Another key while the trigger is down (⌘C, Fn-arrow, ⌥-letter): a shortcut, not a
///     dictation — let go quietly; the rest of that press is ignored.
///   - Esc while listening: cancelled, nothing pasted (and Esc goes no further).
public struct DeskHotkey: Sendable {
    public enum Event: Sendable, Equatable {
        case down, up, otherKey, escape, tick
    }

    public enum Effect: Sendable, Equatable {
        /// Open the mic and start hearing (nothing on screen yet).
        case openMic
        /// It's a hold: show the listening pill.
        case showPill
        /// Two taps: keep listening without the key held.
        case handsFree
        /// Done: stop, clean up, paste.
        case finish
        /// Stop and drop it. `quiet`: nothing was ever shown (a tap, a shortcut).
        case cancel(quiet: Bool)
    }

    public enum Phase: Sendable, Equatable {
        case idle
        /// Down, not yet a hold.
        case pressed
        /// Down long enough: the pill is up.
        case holding
        /// The second press of a double tap, still down: hands-free starts on its release.
        case handsFreeArming
        /// Listening, the key up.
        case handsFree
        /// The press that ended a hands-free dictation, or a shortcut: its release is ignored.
        case ignoringRelease
    }

    public var tapLimit: TimeInterval = 0.3
    public var doubleTapGap: TimeInterval = 0.35
    public var armDelay: TimeInterval = 0.18
    public var pillDelay: TimeInterval = 0.15
    /// A hands-free dictation forgotten about ends itself.
    public var handsFreeLimit: TimeInterval = 600

    public let eagerMic: Bool
    public private(set) var phase: Phase = .idle
    public private(set) var micOpen = false
    public private(set) var pillShown = false
    private var downAt: TimeInterval = 0
    private var lastTapUp: TimeInterval?
    private var handsFreeAt: TimeInterval = 0

    public init(eagerMic: Bool) { self.eagerMic = eagerMic }
    public init(key: DeskKey) { self.init(eagerMic: key.opensMicAtPress) }

    /// Listening right now (Esc means something).
    public var isListening: Bool { micOpen && phase != .idle && phase != .ignoringRelease }

    /// When to send the next `.tick`, or nil when nothing's waiting.
    public var nextDeadline: TimeInterval? {
        switch phase {
        case .pressed:
            if !micOpen { return downAt + armDelay }
            if !pillShown { return downAt + max(pillDelay, eagerMic ? 0 : armDelay) }
            return nil
        case .handsFree:
            return handsFreeAt + handsFreeLimit
        default:
            return nil
        }
    }

    /// Forget everything (the controller stopped on its own: the mic failed, permission missing).
    /// A release still to come is ignored.
    public mutating func reset(keyDown: Bool = false) {
        phase = keyDown ? .ignoringRelease : .idle
        micOpen = false
        pillShown = false
        lastTapUp = nil
    }

    /// Feeds one event at time `t` (seconds, any steady clock). `swallow`: the event shouldn't go
    /// on to the app in front (only Esc that cancelled a dictation).
    public mutating func handle(_ event: Event, at t: TimeInterval) -> (effects: [Effect], swallow: Bool) {
        switch (phase, event) {
        // Idle
        case (.idle, .down):
            if let last = lastTapUp, t - last <= doubleTapGap {
                lastTapUp = nil
                phase = .handsFreeArming
                var fx: [Effect] = []
                if !micOpen { fx.append(.openMic); micOpen = true }
                fx += [.showPill, .handsFree]
                pillShown = true
                return (fx, false)
            }
            lastTapUp = nil
            phase = .pressed
            downAt = t
            pillShown = false
            if eagerMic { micOpen = true; return ([.openMic], false) }
            micOpen = false
            return ([], false)
        case (.idle, _):
            if event == .tick, let last = lastTapUp, t - last > doubleTapGap { lastTapUp = nil }
            // Typing between two taps makes them two taps, not a double tap.
            if event == .otherKey { lastTapUp = nil }
            return ([], false)

        // Down, deciding
        case (.pressed, .tick):
            var fx: [Effect] = []
            if !micOpen, t - downAt >= armDelay { fx.append(.openMic); micOpen = true }
            if micOpen, !pillShown, t - downAt >= max(pillDelay, eagerMic ? 0 : armDelay) {
                fx.append(.showPill)
                pillShown = true
                phase = .holding
            }
            return (fx, false)
        case (.pressed, .up), (.holding, .up):
            let held = t - downAt
            let wasOpen = micOpen, wasShown = pillShown
            phase = .idle
            micOpen = false
            pillShown = false
            if held < tapLimit {
                lastTapUp = t
                return (wasOpen ? [.cancel(quiet: !wasShown)] : [], false)
            }
            // Released before the mic ever opened can't happen past tapLimit, but stay safe.
            return (wasOpen ? [.finish] : [], false)
        case (.pressed, .otherKey), (.holding, .otherKey):
            let wasOpen = micOpen, wasShown = pillShown
            phase = .ignoringRelease
            micOpen = false
            pillShown = false
            lastTapUp = nil
            return (wasOpen ? [.cancel(quiet: !wasShown)] : [], false)
        case (.pressed, .escape), (.holding, .escape):
            let wasOpen = micOpen, wasShown = pillShown
            phase = .ignoringRelease
            micOpen = false
            pillShown = false
            lastTapUp = nil
            // Esc during a press that never listened is the person's Esc.
            return (wasOpen ? [.cancel(quiet: !wasShown)] : [], wasOpen)
        case (.pressed, .down), (.holding, .down), (.holding, .tick):
            return ([], false)

        // Hands-free
        case (.handsFreeArming, .up):
            phase = .handsFree
            handsFreeAt = t
            return ([], false)
        case (.handsFreeArming, .escape), (.handsFree, .escape):
            let wasDown = phase == .handsFreeArming
            phase = wasDown ? .ignoringRelease : .idle
            micOpen = false
            pillShown = false
            return ([.cancel(quiet: false)], true)
        case (.handsFree, .down):
            phase = .ignoringRelease
            micOpen = false
            pillShown = false
            return ([.finish], false)
        case (.handsFree, .tick):
            guard t - handsFreeAt >= handsFreeLimit else { return ([], false) }
            phase = .idle
            micOpen = false
            pillShown = false
            return ([.finish], false)
        case (.handsFreeArming, _), (.handsFree, _):
            // Typing while hands-free goes on as typing; the dictation keeps listening.
            return ([], false)

        // The release of a press that already did its job.
        case (.ignoringRelease, .up):
            phase = .idle
            return ([], false)
        case (.ignoringRelease, _):
            return ([], false)
        }
    }
}

/// What macOS does with the 🌐 key on its own (System Settings › Keyboard › "Press 🌐 key to"),
/// read from `com.apple.HIToolbox` `AppleFnUsageType`. Anything but Do Nothing fires alongside a
/// Fn hold, so the Dictation page says so.
public enum FnKeyUsage: Int, Sendable {
    case doNothing = 0, changeInputSource = 1, showEmoji = 2, startDictation = 3

    /// One line for the Dictation page, nil when it won't get in the way.
    public var conflict: String? {
        switch self {
        case .doNothing: return nil
        case .changeInputSource: return "“Press 🌐 key to” is set to Change Input Source, so holding 🌐 may also switch your keyboard. Set it to Do Nothing."
        case .showEmoji: return "“Press 🌐 key to” is set to Show Emoji & Symbols, so the emoji picker may open too. Set it to Do Nothing."
        case .startDictation: return "“Press 🌐 key to” is set to Start Dictation, so Apple's dictation may start too. Set it to Do Nothing."
        }
    }
}
