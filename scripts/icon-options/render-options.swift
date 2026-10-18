// Macrophone app-icon OPTIONS (Oct 18 2026) — candidates only, nothing here installs.
//
// Sameer: "The app logo still kinda sucks. I don't like the oval in there. Make more modern and
// clean." So: no capsule, no oval, no pill. One bold, flat, confident mark per option on the app's
// ink, drawn in the Thread's cool spectrum (violet → blue → cyan → mint), generous negative space,
// nothing under 14 px at 1024. Each option is written as an Icon Composer bundle (a background
// gradient + one group of opaque foreground layers; no baked light — the system adds the glass),
// (every option is ONE fused foreground layer, so the glass never seams between its parts), as flattened light / dark / tinted PNGs, and onto one comparison sheet.
//
//   xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 scripts/icon-options/render-options.swift -o /tmp/render-options
//   /tmp/render-options preview <dir>            # <dir>/<letter>/AppIcon.icon + flat-*.png for every option
//   sh scripts/icon-render-check.sh <dir>        # the system's own Liquid Glass render of each .icon (macOS 26+)
//   /tmp/render-options sheet <dir> [docs dir]   # the comparison sheet (+ the 1024 light PNGs copied into docs)
//
// scripts/icon-options/run.sh does all three.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UniformTypeIdentifiers

// MARK: - Palette (Theme.swift's Light, the cool end of the Thread)

