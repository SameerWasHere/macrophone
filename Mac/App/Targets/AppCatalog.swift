import AppKit
import Foundation
import MacrophoneKit

/// Open an app (Oct 14 2026): the apps installed on this Mac, for the phone's list, and opening
/// one — launched if it isn't running, brought forward with a window either way.
enum AppCatalog {
    /// Where apps live. One level into folders (Utilities, a vendor's folder).
    private static var roots: [URL] {
        ["/Applications", "/System/Applications", "/System/Applications/Utilities",
         NSHomeDirectory() + "/Applications", "/Applications/Setapp"].map { URL(fileURLWithPath: $0) }
    }

    private static let iconCache = NSCache<NSString, NSData>()

    /// Every app a person opens themselves, by name: no menu bar agents, background helpers or
    /// Macrophone itself. Runs off the main thread.
    static func installed() async -> [MacApp] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return await Task.detached(priority: .userInitiated) {
            var seen = Set<String>()
            var out: [MacApp] = []
            let fm = FileManager.default
            func consider(_ url: URL) {
                guard url.pathExtension == "app", let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier,
                      !seen.contains(bid), bid != Bundle.main.bundleIdentifier, !bid.hasPrefix("com.sameer.macrophone") else { return }
                let info = bundle.infoDictionary ?? [:]
                if (info["LSUIElement"] as? Bool) == true || (info["LSUIElement"] as? String) == "1" { return }
                if (info["LSBackgroundOnly"] as? Bool) == true { return }
                seen.insert(bid)
                var name = fm.displayName(atPath: url.path)
                if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
                out.append(MacApp(bundleID: bid, name: name, icon: icon(url, bid), running: running.contains(bid)))
            }
            for root in roots {
                guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for item in items {
                    if item.pathExtension == "app" { consider(item); continue }
                    if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                       let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        inner.filter { $0.pathExtension == "app" }.forEach(consider)
                    }
                }
            }
            return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    /// A 64 px PNG of the app's icon.
    private static func icon(_ url: URL, _ bid: String) -> Data? {
        if let d = iconCache.object(forKey: bid as NSString) { return d as Data }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let px = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        iconCache.setObject(data as NSData, forKey: bid as NSString)
        return data
    }

    /// Opens the app (or brings it forward, asking it for a window if it has none).
    @MainActor static func open(_ bundleID: String) async -> (Bool, String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (false, "That app isn't on your Mac any more")
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            AX.bringToFront(app)
            return (true, "\(name) is open on your Mac")
        } catch {
            return (false, "Couldn't open \(name) on your Mac")
        }
    }
}
