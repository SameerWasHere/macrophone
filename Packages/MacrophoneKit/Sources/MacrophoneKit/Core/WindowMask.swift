import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The window's real corners (Nov 9 2026, Sameer: "I still see black in the corners too … Can't you
// just take the window recording and plop that straight in"). A single-window capture leaves what's
// outside a Mac window's rounded corners transparent, and that transparency doesn't survive the trip
// — HEVC's 4:2:0 planes and JPEG have no alpha — so the corners arrive black and the phone used to
// guess the radius off the pixels (and failed on real windows). Now the Mac reads the alpha ONCE per
// picture size from one BGRA frame of the window and sends the shape as a mask: the radius along the
// diagonal, and a small PNG whose four corner quadrants are the real alpha of the four corners, for a
// 9-slice layer mask on the phone — so any curve (Tahoe's continuous corners) clips exactly, at any
// zoom, for nothing per frame. The stream itself is untouched (420f HEVC as before).
//
// Why not HEVC with alpha: BGRA capture at 30 fps (four bytes a pixel instead of one and a half) and
// a second encoder layer, for four corners that never change — `mpctl alpha-bench` has the numbers.
//
// The wire: `.watchMask` (Mac → phone) only to a phone whose hello names `WatchWindowMask.feature`;
// the Mac names it in its welcome too. An older phone never sees it; a phone paired with an older Mac
// keeps the pixel guess.

/// The window's corner shape, as read off one frame with alpha.
public struct WatchWindowMask: Codable, Sendable, Equatable {
    public static let feature = "windowMask"
    /// A corner larger than this is no corner (a window nearly all transparent: a drag image, a
    /// panel fading in).
    public static let maxRadius = 160
    /// The PNG never weighs more.
    public static let maxBytes = 64 * 1024

    /// The picture's size, in pixels, the corners were read at.
    public var width: Int
    public var height: Int
    /// The corner radius, in picture pixels (0: square).
    public var radius: Double
    /// A PNG with alpha, `side` pixels a side: its four corner quadrants (`quadrant` a side) are
    /// the real alpha of the picture's four corners, the cross between them opaque — a 9-slice
    /// mask (`contentsCenter`). Nil for square corners, or when only the radius is known.
    public var corners: Data?

    public init(width: Int, height: Int, radius: Double, corners: Data? = nil) {
        self.width = width
        self.height = height
        self.radius = radius
        self.corners = corners
    }

    public var isValid: Bool {
        width > 0 && height > 0 && radius >= 0 && radius <= Double(Self.maxRadius) && (corners?.count ?? 0) <= Self.maxBytes
    }

    /// Applies to a picture of this size (the corners' pixels line up).
    public func fits(width w: Int, height h: Int) -> Bool { w == width && h == height }

    /// The radius for the same window at another picture width (the same window, scaled —
    /// narrowed for a remote link): the arc scales with the picture.
    public func radius(forWidth w: Int) -> Double {
        guard width > 0, w > 0 else { return radius }
        return (radius * Double(w) / Double(width)).rounded()
    }

    // MARK: 9-slice geometry

    /// A corner quadrant's side, in pixels: the radius plus one for the arc's anti-aliased edge.
    public static func quadrant(radius: Double) -> Int { Int(radius.rounded(.up)) + 1 }
    /// The mask image's side: two quadrants and a 2-pixel opaque cross between them (what the
    /// 9-slice stretches).
    public static func side(radius: Double) -> Int { 2 * quadrant(radius: radius) + 2 }

    public var quadrant: Int { Self.quadrant(radius: radius) }
    public var side: Int { Self.side(radius: radius) }

    /// `CALayer.contentsCenter` for the PNG: the 2 × 2 middle, in unit coordinates.
    public var contentsCenter: CGRect {
        let s = CGFloat(side), q = CGFloat(quadrant)
        return CGRect(x: q / s, y: q / s, width: 2 / s, height: 2 / s)
    }
}

/// Reads a window's corners off a frame with alpha. Pure: given a way to read alpha at a pixel.
public enum WindowMaskReader {
    /// Alpha at or above this is the window; below it, outside.
    public static let edge: UInt8 = 128

