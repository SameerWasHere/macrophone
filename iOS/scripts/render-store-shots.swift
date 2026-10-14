#!/usr/bin/env swift
// Frames the raw simulator screens (scripts/capture-store-shots.sh) as App Store screenshots:
// the app's dark ink ground, a small mono kicker and a two-line serif caption on top, a
// Filament of light across the page, and the screen in a slim device frame below.
//
//   swift iOS/scripts/render-store-shots.swift <raw dir> <out dir> <width> <height>
//   e.g. … /tmp/raw-6.9 iOS/docs/store-screenshots/6.9 1320 2868
//        … /tmp/raw-6.5 iOS/docs/store-screenshots/6.5 1284 2778
//
// Output PNGs are opaque sRGB (App Store Connect rejects alpha).

import AppKit
import CoreGraphics
import CoreText
import Foundation

let args = CommandLine.arguments
guard args.count >= 5, let W = Int(args[3]), let H = Int(args[4]) else {
    print("usage: render-store-shots.swift <raw dir> <out dir> <width> <height>")
    exit(2)
}
let rawDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let w = CGFloat(W), h = CGFloat(H)
/// Everything is designed at 1320 wide.
let k = w / 1320

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
let ground = rgb(0.020, 0.024, 0.051)
let ink = rgb(0.957, 0.949, 0.980)
let secondary = rgb(0.788, 0.784, 0.812)
let tertiary = rgb(0.620, 0.616, 0.647)
let cyan = rgb(0.345, 0.725, 0.871)
let teal = rgb(0.361, 0.827, 0.765)
let mint = rgb(0.369, 0.839, 0.635)
let gold = rgb(0.910, 0.753, 0.424)
let ember = rgb(0.914, 0.443, 0.310)
let violet = rgb(0.604, 0.525, 0.902)
let spectrum = [cyan, teal, mint, gold, ember, violet]
let space = CGColorSpace(name: CGColorSpace.sRGB)!

struct Shot {
    var file: String
    var kicker: String
    var caption: String
    var glow: CGColor
    /// Where the Filament's peak sits across the page, 0…1.
    var peak: CGFloat
    /// A before/after card laid over the lower screen: (heard, sent, level).
    var beforeAfter: (String, String, String)? = nil
}

let shots: [Shot] = [
    Shot(file: "01-watch", kicker: "Watch it work", caption: "Your Mac does the coding.\nYour iPhone runs the session.", glow: cyan, peak: 0.42),
    Shot(file: "02-reply", kicker: "Answer by voice", caption: "Say the next prompt.\nIt's pasted in and sent.", glow: ember, peak: 0.58),
    Shot(file: "03-send-to", kicker: "Pick the session", caption: "Every app on your Mac,\none tap away.", glow: teal, peak: 0.36),
    Shot(file: "04-open-app", kicker: "Open any app", caption: "Something closed?\nOpen it from your iPhone.", glow: mint, peak: 0.62),
    Shot(file: "05-cleanup", kicker: "Cleanup", caption: "Four levels, or your own.\nIt edits, never answers.", glow: violet, peak: 0.45,
         beforeAfter: ("so um the thing I want is, uh, make the retry logic back off, no wait, back off exponentially and cap it at thirty seconds",
                       "Make the retry logic back off exponentially and cap it at 30 seconds.", "Medium")),
    Shot(file: "06-pairing", kicker: "Private by design", caption: "Pair once. No account,\nno cloud, no audio kept.", glow: gold, peak: 0.55),
]

// MARK: Text

func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
    return NSFont(name: "New York", size: size) ?? base
}

func mono(_ size: CGFloat) -> NSFont { NSFont.monospacedSystemFont(ofSize: size, weight: .semibold) }

