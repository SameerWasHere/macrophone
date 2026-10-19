import CoreGraphics
import Foundation

/// The windows that belong with a watched window right now (Oct 19 2026). Sameer: "I tried opening
/// TextEdit, the document creator popped up, but I could not click anything on it from my phone."
/// TextEdit is sandboxed, so its Open panel is drawn by another process (the Open and Save Panel
/// Service) in its own window laid over TextEdit's; a context menu, a pop-up button's menu, a
/// popover, a sheet or a tooltip is a window of its own too. The window view streamed the one
/// window, so none of them showed, and a click on them first "raised" the window under them.
///
/// A companion is an on-screen window in front of the watched one that overlaps it and is
/// (a) the same app's: anything above the normal level (menus, popovers, panels, tooltips), or a
/// normal-level window drawn inside it and smaller (a sheet); (b) a remote view's — a known
/// service (open and save panels, view bridges, share sheets, Quick Look), or any process that
/// isn't an ordinary app, made after the watched window, mostly over it and no bigger, while the
/// watched app is in front; or (c) the window server's pop-up menus over it. Never another
/// ordinary app's window, never the system's own overlays (Notification Center's full-screen
/// layer, the Dock, Control Center). Pure: the Mac hands it one window list per look.
public enum WatchCompanions {
    /// One on-screen window, as the window server lists it (front to back).
    public struct Window: Equatable, Sendable {
        public var id: UInt32
        public var pid: Int32
        public var layer: Int
        /// Top-left origin, global points.
        public var bounds: CGRect
        public var alpha: Double
        /// The window server's owner name.
        public var owner: String?
        /// The owning process's bundle id, when it has one.
        public var bundleID: String?
        /// The owning process is an ordinary app (in the Dock).
        public var regularApp: Bool

        public init(id: UInt32, pid: Int32, layer: Int, bounds: CGRect, alpha: Double = 1, owner: String? = nil, bundleID: String? = nil, regularApp: Bool) {
            self.id = id; self.pid = pid; self.layer = layer; self.bounds = bounds
            self.alpha = alpha; self.owner = owner; self.bundleID = bundleID; self.regularApp = regularApp
        }
    }

    /// The pop-up menu level (a context menu, a pop-up button's menu).
    public static let popUpMenuLevel = 101
    /// The highest level a companion sits at (the screen saver's; tooltips and help sit below it).
    public static let highestLevel = 1000

    /// Services that draw part of another app's window: always a companion when over it.
    static let remoteServicePrefixes = [
        "com.apple.appkit.xpc.openAndSavePanelService", "com.apple.appkit.xpc.", "com.apple.ViewBridge",
        "com.apple.share", "com.apple.sharing", "com.apple.ShareSheet", "com.apple.quicklook.",
        "com.apple.QuickLookUIFramework", "com.apple.PrintUI",
    ]
    static let remoteServiceOwners: Set<String> = ["Open and Save Panel Service", "ViewBridgeAuxiliary", "ShareSheetUI", "QuickLookUIService"]
    /// The system's own overlays, never a companion.
    static let systemOwners: Set<String> = [
        "Dock", "Control Center", "ControlCenter", "Spotlight", "Notification Center", "NotificationCenter",
        "WindowManager", "SystemUIServer", "Wallpaper", "screencaptureui", "Screenshot", "loginwindow", "Siri",
    ]

    static func isRemoteService(_ w: Window) -> Bool {
        if let b = w.bundleID, remoteServicePrefixes.contains(where: { b.hasPrefix($0) }) { return true }
        if let o = w.owner, remoteServiceOwners.contains(o) || o.contains("Open and Save Panel") || o.hasPrefix("com.apple.appkit.xpc.") { return true }
        return false
    }

    static func area(_ r: CGRect) -> CGFloat { r.isNull || r.isEmpty ? 0 : r.width * r.height }

    /// The companions of `watched` in `list` (front to back, on screen), front to back. `hostInFront`:
    /// the watched window's app is the one in front (a stranger's window over it counts only then).
    /// `me`: this process, never shown.
    public static func select(watched: UInt32, in list: [Window], hostInFront: Bool, me: Int32 = -1) -> [Window] {
        guard let i = list.firstIndex(where: { $0.id == watched }) else { return [] }
        let host = list[i]
        guard area(host.bounds) > 0 else { return [] }
        return list[..<i].filter { $0.pid != me && isCompanion($0, of: host, hostInFront: hostInFront) }
    }

