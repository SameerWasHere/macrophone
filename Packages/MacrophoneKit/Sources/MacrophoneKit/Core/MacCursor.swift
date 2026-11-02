import Foundation

// The Mac's pointer as it looks right now (Nov 1 2026, Sameer: the trackpad's cursor "should
// contextually change just like it does on the Mac"). The phone draws the one pointer over the
// watched window; with this it draws the Mac's own — the arrow, the I-beam over text, the
// pointing hand over a link, the resize arrows at a window's edge, an app's own cursor — as the
// Mac shows it at that moment.
//
// The wire: `.macCursor` (Mac → phone) only to a phone whose hello names `MacCursor.feature`,
// while that phone's trackpad pointer is up, once when it shows and then on each change; the Mac
// names it in its welcome too. An older peer never sees it (an unknown message ends a session),
// and the phone keeps drawing its own arrow for a Mac that doesn't send it.
//
// What travels is the cursor's picture as a PNG at twice its size in points (a few KB, sent only
// when the shape changes), its size in points and its hot spot — the point of it that clicks.

/// The Mac's pointer, ready for the phone.
public struct MacCursor: Codable, Sendable, Equatable {
    public static let feature = "cursorShape"
    /// The largest cursor that travels, in points a side (macOS's are 16–32; an app's can be more).
    public static let maxSide: Double = 96
    /// A cursor's PNG never weighs more.
    public static let maxBytes = 64 * 1024

    /// The same shape always has the same id: the phone skips one it already shows.
    public var id: String
    public var png: Data
    /// In points.
    public var width: Double
    public var height: Double
    /// The point that clicks, in points from the top left.
    public var hotX: Double
    public var hotY: Double

    public init(id: String, png: Data, width: Double, height: Double, hotX: Double, hotY: Double) {
        self.id = id
        self.png = png
        self.width = width
        self.height = height
        self.hotX = hotX
        self.hotY = hotY
    }

    /// Worth drawing: a picture of a sensible size with its hot spot inside it.
    public var isValid: Bool {
        !png.isEmpty && png.count <= Self.maxBytes && !id.isEmpty && id.count <= 64
            && width > 0 && height > 0 && width <= Self.maxSide && height <= Self.maxSide
            && hotX >= 0 && hotY >= 0 && hotX <= width && hotY <= height
    }
}
