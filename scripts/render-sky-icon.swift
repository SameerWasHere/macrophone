// Macrophone's app icon: the Thread on a night sky — SameerOS's icon (its scripts/render-app-icon.swift:
// one luminous thread, an S with tapered tips, a white-hot core and a wide soft glow, floating on a
// dusk sky with a scatter of stars) in Macrophone's colours. Sameer, Oct 18 2026: "look at the
// SameerOS app icon and model it after that with the colors we use in the app."
//
//   xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 scripts/render-sky-icon.swift -o /tmp/render-sky-icon
//   /tmp/render-sky-icon render <work dir>                    # the flats, the .icon bundles, the layers
//   /tmp/render-sky-icon sheet <work dir> <out dir> [SameerOS appiconset]   # the side-by-side sheet
//   /tmp/render-sky-icon install                              # writes the shipped icon in place (repo root)
//
// scripts/sky-icon.sh runs the whole pipeline.
//
// THE PORT. The composition, the strand and the light are SameerOS's number for number: a 1024 canvas,
// the sky a vertical four-stop gradient with a radial haze behind the thread, a seeded soft-light grain
// (so the long dark gradient dithers instead of banding), SameerOS's own star field (the same seed, the
// first 56 stars in the upper 38 % of the sky, each with a faint halo), and the Thread as ThreadMark's
// idle curve drawn bold: 401 samples across 78 % of the width, y = −0.1275·w·sin(2π(u−½))·sin(πu)^1.2,
// a ribbon tapered by sin(πu)^0.7 at 36 px half-width; a 150 px stroke of the spine's inner 70 % blurred
// 70 px at 0.5 (the halo), the ribbon at 2.3× blurred 26 px at 0.9 (the glow), the ribbon itself, and a
// white core at 0.36× blurred 8 px, plus-lighter at 0.48. Light, dark and tinted take SameerOS's stop
// positions and brightness factors; the tinted icon (white and greys on near black, iOS reads its
// luminance) is identical to SameerOS's.
//
// WHAT IS MACROPHONE'S. The spectrum is the Thread's at rest (Filament.swift `stops()` for .ready:
// violet 0 · cyan 0.5 · mint 1 — the cool half of `RGB.thread`; SameerOS runs the whole spectrum to
// coral), so the thread is cool where SameerOS's is warm. The sky is built from Theme.swift: Ink.ground
// lifted toward Light.violet is the night at the top, a fuller violet the evening, Ink.ground toward
// Light.cyan the glow at the horizon and toward Light.teal the foot — never SameerOS's terracotta
// and dawn rose. The haze behind the thread is cyan (SameerOS's is its second stop, also cyan).
//
// WHAT SHIPS. The same wiring as the Thread icon before it: iOS/Macrophone/AppIcon.icon and
// Mac/Resources/AppIcon.icon (Icon Composer bundles — Liquid Glass on iOS 26 / macOS 26+; three groups,
// each holding its light image and its dark one faded to 0 in the other appearance through
// `opacity-specializations`, the only specialization Xcode 27's actool keeps; tinted = the thread in
// white at 1, the light at ½, the sky hidden) and the classic AppIcon.appiconset PNGs (iOS 17–18:
// light / dark / tinted 1024, opaque; macOS 14–15: the squircle at every size).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Palette (Theme.swift, exactly)

struct RGB {
    var r, g, b: Double
    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    func scaled(_ k: Double) -> RGB { RGB(r: min(1, r * k), g: min(1, g * k), b: min(1, b * k)) }
    var color: Color { Color(red: r, green: g, blue: b) }
    var cg: CGColor { CGColor(colorSpace: srgb, components: [r, g, b, 1])! }

