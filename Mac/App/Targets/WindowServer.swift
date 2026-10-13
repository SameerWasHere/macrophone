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

    static func exists(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == id }
    }
}