/// Draws centred lines; returns the height used. `y` is the top, in a flipped-to-top coordinate.
@discardableResult
func drawCentered(_ ctx: CGContext, _ text: String, font: NSFont, color: CGColor, top: CGFloat, kern: CGFloat = 0, lineGap: CGFloat = 0) -> CGFloat {
    var y = top
    for line in text.components(separatedBy: "\n") {
        let attr = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: kern])
        let ctLine = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let baseline = y + ascent
        ctx.textPosition = CGPoint(x: (w - width) / 2, y: h - baseline)
        CTLineDraw(ctLine, ctx)
        y += ascent + descent + lineGap
    }
    return y - top
}

// MARK: Pieces

/// Wrapped text in a column; returns the height used. `top` measured from the top of the page.
@discardableResult
func drawWrapped(_ ctx: CGContext, _ text: String, font: NSFont, color: CGColor, x: CGFloat, top: CGFloat, width: CGFloat, lineHeight: CGFloat, kern: CGFloat = 0) -> CGFloat {
    let para = NSMutableParagraphStyle()
    para.minimumLineHeight = lineHeight
    para.maximumLineHeight = lineHeight
    let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .paragraphStyle: para, .kern: kern])
    let fs = CTFramesetterCreateWithAttributedString(attr)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    let rect = CGRect(x: x, y: h - top - ceil(size.height), width: width, height: ceil(size.height))
    let frame = CTFramesetterCreateFrame(fs, CFRange(), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, ctx)
    return ceil(size.height)
}

/// "HEARD → SENT": what was said and what went out, on a glass card.
func drawBeforeAfter(_ ctx: CGContext, heard: String, sent: String, level: String, top: CGFloat) {
    let x = 96 * k, cw = w - 192 * k, pad = 52 * k
    let inner = cw - pad * 2
    // Measure first (draw offscreen heights by layout math).
    func height(_ t: String, _ f: NSFont, _ lh: CGFloat) -> CGFloat {
        let para = NSMutableParagraphStyle(); para.minimumLineHeight = lh; para.maximumLineHeight = lh
        let fs = CTFramesetterCreateWithAttributedString(NSAttributedString(string: t, attributes: [.font: f, .paragraphStyle: para]))
        return ceil(CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(), nil, CGSize(width: inner, height: .greatestFiniteMagnitude), nil).height)
    }
    let heardFont = NSFont.systemFont(ofSize: 38 * k), sentFont = serif(50 * k)
    let hh = height(heard, heardFont, 52 * k), sh = height(sent, sentFont, 64 * k)
    let ch = pad + 34 * k + 18 * k + hh + 44 * k + 1 + 44 * k + 34 * k + 18 * k + sh + pad
    let card = CGRect(x: x, y: h - top - ch, width: cw, height: ch)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24 * k), blur: 80 * k, color: rgb(0, 0, 0, 0.75))
    ctx.addPath(roundedRect(card, 54 * k))
    ctx.setFillColor(rgb(0.085, 0.092, 0.140, 0.97))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(roundedRect(card.insetBy(dx: 1 * k, dy: 1 * k), 53 * k))
    ctx.setStrokeColor(rgb(0.957, 0.949, 0.980, 0.16))
    ctx.setLineWidth(2 * k)
    ctx.strokePath()
    var y = top + pad
    func kicker(_ t: String, _ c: CGColor) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: [.font: mono(28 * k), .foregroundColor: NSColor(cgColor: c)!, .kern: 5 * k]))
        ctx.textPosition = CGPoint(x: x + pad, y: h - y - 26 * k)
        CTLineDraw(line, ctx)
        y += 34 * k + 18 * k
    }
    kicker("HEARD", tertiary)
    y += drawWrapped(ctx, heard, font: heardFont, color: tertiary, x: x + pad, top: y, width: inner, lineHeight: 52 * k)
    y += 44 * k
    ctx.setFillColor(rgb(0.957, 0.949, 0.980, 0.12))
    ctx.fill(CGRect(x: x + pad, y: h - y, width: inner, height: max(1, 2 * k)))
    y += 44 * k
    kicker("SENT · \(level.uppercased()) CLEANUP", teal)
    drawWrapped(ctx, sent, font: sentFont, color: ink, x: x + pad, top: y, width: inner, lineHeight: 64 * k)
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The Filament: a tapered spectrum line across the page with a soft swell at `peak`.
func drawFilament(_ ctx: CGContext, y: CGFloat, peak: CGFloat, glow: CGColor) {
    let gradient = CGGradient(colorsSpace: space, colors: spectrum as CFArray, locations: nil)!
    func path(amp: CGFloat, phase: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let steps = 240
        for i in 0...steps {
            let u = CGFloat(i) / CGFloat(steps)
            let x = -20 * k + u * (w + 40 * k)
            let env = exp(-pow((u - peak) / 0.17, 2))
            let yy = y + amp * env * sin(u * 26 + phase) * (0.6 + 0.4 * sin(u * 9 + phase * 0.7))
            if i == 0 { p.move(to: CGPoint(x: x, y: yy)) } else { p.addLine(to: CGPoint(x: x, y: yy)) }
        }
        return p
    }
    // Soft halo in the shot's light.
    ctx.saveGState()
    let halo = CGGradient(colorsSpace: space, colors: [glow.copy(alpha: 0.22)!, glow.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: CGPoint(x: w * peak, y: y), startRadius: 0,
                           endCenter: CGPoint(x: w * peak, y: y), endRadius: 520 * k, options: [])
    ctx.restoreGState()
    // Strands: thick + faint, then thin + bright.
    for (amp, phase, width, alpha, blur) in [(70.0, 0.0, 16.0, 0.10, 28.0), (52.0, 1.3, 6.0, 0.35, 10.0), (60.0, 2.1, 3.0, 0.9, 0.0), (36.0, 0.6, 2.0, 0.6, 0.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] {
        ctx.saveGState()
        ctx.addPath(path(amp: amp * k, phase: phase))
        ctx.setLineWidth(width * k)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.setAlpha(alpha)
        if blur > 0 { ctx.setShadow(offset: .zero, blur: blur * k, color: glow) }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y), end: CGPoint(x: w, y: y), options: [])
        ctx.restoreGState()
    }
    // Fade the ends into the ground.
    for (x0, x1) in [(0.0, 0.16), (1.0, 0.84)] as [(CGFloat, CGFloat)] {
        let g = CGGradient(colorsSpace: space, colors: [ground, ground.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: w * x0, y: y), end: CGPoint(x: w * x1, y: y), options: [])
    }
}

