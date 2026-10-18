// Macrophone's app icon: the Thread — the app's own waveform (iOS/Macrophone/UI/Filament.swift,
// `ThreadView` at rest, `.ready`) — spanning the icon. Sameer, Oct 18 2026: "I want the wave form we
// have in the app to be the main visual of the app icon."
//
//   xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 scripts/render-thread-icon.swift -o /tmp/render-thread-icon
//   /tmp/render-thread-icon preview <dir>          # every framing: the .icon bundles, the flats, the small sizes
//   /tmp/render-thread-icon sheet <dir> <out dir>  # the comparison sheet (+ the system's renders, after icon-render-check.sh)
//   /tmp/render-thread-icon compare <sim.png> <out dir>   # the in-app Thread (a simulator crop) beside this port at the app's size
//   /tmp/render-thread-icon install [framing]      # writes the shipped icon in place (run from the repo root)
//
// scripts/thread-icon.sh runs the whole pipeline. What ships is the same wiring as before (the
// capsule icon, scripts/render-icons.swift): iOS/Macrophone/AppIcon.icon and Mac/Resources/AppIcon.icon
// (Icon Composer bundles: icon.json + Assets/*.png — Liquid Glass on iOS 26 / macOS 26+), with the
// classic AppIcon.appiconset PNGs as the fallback for iOS 17–18 and macOS 14–15.
//
// THE PORT. `ThreadView` is Core Animation; this is the same drawing in CoreGraphics, number for
// number — the geometry (`line(_:look:t:)` for `.ready` at t = 0, which is the Reduce Motion still:
// 96 samples, phases 0 / 2.1 / 4.2, env = sin(πu)^1.25, rest = −0.36·A·sin(2π(u−½))·env, the weave
// 0.11·A·env·sin(2π·1.5·f·u + φ), the per-strand swell), the ribbon taper (sin(πu)^0.65), the strand
// half-widths (2.9 / 1.5 · k bodies, 0.62 / 0.3 · k cores), the two glow strokes (5k wide with an 18k
// shadow at 0.5 round the middle strand's inner 80 %; 3k with a 7k shadow at 0.6 round all three), the
// ready opacities (container 0.9, glow 0.5, bodies 0.82 — the middle ribbon 1, the outer two 0.72 —
// cores 0.42, bloom 0.6 of cyan at 0.10), the stops (violet 0 · cyan 0.5 · mint 1 across the band),
// the tip fade (0 · 0.13 · 0.87 · 1 across the container, which reaches 16 pt past the band on a
// 402 pt phone) and the bloom's ellipse. Two things are the icon's own: the band is far taller
// than the app's (the S is stretched up — the app's is 8:1, the icon's about 3:1, or it is a line
// across a square) and the strands are thicker in proportion (k), so the braid reads at 29 pt.
// `compare` renders the port at the app's exact size next to a simulator crop to prove the match.
//
// LIGHT AND DARK (Sameer: "The app icon should have a light and dark mode as well."). Dark is the
// app: the Thread's light on the app's ground (Theme.swift Ink.ground / raised, the cyan glow the
// app has behind it). Light is a bright, airy ground — the app's ink (#F4F2FA) falling to a pale
// mist, the faintest spectrum tint — with the Thread deepened (the same stops, more saturated and
// darker) so it reads on white, the glow turned into a tinted halo and the cores kept. The .icon
// carries both — each group holds its light layer and its dark one, faded to 0 in the other
// appearance (actool keeps `opacity-specializations`, drops `hidden-` and `image-name-`); the
// background fill is per appearance; tinted is the mono rendition (white strands, the halo at half).
// The system renderer can only be asked for the light appearance (icon-system-render.swift), so
// `preview` also writes a `<framing>-dark` bundle with the appearances swapped, and the sheet's
// "dark" system column is that.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UniformTypeIdentifiers

// MARK: - Palette (Theme.swift, exactly)