    // Ink (Theme.swift).
    static let ground = RGB(r: 0.020, g: 0.024, b: 0.051)   // #05060D
    static let raised = RGB(r: 0.075, g: 0.082, b: 0.125)   // #131520
    static let ink = RGB(r: 0.957, g: 0.949, b: 0.980)      // #F4F2FA
    // Light (Theme.swift) — the Filament's spectrum.
    static let cyan = RGB(r: 0.345, g: 0.725, b: 0.871)
    static let teal = RGB(r: 0.361, g: 0.827, b: 0.765)
    static let mint = RGB(r: 0.369, g: 0.839, b: 0.635)
    static let violet = RGB(r: 0.604, g: 0.525, b: 0.902)
    /// The Thread at rest (Filament.swift `stops()` for `.ready`): violet · cyan · mint.
    static let threadAtRest: [RGB] = [.violet, .cyan, .mint]
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// The sky's keyframes, as SameerOS's `Sky.keyframes` (a top colour and a mid colour each) — but
/// Macrophone's: the ground lifted toward the Thread's own light.
enum Sky {
    typealias Frame = (top: RGB, mid: RGB)
    /// Night: the ground toward the violet — the indigo at the top of the icon.
    static let night: Frame = (RGB.ground.mix(.violet, 0.30), RGB.ground.mix(.violet, 0.20))
    /// Evening: a fuller violet, the middle of the sky.
    static let evening: Frame = (RGB.ground.mix(.violet, 0.47), RGB.ground.mix(.violet, 0.33))
    /// The horizon: the cyan glow the app keeps behind the Thread.
    static let horizon: Frame = (RGB.ground.mix(.cyan, 0.64), RGB.ground.mix(.cyan, 0.46))
    /// The foot: the teal, where SameerOS has its dawn.
    static let dawn: Frame = (RGB.ground.mix(.teal, 0.66), RGB.ground.mix(.teal, 0.48))
}

// MARK: - SameerOS's star field (Ambient.swift: SeededGenerator + Sky.starField, the same seed)

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

struct SkyStar {
    let x: CGFloat, y: CGFloat, r: CGFloat, phase: Double, speed: Double
}

/// Deterministic — the same sky as SameerOS's, so the two icons share their stars.
let starField: [SkyStar] = {
    var g = SeededGenerator(seed: 0x5A4E)
    return (0..<160).map { _ in
        SkyStar(x: CGFloat.random(in: 0...1, using: &g),
                y: CGFloat.random(in: 0...0.75, using: &g) * CGFloat.random(in: 0.3...1, using: &g),
                r: CGFloat.random(in: 0.6...1.6, using: &g),
                phase: Double.random(in: 0...(2 * .pi), using: &g),
                speed: Double.random(in: 0.35...0.9, using: &g))
    }
}()

// MARK: - The icon (SameerOS's IconArt, ported)

struct IconArt: View {
    enum Variant: String, CaseIterable { case light, dark, tinted }

    /// What to draw: the whole icon, or one of the .icon bundle's layers.
    struct Parts: OptionSet {
        let rawValue: Int
        static let sky = Parts(rawValue: 1), grain = Parts(rawValue: 2), haze = Parts(rawValue: 4)
        static let stars = Parts(rawValue: 8), halo = Parts(rawValue: 16), glow = Parts(rawValue: 32)
        static let ribbon = Parts(rawValue: 64), core = Parts(rawValue: 128)
        static let all: Parts = [.sky, .grain, .haze, .stars, .halo, .glow, .ribbon, .core]
        /// The bundle's layers: the opaque sky, the translucent light, the strand (glass).
        static let skyLayer: Parts = [.sky, .grain, .haze]
        static let lightLayer: Parts = [.stars, .halo, .glow]
        static let threadLayer: Parts = [.ribbon, .core]
    }

    static let side: CGFloat = 1024
    let variant: Variant
    var parts: Parts = .all

    var body: some View {
        Canvas { ctx, size in
            if parts.contains(.sky) { drawSky(ctx, size) }
            if parts.contains(.grain) { drawGrain(ctx, size) }
            if parts.contains(.haze) { drawHaze(ctx, size) }
            if parts.contains(.stars) { drawStars(ctx, size) }
            drawThread(ctx, size)
        }
        .frame(width: Self.side, height: Self.side)
    }