func drawDevice(_ ctx: CGContext, screen: CGImage, rect r: CGRect) {
    let bezel = 20 * k
    let outer = r.insetBy(dx: -bezel, dy: -bezel)
    let screenRadius = 168 * k * (r.width / 1080 / k)
    // Shadow + body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -30 * k), blur: 90 * k, color: rgb(0, 0, 0, 0.7))
    ctx.addPath(roundedRect(outer, screenRadius + bezel))
    ctx.setFillColor(rgb(0.035, 0.038, 0.050))
    ctx.fillPath()
    ctx.restoreGState()
    // Titanium edge: a cool rim with a light catch at the top.
    ctx.saveGState()
    ctx.addPath(roundedRect(outer.insetBy(dx: 1.5 * k, dy: 1.5 * k), screenRadius + bezel - 1.5 * k))
    ctx.setLineWidth(3 * k)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rim = CGGradient(colorsSpace: space, colors: [rgb(0.62, 0.64, 0.70), rgb(0.22, 0.23, 0.27), rgb(0.40, 0.42, 0.48)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: outer.minX, y: outer.maxY), end: CGPoint(x: outer.maxX, y: outer.minY), options: [])
    ctx.restoreGState()
    // The screen.
    ctx.saveGState()
    ctx.addPath(roundedRect(r, screenRadius))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(screen, in: r)
    ctx.restoreGState()
    // iPhone 14 Plus class (the 6.5" set): a notch, not an island.
    if screen.width == 1284 || screen.width == 1242 {
        let nw = r.width * 0.376, nh = r.height * 0.0355, rr = nh * 0.62, flare = nh * 0.22
        let x0 = r.midX - nw / 2, x1 = r.midX + nw / 2, top = r.maxY, bottom = r.maxY - nh
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0 - flare, y: top))
        p.addQuadCurve(to: CGPoint(x: x0, y: top - flare), control: CGPoint(x: x0, y: top))
        p.addLine(to: CGPoint(x: x0, y: bottom + rr))
        p.addQuadCurve(to: CGPoint(x: x0 + rr, y: bottom), control: CGPoint(x: x0, y: bottom))
        p.addLine(to: CGPoint(x: x1 - rr, y: bottom))
        p.addQuadCurve(to: CGPoint(x: x1, y: bottom + rr), control: CGPoint(x: x1, y: bottom))
        p.addLine(to: CGPoint(x: x1, y: top - flare))
        p.addQuadCurve(to: CGPoint(x: x1 + flare, y: top), control: CGPoint(x: x1, y: top))
        p.closeSubpath()
        ctx.saveGState()
        ctx.addPath(roundedRect(r, screenRadius))
        ctx.clip()
        ctx.addPath(p)
        ctx.setFillColor(rgb(0.035, 0.038, 0.050))
        ctx.fillPath()
        ctx.restoreGState()
        return
    }
    // Dynamic Island.
    let scale = r.width / CGFloat(screen.width)
    let islandW = 372 * scale * (CGFloat(screen.width) / 1320)
    let islandH = 110 * scale * (CGFloat(screen.width) / 1320)
    let island = CGRect(x: r.midX - islandW / 2, y: r.maxY - 34 * scale * (CGFloat(screen.width) / 1320) - islandH, width: islandW, height: islandH)
    ctx.addPath(roundedRect(island, islandH / 2))
    ctx.setFillColor(rgb(0, 0, 0))
    ctx.fillPath()
}