struct RGB {
    var r, g, b: Double
    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    static func hex(_ v: UInt32) -> RGB {
        RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }
    // Light (Theme.swift) — the Filament's spectrum.
    static let cyan = RGB(r: 0.345, g: 0.725, b: 0.871)
    static let teal = RGB(r: 0.361, g: 0.827, b: 0.765)
    static let mint = RGB(r: 0.369, g: 0.839, b: 0.635)
    static let gold = RGB(r: 0.910, g: 0.753, b: 0.424)
    static let violet = RGB(r: 0.604, g: 0.525, b: 0.902)
    static let coral = RGB(r: 0.914, g: 0.502, b: 0.416)
    /// `RGB.thread` (Filament.swift): violet, cyan, mint, gold, coral. Ready uses the first three.
    static let thread: [RGB] = [.violet, .cyan, .mint, .gold, .coral]
    // Ink (Theme.swift).
    static let ground = RGB(r: 0.020, g: 0.024, b: 0.051)   // #05060D
    static let raised = RGB(r: 0.075, g: 0.082, b: 0.125)   // #131520
    static let ink = RGB(r: 0.957, g: 0.949, b: 0.980)      // #F4F2FA

    /// Deeper and more saturated — the same hue — for the light ground.
    func deepened(saturation: Double = 1.6, brightness: Double = 0.78) -> RGB {
        let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        let d = NSColor(hue: c.hueComponent, saturation: min(1, c.saturationComponent * saturation),
                        brightness: c.brightnessComponent * brightness, alpha: 1).usingColorSpace(.sRGB)!
        return RGB(r: d.redComponent, g: d.greenComponent, b: d.blueComponent)
    }
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func cg(_ c: RGB, _ a: Double = 1) -> CGColor { CGColor(colorSpace: srgb, components: [c.r, c.g, c.b, a])! }
func gray(_ w: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: srgb, components: [w, w, w, a])! }
func gradient(_ stops: [(RGB, Double)], alpha: Double = 1) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map { cg($0.0, alpha) } as CFArray, locations: stops.map { CGFloat($0.1) })!
}
func gradient(colors: [CGColor], locations: [Double]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations.map { CGFloat($0) })!
}

// MARK: - The looks: dark (the app), light, tinted (mono)

enum Appearance: String, CaseIterable { case light, dark, tinted }

struct Look {
    var appearance: Appearance
    /// The spectrum across the band — `stops()` for `.ready`: violet 0, cyan 0.5, mint 1.
    var stops: [(RGB, Double)]
    var glowOpacity: Double      // glowFill.opacity (ready: 0.5)
    var bodyOpacity: Double      // bodyFill.opacity (ready: 0.82)
    var coreOpacity: Double      // each core (ready: 0.42)
    var containerOpacity: Double // container.opacity (ready: 0.9)
    var bloom: (RGB, Double)     // bloomColor() (ready: cyan at 0.10) — bloom.opacity 0.6 is applied on top
    var bloomOpacity: Double
    var mono: Bool

    static func of(_ a: Appearance) -> Look {
        let ready: [(RGB, Double)] = [(.violet, 0), (.cyan, 0.5), (.mint, 1)]
        switch a {
        case .dark:
            return Look(appearance: a, stops: ready, glowOpacity: 0.5, bodyOpacity: 0.82, coreOpacity: 0.42,
                        containerOpacity: 0.9, bloom: (.cyan, 0.10), bloomOpacity: 0.6, mono: false)
        case .light:
            // On white the light has to be paint: deeper strands, solid; the glow a tinted halo; the
            // cores a touch stronger so they aren't lost in the brighter strand.
            return Look(appearance: a, stops: ready.map { ($0.0.deepened(), $0.1) }, glowOpacity: 0.42, bodyOpacity: 0.96,
                        coreOpacity: 0.5, containerOpacity: 1, bloom: (RGB.cyan.deepened(saturation: 1.2, brightness: 0.9), 0.10),
                        bloomOpacity: 0.6, mono: false)
        case .tinted:
            let w = RGB(r: 1, g: 1, b: 1), g = RGB(r: 0.84, g: 0.84, b: 0.84)
            return Look(appearance: a, stops: [(g, 0), (w, 0.5), (g, 1)], glowOpacity: 0.35, bodyOpacity: 0.85, coreOpacity: 0.42,
                        containerOpacity: 0.9, bloom: (w, 0.06), bloomOpacity: 0.6, mono: true)
        }
    }
}

// MARK: - The band: ThreadView's bounds, placed on the canvas

/// The canvas is 1024 × 1024, y down (flipped into CoreGraphics when drawn).
let side = 1024.0

