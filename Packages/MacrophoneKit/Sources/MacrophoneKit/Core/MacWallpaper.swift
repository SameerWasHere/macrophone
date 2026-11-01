import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// The Mac's desktop picture on the iPhone (Nov 1 2026, Sameer: "imagine if Apple built a Mac
// controller for the iPhone"). The phone is being drawn as a little macOS desktop, and behind it
// goes the connected Mac's own wallpaper — the one thing that says "this is my Mac" at a glance.
//
// The wire: `.macWallpaper` (Mac → phone, after the welcome and whenever the picture changes) only
// to a phone whose hello names `MacWallpaper.feature`; the Mac names it in its welcome too. An
// older peer never sees it (an unknown message ends a session). Nothing goes the other way.
//
// What travels is the whole picture as a JPEG, never cropped, its long side at most 2,400 px: the
// phone takes the slice its own shape needs (upright, on its side, the Duo's inner screen), and a
// crop made on the Mac for one of those would starve the others. It's drawn afresh before it's
// encoded, so nothing of the file rides along — no name, no path, no photo's location; the id is
// a hash of the JPEG's bytes.

/// The Mac's desktop picture, ready for the phone.
public struct MacWallpaper: Codable, Sendable, Equatable {
    public static let feature = "wallpaper"
    /// The long side, at most (a 16:9 picture comes as 2400 × 1350; a smaller one as it is).
    public static let maxSide = 2400
    /// What a picture should weigh: the quality steps down from 0.7 until it does.
    public static let targetBytes = 400_000
    /// Never more (a frame is capped at 2 MB, and the JSON carries the bytes as base64).
    public static let maxBytes = 1_200_000

    /// A hash of the JPEG's bytes: the same picture always has the same id, so the phone can keep
    /// the last one for each Mac and skip one it already has.
    public var id: String
    public var jpeg: Data
    /// In pixels.
    public var width: Int
    public var height: Int
    /// Mostly dark (light text and glass read on it); nil when it couldn't be told.
    public var isDark: Bool?

    public init(id: String, jpeg: Data, width: Int, height: Int, isDark: Bool?) {
        self.id = id
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.isDark = isDark
    }

    /// Something a phone can show: a picture with a size and an id of sane length.
    public var isValid: Bool {
        !jpeg.isEmpty && (1...16_384).contains(width) && (1...16_384).contains(height) && (1...64).contains(id.count)
    }

    /// The id for these bytes: the first 16 hex digits of their SHA-256.
    public static func id(of jpeg: Data) -> String {
        SHA256.hash(data: jpeg).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Making one

extension MacWallpaper {
    /// The picture as it goes on the wire: drawn again so its long side is at most `maxSide` (a
    /// smaller one keeps its size), as a JPEG at quality 0.7 — less if that weighs more than
    /// `targetBytes` — and never over `maxBytes`. Nil when it can't be drawn or encoded.
    public static func make(from image: CGImage, maxSide: Int = MacWallpaper.maxSide) -> MacWallpaper? {
        guard image.width > 0, image.height > 0, maxSide > 0 else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let drawn = draw(image, width: w, height: h) else { return nil }
        var jpeg: Data?
        for quality in [0.7, 0.6, 0.5, 0.4, 0.3] {
            guard let data = encodeJPEG(drawn, quality: quality) else { return nil }
            jpeg = data
            if data.count <= targetBytes { break }
        }
        guard let jpeg, jpeg.count <= maxBytes else { return nil }
        return MacWallpaper(id: id(of: jpeg), jpeg: jpeg, width: w, height: h, isDark: isDark(drawn))
    }

    /// Mostly dark: the picture's average brightness (Rec. 709 weights on the encoded values,
    /// over an 8 × 8 reduction) under the middle.
    public static func isDark(_ image: CGImage) -> Bool? {
        let side = 8
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var total = 0.0
        for i in 0..<(side * side) {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            total += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }
        return total / Double(side * side) < 0.5
    }

    /// Drawn into a fresh bitmap (in the picture's own colours when they're RGB, else sRGB).
    static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let own = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
        guard let space = own ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: The demo picture

extension MacWallpaper {
    /// A soft gradient in the way of macOS Tahoe's own pictures — washes of blue, teal and lilac
    /// over a night-blue ground — for the protocol proof (`mpctl serve`) and the phone's
    /// screenshots without a Mac (MACROPHONE_FAKE_WALLPAPER=1).
    public static func demoImage(width: Int = 2400, height: Int = 1350) -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height), span = max(w, h)
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        // The ground: deep blue at the top-left to indigo at the bottom-right (CG's origin is the bottom-left).
        if let ground = CGGradient(colorsSpace: space, colors: [color(0x14245E), color(0x1E3A8A), color(0x2A1E5C)] as CFArray, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // The washes, each a soft-edged glow: (1 − t²)² falls off with no point at the middle.
        let washes: [(x: CGFloat, y: CGFloat, r: CGFloat, hex: UInt32, a: CGFloat)] = [
            (0.22, 0.28, 0.62, 0x2FB3C6, 0.85),  // teal, low left
            (0.80, 0.74, 0.58, 0xB89DF2, 0.80),  // lilac, high right
            (0.58, 0.05, 0.50, 0x3F6FF0, 0.75),  // blue, along the foot
            (0.42, 0.92, 0.40, 0x6FA8FF, 0.45),  // sky, along the top
            (0.60, 0.52, 0.26, 0xEDE6FF, 0.35),  // the light in the middle
        ]
        for wash in washes {
            let stops: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
            let colors = stops.map { t in color(wash.hex, wash.a * (1 - t * t) * (1 - t * t)) }
            guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops) else { continue }
            let c = CGPoint(x: wash.x * w, y: wash.y * h)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: wash.r * span, options: [])
        }
        return ctx.makeImage()
    }

    /// The demo picture, ready for the wire.
    public static func demo(width: Int = 2400, height: Int = 1350) -> MacWallpaper? {
        demoImage(width: width, height: height).flatMap { make(from: $0) }
    }
}