struct RGB { var r, g, b: Double }
enum Palette {
    static func hex(_ v: UInt32) -> RGB {
        RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }
    static let violet = hex(0x9A86E6), blue = hex(0x6E9CEC), cyan = hex(0x58B9DE), teal = hex(0x5CD3C3), mint = hex(0x5ED6A2)
    /// The Thread, cool end only: violet → blue → cyan → mint. (Gold and coral are the live mic's; the icon stays cool.)
    static let spectrum: [(RGB, Double)] = [(violet, 0), (blue, 0.33), (cyan, 0.62), (mint, 1)]
    /// The ground: the app's ink, lifted to indigo at the top.
    static let groundTop = hex(0x1C1C48), groundBottom = hex(0x07070F)
    static let groundTopDark = hex(0x121233), groundBottomDark = hex(0x040409)
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

// MARK: - Geometry (1024 × 1024, y down)

let side = 1024.0
func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

/// A smooth curve through points (Catmull-Rom as cubics).
func smooth(_ pts: [CGPoint]) -> CGMutablePath {
    let p = CGMutablePath()
    guard pts.count >= 2 else { return p }
    let e = [pts[0]] + pts + [pts[pts.count - 1]]
    p.move(to: pts[0])
    for i in 1..<(e.count - 2) {
        let p0 = e[i - 1], p1 = e[i], p2 = e[i + 1], p3 = e[i + 2]
        let c1 = P(p1.x + (p2.x - p0.x) / 6, p1.y + (p2.y - p0.y) / 6)
        let c2 = P(p2.x - (p3.x - p1.x) / 6, p2.y - (p3.y - p1.y) / 6)
        p.addCurve(to: p2, control1: c1, control2: c2)
    }
    return p
}

/// A polyline sampled from a function, as a path.
func sampled(_ n: Int, _ f: (Double) -> CGPoint) -> CGMutablePath {
    let p = CGMutablePath()
    p.move(to: f(0))
    for i in 1...n { p.addLine(to: f(Double(i) / Double(n))) }
    return p
}

func stroked(_ path: CGPath, _ width: Double) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

func rounded(cx: Double, cy: Double, w: Double, h: Double, r: Double) -> CGPath {
    CGPath(roundedRect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
func circle(cx: Double, cy: Double, r: Double) -> CGPath { CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil) }

/// A ribbon of varying half-width along a centreline: `h(u)` px either side of `c(u)`.
func ribbon(_ n: Int, c: (Double) -> CGPoint, h: (Double) -> Double) -> CGPath {
    var centre: [CGPoint] = [], tangent: [CGPoint] = []
    for i in 0...n { centre.append(c(Double(i) / Double(n))) }
    for i in 0...n {
        let a = centre[max(i - 1, 0)], b = centre[min(i + 1, n)]
        let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 1e-6)
        tangent.append(P(dx / len, dy / len))
    }
    var top: [CGPoint] = [], bottom: [CGPoint] = []
    for i in 0...n {
        let w = h(Double(i) / Double(n)), nx = -tangent[i].y, ny = tangent[i].x
        top.append(P(centre[i].x + nx * w, centre[i].y + ny * w))
        bottom.append(P(centre[i].x - nx * w, centre[i].y - ny * w))
    }
    func cap(from a: CGPoint, to b: CGPoint, along d: CGPoint, into p: CGMutablePath) {
        let k = hypot(a.x - b.x, a.y - b.y) / 2 * 4 / 3
        p.addCurve(to: b, control1: P(a.x + d.x * k, a.y + d.y * k), control2: P(b.x + d.x * k, b.y + d.y * k))
    }
    let p = CGMutablePath()
    p.move(to: top[0])
    for q in top.dropFirst() { p.addLine(to: q) }
    cap(from: top[n], to: bottom[n], along: tangent[n], into: p)
    for q in bottom.dropLast().reversed() { p.addLine(to: q) }
    cap(from: bottom[0], to: top[0], along: P(-tangent[0].x, -tangent[0].y), into: p)
    p.closeSubpath()
    return p
}

// MARK: - The options

enum Flow { case across, diagonal }

struct Layer {
    var name: String
    var path: CGPath
    var evenOdd = false
}

struct Option {
    var letter: String
    var slug: String
    var name: String
    var line: String
    var flow: Flow
    var layers: [Layer]
}

let options: [Option] = [
    // A — one confident stroke: the Thread as a single thick sine, round caps, spectrum across it.
    Option(letter: "A", slug: "ribbon", name: "Ribbon", line: "The Thread as one thick stroke — a single confident wave", flow: .across, layers: [
        Layer(name: "ribbon", path: stroked(sampled(240) { u in P(176 + 672 * u, 512 - 170 * sin(2 * .pi * u)) }, 150)),
    ]),
    // B — a solid spectrum disc with a three-bar voice wave cut out of it.
    Option(letter: "B", slug: "cut", name: "Cut", line: "A solid spectrum disc with the voice wave cut out as negative space", flow: .diagonal, layers: [
        Layer(name: "disc", path: {
            let p = CGMutablePath()
            p.addPath(circle(cx: 512, cy: 512, r: 350))
            for (i, h) in [200.0, 380, 200].enumerated() {
                p.addPath(rounded(cx: 512 + Double(i - 1) * 150, cy: 512, w: 84, h: h, r: 42))
            }
            return p
        }(), evenOdd: true),
    ]),
    // C — phone → Mac: an upright plate, the Thread, a wide plate, on one line.
    Option(letter: "C", slug: "bridge", name: "Bridge", line: "Phone to Mac — the Thread runs from the small plate to the wide one", flow: .across, layers: [
        Layer(name: "phone", path: rounded(cx: 204, cy: 512, w: 136, h: 250, r: 40)),
        Layer(name: "thread", path: stroked(sampled(160) { u in P(312 + 212 * u, 512 - 54 * sin(2 * .pi * u)) }, 60)),
        Layer(name: "mac", path: rounded(cx: 718, cy: 512, w: 356, h: 250, r: 40)),
    ]),
    // D — the Thread's braid distilled: two strands crossing once, one shape.
    Option(letter: "D", slug: "braid", name: "Braid", line: "Two strands of the Thread crossing — the braid, distilled to one shape", flow: .across, layers: [
        Layer(name: "strand-up", path: stroked(sampled(240) { u in P(176 + 672 * u, 512 - 160 * sin(2 * .pi * u)) }, 112)),
        Layer(name: "strand-down", path: stroked(sampled(240) { u in P(176 + 672 * u, 512 + 160 * sin(2 * .pi * u)) }, 112)),
    ]),
    // E — an M drawn as one smooth wave: the monogram.
    Option(letter: "E", slug: "monogram", name: "Monogram", line: "An M drawn as one smooth wave — the waveform monogram", flow: .across, layers: [
        Layer(name: "m", path: stroked(smooth([P(192, 740), P(352, 292), P(512, 600), P(672, 292), P(832, 740)]), 118)),
    ]),
    // F — five rounded bars in the spectrum, ultra clean.
    Option(letter: "F", slug: "bars", name: "Bars", line: "Five rounded bars in the spectrum — the sound wave, ultra clean", flow: .across, layers: [
        Layer(name: "bars", path: {
            let p = CGMutablePath()
            let w = 92.0, gap = 68.0, x0 = 512 - (5 * w + 4 * gap) / 2 + w / 2
            for (i, h) in [250.0, 430, 640, 430, 250].enumerated() {
                p.addPath(rounded(cx: x0 + Double(i) * (w + gap), cy: 512, w: w, h: h, r: w / 2))
            }
            return p
        }()),
    ]),
    // G — the wave resolves into a text cursor: speak, and it lands as words.
    Option(letter: "G", slug: "cursor", name: "Cursor", line: "A wave that resolves into the text cursor — speak, it lands as words", flow: .across, layers: [
        Layer(name: "wave", path: stroked(sampled(240) { u in P(150 + 500 * u, 512 - 150 * sin(2 * .pi * u)) }, 118)),
        Layer(name: "cursor", path: rounded(cx: 790, cy: 512, w: 118, h: 470, r: 30)),
    ]),
]

// MARK: - Drawing

func context(_ px: Int, opaque: Bool) -> CGContext {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: info)!
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / side, y: -CGFloat(px) / side)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// The whole mark's box — the gradient runs across the mark, not each layer, so the parts read as one object.
func markBox(_ o: Option) -> CGRect { o.layers.map { $0.path.boundingBox }.reduce(CGRect.null) { $0.union($1) } }