    /// The corner radius the top two corners' transparent runs describe, in pixels: each walked
    /// down its diagonal from the corner; both must agree (within a third) and end inside
    /// `maxRadius`. 0 for square corners (no transparent run, or the two disagree); nil when the
    /// picture is transparent too far in (not a window's corner).
    public static func radius(width w: Int, height h: Int, alpha: (Int, Int) -> UInt8) -> Double? {
        guard w > 8, h > 8 else { return nil }
        let limit = min(WatchWindowMask.maxRadius, w / 2 - 1, h / 2 - 1)
        // The transparent run along the diagonal, to a fraction of a pixel: each pixel below the
        // edge counts its transparency, and the pixel that ends the run (the arc's anti-aliased
        // one) its share too. Nil when the run reaches the limit (not a corner).
        func run(_ x: (Int) -> Int) -> Double? {
            var t = 0, length = 0.0
            while t < limit {
                let a = alpha(x(t), t)
                length += Double(255 - a) / 255
                if a >= edge { return length }
                t += 1
            }
            return nil
        }
        guard let left = run({ $0 }), let right = run({ w - 1 - $0 }) else { return nil }
        guard left >= 0.5, right >= 0.5 else { return 0 }
        guard abs(left - right) <= max(2, max(left, right) / 3) else { return 0 }
        // The radius is where the arc meets the edge — along the top row from each corner, and
        // down each side — not what a circle through the diagonal's run would have: a Tahoe
        // window's corner is a continuous curve, shallower on the diagonal than a circle (seen on
        // a real window: 9.6 px transparent on the diagonal, the edge opaque from 48 px — a circle
        // of 33 by the diagonal, of 48 by the edge). The mask's quadrant must hold the whole arc,
        // so the edge's number is the one; the diagonal only says there IS a corner.
        func reach(_ at: (Int) -> (Int, Int)) -> Double? {
            var t = 0
            while t < limit { let (x, y) = at(t); if alpha(x, y) >= 250 { return Double(t) }; t += 1 }
            return nil
        }
        let top: (Int) -> (Int, Int) = { t in (t, 0) }, topRight: (Int) -> (Int, Int) = { t in (w - 1 - t, 0) }
        let leftSide: (Int) -> (Int, Int) = { t in (0, t) }, rightSide: (Int) -> (Int, Int) = { t in (w - 1, t) }
        let edges = [reach(top), reach(topRight), reach(leftSide), reach(rightSide)].compactMap { $0 }
        if edges.count == 4 { return (edges.reduce(0, +) / 4).rounded() }
        // An edge that never turns opaque (a translucent window): the circle the diagonal gives.
        let t = (left + right) / 2
        return (t / (1 - 1 / 2.squareRoot())).rounded()
    }

    /// The mask for a picture of `w` × `h` whose alpha is `alpha(x, y)` (top-left origin). Nil
    /// when the picture isn't a window (transparent too far in).
    public static func make(width w: Int, height h: Int, alpha: (Int, Int) -> UInt8) -> WatchWindowMask? {
        guard let r = radius(width: w, height: h, alpha: alpha) else { return nil }
        guard r > 0 else { return WatchWindowMask(width: w, height: h, radius: 0) }
        let png = cornersPNG(width: w, height: h, radius: r, alpha: alpha)
        return WatchWindowMask(width: w, height: h, radius: r, corners: png)
    }

    /// The 9-slice PNG: `side` a side, its corner quadrants the picture's own corner alpha (the
    /// quadrant's pixel (i, j) is the picture's (i, j), (w − q + i, j), … — the arc's first
    /// quadrant-plus-one pixels), the cross between them opaque. RGBA with white under the alpha,
    /// so a mask layer and a plain look at the file both read it.
    public static func cornersPNG(width w: Int, height h: Int, radius r: Double, alpha: (Int, Int) -> UInt8) -> Data? {
        let q = WatchWindowMask.quadrant(radius: r), s = WatchWindowMask.side(radius: r)
        guard q * 2 <= min(w, h), s > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: s * s * 4)
        for y in 0..<s {
            for x in 0..<s {
                let a: UInt8
                // The picture pixel this mask pixel stands for; the cross in the middle is opaque.
                let px: Int? = x < q ? x : x >= s - q ? w - s + x : nil
                let py: Int? = y < q ? y : y >= s - q ? h - s + y : nil
                if let px, let py { a = alpha(px, py) } else { a = 255 }
                let i = (y * s + x) * 4
                pixels[i] = a; pixels[i + 1] = a; pixels[i + 2] = a; pixels[i + 3] = a
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: s, height: s, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: s * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// The mask for a picture with alpha (a BGRA capture of one window, the demo window): its
    /// alpha is drawn into an alpha-only bitmap and read from there. Nil for a picture with no
    /// alpha at all (nothing to read: the phone keeps its own guess).
    public static func make(from image: CGImage) -> WatchWindowMask? {
        let w = image.width, h = image.height
        guard w > 8, h > 8 else { return nil }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return nil
        default: break
        }
        // Drawn into RGBA (premultiplied, alpha last) and the alpha byte read: one frame, once per
        // size, so the four bytes a pixel don't matter.
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let stride = ctx.bytesPerRow
        let p = data.assumingMemoryBound(to: UInt8.self)
        // A bitmap context's first row in memory is the image's top row.
        return make(width: w, height: h, alpha: { x, y in p[y * stride + x * 4 + 3] })
    }

    /// The mask for a BGRA frame in memory (a one-frame capture's pixel buffer, locked): the alpha
    /// byte of each 32-bit pixel is the fourth (B, G, R, A in memory). Nil when the frame is
    /// transparent too far in (not a window).
    public static func make(bgra base: UnsafeRawPointer, width w: Int, height h: Int, bytesPerRow: Int) -> WatchWindowMask? {
        let p = base.assumingMemoryBound(to: UInt8.self)
        return make(width: w, height: h, alpha: { x, y in p[y * bytesPerRow + x * 4 + 3] })
    }

    /// The PNG back as an image (the phone's mask layer contents).
    public static func image(_ png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