struct Framing {
    var name: String
    var title: String
    /// ThreadView's bounds, in canvas px. The app's band is 402 × 96 pt; `height` here is what
    /// stretches the S up (A = height / 2 drives every amplitude).
    var width: Double, height: Double
    /// Thickness. The app: k = clamp(height / 88, 0.8, 1.45) — 1.09 at 96 pt, a 6.3 pt middle strand.
    var k: Double
    /// The weave's cycles: the app's f = clamp(width / 360, 1, 1.4) — 1.07 on a 402 pt phone.
    var f: Double = 386.0 / 360
    /// Degrees, counter-clockwise; the S rises to the right already, a tilt leans into it.
    var rotation: Double = 0
    var centre = CGPoint(x: side / 2, y: side / 2)
    /// Seconds into `.ready`: 0 is the Reduce Motion still.
    var t: Double = 0

    /// Band space (ThreadView's bounds: origin top-left, y down) → the canvas.
    var transform: CGAffineTransform {
        CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: -rotation * .pi / 180)
            .translatedBy(x: -width / 2, y: -height / 2)
    }

    /// The light reaches 16 pt past the band on the phone; the same fraction here.
    var reach: Double { 16 * width / 402 }
    var container: CGRect { CGRect(x: -reach, y: -height * 0.6, width: width + 2 * reach, height: height * 2.2) }
    var band: CGRect { CGRect(x: width * 0.02, y: 0, width: width * 0.96, height: height) }
    var amp: Double { height * 0.5 }

    static let samples = 96
    static let phases: [Double] = [0, 2.1, 4.2]
    static let flowSpeed = 0.55, breath = 7.0

    func env(_ u: Double) -> Double { pow(sin(.pi * u), 1.25) }

    /// `ThreadView.line(_:look:t:)` for `.ready`, in band space.
    func line(_ s: Int) -> [CGPoint] {
        let n = Self.samples
        let phi = Self.phases[s]
        let r = band
        let w = Double(r.width)
        let A = amp
        return (0...n).map { i in
            let u = Double(i) / Double(n)
            let e = env(u)
            let rest = -A * 0.36 * sin(2 * .pi * (u - 0.5)) * e
            let swell = 1 + 0.08 * sin(2 * .pi * t / Self.breath + phi * 0.4)
            let y = rest * swell + A * 0.11 * e * sin(2 * .pi * 1.5 * f * u + phi - Self.flowSpeed * t)
            return CGPoint(x: Double(r.minX) + u * w, y: Double(r.midY) + y)
        }
    }

    /// The lines on the canvas.
    func lines() -> [[CGPoint]] {
        let T = transform
        return (0..<3).map { line($0).map { $0.applying(T) } }
    }

    /// `ThreadView.ribbon(_:half:)`.
    static func ribbon(_ pts: [CGPoint], half: Double) -> CGPath {
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        for i in pts.indices {
            let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 0.0001)
            let nx = -dy / len, ny = dx / len
            let u = Double(i) / Double(pts.count - 1)
            let hw = half * pow(sin(.pi * u), 0.65)
            top.append(CGPoint(x: pts[i].x + nx * hw, y: pts[i].y + ny * hw))
            bottom.append(CGPoint(x: pts[i].x - nx * hw, y: pts[i].y - ny * hw))
        }
        let path = CGMutablePath()
        path.addLines(between: top)
        path.addLines(between: bottom.reversed())
        path.closeSubpath()
        return path
    }
}

// MARK: - Drawing helpers

func context(_ px: Int, opaque: Bool) -> CGContext {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: info)!
    // Draw in a y-down 1024 canvas whatever the pixel size.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / side, y: -CGFloat(px) / side)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}
let full = CGRect(x: 0, y: 0, width: side, height: side)

/// Draws one of our own canvases back pixel for pixel. (`draw(_:in:)` lays an image upright in user
/// space, and user space here is y-down, so a plain draw flips it.)
func put(_ image: CGImage, in ctx: CGContext, at rect: CGRect = full) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
}