    static func isCompanion(_ c: Window, of host: Window, hostInFront: Bool) -> Bool {
        guard c.id != host.id, c.alpha >= 0.05, c.bounds.width >= 2, c.bounds.height >= 2,
              c.layer >= 0, c.layer <= highestLevel else { return false }
        let overlap = c.bounds.intersection(host.bounds)
        let size = area(c.bounds)
        guard area(overlap) > 0, size > 0 else { return false }
        let inside = area(overlap) / size
        if c.pid == host.pid {
            // Menus, popovers, panels, tooltips; at the normal level only a sheet (inside it, smaller).
            if c.layer > 0 { return true }
            return inside >= 0.9 && size < area(host.bounds) * 0.95
        }
        if c.owner == "Window Server" { return c.layer >= popUpMenuLevel && inside >= 0.5 }
        if c.regularApp { return false }
        if let o = c.owner, systemOwners.contains(o) { return false }
        guard size <= area(host.bounds) * 1.1 else { return false }
        if isRemoteService(c) { return inside >= 0.5 }
        return hostInFront && inside >= 0.8 && c.id > host.id
    }

    /// Whether a spot is clear for a click on the watched window: the first window there (front to
    /// back) that's the watched one or a companion of it, before any other ordinary-level window.
    /// Other windows above the normal level (another app's floating panel) are passed over, as the
    /// old check did. `.companion` means post straight there — no raise, no wait.
    public enum Spot: Equatable, Sendable { case watched, companion, covered }

    public static func spot(_ p: CGPoint, watched: UInt32, in list: [Window], hostInFront: Bool, me: Int32 = -1) -> Spot {
        guard let i = list.firstIndex(where: { $0.id == watched }) else { return .covered }
        let host = list[i]
        for w in list[..<i] where w.pid != me && w.alpha >= 0.05 && w.bounds.contains(p) {
            if isCompanion(w, of: host, hostInFront: hostInFront) { return .companion }
            if w.layer == 0 { return .covered }
        }
        return host.bounds.contains(p) ? .watched : .covered
    }

    /// The part of the screen to stream: the watched window and its companions, on the display it's
    /// on (clipped to it), in whole points.
    public static func area(window: CGRect, companions: [CGRect], display: CGRect?) -> CGRect {
        var r = companions.reduce(window) { $0.union($1) }
        if let display {
            let clipped = r.intersection(display)
            if !clipped.isNull, clipped.width >= 1, clipped.height >= 1 { r = clipped }
        }
        return r.integral
    }

    /// A spot on the phone's picture (fractions of what's streamed) on screen.
    public static func point(_ fraction: CGPoint, in area: CGRect) -> CGPoint {
        CGPoint(x: area.minX + fraction.x * area.width, y: area.minY + fraction.y * area.height)
    }

    /// A rect given as fractions of the window, as fractions of the streamed area instead (the
    /// place to type, so the phone centres on it in the wider picture).
    public static func reframe(_ f: CGRect, window: CGRect, in area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return f }
        let onScreen = CGRect(x: window.minX + f.minX * window.width, y: window.minY + f.minY * window.height,
                              width: f.width * window.width, height: f.height * window.height)
        return CGRect(x: (onScreen.minX - area.minX) / area.width, y: (onScreen.minY - area.minY) / area.height,
                      width: onScreen.width / area.width, height: onScreen.height / area.height)
    }

    /// What's streamed: the watched window alone (nil), or it with these companions over this area.
    public struct Plan: Equatable, Sendable {
        public var ids: [UInt32]
        public var area: CGRect
        public init(ids: [UInt32], area: CGRect) { self.ids = ids.sorted(); self.area = area.integral }
    }

    /// When to change what's streamed — not every look: a new set of companions (or a moved area)
    /// goes at once (a menu should show the moment it opens); going back to the window alone waits
    /// until they've been gone `settle` seconds (a menu closing as its submenu opens, a sheet
    /// swapped for the next one) so the stream isn't remade back and forth.
    public struct Settle: Sendable {
        public private(set) var applied: Plan?
        private var goneSince: Date?
        public let settle: TimeInterval
        public init(settle: TimeInterval = 0.4) { self.settle = settle }

        public enum Change: Equatable, Sendable { case none, show(Plan), alone }

        public mutating func next(_ wanted: Plan?, now: Date = Date()) -> Change {
            guard let wanted else {
                guard applied != nil else { goneSince = nil; return .none }
                let since = goneSince ?? now
                goneSince = since
                guard now.timeIntervalSince(since) >= settle else { return .none }
                applied = nil
                goneSince = nil
                return .alone
            }
            goneSince = nil
            guard wanted != applied else { return .none }
            applied = wanted
            return .show(wanted)
        }

        /// The stream was made again (or dropped): it shows the window alone.
        public mutating func reset() { applied = nil; goneSince = nil }
    }
}
