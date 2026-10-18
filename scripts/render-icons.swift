// Macrophone's app icon, from code — the Liquid Glass (iOS 26 / macOS 26) icon and its fallbacks.
//
//   xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 scripts/render-icons.swift -o /tmp/render-icons
//   /tmp/render-icons preview <dir>       # every direction: layers, .icon bundles, flattened renders, one comparison sheet
//   /tmp/render-icons install [design]    # writes the shipped icon in place (run from the repo root)
//
// What ships (design `capsule` unless told otherwise):
//   iOS/Macrophone/AppIcon.icon, Mac/Resources/AppIcon.icon   the Icon Composer bundle (icon.json + Assets/*.png)
//       — square, unmasked 1024 layers with hard edges and no baked light: the system draws the
//       specular edge, the refraction, the translucency and the shadow (HIG › App icons).
//       Xcode 26+ takes this over the asset catalog's set of the same name and flattens it itself
//       for iOS 17–18 and macOS 14–15 (checked in the built Assets.car: the IconImageStack plus
//       actool's own flat images).
//   iOS/…/Assets.xcassets/AppIcon.appiconset                  flattened light / dark / tinted 1024 PNGs — the fallback
//   Mac/Resources/Assets.xcassets/AppIcon.appiconset          the macOS squircle at every size — for a build with an
//                                                             older Xcode, which can't read a .icon
//   docs/icon/                                                the comparison sheet and the final renders
//
// scripts/icon-render-check.sh draws each candidate .icon the way macOS 26+ does (actool → a stub
// app → the system's icon), which is how the glass settings below were chosen.
//
// The mark: a glass microphone capsule — one filled pill, no stand, no outline — with the Thread
// (the app's luminous braided waveform, Filament.swift) passing through it: the bold strand in
// front, the two finer strands behind the glass. The ground is the app's ink, lifted to indigo.
// No text, no photo, no thin line (nothing under 14 px at 1024 — about 1 px at 29 pt @3x).

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UniformTypeIdentifiers

// MARK: - Palette (Theme.swift's Light — the Filament's spectrum — and Ink)

struct RGB { var r, g, b: Double }
enum Palette {
    static func hex(_ v: UInt32) -> RGB {
        RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }
    static let cyan = hex(0x58B9DE), teal = hex(0x5CD3C3), mint = hex(0x5ED6A2)
    static let gold = hex(0xE8C06C), ember = hex(0xE9714F), violet = hex(0x9A86E6)
    /// The Thread, cool to warm, as the app draws it.
    static let spectrum: [(RGB, Double)] = [(cyan, 0), (teal, 0.22), (mint, 0.40), (gold, 0.60), (ember, 0.80), (violet, 1)]
    /// The ground: ink lifted to indigo at the top, the app's ground at the foot.
    static let groundTop = hex(0x1A1A42), groundBottom = hex(0x07070F)
    static let groundTopDark = hex(0x111130), groundBottomDark = hex(0x040409)
}

func cg(_ c: RGB, _ a: Double = 1) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: a) }
func gray(_ w: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: w, green: w, blue: w, alpha: a) }
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(RGB, Double)], alpha: Double = 1) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map { cg($0.0, alpha) } as CFArray, locations: stops.map { CGFloat($0.1) })!
}
func grayGradient(_ stops: [(Double, Double, Double)]) -> CGGradient {  // (white, alpha, location)
    CGGradient(colorsSpace: srgb, colors: stops.map { gray($0.0, $0.1) } as CFArray, locations: stops.map { CGFloat($0.2) })!
}

// MARK: - Geometry: the Thread as a tapered ribbon

/// The canvas is 1024 × 1024, y down (flipped into CoreGraphics when drawn).
let side = 1024.0

struct Strand {
    /// Half-width at the peak, in px of 1024.
    var weight: Double
    /// Lateral offset from the S's centreline: a braid, `spread` px, `turns` crossings, phase.
    var spread: Double, turns: Double, phase: Double
    /// Reach across the canvas (0…1 of the width) and the S's height (fraction of the reach).
    var reach: Double, amp: Double
    var centreY: Double

