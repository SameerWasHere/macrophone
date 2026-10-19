import CoreGraphics
import Foundation

// Pick a display (Oct 19 2026, "control the Mac entirely from the iPhone"): a Mac with more than
// one screen tells a phone that asks what its displays are, and the window view's switcher offers
// a Whole Screen per display ("Whole Screen — Studio Display"). The whole screen is still the
// reserved DesktopWatch place; which display is its `windowKey` ("display:<the display's UUID>").
// A Mac from before ignores the key and shows the main display, as it always did.

/// One of the Mac's displays.
public struct MacDisplay: Codable, Sendable, Hashable, Identifiable {
    /// Stable across reboots and re-plugging: the display's own UUID.
    public var id: String
    /// "Built-in Retina Display", "Studio Display".
    public var name: String
    /// Where it sits in the Mac's one big desktop, in points, top-left origin (the main display's
    /// top-left is 0,0 — one to its left or above has a negative origin).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// The one with the menu bar.
    public var isMain: Bool

    public init(id: String, name: String, x: Double, y: Double, width: Double, height: Double, isMain: Bool) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isMain = isMain
    }

    public var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public enum Displays {
    /// The Mac names it in its welcome (and sends `.displays`); the phone names it in its hello.
    public static let feature = "displays"
    static let prefix = "display:"

    /// The Whole Screen place for one display (nil = the Mac's main display, as before).
    public static func target(for display: MacDisplay?, among all: [MacDisplay] = []) -> TargetRef {
        guard let display else { return DesktopWatch.target }
        return .app(bundleID: DesktopWatch.bundleID, windowKey: prefix + display.id, name: title(for: display, among: all))
    }

    /// The display a Whole Screen place names (nil: the main one).
    public static func key(of target: TargetRef?) -> String? {
        guard case let .app(bid, key?, _) = target, bid == DesktopWatch.bundleID, key.hasPrefix(prefix) else { return nil }
        let id = String(key.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// Which display to show for a key: that one while it's connected, else the main display (it
    /// was unplugged), else the first.
    public static func resolve(_ key: String?, in all: [MacDisplay]) -> MacDisplay? {
        if let key, let d = all.first(where: { $0.id == key }) { return d }
        return all.first(where: \.isMain) ?? all.first
    }

    /// The main display first, then left to right, then top to bottom — how they sit on the desk.
    public static func ordered(_ all: [MacDisplay]) -> [MacDisplay] {
        all.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            if a.x != b.x { return a.x < b.x }
            return a.y < b.y
        }
    }

    /// A display's name in the menu; two with the same name get "2", "3" after it (in order).
    public static func name(for display: MacDisplay, among all: [MacDisplay]) -> String {
        let base = display.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Display" : display.name
        let same = ordered(all).filter { $0.name == display.name }
        guard same.count > 1, let i = same.firstIndex(where: { $0.id == display.id }), i > 0 else { return base }
        return "\(base) \(i + 1)"
    }

    /// "Whole Screen — Studio Display" (just "Whole Screen" with one display).
    public static func title(for display: MacDisplay, among all: [MacDisplay]) -> String {
        all.count > 1 ? "Whole Screen — \(name(for: display, among: all))" : "Whole Screen"
    }

    /// A spot on the picture (fractions of it, 0…1, top-left origin) as a point in the Mac's
    /// desktop (global coordinates) on the display with these bounds.
    public static func point(_ fraction: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + min(max(fraction.x, 0), 1) * bounds.width,
                y: bounds.minY + min(max(fraction.y, 0), 1) * bounds.height)
    }

    /// The list a phone keeps: at most 16, nothing empty or nonsensical.
    public static func clean(_ all: [MacDisplay]) -> [MacDisplay] {
        Array(all.filter { !$0.id.isEmpty && $0.id.count <= 64 && $0.width > 0 && $0.height > 0 }.prefix(16))
            .map { var d = $0; d.name = String(d.name.prefix(80)); return d }
    }
}