func fillSpectrum(_ ctx: CGContext, _ o: Option, _ layer: Layer, mono: Bool, alpha: Double = 1) {
    ctx.saveGState()
    ctx.addPath(layer.path)
    ctx.clip(using: layer.evenOdd ? .evenOdd : .winding)
    if mono {
        ctx.setFillColor(gray(1, alpha))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    } else {
        let box = markBox(o)
        let (s, e): (CGPoint, CGPoint)
        switch o.flow {
        case .across: (s, e) = (P(box.minX, 0), P(box.maxX, 0))
        case .diagonal: (s, e) = (P(box.minX, box.minY), P(box.maxX, box.maxY))
        }
        ctx.drawLinearGradient(gradient(Palette.spectrum, alpha: alpha), start: s, end: e, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()
}

/// Draws an image upright in the y-down canvas (a bare `draw` flips it).
func place(_ ctx: CGContext, _ image: CGImage, _ rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: rect.midY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 0, y: -rect.midY)
    ctx.draw(image, in: rect)
    ctx.restoreGState()
}

func blurred(_ image: CGImage, radius: Double) -> CGImage {
    let f = CIFilter.gaussianBlur()
    f.inputImage = CIImage(cgImage: image).clampedToExtent()
    f.radius = Float(radius)
    let out = f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb]).createCGImage(out, from: out.extent)!
}

/// The mark, fused: every part on one image — one object, one spectrum across it, no seams between parts.
func markImage(_ o: Option, mono: Bool, alpha: Double = 1, px: Int = Int(side)) -> CGImage {
    let ctx = context(px, opaque: false)
    for l in o.layers { fillSpectrum(ctx, o, l, mono: mono, alpha: alpha) }
    return ctx.makeImage()!
}

