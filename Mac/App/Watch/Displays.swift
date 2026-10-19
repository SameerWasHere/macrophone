import AppKit
import CoreGraphics
import Foundation
import MacrophoneKit

/// Pick a display (Oct 19 2026): this Mac's displays as a phone sees them, and which one the whole
/// screen shows. A phone that names Displays.feature hears the list after welcome and whenever a
/// display is plugged in, moved or unplugged; its Whole Screen place names one by its UUID
/// (`Displays.key`), and `WindowServer.desktopBounds` — the stream, the fit, every click and
/// scroll on the whole screen — follows `watched`.
///
/// One display at a time for the whole screen: two phones watching two displays at once would
/// share the last one picked (a phone and a Mac, in practice, are one person).
enum MacDisplays {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var picked: CGDirectDisplayID?

    /// The display the whole screen shows: the one picked while it's still connected, else the main one.
    static var watched: CGDirectDisplayID {
        let id = lock.withLock { picked }
        if let id, online().contains(id) { return id }
        return CGMainDisplayID()
    }

    /// Shows this display (by its key from the phone; nil or unknown = the main one).
    static func watch(key: String?) {
        let id = key.flatMap(displayID(forKey:))
        lock.withLock { picked = id }
    }

    /// The displays in use, not counting a mirror of another.
    static func online() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &n) == .success, n > 0 else { return [CGMainDisplayID()] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetActiveDisplayList(n, &ids, &n) == .success else { return [CGMainDisplayID()] }
        return Array(ids.prefix(Int(n))).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    /// A display's stable key: its UUID (the id itself changes across reboots and re-plugging).
    static func key(for id: CGDirectDisplayID) -> String {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, u) as String? else { return "id-\(id)" }
        return s
    }

    static func displayID(forKey key: String) -> CGDirectDisplayID? {
        online().first { self.key(for: $0) == key }
    }

    /// What a phone is told. The names are the system's ("Built-in Retina Display", "Studio Display").
    @MainActor static func current() -> [MacDisplay] {
        #if DEBUG
        if let fake = fakeDisplays { return fake }
        #endif
        let names: [CGDirectDisplayID: String] = Dictionary(NSScreen.screens.compactMap { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { ($0.uint32Value, s.localizedName) }
        }, uniquingKeysWith: { a, _ in a })
        let main = CGMainDisplayID()
        return online().map { id in
            let b = CGDisplayBounds(id)
            let name = names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display")
            return MacDisplay(id: key(for: id), name: name, x: b.minX, y: b.minY, width: b.width, height: b.height, isMain: id == main)
        }
    }

    /// Whether the Mac's own brightness keys reach a display here: a built-in one, or an Apple
    /// display (Studio Display, Pro Display XDR, the LG UltraFine's own controls). Other displays
    /// take brightness only from their own buttons (DDC isn't something a key can reach).
    static var brightnessKeysWork: Bool {
        online().contains { CGDisplayIsBuiltin($0) != 0 || CGDisplayVendorNumber($0) == 0x0610 }
    }

    #if DEBUG
    /// MACROPHONE_FAKE_DISPLAYS=1: a second display to the left of the main one, in the list a
    /// phone hears (the whole screen still shows the main one — there is no second to stream).
    private static var fakeDisplays: [MacDisplay]? {
        guard ProcessInfo.processInfo.environment["MACROPHONE_FAKE_DISPLAYS"] == "1" else { return nil }
        let main = CGDisplayBounds(CGMainDisplayID())
        return [MacDisplay(id: key(for: CGMainDisplayID()), name: "Built-in Retina Display", x: 0, y: 0, width: main.width, height: main.height, isMain: true),
                MacDisplay(id: "fake-studio", name: "Studio Display", x: -2560, y: -300, width: 2560, height: 1440, isMain: false)]
    }
    #endif
}