// MARK: Render

for shot in shots {
    let src = rawDir.appendingPathComponent(shot.file + ".png")
    guard let img = NSImage(contentsOf: src), let screen = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("missing \(src.path)")
        continue
    }
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("no context") }

    // Ground with a glow behind the caption.
    ctx.setFillColor(ground)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let top = CGGradient(colorsSpace: space, colors: [shot.glow.copy(alpha: 0.16)!, shot.glow.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(top, startCenter: CGPoint(x: w * 0.5, y: h * 1.02), startRadius: 0,
                           endCenter: CGPoint(x: w * 0.5, y: h * 1.02), endRadius: 1100 * k, options: [])

    // Caption.
    let kickerTop: CGFloat = 196 * k
    drawCentered(ctx, shot.kicker.uppercased(), font: mono(30 * k), color: shot.glow, top: kickerTop, kern: 6 * k)
    drawCentered(ctx, shot.caption, font: serif(86 * k), color: ink, top: kickerTop + 70 * k, kern: -0.6 * k, lineGap: 10 * k)

    // The Filament, crossing just above the device.
    let deviceTop = 610 * k * (h / w) / (2868.0 / 1320.0) + 10 * k
    drawFilament(ctx, y: h - (deviceTop - 6 * k), peak: shot.peak, glow: shot.glow)

    // The device: wide enough to read, its foot running off the page.
    let dw = 1060 * k
    let dh = dw * CGFloat(screen.height) / CGFloat(screen.width)
    let rect = CGRect(x: (w - dw) / 2, y: h - deviceTop - 24 * k - dh, width: dw, height: dh)
    drawDevice(ctx, screen: screen, rect: rect)

    if let ba = shot.beforeAfter {
        drawBeforeAfter(ctx, heard: ba.0, sent: ba.1, level: ba.2, top: h * 0.60)
    }

    // A dissolve at the very foot so the cut-off reads as intended.
    let foot = CGGradient(colorsSpace: space, colors: [ground, ground.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(foot, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 150 * k), options: [])

    let out = outDir.appendingPathComponent(shot.file + ".png")
    let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(out.path)")
}