/// A Gaussian blur in canvas px (CA's shadowRadius is about two sigmas).
func blurred(_ image: CGImage, sigma: Double) -> CGImage {
    guard sigma > 0.01 else { return image }
    let f = CIFilter.gaussianBlur()
    f.inputImage = CIImage(cgImage: image).clampedToExtent()
    f.radius = Float(sigma * Double(image.width) / side)
    let out = f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb]).createCGImage(out, from: out.extent)!
}

/// `fill` drawn, then kept only where `mask` has alpha (a CALayer mask).
func masked(px: Int, mask: CGImage, _ fill: (CGContext) -> Void) -> CGImage {
    let ctx = context(px, opaque: false)
    fill(ctx)
    ctx.setBlendMode(.destinationIn)
    put(mask, in: ctx)
    return ctx.makeImage()!
}

// MARK: - The Thread, rendered (ThreadView.build + render, for .ready)

struct ThreadRender {
    /// The bloom and the glow — the light behind and round the strands (translucent).
    var light: CGImage
    /// The strands and their cores (translucent).
    var strands: CGImage
}

func render(_ fr: Framing, _ look: Look, px: Int = 1024) -> ThreadRender {
    let lines = fr.lines()
    let T = fr.transform
    let band = fr.band, container = fr.container
    let k = fr.k

    // The spectrum fill, left to right across the band (CA: locations lo…hi of the container).
    let a = CGPoint(x: band.minX, y: band.midY).applying(T), b = CGPoint(x: band.maxX, y: band.midY).applying(T)
    func spectrum(_ ctx: CGContext, alpha: Double) {
        ctx.drawLinearGradient(gradient(look.stops, alpha: alpha), start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // The glow: two black strokes, each its own shadow (CA: shadowRadius, opacity 1, no offset), at
    // the layer's opacity, together the mask of one spectrum fill.
    let mid = lines[1]
    let midSpine = CGMutablePath()
    midSpine.addLines(between: Array(mid[(mid.count / 10)...(mid.count * 9 / 10)]))
    let spines = CGMutablePath()
    for l in lines { spines.addLines(between: l) }
    let glowMask = context(px, opaque: false)
    for (path, lineWidth, radius, opacity) in [(midSpine, 5 * k, 18 * k, 0.5), (spines, 3 * k, 7 * k, 0.6)] as [(CGPath, Double, Double, Double)] {
        let stroke = context(px, opaque: false)
        stroke.addPath(path)
        stroke.setStrokeColor(gray(0))
        stroke.setLineWidth(lineWidth)
        stroke.setLineCap(.round); stroke.setLineJoin(.round)
        stroke.strokePath()
        let hard = stroke.makeImage()!
        let layer = context(px, opaque: false)
        put(blurred(hard, sigma: radius / 2), in: layer)
        put(hard, in: layer)
        glowMask.setAlpha(opacity)
        put(layer.makeImage()!, in: glowMask)
    }
    let glow = masked(px: px, mask: glowMask.makeImage()!) { spectrum($0, alpha: look.glowOpacity) }

    // The strands: three ribbons (the middle strongest) masking one spectrum fill.
    let bodyMask = context(px, opaque: false)
    for (i, l) in lines.enumerated() {
        bodyMask.setAlpha(i == 1 ? 1 : 0.72)
        bodyMask.addPath(Framing.ribbon(l, half: (i == 1 ? 2.9 : 1.5) * k))
        bodyMask.setFillColor(gray(0))
        bodyMask.fillPath()
    }
    let bodies = masked(px: px, mask: bodyMask.makeImage()!) { spectrum($0, alpha: look.bodyOpacity) }

    // The tip fade over the container (a horizontal gradient in band space).
    let fadeMask = context(px, opaque: false)
    let w = CGColor.white
    let fade = gradient(colors: [w.copy(alpha: 0)!, w, w, w.copy(alpha: 0)!], locations: [0, 0.13, 0.87, 1])
    fadeMask.drawLinearGradient(fade, start: CGPoint(x: container.minX, y: container.midY).applying(T),
                                end: CGPoint(x: container.maxX, y: container.midY).applying(T), options: [])
    let tipFade = fadeMask.makeImage()!

    // The container: glow, bodies, cores — at its opacity, through the tip fade.
    func contained(_ draw: (CGContext) -> Void) -> CGImage {
        let inner = context(px, opaque: false)
        draw(inner)
        let out = context(px, opaque: false)
        out.setAlpha(look.containerOpacity)
        put(masked(px: px, mask: tipFade) { put(inner.makeImage()!, in: $0) }, in: out)
        return out.makeImage()!
    }
    let glowLayer = contained { put(glow, in: $0) }
    let strandLayer = contained { ctx in
        put(bodies, in: ctx)
        for (i, l) in lines.enumerated() {
            ctx.setAlpha(look.coreOpacity)
            ctx.addPath(Framing.ribbon(l, half: (i == 1 ? 0.62 : 0.3) * k))
            ctx.setFillColor(gray(1))
            ctx.fillPath()
        }
    }

    // The bloom: a radial ellipse (0.9 w × 2.8 h, centred on the band) at bloom.opacity.
    let light = context(px, opaque: false)
    let bloomRect = CGRect(x: fr.width * 0.05, y: -fr.height * 0.9, width: fr.width * 0.9, height: fr.height * 2.8)
    light.saveGState()
    light.setAlpha(look.bloomOpacity)
    light.concatenate(T)
    light.translateBy(x: bloomRect.midX, y: bloomRect.midY)
    light.scaleBy(x: bloomRect.width / 2, y: bloomRect.height / 2)
    let bc = look.bloom
    light.drawRadialGradient(gradient(colors: [cg(bc.0, bc.1), cg(bc.0, bc.1 * 0.35), cg(bc.0, 0)], locations: [0, 0.45, 1]),
                             startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
    light.restoreGState()
    if look.appearance == .light {
        // A breath of the spectrum in the light ground's corners (in the layer, so the .icon has it too).
        light.drawRadialGradient(gradient(colors: [cg(.violet, 0.10), cg(.violet, 0)], locations: [0, 1]), startCenter: CGPoint(x: 60, y: 160), startRadius: 0,
                                 endCenter: CGPoint(x: 60, y: 160), endRadius: 760, options: [])
        light.drawRadialGradient(gradient(colors: [cg(.mint, 0.09), cg(.mint, 0)], locations: [0, 1]), startCenter: CGPoint(x: 980, y: 900), startRadius: 0,
                                 endCenter: CGPoint(x: 980, y: 900), endRadius: 760, options: [])
    }
    put(glowLayer, in: light)
    return ThreadRender(light: light.makeImage()!, strands: strandLayer)
}

// MARK: - The ground

func drawGround(_ ctx: CGContext, _ a: Appearance) {
    switch a {
    case .dark:
        // The app's ground, lifted a touch at the top (Ink.raised → Ink.ground), the cyan the app
        // keeps behind the Thread.
        ctx.setFillColor(cg(.ground))
        ctx.fill(full)
        ctx.drawLinearGradient(gradient([(RGB.raised.mix(.ground, 0.45), 0), (.ground, 1)]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: side), options: [])
        ctx.drawRadialGradient(gradient(colors: [cg(.cyan, 0.07), cg(.cyan, 0)], locations: [0, 1]), startCenter: CGPoint(x: 512, y: 0), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 0), endRadius: 760, options: [])
    case .light:
        // The app's ink falling to a pale mist (the spectrum's breath in the corners is in the Light layer).
        let mist = RGB.hex(0xE3E6F1)
        ctx.setFillColor(cg(.ink))
        ctx.fill(full)
        ctx.drawLinearGradient(gradient([(.ink, 0), (mist, 1)]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: side), options: [])
    case .tinted:
        ctx.setFillColor(cg(RGB.hex(0x050505)))
        ctx.fill(full)
        ctx.drawLinearGradient(gradient([(RGB.hex(0x151515), 0), (RGB.hex(0x050505), 1)]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: side), options: [])
    }
}

/// The ground's two gradient colours for icon.json (top, bottom).
func groundStops(_ a: Appearance) -> (RGB, RGB) {
    switch a {
    case .dark: (RGB.raised.mix(.ground, 0.45), .ground)
    case .light: (.ink, RGB.hex(0xE3E6F1))
    case .tinted: (RGB.hex(0x151515), RGB.hex(0x050505))
    }
}

// MARK: - The flattened icon (iOS 17–18, macOS 14–15, the sheet)

func flat(_ fr: Framing, _ a: Appearance, px: Int = 1024) -> CGImage {
    let ctx = context(px, opaque: true)
    drawGround(ctx, a)
    let r = render(fr, Look.of(a), px: px)
    put(r.light, in: ctx)
    put(r.strands, in: ctx)
    return ctx.makeImage()!
}

/// The macOS squircle on a clear canvas: an 824 body centred on 1024, the continuous corner, a soft shadow.
func macFlat(_ fr: Framing, _ a: Appearance, px: Int = 1024) -> CGImage {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let art = flat(fr, a)
    let ctx = context(px, opaque: false)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: gray(0, 0.4))
    ctx.addPath(shape)
    ctx.setFillColor(gray(0))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    put(art, in: ctx, at: body)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient(colors: [gray(1, 0.28), gray(1, 0.05)], locations: [0, 1]), start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: - The .icon bundle (Icon Composer: icon.json + Assets/)

func color(_ c: RGB) -> String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b) }

