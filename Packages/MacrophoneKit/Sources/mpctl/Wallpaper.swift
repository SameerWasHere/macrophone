import Foundation
import ImageIO
import MacrophoneKit

// The Mac's desktop picture (Nov 1 2026) in the protocol proof. `mpctl serve` sends a phone that
// names MacWallpaper.feature the drawn demo gradient (blue, teal, lilac, after Tahoe's pictures),
// or with `--wallpaper <path>` any picture ImageIO reads, made exactly as the Mac app makes its
// own. A phone-side command run with `--features wallpaper` prints `WALLPAPER <w>×<h> <KB> KB`.

enum ServeWallpaper {
    /// Made once, on first use (off the main actor): --wallpaper's picture, else the demo.
    static let made: MacWallpaper? = {
        let t0 = Date()
        let w: MacWallpaper?
        if let path = flag("--wallpaper") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                           kCGImageSourceThumbnailMaxPixelSize: MacWallpaper.maxSide] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options) else {
                stdout("WALLPAPER couldn't read \(url.lastPathComponent)")
                return nil
            }
            w = MacWallpaper.make(from: image)
        } else {
            w = MacWallpaper.demo()
        }
        if let w { stdout("WALLPAPER made \(w.width)×\(w.height) \(w.jpeg.count / 1024) KB in \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
        return w
    }()
}

extension ServeDelegate: LinkServerWallpaperDelegate {
    func macWallpaper(_ server: LinkServer, for peerID: UUID) async -> MacWallpaper? {
        let w = await Task.detached(priority: .utility) { ServeWallpaper.made }.value
        if let w { stdout("WALLPAPER sent \(w.width)×\(w.height) \(w.jpeg.count / 1024) KB") }
        return w
    }
}

extension PhoneDelegate: LinkClientWallpaperDelegate {
    func linkClient(_ client: LinkClient, macWallpaper w: MacWallpaper, macID: UUID) {
        stdout("WALLPAPER \(w.width)×\(w.height) \(w.jpeg.count / 1024) KB"
               + (w.isDark.map { $0 ? " · dark" : " · light" } ?? "") + " · id \(w.id)")
        // --save-wallpaper <file.jpg>: the bytes as they came.
        if let path = flag("--save-wallpaper") {
            try? w.jpeg.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            stdout("WALLPAPER saved to \(path)")
        }
    }
}