/// The mark's silhouette minus itself shifted down: a sliver along every upper edge.
func edgeImage(_ o: Option) -> CGImage {
    let ctx = context(Int(side), opaque: false)
    let box = markBox(o)
    for l in o.layers {
        ctx.saveGState()
        ctx.addPath(l.path)
        ctx.clip(using: l.evenOdd ? .evenOdd : .winding)
        ctx.drawLinearGradient(grayGradient([(1, 0.55, 0), (1, 0.12, 1)]), start: P(0, box.minY), end: P(0, box.maxY), options: [])
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.setBlendMode(.destinationOut)
    place(ctx, markImage(o, mono: true), CGRect(x: 0, y: 8, width: side, height: side))
    ctx.restoreGState()
    return ctx.makeImage()!
}

enum Appearance: String, CaseIterable { case light, dark, tinted }

/// The flattened icon (iOS 17–18 and the sheet): the ground, a faint halo, the mark. No glass — the
/// fallback stays as clean as the mark itself.
func flat(_ o: Option, _ a: Appearance, px: Int = 1024) -> CGImage {
    let ctx = context(px, opaque: true)
    let full = CGRect(x: 0, y: 0, width: side, height: side)
    let top: RGB, bottom: RGB
    switch a {
    case .light: (top, bottom) = (Palette.groundTop, Palette.groundBottom)
    case .dark: (top, bottom) = (Palette.groundTopDark, Palette.groundBottomDark)
    case .tinted: (top, bottom) = (Palette.hex(0x1A1A1A), Palette.hex(0x050505))
    }
    ctx.setFillColor(cg(bottom))
    ctx.fill(full)
    ctx.drawLinearGradient(gradient([(top, 0), (bottom, 1)]), start: P(200, 0), end: P(824, side), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let mono = a == .tinted
    if !mono {
        // The light the mark throws on the ground: one tight halo, nothing else baked.
        let glow = blurred(markImage(o, mono: false, alpha: 0.85, px: 512), radius: 6)
        ctx.saveGState()
        ctx.setAlpha(a == .dark ? 0.26 : 0.32)
        place(ctx, glow, CGRect(x: 0, y: 6, width: side, height: side))
        ctx.restoreGState()
    }
    place(ctx, markImage(o, mono: mono), full)
    // A whisper of light along the upper edge (the one thing that keeps it from reading as a sticker).
    if !mono { place(ctx, edgeImage(o), full) }
    return ctx.makeImage()!
}

// MARK: - The .icon bundle (Icon Composer: a background fill + one group of glass layers)

func color(_ c: RGB) -> String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b) }

func iconJSON(_ o: Option) -> [String: Any] {
    let layer: [String: Any] = [
        "name": "mark", "image-name": "mark.png", "glass": true, "hidden": false,
        "position": ["scale": 1, "translation-in-points": [0, 0]],
        // The image's own spectrum; solid white in the mono rendition so the system's tint reads clean.
        "fill-specializations": [["appearance": "tinted", "value": ["solid": "extended-gray:1.00000,1.00000"]]],
    ]
    let group: [String: Any] = [
        "name": "Mark", "layers": [layer], "lighting": "individual", "hidden": false,
        "specular": true,
        "shadow": ["kind": "layer-color", "opacity": 0.5],
        "translucency": ["enabled": false, "value": 0.5],
    ]
    return [
        "fill-specializations": [
            ["value": ["linear-gradient": [color(Palette.groundTop), color(Palette.groundBottom)]]],
            ["appearance": "dark", "value": ["linear-gradient": [color(Palette.groundTopDark), color(Palette.groundBottomDark)]]],
        ],
        "groups": [group],
        "supported-platforms": ["squares": "shared", "circles": ["watchOS"]],
    ]
}

func writeIconBundle(_ o: Option, at dir: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: dir)
    try! fm.createDirectory(atPath: "\(dir)/Assets", withIntermediateDirectories: true)
    writePNG(markImage(o, mono: false), "\(dir)/Assets/mark.png")
    let data = try! JSONSerialization.data(withJSONObject: iconJSON(o), options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: "\(dir)/icon.json"))
}