/// `darkAsBase` swaps the appearances (the dark layers and ground as the base, the light ones under
/// "dark") — a bundle only for proving the dark look through the system's renderer, which
/// scripts/icon-system-render.swift can only ask for in the light appearance.
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
    // Front first (Icon Composer's sidebar order). The light-appearance layers show in light and —
    // white, through their alpha — in tinted; the dark-appearance layers only in dark.
    let strands: [[String: Any]] = [
        layer("strands-dark", image: "strands-dark.png", glass: true, opacity: [(lightName, 0), ("tinted", 0), (darkName, 1)], tintedFill: false),
        layer("strands-light", image: "strands-light.png", glass: true, opacity: [(darkName, 0), ("tinted", 1)], tintedFill: true),
    ]
    let light: [[String: Any]] = [
        layer("light-dark", image: "light-dark.png", glass: false, opacity: [(lightName, 0), ("tinted", 0), (darkName, 1)], tintedFill: false),
        layer("light-light", image: "light-light.png", glass: false, opacity: [(darkName, 0), ("tinted", 0.5)], tintedFill: true),
    ]
    let groups: [[String: Any]] = [
        // The strands: glass, so the system lights their edge; their halo is a chromatic shadow
        // (the layer's own colour), as the Thread's glow is.
        ["name": "Thread", "layers": strands, "lighting": "individual", "hidden": false, "specular": true,
         "shadow": ["kind": "layer-color", "opacity": 0.5], "translucency": ["enabled": false, "value": 0.45]],
        // The light behind it: no glass, no shadow — a translucent picture.
        ["name": "Light", "layers": light, "lighting": "individual", "hidden": false, "specular": false,
         "shadow": ["kind": "none", "opacity": 0], "translucency": ["enabled": false, "value": 0.45]],
    ]
    let (lt, lb) = groundStops(darkAsBase ? .dark : .light), (dt, db) = groundStops(darkAsBase ? .light : .dark)
    return [
        "fill-specializations": [["value": ["linear-gradient": [color(lt), color(lb)]]],
                                 ["appearance": "dark", "value": ["linear-gradient": [color(dt), color(db)]]]],
        "groups": groups,
        "supported-platforms": ["squares": "shared", "circles": ["watchOS"]],
    ]
}

