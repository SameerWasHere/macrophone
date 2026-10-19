import AppKit
import CoreGraphics
import Foundation

/// What the window server knows that Accessibility doesn't: every app's windows on every
/// desktop (Space), front to back. Accessibility only sees windows on the current desktop.
/// No titles are read here (those need Screen Recording) — only ids, owners, sizes and order.
enum WindowServer {
    struct Window: Hashable {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        /// Front-to-back position (0 = front-most).
        let z: Int
    }

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    private static let mainConnection: MainConnectionFn? = dlsym(handle, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnectionFn.self) }
    private static let copySpaces: CopySpacesFn? = dlsym(handle, "CGSCopySpacesForWindows").map { unsafeBitCast($0, to: CopySpacesFn.self) }

    /// Real app windows on some desktop: layer 0, a usable size, and placed on a Space (a window
    /// an app has ordered out — a closed Messages window, a hidden login sheet — is on none).
    static func appWindows() -> [Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let cid = mainConnection?()
        var out: [Window] = []
        var z = 0
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.width >= 160, rect.height >= 90 else { continue }
            if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
            let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            if !onscreen {
                // Off this desktop: keep it only if it lives on another one.
                guard let cid, let copySpaces,
                      let spaces = copySpaces(cid, 0x7, [id] as CFArray)?.takeRetainedValue() as? [Any], !spaces.isEmpty else { continue }
            }
            out.append(Window(id: id, pid: pid, bounds: rect, z: z))
            z += 1
        }
        return out
    }

    /// One window's frame on screen (top-left origin) — a lookup of that window alone, cheap enough
    /// for every step of a swipe (the whole list, with each window's desktops, isn't).
    /// Every window on this desktop worth watching, front to back — app windows, dialogs, panels and
    /// alerts (layers up to the pop-up levels), not the Dock, the menu bar or the wallpaper, nor
    /// Macrophone's own. Titles come with Screen Recording.
    static func everyWindow() -> [(id: CGWindowID, pid: pid_t, title: String?)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let skip: Set<String> = ["Dock", "Window Server", "SystemUIServer", "Control Center", "Spotlight", "Wallpaper", "WindowManager", "TextInputMenuAgent"]
        var out: [(id: CGWindowID, pid: pid_t, title: String?)] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, (0...25).contains(layer),
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.width >= 120, rect.height >= 60,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) >= 0.05 else { continue }
            if let owner = w[kCGWindowOwnerName as String] as? String, skip.contains(owner) { continue }
            let title = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.append((id, pid, title))
        }
        return out
    }

    /// The whole screen, watched like a window (DesktopWatch): its place is the picked display's
    /// (Oct 19 2026, `MacDisplays` — the main one unless a phone picked another), in global
    /// coordinates: a display left of or above the main one has a negative origin.
    static let desktopID: CGWindowID = 0x7FFF_FFF0
    static var desktopBounds: CGRect { CGDisplayBounds(MacDisplays.watched) }

    static func bounds(of id: CGWindowID) -> CGRect? {
        if id == desktopID { return desktopBounds }
        guard let w = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let b = w[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: b as CFDictionary)
    }

    /// Whether `id` is the window on top at a point on screen (a scroll event posted there reaches
    /// it): no on-screen app window of any app is above it there. Only windows on this desktop
    /// count — one on another desktop is listed in front, but covers nothing.
    static func isOnTop(_ id: CGWindowID, at p: CGPoint) -> Bool {
        if id == desktopID { return true }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) >= 0.05, rect.contains(p) else { continue }
            return wid == id
        }
        return false
    }

    static func exists(_ id: CGWindowID) -> Bool { info(id) != nil }

    /// One window's place: nil when it's gone; on screen = on this desktop and not minimized.
    static func info(_ id: CGWindowID) -> (onScreen: Bool, bounds: CGRect)? {
        if id == desktopID { return (true, desktopBounds) }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let w = list.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == id }) else { return nil }
        let bounds = (w[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        return ((w[kCGWindowIsOnscreen as String] as? Bool) ?? false, bounds)
    }
}