    // MARK: Sky

    /// SameerOS's stop positions and brightness factors, Macrophone's keyframes.
    private var skyStops: [Gradient.Stop] {
        switch variant {
        case .dark:
            return [.init(color: Sky.night.mid.scaled(0.62).color, location: 0),
                    .init(color: Sky.evening.mid.scaled(0.95).color, location: 0.52),
                    .init(color: Sky.evening.top.scaled(0.78).color, location: 0.78),
                    .init(color: Sky.horizon.top.scaled(0.72).color, location: 1)]
        case .light:
            return [.init(color: Sky.night.top.scaled(1.0).color, location: 0),
                    .init(color: Sky.evening.top.scaled(1.15).color, location: 0.5),
                    .init(color: Sky.horizon.top.scaled(1.05).color, location: 0.84),
                    .init(color: Sky.dawn.top.scaled(1.25).color, location: 1)]
        case .tinted:
            return [.init(color: Color(white: 0.02), location: 0), .init(color: Color(white: 0.09), location: 1)]
        }
    }

    /// The two ends of the sky, for the bundle's fallback fill.
    static func fill(_ v: Variant) -> (RGB, RGB) {
        switch v {
        case .dark: return (Sky.night.mid.scaled(0.62), Sky.horizon.top.scaled(0.72))
        case .light: return (Sky.night.top, Sky.dawn.top.scaled(1.25))
        case .tinted: return (RGB(r: 0.02, g: 0.02, b: 0.02), RGB(r: 0.09, g: 0.09, b: 0.09))
        }
    }