func writeIconBundle(_ fr: Framing, at dir: String, darkAsBase: Bool = false) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: dir)
    try! fm.createDirectory(atPath: "\(dir)/Assets", withIntermediateDirectories: true)
    for a in [Appearance.light, .dark] {
        let r = render(fr, Look.of(a))
        writePNG(r.strands, "\(dir)/Assets/strands-\(a.rawValue).png")
        writePNG(r.light, "\(dir)/Assets/light-\(a.rawValue).png")
    }
    let data = try! JSONSerialization.data(withJSONObject: iconJSON(darkAsBase: darkAsBase), options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: "\(dir)/icon.json"))
    print("wrote \(dir)")
}

// MARK: - Output

func resized(_ image: CGImage, to px: Int, opaque: Bool) -> CGImage {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: info)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
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

/// The iOS mask at a size: the continuous corner, ~22.37% of the side.
func iosMasked(_ image: CGImage, px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let r = Double(px) * 0.2237
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: px, height: px), cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

// MARK: - The framings

enum Framings {
    /// (1) The whole S edge to edge: the container is the icon's width, so the tips fade exactly as
    /// the app's do; the S lifted to about 3:1.
    static let span = Framing(name: "span", title: "Span — the whole S edge to edge, tips fading as in the app",
                              width: 948, height: 520, k: 12)
    /// (2) Bolder and closer: a wider band than the icon, so the braid runs off both edges at nearly
    /// full weight; taller, thicker — made to read at 29 pt.
    static let bold = Framing(name: "bold", title: "Bold — a closer crop, the braid running off both edges",
                              width: 1500, height: 880, k: 15)
    /// (3) A diagonal sweep: the S tilted into its own rise, corner to corner.
    static let sweep = Framing(name: "sweep", title: "Sweep — the S tilted into its rise",
                               width: 1420, height: 640, k: 13, rotation: 18)
    static let all = [span, bold, sweep]
    static func named(_ n: String) -> Framing? { all.first { $0.name == n } }
}

