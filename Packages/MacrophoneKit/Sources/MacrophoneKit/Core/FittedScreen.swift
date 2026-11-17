import CoreGraphics
import Foundation

// The Whole Screen, fitted to the iPhone (Nov 16 2026). Sameer: "even in whole screen mode the Mac
// screen is optimized for the space available on the phone in its various orientations. Default
// size should still be an option." The Mac makes a display of the phone's view's shape (a virtual
// one, HiDPI, with its own menu bar and Dock), makes it the main display, moves the windows onto
// it and streams it as the Whole Screen — so the picture fills the phone's view with no letterbox.
// Off (or the watch over), everything goes back.
//
// The wire: `.screenFit` (phone → Mac, only to a Mac whose welcome names `FittedScreen.feature`):
// on with the view's size in phone points, or off. `.screenFitState` (Mac → phone, only to a
// phone whose hello names it): what the Mac did — on with the display's size in Mac points, off,
// or why it couldn't. An older phone or Mac never sees either.

public enum FittedScreen {
    public static let feature = "fittedScreen"

    /// Mac points per phone point: a phone's view is small, so the Mac's screen is made half as
    /// big again and shown at two thirds — text stays readable, and there's room to work.
    public static let pointScale = 1.5
    /// Never narrower than this in Mac points (a menu bar and most windows need it).
    public static let minWidth = 640.0
    /// The long side at most, in Mac points (twice that in pixels: 3,840).
    public static let maxLong = 1920.0
    /// Pixels per Mac point.
    public static let pixelScale = 2
    /// A phone view's shape that can be a screen: between these, width over height.
    public static let aspects = 0.4...2.6

    /// The Mac display, in Mac points, for a phone view of this size in phone points: the view's
    /// own shape, `pointScale` bigger, at least `minWidth` wide, the long side within `maxLong`,
    /// both sides even. Nil for a view that isn't a screen's shape.
    public static func size(forView width: Double, _ height: Double) -> FittedScreenSize? {
        guard width.isFinite, height.isFinite, width >= 150, height >= 150, aspects.contains(width / height) else { return nil }
        var s = pointScale
        if width * s < minWidth { s = minWidth / width }
        if max(width, height) * s > maxLong { s = maxLong / max(width, height) }
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return FittedScreenSize(width: even(width * s), height: even(height * s))
    }

    /// Whether a display of `a` has to be remade to be `b`: more than a few points either way
    /// (a layout settling by a point or two never remakes the Mac's screen).
    public static func differs(_ a: FittedScreenSize, _ b: FittedScreenSize) -> Bool {
        abs(a.width - b.width) > 8 || abs(a.height - b.height) > 8
    }
}

/// A display's size in Mac points.
public struct FittedScreenSize: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var pixelsWide: Int { width * FittedScreen.pixelScale }
    public var pixelsHigh: Int { height * FittedScreen.pixelScale }
    public var aspect: Double { Double(width) / Double(max(1, height)) }
}

/// Phone → Mac: fit the whole screen to this view (its size in phone points), or put it back.
public struct FittedScreenRequest: Codable, Sendable, Equatable {
    public var on: Bool
    public var width: Double
    public var height: Double

    public init(on: Bool, width: Double = 0, height: Double = 0) {
        self.on = on
        self.width = width
        self.height = height
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.decode(Bool.self, forKey: .on)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0
    }

    /// The display it asks for (nil: off, or not a screen's shape).
    public var size: FittedScreenSize? { on ? FittedScreen.size(forView: width, height) : nil }
}

/// Mac → phone: how the fitted screen stands.
public struct FittedScreenState: Codable, Sendable, Equatable {
    public var on: Bool
    /// The display's key (as `Displays.key` names one) while on.
    public var key: String?
    /// Its size in Mac points while on.
    public var width: Int
    public var height: Int
    /// Why it isn't on, when it was asked for and couldn't be ("This Mac can't make a screen
    /// that shape"). Nil when it's on, or simply off.
    public var reason: String?

    public init(on: Bool, key: String? = nil, width: Int = 0, height: Int = 0, reason: String? = nil) {
        self.on = on
        self.key = key
        self.width = width
        self.height = height
        self.reason = reason.map { String($0.prefix(160)) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.decode(Bool.self, forKey: .on)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    public static let off = FittedScreenState(on: false)
    public var size: FittedScreenSize? { on && width > 0 && height > 0 ? FittedScreenSize(width: width, height: height) : nil }
}
