import Foundation

// Mac Controls (Oct 19 2026, "control the Mac entirely from the iPhone"): the keys on the Mac's
// keyboard's top row — volume, brightness, play / pause, next, previous — pressed from the phone.
// The Mac presses them as the keyboard does (system-defined media key events), so whatever the
// Mac does with its own keys happens: the volume HUD, the app playing music. Only to a Mac whose
// welcome names the feature; the Mac answers with the volume it reads back and one plain line.

public enum MacControl: String, Codable, Sendable, CaseIterable, Identifiable {
    case volumeDown, mute, volumeUp
    case brightnessDown, brightnessUp
    case previous, playPause, next

    public static let feature = "macControls"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .brightnessUp: return "Brighter"
        case .brightnessDown: return "Dimmer"
        case .playPause: return "Play or Pause"
        case .next: return "Next"
        case .previous: return "Previous"
        }
    }

    public var symbol: String {
        switch self {
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .mute: return "speaker.slash.fill"
        case .brightnessUp: return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        case .playPause: return "playpause.fill"
        case .next: return "forward.fill"
        case .previous: return "backward.fill"
        }
    }

    public var isVolume: Bool { self == .volumeUp || self == .volumeDown || self == .mute }
    public var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }

    /// The rows the menus show, in order.
    public static let volume: [MacControl] = [.volumeDown, .mute, .volumeUp]
    public static let brightness: [MacControl] = [.brightnessDown, .brightnessUp]
    public static let media: [MacControl] = [.previous, .playPause, .next]

    /// The key's number in the Mac's system-defined events (IOKit's ev_keymap.h, NX_KEYTYPE_*).
    public var keyType: Int32 {
        switch self {
        case .volumeUp: return 0       // NX_KEYTYPE_SOUND_UP
        case .volumeDown: return 1     // NX_KEYTYPE_SOUND_DOWN
        case .brightnessUp: return 2   // NX_KEYTYPE_BRIGHTNESS_UP
        case .brightnessDown: return 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
        case .mute: return 7           // NX_KEYTYPE_MUTE
        case .playPause: return 16     // NX_KEYTYPE_PLAY
        case .next: return 17          // NX_KEYTYPE_NEXT
        case .previous: return 18      // NX_KEYTYPE_PREVIOUS
        }
    }

    /// The `data1` of the key's system-defined event (subtype 8): the key type in the high half,
    /// then the state — 0xA down, 0xB up.
    public func data1(down: Bool) -> Int {
        Int(keyType) << 16 | (down ? 0xA : 0xB) << 8
    }
}

/// The Mac's answer to a control.
public struct MacControlResult: Codable, Sendable, Equatable {
    public var control: MacControl
    public var ok: Bool
    /// The output volume after a volume key, 0…1, when the Mac could read it.
    public var volume: Double?
    public var muted: Bool?
    /// One plain line ("Volume 40%", "Brightness keys change only a built-in or Apple display").
    public var detail: String

    public init(control: MacControl, ok: Bool, volume: Double? = nil, muted: Bool? = nil, detail: String) {
        self.control = control
        self.ok = ok
        self.volume = volume
        self.muted = muted
        self.detail = detail
    }

    /// "Volume 40%" / "Muted" — what a volume key's answer says.
    public static func volumeLine(_ volume: Double?, muted: Bool?) -> String? {
        if muted == true { return "Muted" }
        guard let volume else { return nil }
        return "Volume \(Int((min(max(volume, 0), 1) * 100).rounded()))%"
    }
}