// MARK: - The comparison sheet

func sheet(_ work: String, out: String, simCrop: String?) {
    let big = 400, pad = 40, gap = 24
    let small = [180, 120, 87, 58]
    let smallW = small.reduce(0, +) + 16 * (small.count - 1)
    let cols = 5
    let W = pad + cols * (big + gap) + smallW + pad
    let rowH = big + 120
    let headerH = 300
    let H = pad + headerH + Framings.all.count * rowH + pad
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(gray(0.12))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.interpolationQuality = .high
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    func label(_ s: String, _ x: Int, _ y: Int, size: CGFloat = 20, bold: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        NSString(string: s).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }
    // The header: the Thread in the app beside the port at the app's size.
    var top = H - pad
    label("The Thread in the app (simulator, iPhone, 402 × 96 pt @3x) — and this port at the same size, t = 0", pad, top - 34, size: 26, bold: true)
    let stripH = 100
    if let crop = simCrop.flatMap(readPNG) {
        let w = crop.width * stripH / crop.height
        ctx.draw(crop, in: CGRect(x: pad, y: top - 60 - stripH, width: w, height: stripH))
        label("in the app", pad, top - 60 - stripH - 26)
        let port = appSizedPort()
        let pw = port.width * stripH / port.height
        ctx.draw(port, in: CGRect(x: pad + w + gap, y: top - 60 - stripH, width: pw, height: stripH))
        label("the port (CoreGraphics)", pad + w + gap, top - 60 - stripH - 26)
    }
    top -= headerH
    for fr in Framings.all {
        label(fr.title, pad, top - 34, size: 26, bold: true)
        var x = pad
        let y0 = top - 60 - big
        for a in Appearance.allCases {
            ctx.draw(iosMasked(flat(fr, a, px: big), px: big), in: CGRect(x: x, y: y0, width: big, height: big))
            label(a.rawValue, x, y0 - 28)
            x += big + gap
        }
        for (dir, name) in [(fr.name, "macOS 27 draws the .icon · light"), (fr.name + "-dark", "the same · dark (the swapped bundle)")] {
            if let r = readPNG("\(work)/\(dir)/system-1024.png") {
                ctx.draw(r, in: CGRect(x: x, y: y0, width: big, height: big))
                label(name, x, y0 - 28)
            }
            x += big + gap
        }
        // The small sizes, light and dark: 60 / 40 / 29 pt @3x and 29 pt @2x — Home, Settings, Spotlight.
        var y = top - 60
        for a in [Appearance.light, .dark] {
            let fullImage = flat(fr, a)
            var sx = x
            for px in small {
                ctx.draw(iosMasked(resized(fullImage, to: px, opaque: true), px: px), in: CGRect(x: sx, y: y - px, width: px, height: px))
                sx += px + 16
            }
            label(a == .light ? "60 · 40 · 29 pt @3x · 29 pt @2x" : "the same, dark", x, y - 180 - 26)
            y -= 180 + 50
        }
        top -= rowH
    }
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    writePNG(ctx.makeImage()!, "\(out)/sheet.png")
    print("wrote \(out)/sheet.png")
}