    private func drawSky(_ ctx: GraphicsContext, _ size: CGSize) {
        let full = Path(CGRect(origin: .zero, size: size))
        ctx.fill(full, with: .linearGradient(Gradient(stops: skyStops),
                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }

    /// A haze behind the thread, so it sits in light rather than on paint.
    private func drawHaze(_ ctx: GraphicsContext, _ size: CGSize) {
        let full = Path(CGRect(origin: .zero, size: size))
        let haze: Color = variant == .tinted ? .white : RGB.cyan.color
        let c = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        ctx.fill(full, with: .radialGradient(Gradient(colors: [haze.opacity(variant == .light ? 0.16 : 0.12), haze.opacity(0)]),
                                             center: c, startRadius: 0, endRadius: size.width * 0.48))
    }

    /// A fine, neutral grain (soft light over mid grey changes nothing on average), so the long
    /// dark gradient dithers instead of banding when it is quantised to 8 bits.
    private func drawGrain(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let grain = Self.grain else { return }
        var g = ctx
        g.blendMode = .softLight
        g.opacity = 0.05
        g.draw(Image(decorative: grain, scale: 1), in: CGRect(origin: .zero, size: size))
    }

    /// Uniform noise, the same every render (seeded), one byte per pixel.
    private static let grain: CGImage? = {
        let side = Int(IconArt.side)
        var bytes = [UInt8](repeating: 0, count: side * side)
        var generator = SeededGenerator(seed: 0x51C0)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    private func drawStars(_ ctx: GraphicsContext, _ size: CGSize) {
        // The star field, upper sky only, quieter toward the thread.
        for s in starField.prefix(56) where s.y < 0.38 {
            let p = CGPoint(x: s.x * size.width, y: s.y * size.height * 0.9 + size.height * 0.05)
            let fade = 1 - Double(s.y) / 0.38
            let alpha = (0.2 + 0.5 * fade) * (variant == .light ? 0.4 : 0.6)
            let r = s.r * 2.2
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(alpha)))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)),
                     with: .radialGradient(Gradient(colors: [.white.opacity(alpha * 0.25), .white.opacity(0)]),
                                           center: p, startRadius: 0, endRadius: r * 3))
        }
    }

    // MARK: Thread

    private var threadStops: [Gradient.Stop] {
        if variant == .tinted {
            return [.init(color: Color(white: 0.72), location: 0), .init(color: Color(white: 0.92), location: 0.35),
                    .init(color: .white, location: 0.6), .init(color: Color(white: 0.8), location: 1)]
        }
        let s = RGB.threadAtRest
        return s.enumerated().map { .init(color: $1.color, location: Double($0) / Double(s.count - 1)) }
    }

    /// The Thread's resting stroke — one S rising left to right, cool end to warm, still at the tips.
    private func centerline(_ size: CGSize) -> [CGPoint] {
        let w = size.width * 0.78, x0 = (size.width - w) / 2, cy = size.height * 0.5
        return (0...400).map { i in
            let u = Double(i) / 400
            let env = pow(sin(.pi * u), 1.2)
            let y = -Double(w) * 0.1275 * sin(2 * .pi * (u - 0.5)) * env
            return CGPoint(x: x0 + CGFloat(u) * w, y: cy + CGFloat(y))
        }
    }

    private func ribbon(_ pts: [CGPoint], half: CGFloat) -> Path {
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        for i in pts.indices {
            let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
            let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 0.0001)
            let nx = -dy / len, ny = dx / len
            let u = Double(i) / Double(pts.count - 1)
            let h = half * CGFloat(pow(sin(.pi * u), 0.7))
            top.append(CGPoint(x: pts[i].x + nx * h, y: pts[i].y + ny * h))
            bottom.append(CGPoint(x: pts[i].x - nx * h, y: pts[i].y - ny * h))
        }
        var path = Path()
        path.addLines(top)
        path.addLines(bottom.reversed())
        path.closeSubpath()
        return path
    }

    private func drawThread(_ ctx: GraphicsContext, _ size: CGSize) {
        let pts = centerline(size)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: threadStops), startPoint: CGPoint(x: pts[0].x, y: 0), endPoint: CGPoint(x: pts[pts.count - 1].x, y: 0))
        let half: CGFloat = 36

        if parts.contains(.halo) {
            var spine = Path()
            spine.addLines(Array(pts[60...340]))
            var halo = ctx
            halo.opacity = variant == .tinted ? 0.3 : 0.5
            halo.addFilter(.blur(radius: 70))
            halo.stroke(spine, with: shading, style: StrokeStyle(lineWidth: 150, lineCap: .round, lineJoin: .round))
        }

        if parts.contains(.glow) {
            var glow = ctx
            glow.opacity = 0.9
            glow.addFilter(.blur(radius: 26))
            glow.fill(ribbon(pts, half: half * 2.3), with: shading)
        }

        if parts.contains(.ribbon) {
            ctx.fill(ribbon(pts, half: half), with: shading)
        }

        if parts.contains(.core) {
            var core = ctx
            core.blendMode = .plusLighter
            core.opacity = 0.48
            core.addFilter(.blur(radius: 8))
            core.fill(ribbon(pts, half: half * 0.36), with: .color(.white))
        }
    }
}

// MARK: - Rendering

enum RenderError: Error { case render(String), write(String) }

@MainActor
func render(_ variant: IconArt.Variant, parts: IconArt.Parts = .all) throws -> CGImage {
    let renderer = ImageRenderer(content: IconArt(variant: variant, parts: parts))
    renderer.proposedSize = ProposedViewSize(width: IconArt.side, height: IconArt.side)
    renderer.scale = 1
    guard let image = renderer.cgImage else { throw RenderError.render("\(variant) \(parts.rawValue)") }
    return image
}

/// Flattens onto an alpha-free bitmap (App Store Connect rejects an icon with alpha).
func opaque(_ image: CGImage) -> CGImage {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage()!
}

func resized(_ image: CGImage, to px: Int, opaque: Bool) -> CGImage {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: info)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

/// The iOS mask at a size: the continuous corner, ~22.37% of the side.
func iosMasked(_ image: CGImage, px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let r = Double(px) * 0.2237
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: px, height: px), cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