    func path() -> CGPath {
        let n = 480
        let width = reach * side, x0 = (side - width) / 2
        var centre: [CGPoint] = [], tangent: [CGPoint] = []
        for i in 0...n {
            let u = Double(i) / Double(n)
            let env = pow(sin(.pi * u), 1.15)
            let y = centreY - amp * width * sin(2 * .pi * (u - 0.5)) * env
            centre.append(CGPoint(x: x0 + u * width, y: y))
        }
        for i in 0...n {
            let a = centre[max(i - 1, 0)], b = centre[min(i + 1, n)]
            let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 1e-6)
            tangent.append(CGPoint(x: dx / len, y: dy / len))
        }
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        for i in 0...n {
            let u = Double(i) / Double(n)
            let nx = -tangent[i].y, ny = tangent[i].x
            // The braid: the strand wanders off the S and back, fading to the centreline at the tips.
            let wander = spread * sin(2 * .pi * turns * u + phase) * pow(sin(.pi * u), 0.8)
            let c = CGPoint(x: centre[i].x + nx * wander, y: centre[i].y + ny * wander)
            // A voice's swell: full weight in the middle, a fine tip either end (never a hairline: the floor is 7 px).
            let h = max(7, weight * pow(sin(.pi * u), 0.75))
            top.append(CGPoint(x: c.x + nx * h, y: c.y + ny * h))
            bottom.append(CGPoint(x: c.x - nx * h, y: c.y - ny * h))
        }
        // Round caps at the tips (a flat end reads as a nub at 1024): a half-circle bulging along the
        // strand's own direction, as one cubic.
        func cap(from a: CGPoint, to b: CGPoint, along d: CGPoint, into p: CGMutablePath) {
            let k = hypot(a.x - b.x, a.y - b.y) / 2 * 4 / 3
            p.addCurve(to: b, control1: CGPoint(x: a.x + d.x * k, y: a.y + d.y * k), control2: CGPoint(x: b.x + d.x * k, y: b.y + d.y * k))
        }
        let p = CGMutablePath()
        p.move(to: top[0])
        for q in top.dropFirst() { p.addLine(to: q) }
        cap(from: top[n], to: bottom[n], along: tangent[n], into: p)
        for q in bottom.dropLast().reversed() { p.addLine(to: q) }
        cap(from: bottom[0], to: top[0], along: CGPoint(x: -tangent[0].x, y: -tangent[0].y), into: p)
        p.closeSubpath()
        return p
    }
}

