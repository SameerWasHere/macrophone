import CoreImage
import CryptoKit
import Foundation
import ImageIO
import MacrophoneKit
import UIKit

/// Each window's last picture (Nov 3 2026, Sameer: "show the last picture right away"): kept on
/// this iPhone, per Mac and per place, so a window opening — at launch, on the Duo opening, on a
/// switch — shows what it last looked like, dimmed, until the Mac's first frame takes over. Never
/// leaves the phone; dropped with the app's caches. Small: at most 1,280 px on its long side.
enum WindowSnapshots {
    static let longSide: CGFloat = 1280

    /// A place on a Mac, as a file name (a window's title changes, so only the app, the window's
    /// number and the display go in).
    static func key(mac: UUID?, target: TargetRef) -> String? {
        guard let mac, case let .app(bundleID, windowKey, _) = target else { return nil }
        let raw = "\(mac.uuidString)|\(bundleID)|\(windowKey ?? "")"
        return SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static var directory: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("WindowSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func url(_ key: String) -> URL { directory.appendingPathComponent("\(key).jpg") }

    /// The kept picture, decoded (small: a few ms), or nil.
    static func load(_ key: String?) -> UIImage? {
        guard let key, let data = try? Data(contentsOf: url(key)), let ui = UIImage(data: data) else { return nil }
        return ui.preparingForDisplay() ?? ui
    }

    /// The kept picture from memory, else from disk once (a screen's first frame can draw it, so
    /// nothing shows a placeholder first and then jumps to the picture).
    static func cached(_ key: String?) -> UIImage? {
        guard let key else { return nil }
        if let m = memory.object(forKey: key as NSString) { return m }
        guard let ui = load(key) else { return nil }
        memory.setObject(ui, forKey: key as NSString)
        return ui
    }

    private static let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 6
        return c
    }()

    /// Every kept picture gone (DEBUG `MACROPHONE_FORGET_WINDOWS`, Nov 8 2026: the first open's state).
    static func forgetAll() {
        memory.removeAllObjects()
        smallMemory.removeAllObjects()
        sizes.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
    }

    /// A window's picture was kept (posted on the main thread, the key as the object): the
    /// desktop's card draws the new one.
    static let didKeep = Notification.Name("WindowSnapshots.didKeep")

    /// Kept off the main thread.
    static func save(_ image: UIImage, key: String) {
        memory.removeObject(forKey: key as NSString)
        Task.detached(priority: .utility) {
            guard let small = shrink(image), let data = small.jpegData(compressionQuality: 0.6) else { return }
            try? data.write(to: url(key), options: .atomic)
            kept(small, key: key)
        }
    }

    /// The video's frame on screen, kept off the main thread (the copy itself is cheap).
    static func save(_ buffer: CVPixelBuffer, key: String) {
        memory.removeObject(forKey: key as NSString)
        nonisolated(unsafe) let b = buffer
        Task.detached(priority: .utility) {
            let ci = CIImage(cvPixelBuffer: b)
            let scale = min(1, longSide / max(ci.extent.width, ci.extent.height))
            let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return }
            let ui = UIImage(cgImage: cg)
            guard let data = ui.jpegData(compressionQuality: 0.6) else { return }
            try? data.write(to: url(key), options: .atomic)
            kept(ui, key: key)
        }
    }

    /// The new picture is the one in memory — a screen that read the file while it was being
    /// written would otherwise keep the old one until the next save — and the card hears of it.
    private static func kept(_ image: UIImage, key: String) {
        forgetSmall(key)
        memory.setObject(image.preparingForDisplay() ?? image, forKey: key as NSString)
        Task { @MainActor in NotificationCenter.default.post(name: didKeep, object: key) }
    }

    // MARK: The Dock's window previews (Nov 5 2026)

    /// The kept picture's size in pixels, read off the file's header (no decode): a card takes
    /// its shape at once, before its picture is drawn, so the previews never change width.
    static func pictureSize(_ key: String?) -> CGSize? {
        guard let key else { return nil }
        if let s = sizes.object(forKey: key as NSString) { return s.cgSizeValue }
        guard let src = CGImageSourceCreateWithURL(url(key) as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? CGFloat, let h = p[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0 else { return nil }
        let size = CGSize(width: w, height: h)
        sizes.setObject(NSValue(cgSize: size), forKey: key as NSString)
        return size
    }

    /// A card's picture: the kept one decoded small (ImageIO's thumbnail, `maxPixel` on its long
    /// side), from memory once made. Nil when this window has no picture yet.
    static func smallCached(_ key: String?) -> UIImage? {
        guard let key else { return nil }
        return smallMemory.object(forKey: key as NSString)
    }

    /// Made off the main thread (a few ms each).
    static func small(_ key: String?, maxPixel: CGFloat) async -> UIImage? {
        guard let key else { return nil }
        if let m = smallMemory.object(forKey: key as NSString) { return m }
        let file = url(key)
        let made: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let made { smallMemory.setObject(made, forKey: key as NSString) }
        return made
    }

    /// A new picture was kept: the small one and its size are made again from it next time.
    private static func forgetSmall(_ key: String) {
        smallMemory.removeObject(forKey: key as NSString)
        sizes.removeObject(forKey: key as NSString)
    }

    private static let smallMemory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 40
        return c
    }()

    private static let sizes = NSCache<NSString, NSValue>()

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The video's frame on screen as a picture, at its own size (held over a dropped link).
    static func image(from buffer: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Where you type in the window (the Mac's `focus`, fractions of it), kept with its picture.
    static func keep(focus: CGRect?, key: String) {
        let k = "watch.focus.\(key)"
        if let f = focus { UserDefaults.standard.set([f.minX, f.minY, f.width, f.height], forKey: k) }
        else { UserDefaults.standard.removeObject(forKey: k) }
    }

    static func focus(_ key: String?) -> CGRect? {
        guard let key, let v = UserDefaults.standard.array(forKey: "watch.focus.\(key)") as? [Double], v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    private static func shrink(_ image: UIImage) -> UIImage? {
        let size = image.size
        let scale = min(1, longSide / max(size.width, size.height))
        guard scale < 1 else { return image }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }
}