/// The macOS squircle on a clear canvas: an 824 body centred on 1024, the continuous corner, a soft shadow.
func macFlat(_ art: CGImage) -> CGImage {
    let px = 1024
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    func gray(_ w: Double, _ a: Double) -> CGColor { CGColor(colorSpace: srgb, components: [w, w, w, a])! }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: gray(0, 0.4))
    ctx.addPath(shape)
    ctx.setFillColor(gray(0, 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(art, in: body)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    // Lit from above: the brighter end at the top (this context is y-up).
    let edge = CGGradient(colorsSpace: srgb, colors: [gray(1, 0.05), gray(1, 0.28)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(edge, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func readPNG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - The .icon bundle (Icon Composer: icon.json + Assets/)

func color(_ c: RGB) -> String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b) }

/// `darkAsBase` swaps the appearances (the dark layers and fill as the base, the light ones under
/// "dark") — a bundle only for proving the dark look through the system's renderer.
func iconJSON(darkAsBase: Bool = false) -> [String: Any] {
    // The appearance names actool honours on a layer: light, dark, tinted — all three, through
    // `opacity-specializations` (a layer with a base "opacity" key loses them; `hidden-` and
    // `image-name-specializations` are dropped, checked on Xcode 27's actool). So each group
    // carries its light image and its dark one, each faded to 0 in the other's appearance.
    func spec(_ pairs: [(String, Any)]) -> [[String: Any]] { pairs.map { ["appearance": $0.0, "value": $0.1] } }
    let (lightName, darkName) = darkAsBase ? ("dark", "light") : ("light", "dark")
    let white: [String: Any] = ["solid": "extended-gray:1.00000,1.00000"]
    func layer(_ name: String, image: String, glass: Bool, opacity: [(String, Any)], tintedFill: Bool) -> [String: Any] {
        var l: [String: Any] = [
            "name": name, "image-name": image, "glass": glass, "hidden": false,
            "opacity-specializations": spec(opacity),
            "position": ["scale": 1, "translation-in-points": [0, 0]],
        ]
        if tintedFill { l["fill-specializations"] = spec([("tinted", white)]) }
        return l
    }
    func pair(_ base: String, glass: Bool, tinted: Double) -> [[String: Any]] {
        [layer("\(base)-dark", image: "\(base)-dark.png", glass: glass, opacity: [(lightName, 0), ("tinted", 0), (darkName, 1)], tintedFill: false),
         layer("\(base)-light", image: "\(base)-light.png", glass: glass, opacity: [(darkName, 0), ("tinted", tinted)], tintedFill: tinted > 0)]
    }
    // Front first (Icon Composer's sidebar order). The light-appearance layers show in light and —
    // white, through their alpha — in tinted; the dark-appearance layers only in dark.
    let groups: [[String: Any]] = [
        // The strand: glass, so the system lights its edge; its halo is a chromatic shadow (the
        // layer's own colour), as the Thread's glow is.
        ["name": "Thread", "layers": pair("thread", glass: true, tinted: 1), "lighting": "individual", "hidden": false, "specular": true,
         "shadow": ["kind": "layer-color", "opacity": 0.5], "translucency": ["enabled": false, "value": 0.45]],
        // The light round it and the stars: no glass, no shadow — a translucent picture.
        ["name": "Light", "layers": pair("light", glass: false, tinted: 0.5), "lighting": "individual", "hidden": false, "specular": false,
         "shadow": ["kind": "none", "opacity": 0], "translucency": ["enabled": false, "value": 0.45]],
        // The sky: the opaque ground, hidden in tinted (the system's tinted ground shows instead).
        ["name": "Sky", "layers": pair("sky", glass: false, tinted: 0), "lighting": "individual", "hidden": false, "specular": false,
         "shadow": ["kind": "none", "opacity": 0], "translucency": ["enabled": false, "value": 0.45]],
    ]
    let (lt, lb) = IconArt.fill(darkAsBase ? .dark : .light), (dt, db) = IconArt.fill(darkAsBase ? .light : .dark)
    return [
        "fill-specializations": [["value": ["linear-gradient": [color(lt), color(lb)]]],
                                 ["appearance": "dark", "value": ["linear-gradient": [color(dt), color(db)]]]],
        "groups": groups,
        "supported-platforms": ["squares": "shared", "circles": ["watchOS"]],
    ]
}

@MainActor
func writeIconBundle(at dir: String, darkAsBase: Bool = false) throws {
    let fm = FileManager.default
    try? fm.removeItem(atPath: dir)
    try fm.createDirectory(atPath: "\(dir)/Assets", withIntermediateDirectories: true)
    for a in [IconArt.Variant.light, .dark] {
        writePNG(opaque(try render(a, parts: .skyLayer)), "\(dir)/Assets/sky-\(a.rawValue).png")
        writePNG(try render(a, parts: .lightLayer), "\(dir)/Assets/light-\(a.rawValue).png")
        writePNG(try render(a, parts: .threadLayer), "\(dir)/Assets/thread-\(a.rawValue).png")
    }
    let data = try JSONSerialization.data(withJSONObject: iconJSON(darkAsBase: darkAsBase), options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: "\(dir)/icon.json"))
    print("wrote \(dir)")
}

// MARK: - The sheet: SameerOS's icon beside Macrophone's

@MainActor
func sheet(_ work: String, out: String, sameerOS: String) throws {
    let big = 400, pad = 40, gap = 24
    let small = [180, 120, 87]
    let smallW = small.reduce(0, +) + 16 * (small.count - 1)
    let W = pad + 3 * (big + gap) + smallW + pad
    let rowH = big + 120
    let rows = 3
    let H = pad + 60 + rows * rowH + pad
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: srgb, components: [0.12, 0.12, 0.12, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.interpolationQuality = .high
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    func label(_ s: String, _ x: Int, _ y: Int, size: CGFloat = 20, bold: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                                                    .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        NSString(string: s).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }
    var top = H - pad
    label("The SameerOS app icon, and Macrophone's modelled on it — light · dark · tinted, then 60 · 40 · 29 pt @3x (light, dark)", pad, top - 34, size: 26, bold: true)
    top -= 60

    // Row 1: SameerOS (its AppIcon-Light/Dark/Tinted.png). Row 2: Macrophone's flats. Row 3: the
    // system's Liquid Glass renders of the bundle, and the macOS squircle.
    typealias Row = (title: String, images: [(String, CGImage?)], smalls: [(String, CGImage?)])
    let sos = ["Light", "Dark", "Tinted"].map { ($0.lowercased(), readPNG("\(sameerOS)/AppIcon-\($0).png")) }
    let mac = IconArt.Variant.allCases.map { ($0.rawValue, readPNG("\(work)/flat-\($0.rawValue).png")) }
    let system: [(String, CGImage?)] = [("macOS 27 draws the .icon · light", readPNG("\(work)/sky/system-1024.png")),
                                        ("the same · dark (the swapped bundle)", readPNG("\(work)/sky-dark/system-1024.png")),
                                        ("the macOS 14–15 squircle · light", readPNG("\(work)/flat-mac.png"))]
    let rowsToDraw: [Row] = [
        ("SameerOS — the model (SameerOS/Assets.xcassets/AppIcon.appiconset)", sos, Array(sos.prefix(2))),
        ("Macrophone — the Thread at rest on its night sky", mac, Array(mac.prefix(2))),
        ("Macrophone — what the system makes of the bundle", system, []),
    ]
    for row in rowsToDraw {
        label(row.title, pad, top - 34, size: 26, bold: true)
        var x = pad
        let y0 = top - 60 - big
        for (name, image) in row.images {
            if let image {
                let masked = name.hasPrefix("the macOS") ? resized(image, to: big, opaque: false) : iosMasked(resized(image, to: big, opaque: true), px: big)
                ctx.draw(masked, in: CGRect(x: x, y: y0, width: big, height: big))
            }
            label(name, x, y0 - 28)
            x += big + gap
        }
        var y = top - 60
        for (name, image) in row.smalls {
            guard let image else { continue }
            var sx = x
            for px in small {
                ctx.draw(iosMasked(resized(image, to: px, opaque: true), px: px), in: CGRect(x: sx, y: y - px, width: px, height: px))
                sx += px + 16
            }
            label(name == "light" ? "60 · 40 · 29 pt @3x" : "the same, dark", x, y - 180 - 26)
            y -= 180 + 50
        }
        top -= rowH
    }
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    writePNG(ctx.makeImage()!, "\(out)/sheet.png")
    print("wrote \(out)/sheet.png")
}

// MARK: - Main

@main
struct Main {
    @MainActor
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: render-sky-icon render <dir> | sheet <dir> <out> [SameerOS appiconset] | install")
            exit(2)
        }
        switch args[1] {
        case "render":
            let dir = args[2]
            for a in IconArt.Variant.allCases { writePNG(opaque(try render(a)), "\(dir)/flat-\(a.rawValue).png") }
            writePNG(macFlat(opaque(try render(.light))), "\(dir)/flat-mac.png")
            writePNG(macFlat(opaque(try render(.dark))), "\(dir)/flat-mac-dark.png")
            try writeIconBundle(at: "\(dir)/sky/AppIcon.icon")
            try writeIconBundle(at: "\(dir)/sky-dark/AppIcon.icon", darkAsBase: true)
        case "sheet":
            let sameerOS = args.count > 4 ? args[4]
                : NSString(string: "~/claude-projects/SameerOS/SameerOS/Assets.xcassets/AppIcon.appiconset").expandingTildeInPath
            try sheet(args[2], out: args[3], sameerOS: sameerOS)
        case "install":
            // The Liquid Glass icon, one bundle per app (the same bytes; Xcode wants it beside each target).
            try writeIconBundle(at: "iOS/Macrophone/AppIcon.icon")
            try writeIconBundle(at: "Mac/Resources/AppIcon.icon")
            // iOS 17–18: light, dark and tinted, 1024, opaque.
            let flats = Dictionary(uniqueKeysWithValues: try IconArt.Variant.allCases.map { ($0, opaque(try render($0))) })
            let ios = "iOS/Macrophone/Resources/Assets.xcassets/AppIcon.appiconset"
            writePNG(flats[.light]!, "\(ios)/AppIcon-1024.png")
            writePNG(flats[.dark]!, "\(ios)/AppIcon-1024-dark.png")
            writePNG(flats[.tinted]!, "\(ios)/AppIcon-1024-tinted.png")
            // macOS 14–15: the squircle at every size (one appearance there — the light, as iOS's default).
            let mac = macFlat(flats[.light]!)
            let macDir = "Mac/Resources/Assets.xcassets/AppIcon.appiconset"
            for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
                let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
                writePNG(resized(mac, to: pt * scale, opaque: false), "\(macDir)/\(name)")
            }
            // The record: the final renders at 1024 and the small sizes.
            let docs = "docs/icon/sky"
            for a in IconArt.Variant.allCases { writePNG(flats[a]!, "\(docs)/final-\(a.rawValue)-1024.png") }
            writePNG(mac, "\(docs)/final-mac-light-1024.png")
            writePNG(macFlat(flats[.dark]!), "\(docs)/final-mac-dark-1024.png")
            for a in [IconArt.Variant.light, .dark] {
                for (pt, px) in [(60, 180), (40, 120), (29, 87)] {
                    writePNG(iosMasked(resized(flats[a]!, to: px, opaque: true), px: px), "\(docs)/final-\(a.rawValue)-\(pt)pt@3x.png")
                }
            }
            print("installed")
        default:
            exit(2)
        }
    }
}