// MARK: - Output

func resized(_ image: CGImage, to px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

func iosMasked(_ image: CGImage, px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let r = Double(px) * 0.2237
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: px, height: px), cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
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

func loadPNG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - The comparison sheet

func sheet(_ dir: String) {
    let big = 400, gap = 24, pad = 40, rowH = 540
    let W = pad + 5 * (big + gap) + 40 + (180 + 16 + 120 + 16 + 87 + 16 + 58) + pad
    let H = pad + 70 + options.count * rowH + pad
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(gray(0.11))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.interpolationQuality = .high
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    func label(_ s: String, _ x: Int, _ y: Int, size: CGFloat = 20, bold: Bool = false, white: CGFloat = 0.82) {
        let attrs: [NSAttributedString.Key: Any] = [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(white: white, alpha: 1)]
        NSString(string: s).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }
    label("Macrophone — icon options, Oct 18 2026. Flat vector marks on the app's ink; the system adds the glass. Nothing installed.", pad, H - pad - 30, size: 24, bold: true)
    for (row, o) in options.enumerated() {
        let top = H - pad - 70 - row * rowH
        label("\(o.letter)  ·  \(o.name)", pad, top - 36, size: 30, bold: true, white: 0.95)
        label(o.line, pad + 300, top - 32, size: 21, white: 0.7)
        var x = pad
        let y = top - 64 - big
        for a in Appearance.allCases {
            ctx.draw(iosMasked(flat(o, a, px: big), px: big), in: CGRect(x: x, y: y, width: big, height: big))
            label(a.rawValue, x, y - 28)
            x += big + gap
        }
        for (file, title) in [("system-1024.png", "macOS 27 renders the .icon"), ("system-dark-1024.png", "the same, dark")] {
            if let img = loadPNG("\(dir)/\(o.letter)/\(file)") {
                ctx.draw(img, in: CGRect(x: x, y: y, width: big, height: big))
                label(title, x, y - 28)
            }
            x += big + gap
        }
        x += 40
        var sy = top - 64
        for a in [Appearance.light, .dark] {
            let full = flat(o, a)
            var sx = x
            for px in [180, 120, 87, 58] {
                ctx.draw(iosMasked(resized(full, to: px), px: px), in: CGRect(x: sx, y: sy - px, width: px, height: px))
                sx += px + 16
            }
            label(a == .light ? "60 · 40 · 29 pt @3x · 29 pt @2x" : "the same, dark", x, sy - 180 - 26)
            sy -= 180 + 50
        }
    }
    writePNG(ctx.makeImage()!, "\(dir)/options-sheet.png")
    print("wrote \(dir)/options-sheet.png")
}

extension CGFloat { var int: Int { Int(self) } }

// MARK: - Main

@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: render-options preview <dir> | sheet <dir> [docs dir]"); exit(2) }
        let dir = args[2]
        switch args[1] {
        case "preview":
            for o in options {
                writeIconBundle(o, at: "\(dir)/\(o.letter)/AppIcon.icon")
                for a in Appearance.allCases { writePNG(flat(o, a), "\(dir)/\(o.letter)/flat-\(a.rawValue).png") }
                print("wrote \(dir)/\(o.letter)")
            }
        case "sheet":
            sheet(dir)
            if args.count > 3 {
                let docs = args[3]
                try? FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)
                for o in options { writePNG(flat(o, .light), "\(docs)/\(o.letter)-\(o.slug).png") }
                let from = URL(fileURLWithPath: "\(dir)/options-sheet.png"), to = URL(fileURLWithPath: "\(docs)/options-sheet.png")
                try? FileManager.default.removeItem(at: to)
                try! FileManager.default.copyItem(at: from, to: to)
                print("copied into \(docs)")
            }
        default:
            exit(2)
        }
    }
}
