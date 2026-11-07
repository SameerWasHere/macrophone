import Foundation

// The Mac's output volume and mute, as it is now (Nov 7 2026). Mac Controls' slider stands at the
// real level from the moment the panel opens, so a drag lands where it looks like it will — it
// used to sit at 0 until a key had been pressed, and a drag from that 0 added its steps on top of
// the real level.
//
// The wire: `.macVolume` (Mac → phone, after the welcome and on every change — its own keys, the
// menu bar, another output device) only to a phone whose hello named `MacVolume.feature`; an
// older phone never gets it, and an older Mac never sends it (the phone's slider is then drawn
// with no level at all, never a guessed 0).

public struct MacVolume: Codable, Sendable, Equatable {
    public static let feature = "macVolume"

    /// A Mac's volume keys move it in sixteenths.
    public static let steps = 16

    /// The default output's volume, 0…1; nil when that device has no volume the Mac can read
    /// (some HDMI and USB outputs).
    public var volume: Double?
    public var muted: Bool

    public init(volume: Double?, muted: Bool) {
        self.volume = volume.map { min(1, max(0, $0)) }
        self.muted = muted
    }

    /// "Volume 56%" / "Muted" — nil when there's nothing to say.
    public var line: String? { MacControlResult.volumeLine(volume, muted: muted) }

    /// The sixteenth the level is nearest (what the Mac's keys step from).
    public static func step(of level: Double) -> Int { Int((min(1, max(0, level)) * Double(steps)).rounded()) }

    /// How many keys, and which way, take the volume from `level` to `target` (both 0…1).
    public static func keys(from level: Double, to target: Double) -> Int { step(of: target) - step(of: level) }
}