func pill(cx: Double, cy: Double, w: Double, h: Double) -> CGPath {
    CGPath(roundedRect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
}
func rounded(cx: Double, cy: Double, w: Double, h: Double, r: Double) -> CGPath {
    CGPath(roundedRect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

// MARK: - The designs, as layers

enum Kind { case thread, glass }

struct Layer {
    var name: String
    var path: CGPath
    var kind: Kind
    /// A finer strand sits behind the glass; the bold one in front.
    var group: String
}

struct Group {
    var name: String
    var kind: Kind
}

enum Design: String, CaseIterable {
    case strand    // the Thread alone: one bold strand with its two finer strands braided round it
    case capsule   // a glass microphone capsule with the Thread passing through it
    case window    // a Mac window with the Thread rising through it

    var title: String {
        switch self {
        case .strand: "The Strand — the Thread distilled"
        case .capsule: "Capsule — a glass mic with the Thread through it"
        case .window: "Window — a Mac window and the wave"
        }
    }

    /// Groups back to front, and the layers in them.
    var groups: [Group] {
        switch self {
        case .strand: [Group(name: "Thread", kind: .thread)]
        case .capsule: [Group(name: "Behind", kind: .thread), Group(name: "Capsule", kind: .glass), Group(name: "Thread", kind: .thread)]
        case .window: [Group(name: "Window", kind: .glass), Group(name: "Thread", kind: .thread)]
        }
    }

    var layers: [Layer] {
        switch self {
        case .strand:
            let cy = 512.0
            return [
                Layer(name: "strand-fine-2", path: Strand(weight: 26, spread: 110, turns: 1.0, phase: .pi, reach: 0.80, amp: 0.17, centreY: cy).path(), kind: .thread, group: "Thread"),
                Layer(name: "strand-fine-1", path: Strand(weight: 32, spread: 92, turns: 1.0, phase: 0, reach: 0.82, amp: 0.17, centreY: cy).path(), kind: .thread, group: "Thread"),
                Layer(name: "strand-bold", path: Strand(weight: 80, spread: 0, turns: 1, phase: 0, reach: 0.84, amp: 0.17, centreY: cy).path(), kind: .thread, group: "Thread"),
            ]
        case .capsule:
            // The capsule sits a touch above centre (the visual mass of the S is below its midline).
            let cy = 500.0
            return [
                Layer(name: "strand-fine", path: Strand(weight: 30, spread: 104, turns: 1.0, phase: 0, reach: 0.78, amp: 0.15, centreY: cy).path(), kind: .thread, group: "Behind"),
                Layer(name: "capsule", path: pill(cx: 512, cy: cy, w: 384, h: 700), kind: .glass, group: "Capsule"),
                Layer(name: "strand-bold", path: Strand(weight: 64, spread: 0, turns: 1, phase: 0, reach: 0.82, amp: 0.15, centreY: cy).path(), kind: .thread, group: "Thread"),
            ]
        case .window:
            let cy = 520.0
            return [
                Layer(name: "window", path: rounded(cx: 512, cy: cy, w: 690, h: 500, r: 72), kind: .glass, group: "Window"),
                Layer(name: "strand-fine-1", path: Strand(weight: 28, spread: 90, turns: 1.0, phase: 0, reach: 0.82, amp: 0.15, centreY: cy).path(), kind: .thread, group: "Thread"),
                Layer(name: "strand-bold", path: Strand(weight: 66, spread: 0, turns: 1, phase: 0, reach: 0.84, amp: 0.15, centreY: cy).path(), kind: .thread, group: "Thread"),
            ]
        }
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

/// Fills a path with the spectrum, left to right across the path's own box.
func fillSpectrum(_ ctx: CGContext, _ path: CGPath, alpha: Double = 1, mono: Bool = false) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let box = path.boundingBox
    let g = mono ? grayGradient([(0.86, alpha, 0), (1, alpha, 0.5), (0.86, alpha, 1)]) : gradient(Palette.spectrum, alpha: alpha)
    ctx.drawLinearGradient(g, start: CGPoint(x: box.minX, y: 0), end: CGPoint(x: box.maxX, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func blurred(_ image: CGImage, radius: Double) -> CGImage {
    let f = CIFilter.gaussianBlur()
    f.inputImage = CIImage(cgImage: image).clampedToExtent()
    f.radius = Float(radius)
    let out = f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb]).createCGImage(out, from: out.extent)!
}

// MARK: - Layer images (what the .icon carries: hard edges, flat light, square and unmasked)

func layerImage(_ layer: Layer, mono: Bool = false) -> CGImage {
    let ctx = context(Int(side), opaque: false)
    switch layer.kind {
    case .thread:
        fillSpectrum(ctx, layer.path, mono: mono)
    case .glass:
        // Imported white: Icon Composer's fill and the group's translucency make it glass.
        ctx.addPath(layer.path)
        ctx.setFillColor(gray(1))
        ctx.fillPath()
    }
    return ctx.makeImage()!
}

// MARK: - The flattened icon (iOS 17–18, macOS 14–15, the website, the comparison sheet)

enum Appearance: String, CaseIterable { case light, dark, tinted }

struct Flat {
    var design: Design
    var appearance: Appearance = .light

    /// The icon on its ground, square, 1024, y down. (`mac` draws it inside the macOS squircle.)
    func draw(_ ctx: CGContext) {
        drawGround(ctx)
        let groups = design.groups
        let layers = design.layers
        for g in groups {
            for l in layers where l.group == g.name {
                switch l.kind {
                case .thread: drawThread(ctx, l.path, behindGlass: g.name == "Behind")
                case .glass: drawGlass(ctx, l.path)
                }
            }
        }
    }

    private func drawGround(_ ctx: CGContext) {
        let full = CGRect(x: 0, y: 0, width: side, height: side)
        let top: RGB, bottom: RGB
        switch appearance {
        case .light: (top, bottom) = (Palette.groundTop, Palette.groundBottom)
        case .dark: (top, bottom) = (Palette.groundTopDark, Palette.groundBottomDark)
        case .tinted: (top, bottom) = (Palette.hex(0x151515), Palette.hex(0x050505))
        }
        ctx.setFillColor(cg(bottom))
        ctx.fill(full)
        ctx.drawLinearGradient(gradient([(top, 0), (bottom, 1)]), start: CGPoint(x: 160, y: 0), end: CGPoint(x: 860, y: side), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // The light the Thread throws on the ground.
        guard appearance != .tinted else { return }
        let lift = grayGradient([(1, appearance == .dark ? 0.05 : 0.08, 0), (1, 0, 1)])
        ctx.drawRadialGradient(lift, startCenter: CGPoint(x: 512, y: 500), startRadius: 0, endCenter: CGPoint(x: 512, y: 500), endRadius: 520, options: [])
    }

    private func drawThread(_ ctx: CGContext, _ path: CGPath, behindGlass: Bool) {
        let mono = appearance == .tinted
        // A chromatic glow under the strand — the Thread's halo, what the system's chromatic shadow does on 26.
        if !behindGlass && !mono {
            let g = context(512, opaque: false)
            fillSpectrum(g, path, alpha: mono ? 0.5 : 0.9, mono: mono)
            let glow = blurred(g.makeImage()!, radius: 9)
            ctx.saveGState()
            ctx.setAlpha(appearance == .dark ? 0.5 : 0.6)
            ctx.draw(glow, in: CGRect(x: 0, y: 8, width: side, height: side))
            ctx.restoreGState()
        }
        // The body — behind the glass it is light on the ink, not paint (screen, so orange never goes brown).
        if behindGlass {
            ctx.saveGState()
            ctx.setBlendMode(.screen)
            fillSpectrum(ctx, path, alpha: 0.5, mono: mono)
            ctx.restoreGState()
        } else {
            fillSpectrum(ctx, path, mono: mono)
        }
        // A specular edge along the lit (upper) side: the strand minus its own shape shifted down.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        var shift = CGAffineTransform(translationX: 0, y: behindGlass ? 7 : 11)
        ctx.addRect(CGRect(x: -10, y: -10, width: side + 20, height: side + 20))
        ctx.addPath(path.copy(using: &shift)!)
        ctx.clip(using: .evenOdd)
        let box = path.boundingBox
        ctx.drawLinearGradient(grayGradient([(1, behindGlass ? 0.35 : 0.8, 0), (1, 0.15, 1)]), start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
        ctx.restoreGState()
        // A white-hot core, the Thread's — faint, so the spectrum keeps its colour.
        if !behindGlass && !mono {
            let g = context(512, opaque: false)
            g.addPath(path)
            g.setFillColor(gray(1, 0.5))
            g.fillPath()
            let core = blurred(g.makeImage()!, radius: 6)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setBlendMode(.plusLighter)
            ctx.setAlpha(0.28)
            ctx.draw(core, in: CGRect(x: 0, y: 0, width: side, height: side))
            ctx.restoreGState()
        }
    }

    private func drawGlass(_ ctx: CGContext, _ path: CGPath) {
        let box = path.boundingBox
        // A soft shadow on the ground.
        let s = context(512, opaque: false)
        s.addPath(path)
        s.setFillColor(gray(0, 0.6))
        s.fillPath()
        let shadow = blurred(s.makeImage()!, radius: 12)
        ctx.saveGState()
        ctx.setAlpha(0.5)
        ctx.draw(shadow, in: CGRect(x: 0, y: 14, width: side, height: side))
        ctx.restoreGState()
        // The frosted plate: a cool white, lighter at the top.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // As present as the system draws it on 26 (a light, nearly solid glass), so the two generations read as one icon.
        let plate = appearance == .tinted ? 0.34 : 0.42
        ctx.drawLinearGradient(grayGradient([(1, plate + 0.2, 0), (1, plate - 0.1, 1)]), start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
        // A sheen across the upper third.
        ctx.drawLinearGradient(grayGradient([(1, 0.22, 0), (1, 0, 1)]), start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX, y: box.minY + box.height * 0.6), options: [])
        // The rim: a bright edge at the top, fading down the sides, a glint at the foot.
        ctx.addPath(path)
        ctx.setLineWidth(10)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(grayGradient([(1, 0.95, 0), (1, 0.3, 0.45), (1, 0.55, 1)]), start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
        ctx.restoreGState()
    }
}

/// The flattened icon: full-bleed square (iOS) or the macOS squircle on a clear canvas.
func flat(_ design: Design, _ appearance: Appearance, mac: Bool, px: Int = 1024) -> CGImage {
    if !mac {
        let ctx = context(px, opaque: true)
        Flat(design: design, appearance: appearance).draw(ctx)
        return ctx.makeImage()!
    }
    // macOS grid: an 824 body centred on the 1024 canvas, the continuous corner, a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let art = context(1024, opaque: true)
    Flat(design: design, appearance: appearance).draw(art)
    let artImage = art.makeImage()!
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
    ctx.draw(artImage, in: body)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(grayGradient([(1, 0.28, 0), (1, 0.05, 1)]), start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: - The .icon bundle (Icon Composer's format: icon.json + Assets/)

func color(_ c: RGB) -> String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b) }

func iconJSON(_ design: Design) -> [String: Any] {
    func spec(_ base: Any?, dark: Any? = nil, tinted: Any? = nil) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let base { out.append(["value": base]) }
        if let dark { out.append(["appearance": "dark", "value": dark]) }
        if let tinted { out.append(["appearance": "tinted", "value": tinted]) }
        return out
    }
    // icon.json lists groups as Icon Composer's sidebar does: the FIRST is the frontmost (checked on
    // macOS 27 by scripts/icon-render-check.sh); `Design.groups` is back to front, so reverse it.
    var groups: [[String: Any]] = []
    for g in design.groups.reversed() {
        var layers: [[String: Any]] = []
        for l in design.layers where l.group == g.name {
            var layer: [String: Any] = [
                "name": l.name, "image-name": "\(l.name).png", "glass": true, "hidden": false,
                "position": ["scale": 1, "translation-in-points": [0, 0]],
            ]
            switch l.kind {
            case .thread:
                // The image's own spectrum; white in the mono rendition so the tint reads clean.
                layer["fill-specializations"] = spec(nil, tinted: ["solid": "extended-gray:1.00000,1.00000"])
            case .glass:
                layer["fill"] = ["solid": "extended-gray:1.00000,1.00000"]
            }
            layers.append(layer)
        }
        var group: [String: Any] = ["name": g.name, "layers": layers, "lighting": "individual", "hidden": false]
        switch g.kind {
        case .thread:
            // The Thread's halo is a chromatic shadow; the strand itself is solid light.
            group["specular"] = true
            group["shadow"] = ["kind": "layer-color", "opacity": 0.6]
            group["translucency"] = ["enabled": g.name == "Behind", "value": 0.45]
            if g.name == "Behind" { group["opacity"] = 0.85 }
        case .glass:
            // Glass: translucent (a higher value is MORE see-through — 0.3 rendered an opaque white
            // pill, 1.0 showed the ink through it), lightly frosted so the strand behind softens,
            // a neutral shadow on the ground.
            group["specular"] = true
            group["blur-material"] = 0.12
            group["translucency"] = ["enabled": true, "value": 1]
            group["shadow"] = ["kind": "neutral", "opacity": 0.5]
        }
        groups.append(group)
    }
    return [
        "fill-specializations": spec(
            ["linear-gradient": [color(Palette.groundTop), color(Palette.groundBottom)]],
            dark: ["linear-gradient": [color(Palette.groundTopDark), color(Palette.groundBottomDark)]]),
        "groups": groups,
        "supported-platforms": ["squares": "shared", "circles": ["watchOS"]],
    ]
}

func writeIconBundle(_ design: Design, at dir: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: dir)
    try! fm.createDirectory(atPath: "\(dir)/Assets", withIntermediateDirectories: true)
    for l in design.layers { writePNG(layerImage(l), "\(dir)/Assets/\(l.name).png") }
    let data = try! JSONSerialization.data(withJSONObject: iconJSON(design), options: [.prettyPrinted, .sortedKeys])
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

// MARK: - The comparison sheet: each direction in light / dark / tinted, the Mac squircle, and the small sizes

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

func sheet(_ dir: String, rendered: [Design: CGImage?] = [:]) {
    let W = 2900, rowH = 560, pad = 40
    let H = pad + Design.allCases.count * rowH + pad
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(gray(0.12))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.interpolationQuality = .high
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = ns
    func label(_ s: String, _ x: Int, _ y: Int, size: CGFloat = 20, bold: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        NSString(string: s).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }
    for (row, d) in Design.allCases.enumerated() {
        let top = H - pad - row * rowH   // y up
        label(d.title, pad, top - 34, size: 26, bold: true)
        var x = pad
        let big = 420
        for a in Appearance.allCases {
            let img = iosMasked(flat(d, a, mac: false, px: big), px: big)
            ctx.draw(img, in: CGRect(x: x, y: top - 60 - big, width: big, height: big))
            label(a.rawValue, x, top - 60 - big - 28)
            x += big + 24
        }
        let mac = flat(d, .light, mac: true, px: big)
        ctx.draw(mac, in: CGRect(x: x, y: top - 60 - big, width: big, height: big))
        label("macOS 14 fallback", x, top - 60 - big - 28)
        x += big + 24
        if let r = rendered[d], let r {
            ctx.draw(r, in: CGRect(x: x, y: top - 60 - big, width: big, height: big))
            label("macOS 27 renders the .icon", x, top - 60 - big - 28)
        }
        x += big + 40
        // The small sizes, light and dark: 60 / 40 / 29 pt at @3x and 29 pt @2x — what Home, Settings and Spotlight show.
        var y = top - 60
        for a in [Appearance.light, .dark] {
            let full = flat(d, a, mac: false)
            var sx = x
            for px in [180, 120, 87, 58] {
                ctx.draw(iosMasked(resized(full, to: px, opaque: true), px: px), in: CGRect(x: sx, y: y - px, width: px, height: px))
                sx += px + 16
            }
            label(a == .light ? "60 · 40 · 29 pt @3x · 29 pt @2x" : "the same, dark", x, y - 180 - 26)
            y -= 180 + 50
        }
    }
    writePNG(ctx.makeImage()!, "\(dir)/comparison.png")
    print("wrote \(dir)/comparison.png")
}

// MARK: - Main

@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("usage: render-icons preview <dir> | install [design] | sheet <dir>"); exit(2) }
        switch args[1] {
        case "preview":
            let dir = args[2]
            for d in Design.allCases {
                writeIconBundle(d, at: "\(dir)/\(d.rawValue)/AppIcon.icon")
                for a in Appearance.allCases { writePNG(flat(d, a, mac: false), "\(dir)/\(d.rawValue)/flat-\(a.rawValue).png") }
                writePNG(flat(d, .light, mac: true), "\(dir)/\(d.rawValue)/flat-mac.png")
            }
            sheet(dir)
        case "sheet":
            // The sheet again, with the system's own renders of each .icon beside the fallbacks (see scripts/icon-render-check.sh).
            let dir = args[2]
            var rendered: [Design: CGImage?] = [:]
            for d in Design.allCases {
                let path = "\(dir)/\(d.rawValue)/system-1024.png"
                if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) {
                    rendered[d] = CGImageSourceCreateImageAtIndex(src, 0, nil)
                }
            }
            sheet(dir, rendered: rendered)
        case "install":
            let design = args.count > 2 ? Design(rawValue: args[2]) ?? .capsule : .capsule
            // The Liquid Glass icon, one bundle per app (the same bytes; Xcode wants it beside each target).
            writeIconBundle(design, at: "iOS/Macrophone/AppIcon.icon")
            writeIconBundle(design, at: "Mac/Resources/AppIcon.icon")
            // iOS 17–18: light, dark and tinted, 1024, opaque.
            let ios = "iOS/Macrophone/Resources/Assets.xcassets/AppIcon.appiconset"
            writePNG(flat(design, .light, mac: false), "\(ios)/AppIcon-1024.png")
            writePNG(flat(design, .dark, mac: false), "\(ios)/AppIcon-1024-dark.png")
            writePNG(flat(design, .tinted, mac: false), "\(ios)/AppIcon-1024-tinted.png")
            // macOS 14–15: the squircle at every size.
            let mac = flat(design, .light, mac: true)
            let macDir = "Mac/Resources/Assets.xcassets/AppIcon.appiconset"
            for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
                let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
                writePNG(resized(mac, to: pt * scale, opaque: false), "\(macDir)/\(name)")
            }
            // The record: the final renders at 1024 and the small sizes.
            let docs = "docs/icon"
            for a in Appearance.allCases { writePNG(flat(design, a, mac: false), "\(docs)/final-\(a.rawValue)-1024.png") }
            writePNG(mac, "\(docs)/final-mac-1024.png")
            let full = flat(design, .light, mac: false)
            for (pt, px) in [(60, 180), (40, 120), (29, 87)] { writePNG(iosMasked(resized(full, to: px, opaque: true), px: px), "\(docs)/final-\(pt)pt@3x.png") }
            print("installed \(design.rawValue)")
        default:
            exit(2)
        }
    }
}