/// The port at the app's own size — a 402 × 96 pt band at @3x on the app's ground — to hold
/// against a simulator crop. Nothing is thickened: k and f are the app's.
func appSizedPort() -> CGImage {
    let scale = 3.0
    let w = 402 * scale, h = 96 * scale
    let fr = Framing(name: "app", title: "", width: w, height: h, k: min(1.45, max(0.8, 96 / 88)) * scale, f: min(1.4, max(1, 402 * 0.96 / 360)),
                     centre: CGPoint(x: side / 2, y: side / 2))
    let ctx = context(1024, opaque: true)
    ctx.setFillColor(cg(.ground))
    ctx.fill(full)
    let r = render(fr, Look.of(.dark))
    put(r.light, in: ctx)
    put(r.strands, in: ctx)
    let whole = ctx.makeImage()!
    // Cut the band and a little air (the sim crop is 1206 × 240 px).
    let cut = CGRect(x: (side - w) / 2, y: (side - 240) / 2, width: w, height: 240)
    return whole.cropping(to: cut)!
}

// MARK: - Main

@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("usage: render-thread-icon preview <dir> | sheet <dir> <out> [sim crop] | compare <sim crop> <out> | install [framing]"); exit(2) }
        switch args[1] {
        case "preview":
            let dir = args[2]
            for fr in Framings.all {
                writeIconBundle(fr, at: "\(dir)/\(fr.name)/AppIcon.icon")
                writeIconBundle(fr, at: "\(dir)/\(fr.name)-dark/AppIcon.icon", darkAsBase: true)
                for a in Appearance.allCases { writePNG(flat(fr, a), "\(dir)/\(fr.name)/flat-\(a.rawValue).png") }
                writePNG(macFlat(fr, .light), "\(dir)/\(fr.name)/flat-mac.png")
            }
        case "sheet":
            sheet(args[2], out: args[3], simCrop: args.count > 4 ? args[4] : nil)
        case "compare":
            let out = args[3]
            let port = appSizedPort()
            writePNG(port, "\(out)/port-app-size.png")
            if let crop = readPNG(args[2]) {
                let w = max(crop.width, port.width), h = crop.height + port.height + 40
                let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.setFillColor(cg(.ground))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(crop, in: CGRect(x: 0, y: h - crop.height, width: crop.width, height: crop.height))
                ctx.draw(port, in: CGRect(x: 0, y: 0, width: port.width, height: port.height))
                writePNG(ctx.makeImage()!, "\(out)/in-app-vs-port.png")
                print("wrote \(out)/in-app-vs-port.png")
            }
        case "install":
            let fr = args.count > 2 ? Framings.named(args[2]) ?? Framings.span : Framings.span
            // The Liquid Glass icon, one bundle per app (the same bytes; Xcode wants it beside each target).
            writeIconBundle(fr, at: "iOS/Macrophone/AppIcon.icon")
            writeIconBundle(fr, at: "Mac/Resources/AppIcon.icon")
            // iOS 17–18: light, dark and tinted, 1024, opaque.
            let ios = "iOS/Macrophone/Resources/Assets.xcassets/AppIcon.appiconset"
            writePNG(flat(fr, .light), "\(ios)/AppIcon-1024.png")
            writePNG(flat(fr, .dark), "\(ios)/AppIcon-1024-dark.png")
            writePNG(flat(fr, .tinted), "\(ios)/AppIcon-1024-tinted.png")
            // macOS 14–15: the squircle at every size (one appearance there — the light, as iOS's default).
            let mac = macFlat(fr, .light)
            let macDir = "Mac/Resources/Assets.xcassets/AppIcon.appiconset"
            for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
                let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
                writePNG(resized(mac, to: pt * scale, opaque: false), "\(macDir)/\(name)")
            }
            // The record: the final renders at 1024 and the small sizes.
            let docs = "docs/icon/thread"
            for a in Appearance.allCases { writePNG(flat(fr, a), "\(docs)/final-\(a.rawValue)-1024.png") }
            writePNG(mac, "\(docs)/final-mac-light-1024.png")
            writePNG(macFlat(fr, .dark), "\(docs)/final-mac-dark-1024.png")
            for a in [Appearance.light, .dark] {
                let f = flat(fr, a)
                for (pt, px) in [(60, 180), (40, 120), (29, 87)] { writePNG(iosMasked(resized(f, to: px, opaque: true), px: px), "\(docs)/final-\(a.rawValue)-\(pt)pt@3x.png") }
            }
            print("installed \(fr.name)")
        default:
            exit(2)
        }
    }
}
