#!/usr/bin/env swift
// Frames the raw simulator screens (scripts/capture-store-shots.sh, capture-duo-store-shots.sh) as
// App Store screenshots: a night ground, a big bold two-line headline with one lit word on top, the
// Thread of light (Apple Intelligence's colours, as on the app's mic) across the page, and the
// screen in a slim device frame below.
//
//   swift iOS/scripts/render-store-shots.swift <raw dir> <out dir> <width> <height> [phone|duo]
//   e.g. … /tmp/raw-6.9 iOS/docs/store-screenshots/6.9 1320 2868
//        … /tmp/raw-6.5 iOS/docs/store-screenshots/6.5 1284 2778
//        … /tmp/raw-duo  iOS/docs/store-screenshots/duo 2007 2853 duo
//
// Output PNGs are opaque sRGB (App Store Connect rejects alpha).

import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

let args = CommandLine.arguments
guard args.count >= 5, let W = Int(args[3]), let H = Int(args[4]) else {
    print("usage: render-store-shots.swift <raw dir> <out dir> <width> <height> [phone|duo]")
    exit(2)
}
let rawDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let set = args.count > 5 ? args[5] : "phone"
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let w = CGFloat(W), h = CGFloat(H)
/// Everything is designed at 1320 wide.
let k = w / 1320

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
let ground = rgb(0.027, 0.035, 0.082)
let ink = rgb(0.965, 0.965, 0.985)
// Apple Intelligence's colours, as the app's mic ring and Thread wear them (MacOSLook.intelligence).
let blue = rgb(0.271, 0.604, 1.000)
let purple = rgb(0.737, 0.510, 0.953)
let pink = rgb(0.961, 0.447, 0.718)
let orange = rgb(1.000, 0.596, 0.341)
let teal = rgb(0.361, 0.827, 0.765)
let spectrum = [blue, purple, pink, orange, blue]
let space = CGColorSpace(name: CGColorSpace.sRGB)!

struct Shot {
    var out: String
    /// The raw screen it frames.
    var file: String
    /// Two short lines; *a word* between asterisks takes the shot's light.
    var caption: String
    var glow: CGColor
    /// Where the Thread's peak sits across the page, 0…1.
    var peak: CGFloat
    /// A before/after card laid over the lower screen: (heard, sent, level).
    var beforeAfter: (String, String, String)? = nil
    /// The hero: a MacBook showing this window, the phone in front of it.
    var macWindow: String? = nil
    /// A finger's tap, as a fraction of the screen.
    var tap: CGPoint? = nil
    /// A band of the screen (fractions, top-down) lifted out and magnified in place.
    var magnify: (top: CGFloat, bottom: CGFloat, scale: CGFloat)? = nil
    /// The Duo half-folded like a laptop: the lower half laid back in perspective.
    var laptop = false
}

// The redesign pass (Nov 1 2026): the same story as Oct 14, on the new screens. No caption names a
// third-party app, and none says "Mac" (Apple turned down "Control your Mac by voice", 5.2.5) —
// "your computer" where it reads fine.
let phoneShots: [Shot] = [
    Shot(out: "01-hero", file: "01-watch", caption: "Your computer,\nlive on your *iPhone*.", glow: blue, peak: 0.5, macWindow: "mac-window.png"),
    Shot(out: "02-talk", file: "02-reply", caption: "*Say* what's next.\nIt's typed and sent.", glow: orange, peak: 0.58),
    Shot(out: "03-tap", file: "03-trackpad", caption: "Point, tap, *scroll*,\nlike you're there.", glow: teal, peak: 0.36, tap: CGPoint(x: 0.56, y: 0.80)),
    Shot(out: "04-apps", file: "04-desktop", caption: "Every app\nin your *Dock*.", glow: blue, peak: 0.42, magnify: (0.475, 0.672, 1.14)),
    Shot(out: "05-open", file: "05-open-app", caption: "Open *any app*\non your computer.", glow: purple, peak: 0.62),
    Shot(out: "06-cleanup", file: "06-settings", caption: "Ums and uhs,\n*cleaned up*.", glow: purple, peak: 0.45,
         beforeAfter: ("so um the thing I want is, uh, make the retry logic back off, no wait, back off exponentially and cap it at thirty seconds",
                       "Make the retry logic back off exponentially and cap it at 30 seconds.", "Medium")),
    Shot(out: "07-private", file: "07-pairing", caption: "*Private.* No account.\nNo cloud.", glow: orange, peak: 0.55),
]

let duoShots: [Shot] = [
    Shot(out: "01-laptop", file: "01-laptop-trackpad", caption: "Fold it into a\nlittle *laptop*.", glow: blue, peak: 0.5, laptop: true),
    Shot(out: "02-keyboard", file: "02-laptop-keyboard", caption: "A full *keyboard*\nfor your computer.", glow: purple, peak: 0.4, laptop: true),
    Shot(out: "03-book", file: "03-book", caption: "Open it up.\n*Everything* in hand.", glow: teal, peak: 0.6),
    Shot(out: "04-open", file: "04-open-flat", caption: "Watch on one side,\n*talk* on the other.", glow: orange, peak: 0.45),
    Shot(out: "05-cover", file: "05-cover", caption: "Closed, it's all\nin one *hand*.", glow: pink, peak: 0.55),
]

let shots = set == "duo" ? duoShots : phoneShots

// MARK: Text

func serif(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size)
    if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
    return base
}

func mono(_ size: CGFloat) -> NSFont { NSFont.monospacedSystemFont(ofSize: size, weight: .semibold) }

func headlineLine(_ line: String, size: CGFloat, light: CGColor) -> CTLine {
    let font = NSFont.systemFont(ofSize: size, weight: .bold)
    let attr = NSMutableAttributedString()
    for (i, part) in line.components(separatedBy: "*").enumerated() where !part.isEmpty {
        attr.append(NSAttributedString(string: part, attributes: [.font: font, .kern: -size * 0.022,
            .foregroundColor: NSColor(cgColor: i % 2 == 1 ? light : ink)!]))
    }
    return CTLineCreateWithAttributedString(attr)
}

/// The headline: bold, tight, centred; *words* in the light. Shrinks to fit the page's width.
@discardableResult
func drawHeadline(_ ctx: CGContext, _ text: String, size wanted: CGFloat, light: CGColor, top: CGFloat) -> CGFloat {
    let lines = text.components(separatedBy: "\n")
    var size = wanted
    let room = w - 150 * k
    let widest = lines.map { CGFloat(CTLineGetTypographicBounds(headlineLine($0, size: size, light: light), nil, nil, nil)) }.max() ?? 0
    if widest > room { size *= room / widest }
    var y = top
    for line in lines {
        let ctLine = headlineLine(line, size: size, light: light)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        ctx.textPosition = CGPoint(x: (w - width) / 2, y: h - (y + ascent))
        CTLineDraw(ctLine, ctx)
        y += size * 1.08
    }
    return y - top
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: Pieces

/// A MacBook, front on: the window on its screen over a desktop like the stand-in's wallpaper, a thin base.
func drawMac(_ ctx: CGContext, window: CGImage, rect r: CGRect) {
    let bezel = r.width * 0.022
    let lidH = r.height * 0.93
    let lid = CGRect(x: r.minX, y: r.maxY - lidH, width: r.width, height: lidH)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -30 * k), blur: 90 * k, color: rgb(0, 0, 0, 0.75))
    ctx.addPath(roundedRect(lid, 34 * k))
    ctx.setFillColor(rgb(0.06, 0.063, 0.075))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(roundedRect(lid.insetBy(dx: 1.5 * k, dy: 1.5 * k), 33 * k))
    ctx.setStrokeColor(rgb(0.45, 0.47, 0.53, 0.8)); ctx.setLineWidth(3 * k); ctx.strokePath()
    // The screen: a soft blue-lilac desktop, a menu bar, the window.
    let screen = lid.insetBy(dx: bezel, dy: bezel)
    ctx.saveGState()
    ctx.addPath(roundedRect(screen, 14 * k)); ctx.clip()
    let desk = CGGradient(colorsSpace: space, colors: [rgb(0.36, 0.55, 0.85), rgb(0.50, 0.58, 0.90), rgb(0.66, 0.60, 0.88)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(desk, start: CGPoint(x: screen.minX, y: screen.minY), end: CGPoint(x: screen.maxX, y: screen.maxY), options: [])
    ctx.setFillColor(rgb(1, 1, 1, 0.30))
    ctx.fill(CGRect(x: screen.minX, y: screen.maxY - 26 * k, width: screen.width, height: 26 * k))
    let ww = screen.width * 0.80, wh = ww * CGFloat(window.height) / CGFloat(window.width)
    let wr = CGRect(x: screen.midX - ww / 2, y: screen.maxY - 26 * k - 28 * k - wh, width: ww, height: wh)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 30 * k, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(roundedRect(wr, 12 * k)); ctx.setFillColor(rgb(0.12, 0.12, 0.13)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(roundedRect(wr, 12 * k)); ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(window, in: wr)
    ctx.restoreGState()
    ctx.restoreGState()
    // The base.
    let base = CGRect(x: r.minX - r.width * 0.06, y: r.minY, width: r.width * 1.12, height: r.height - lidH + 4 * k)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: base.minX, y: base.maxY)); p.addLine(to: CGPoint(x: base.maxX, y: base.maxY))
    p.addLine(to: CGPoint(x: base.maxX - 30 * k, y: base.minY)); p.addLine(to: CGPoint(x: base.minX + 30 * k, y: base.minY)); p.closeSubpath()
    ctx.addPath(p)
    let metal = CGGradient(colorsSpace: space, colors: [rgb(0.62, 0.64, 0.70), rgb(0.26, 0.27, 0.31)] as CFArray, locations: [0, 1])!
    ctx.saveGState(); ctx.clip()
    ctx.drawLinearGradient(metal, start: CGPoint(x: 0, y: base.maxY), end: CGPoint(x: 0, y: base.minY), options: [])
    ctx.restoreGState()
}

/// A fingertip's touch: a soft disc with rings in the shot's light.
func drawTap(_ ctx: CGContext, at c: CGPoint, light: CGColor) {
    for (radius, alpha, width) in [(120.0, 0.20, 0.0), (86.0, 0.0, 5.0), (132.0, 0.0, 3.0)] as [(CGFloat, CGFloat, CGFloat)] {
        let r = CGRect(x: c.x - radius * k, y: c.y - radius * k, width: radius * 2 * k, height: radius * 2 * k)
        if width == 0 {
            ctx.setFillColor(light.copy(alpha: alpha)!); ctx.fillEllipse(in: r)
        } else {
            ctx.setStrokeColor(light.copy(alpha: width > 4 ? 0.95 : 0.45)!); ctx.setLineWidth(width * k); ctx.strokeEllipse(in: r)
        }
    }
    ctx.setFillColor(rgb(1, 1, 1, 0.88))
    ctx.fillEllipse(in: CGRect(x: c.x - 34 * k, y: c.y - 34 * k, width: 68 * k, height: 68 * k))
}

/// Wrapped text in a column; returns the height used. `top` measured from the top of the page.
@discardableResult
func drawWrapped(_ ctx: CGContext, _ text: String, font: NSFont, color: CGColor, x: CGFloat, top: CGFloat, width: CGFloat, lineHeight: CGFloat) -> CGFloat {
    let para = NSMutableParagraphStyle()
    para.minimumLineHeight = lineHeight
    para.maximumLineHeight = lineHeight
    let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .paragraphStyle: para])
    let fs = CTFramesetterCreateWithAttributedString(attr)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    let rect = CGRect(x: x, y: h - top - ceil(size.height), width: width, height: ceil(size.height))
    let frame = CTFramesetterCreateFrame(fs, CFRange(), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, ctx)
    return ceil(size.height)
}

/// "Heard → Sent": what was said and what went out, on a card of glass (the app's own light look).
func drawBeforeAfter(_ ctx: CGContext, heard: String, sent: String, level: String, top: CGFloat) {
    let x = 96 * k, cw = w - 192 * k, pad = 52 * k
    let inner = cw - pad * 2
    func height(_ t: String, _ f: NSFont, _ lh: CGFloat) -> CGFloat {
        let para = NSMutableParagraphStyle(); para.minimumLineHeight = lh; para.maximumLineHeight = lh
        let fs = CTFramesetterCreateWithAttributedString(NSAttributedString(string: t, attributes: [.font: f, .paragraphStyle: para]))
        return ceil(CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(), nil, CGSize(width: inner, height: .greatestFiniteMagnitude), nil).height)
    }
    let heardFont = NSFont.systemFont(ofSize: 38 * k), sentFont = NSFont.systemFont(ofSize: 48 * k, weight: .medium)
    let hh = height(heard, heardFont, 52 * k), sh = height(sent, sentFont, 62 * k)
    let kickerH = 34 * k + 18 * k
    let ch = pad + kickerH + hh + 44 * k + 1 + 44 * k + kickerH + sh + pad
    let card = CGRect(x: x, y: h - top - ch, width: cw, height: ch)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24 * k), blur: 80 * k, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(roundedRect(card, 54 * k))
    ctx.setFillColor(rgb(1, 1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()
    let label = rgb(0.0, 0.0, 0.0), secondary = rgb(0.24, 0.24, 0.26, 0.6)
    var y = top + pad
    func kicker(_ t: String, _ c: CGColor) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 30 * k, weight: .semibold), .foregroundColor: NSColor(cgColor: c)!]))
        ctx.textPosition = CGPoint(x: x + pad, y: h - y - 28 * k)
        CTLineDraw(line, ctx)
        y += kickerH
    }
    kicker("Heard", secondary)
    y += drawWrapped(ctx, heard, font: heardFont, color: secondary, x: x + pad, top: y, width: inner, lineHeight: 52 * k)
    y += 44 * k
    ctx.setFillColor(rgb(0.24, 0.24, 0.26, 0.18))
    ctx.fill(CGRect(x: x + pad, y: h - y, width: inner, height: max(1, 2 * k)))
    y += 44 * k
    kicker("Sent · \(level) cleanup", purple)
    drawWrapped(ctx, sent, font: sentFont, color: label, x: x + pad, top: y, width: inner, lineHeight: 62 * k)
}

/// The Thread: a tapered spectrum line across the page with a soft swell at `peak`.
func drawThread(_ ctx: CGContext, y: CGFloat, peak: CGFloat, glow: CGColor) {
    let gradient = CGGradient(colorsSpace: space, colors: spectrum as CFArray, locations: nil)!
    func path(amp: CGFloat, phase: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let steps = 240
        for i in 0...steps {
            let u = CGFloat(i) / CGFloat(steps)
            let x = -20 * k + u * (w + 40 * k)
            let env = exp(-pow((u - peak) / 0.2, 2))
            let yy = y + amp * env * sin(u * 18 + phase) * (0.6 + 0.4 * sin(u * 7 + phase * 0.7))
            if i == 0 { p.move(to: CGPoint(x: x, y: yy)) } else { p.addLine(to: CGPoint(x: x, y: yy)) }
        }
        return p
    }
    ctx.saveGState()
    let halo = CGGradient(colorsSpace: space, colors: [glow.copy(alpha: 0.20)!, glow.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: CGPoint(x: w * peak, y: y), startRadius: 0,
                           endCenter: CGPoint(x: w * peak, y: y), endRadius: 520 * k, options: [])
    ctx.restoreGState()
    for (amp, phase, width, alpha, blur) in [(64.0, 0.0, 16.0, 0.10, 28.0), (48.0, 1.3, 6.0, 0.35, 10.0), (56.0, 2.1, 3.0, 0.9, 0.0), (34.0, 0.6, 2.0, 0.6, 0.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] {
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
    for (x0, x1) in [(0.0, 0.16), (1.0, 0.84)] as [(CGFloat, CGFloat)] {
        let g = CGGradient(colorsSpace: space, colors: [ground, ground.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: w * x0, y: y), end: CGPoint(x: w * x1, y: y), options: [])
    }
}

/// A rectangle with only its top corners rounded (the lid of a folded Duo, square at the hinge).
func topRounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX, y: r.minY))
    p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX + radius, y: r.maxY), radius: radius)
    p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX, y: r.maxY - radius), radius: radius)
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    p.closeSubpath()
    return p
}

/// The device's body: a shadow, the black glass and a cool titanium rim.
func drawBody(_ ctx: CGContext, outer: CGRect, radius: CGFloat, squareFoot: Bool = false) {
    let shape: (CGRect, CGFloat) -> CGPath = squareFoot ? topRounded : roundedRect
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -30 * k), blur: 90 * k, color: rgb(0, 0, 0, 0.7))
    ctx.addPath(shape(outer, radius))
    ctx.setFillColor(rgb(0.035, 0.038, 0.050))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape(outer.insetBy(dx: 1.5 * k, dy: 1.5 * k), radius - 1.5 * k))
    ctx.setLineWidth(3 * k)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rim = CGGradient(colorsSpace: space, colors: [rgb(0.62, 0.64, 0.70), rgb(0.22, 0.23, 0.27), rgb(0.40, 0.42, 0.48)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: outer.minX, y: outer.maxY), end: CGPoint(x: outer.maxX, y: outer.minY), options: [])
    ctx.restoreGState()
}

func drawScreen(_ ctx: CGContext, _ screen: CGImage, in r: CGRect, radius: CGFloat) {
    ctx.saveGState()
    ctx.addPath(roundedRect(r, radius))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(screen, in: r)
    ctx.restoreGState()
}

func drawDevice(_ ctx: CGContext, screen: CGImage, rect r: CGRect) {
    let bezel = 20 * k
    let outer = r.insetBy(dx: -bezel, dy: -bezel)
    let screenRadius = 168 * k * (r.width / 1080 / k)
    drawBody(ctx, outer: outer, radius: screenRadius + bezel)
    drawScreen(ctx, screen, in: r, radius: screenRadius)
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

/// The fold's crease, faint, across (`across`) or down the middle of an inner screen.
func drawCrease(_ ctx: CGContext, in r: CGRect, across: Bool) {
    let band = 18 * k
    let c = across ? CGPoint(x: r.midX, y: r.midY) : CGPoint(x: r.midX, y: r.midY)
    let g = CGGradient(colorsSpace: space, colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.10), rgb(1, 1, 1, 0.10), rgb(0, 0, 0, 0)] as CFArray, locations: [0, 0.45, 0.55, 1])!
    ctx.saveGState()
    if across {
        ctx.clip(to: CGRect(x: r.minX, y: c.y - band, width: r.width, height: band * 2))
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: c.y + band), end: CGPoint(x: 0, y: c.y - band), options: [])
    } else {
        ctx.clip(to: CGRect(x: c.x - band, y: r.minY, width: band * 2, height: r.height))
        ctx.drawLinearGradient(g, start: CGPoint(x: c.x - band, y: 0), end: CGPoint(x: c.x + band, y: 0), options: [])
    }
    ctx.restoreGState()
}

/// The Duo's inner screen or cover, flat and front on: a slimmer body, no island.
func drawDuo(_ ctx: CGContext, screen: CGImage, rect r: CGRect, inner: Bool) {
    let bezel = 18 * k
    let radius = min(r.width, r.height) * 0.055
    drawBody(ctx, outer: r.insetBy(dx: -bezel, dy: -bezel), radius: radius + bezel)
    drawScreen(ctx, screen, in: r, radius: radius)
    if inner { drawCrease(ctx, in: r, across: r.height > r.width) }
}

let ciContext = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])

/// The Duo half-folded: the top half upright, the lower half laid back towards the viewer (a
/// trapezoid wider at the front), the hinge between — a little laptop.
func drawLaptopDuo(_ ctx: CGContext, screen: CGImage, rect r: CGRect) {
    let bezel = 18 * k
    let radius = r.width * 0.055
    let sw = CGFloat(screen.width), sh = CGFloat(screen.height)
    guard let topImg = screen.cropping(to: CGRect(x: 0, y: 0, width: sw, height: sh / 2)),
          let botImg = screen.cropping(to: CGRect(x: 0, y: sh / 2, width: sw, height: sh / 2)) else { return }
    let halfH = r.height / 2
    // The lid: the upper half, upright.
    let lid = CGRect(x: r.minX, y: r.maxY - halfH, width: r.width, height: halfH)
    // The deck: the lower half laid back — shorter, its front edge wider.
    let deckH = halfH * 0.62, spread = r.width * 0.07
    let backY = lid.minY - 6 * k, frontY = backY - deckH
    let backL = CGPoint(x: lid.minX, y: backY), backR = CGPoint(x: lid.maxX, y: backY)
    let frontL = CGPoint(x: lid.minX - spread, y: frontY), frontR = CGPoint(x: lid.maxX + spread, y: frontY)
    // Bodies first: the deck's slab (with its front edge), then the lid.
    let deckBody = CGMutablePath()
    let b = bezel * 0.9
    deckBody.move(to: CGPoint(x: backL.x - b, y: backY + b * 0.3))
    deckBody.addLine(to: CGPoint(x: backR.x + b, y: backY + b * 0.3))
    deckBody.addLine(to: CGPoint(x: frontR.x + b * 1.2, y: frontY - b))
    deckBody.addLine(to: CGPoint(x: frontR.x + b * 1.2, y: frontY - b - 22 * k))
    deckBody.addLine(to: CGPoint(x: frontL.x - b * 1.2, y: frontY - b - 22 * k))
    deckBody.addLine(to: CGPoint(x: frontL.x - b * 1.2, y: frontY - b))
    deckBody.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -40 * k), blur: 100 * k, color: rgb(0, 0, 0, 0.75))
    ctx.addPath(deckBody); ctx.setFillColor(rgb(0.035, 0.038, 0.050)); ctx.fillPath()
    ctx.restoreGState()
    // The deck's front edge: titanium.
    ctx.saveGState()
    let edge = CGRect(x: frontL.x - b * 1.2, y: frontY - b - 22 * k, width: (frontR.x - frontL.x) + b * 2.4, height: 22 * k)
    ctx.addPath(roundedRect(edge, 10 * k)); ctx.clip()
    let metal = CGGradient(colorsSpace: space, colors: [rgb(0.60, 0.62, 0.68), rgb(0.26, 0.27, 0.31)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(metal, start: CGPoint(x: 0, y: edge.maxY), end: CGPoint(x: 0, y: edge.minY), options: [])
    ctx.restoreGState()
    // The deck's screen, in perspective.
    let ci = CIImage(cgImage: botImg)
    let f = CIFilter(name: "CIPerspectiveTransform")!
    f.setValue(ci, forKey: kCIInputImageKey)
    let ox = frontL.x, oy = frontY
    f.setValue(CIVector(x: backL.x - ox, y: backY - oy), forKey: "inputTopLeft")
    f.setValue(CIVector(x: backR.x - ox, y: backY - oy), forKey: "inputTopRight")
    f.setValue(CIVector(x: frontL.x - ox, y: 0), forKey: "inputBottomLeft")
    f.setValue(CIVector(x: frontR.x - ox, y: 0), forKey: "inputBottomRight")
    // Scale the source to the target's pixel size first so the warp samples well.
    if let out = f.outputImage, let cg = ciContext.createCGImage(out, from: out.extent) {
        let trap = CGMutablePath()
        trap.move(to: backL); trap.addLine(to: backR); trap.addLine(to: frontR); trap.addLine(to: frontL); trap.closeSubpath()
        ctx.saveGState()
        ctx.addPath(trap); ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: ox + out.extent.minX, y: oy + out.extent.minY, width: out.extent.width, height: out.extent.height))
        // A touch of shade towards the hinge, as the deck tilts away from the light.
        let shade = CGGradient(colorsSpace: space, colors: [rgb(0, 0, 0, 0.16), rgb(0, 0, 0, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: backY), end: CGPoint(x: 0, y: backY - deckH * 0.5), options: [])
        ctx.restoreGState()
    }
    // The lid on top.
    drawBody(ctx, outer: CGRect(x: lid.minX - bezel, y: lid.minY - 4 * k, width: lid.width + bezel * 2, height: lid.height + bezel + 4 * k), radius: radius + bezel, squareFoot: true)
    ctx.saveGState()
    ctx.addPath(topRounded(lid, radius)); ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(topImg, in: lid)
    ctx.restoreGState()
    // The hinge: a dark seam with a highlight.
    ctx.setFillColor(rgb(0.02, 0.02, 0.03)); ctx.fill(CGRect(x: lid.minX - bezel, y: backY - 2 * k, width: lid.width + bezel * 2, height: lid.minY - backY + 4 * k))
    ctx.setFillColor(rgb(1, 1, 1, 0.10)); ctx.fill(CGRect(x: lid.minX, y: lid.minY - 1.5 * k, width: lid.width, height: 1.5 * k))
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

    // Ground, with the shot's light pooled behind the headline and under the device.
    ctx.setFillColor(ground)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for (cy, radius, alpha) in [(h * 0.97, 1250 * k, 0.28), (h * 0.35, 1100 * k, 0.12)] as [(CGFloat, CGFloat, CGFloat)] {
        let g = CGGradient(colorsSpace: space, colors: [shot.glow.copy(alpha: alpha)!, shot.glow.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: w * 0.5, y: cy), startRadius: 0, endCenter: CGPoint(x: w * 0.5, y: cy), endRadius: radius, options: [])
    }

    // The headline: big enough to read as a thumbnail.
    let sw = CGFloat(screen.width), sh = CGFloat(screen.height)
    var headTop: CGFloat = 170 * k
    if set == "duo", sw > sh {
        // On its side the screen is short: the headline and the device as one block, centred.
        let lines = CGFloat(shot.caption.components(separatedBy: "\n").count)
        let block = lines * 122 * k * 1.08 + 110 * k + (w - 150 * k) * sh / sw
        headTop = max(headTop, (h - block) / 2 - 40 * k)
    }
    let used = drawHeadline(ctx, shot.caption, size: 122 * k, light: shot.glow, top: headTop)
    let below = headTop + used + 70 * k

    if set == "duo" {
        let inner = sw >= 2000 || sh >= 2000
        if shot.laptop {
            // Half-folded: the lid's top under the headline, the deck laid back below it.
            let dw = w * 0.77
            let dh = dw * sh / sw
            let rect = CGRect(x: (w - dw) / 2, y: h - below - 70 * k - dh, width: dw, height: dh)
            drawThread(ctx, y: h - (below - 6 * k), peak: shot.peak, glow: shot.glow)
            drawLaptopDuo(ctx, screen: screen, rect: rect)
        } else if sw > sh {
            // On its side: as wide as the page allows, in the room under the headline.
            let dw = w - 150 * k
            let dh = dw * sh / sw
            let top = below + 40 * k
            let rect = CGRect(x: (w - dw) / 2, y: h - top - dh, width: dw, height: dh)
            drawThread(ctx, y: h - (below - 6 * k), peak: shot.peak, glow: shot.glow)
            drawDuo(ctx, screen: screen, rect: rect, inner: inner)
        } else {
            // Upright (the cover): all of it under the headline, the mic at its foot in view.
            let fit = (h - below - 40 * k - 110 * k) * sw / sh
            let dw = min(inner ? w * 0.80 : w * 0.72, fit)
            let dh = dw * sh / sw
            let rect = CGRect(x: (w - dw) / 2, y: h - below - 40 * k - dh, width: dw, height: dh)
            drawThread(ctx, y: h - (below - 6 * k), peak: shot.peak, glow: shot.glow)
            drawDuo(ctx, screen: screen, rect: rect, inner: inner)
        }
    } else if let macFile = shot.macWindow, let macImg = NSImage(contentsOf: rawDir.appendingPathComponent(macFile))?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        // The Mac at the back, the phone in front showing the same window.
        let mw = 1180 * k, mh = mw * 0.66
        let macRect = CGRect(x: (w - mw) / 2, y: h - below - mh, width: mw, height: mh)
        drawMac(ctx, window: macImg, rect: macRect)
        drawThread(ctx, y: macRect.minY - 40 * k, peak: shot.peak, glow: shot.glow)
        let dw = 820 * k
        let dh = dw * sh / sw
        let rect = CGRect(x: (w - dw) / 2, y: macRect.minY + 120 * k - dh, width: dw, height: dh)
        drawDevice(ctx, screen: screen, rect: rect)
    } else {
        drawThread(ctx, y: h - (below - 6 * k), peak: shot.peak, glow: shot.glow)
        // The device: wide enough to read, its foot running off the page.
        let dw = 1060 * k
        let dh = dw * sh / sw
        let rect = CGRect(x: (w - dw) / 2, y: h - below - 24 * k - dh, width: dw, height: dh)
        drawDevice(ctx, screen: screen, rect: rect)
        if let m = shot.magnify, let band = screen.cropping(to: CGRect(x: 0, y: m.top * sh, width: sw, height: (m.bottom - m.top) * sh)) {
            // The band lifted off the screen and magnified in place, on its own card.
            let bw = rect.width * m.scale, bh = (m.bottom - m.top) * rect.height * m.scale
            let cy = rect.maxY - (m.top + m.bottom) / 2 * rect.height
            let card = CGRect(x: rect.midX - bw / 2, y: cy - bh / 2, width: bw, height: bh)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -24 * k), blur: 70 * k, color: rgb(0, 0, 0, 0.55))
            ctx.addPath(roundedRect(card, 56 * k)); ctx.setFillColor(rgb(0.5, 0.6, 0.9)); ctx.fillPath()
            ctx.restoreGState()
            drawScreen(ctx, band, in: card, radius: 56 * k)
            ctx.addPath(roundedRect(card.insetBy(dx: 1.5 * k, dy: 1.5 * k), 55 * k))
            ctx.setStrokeColor(rgb(1, 1, 1, 0.55)); ctx.setLineWidth(3 * k); ctx.strokePath()
        }
        if let t = shot.tap {
            drawTap(ctx, at: CGPoint(x: rect.minX + t.x * rect.width, y: rect.maxY - t.y * rect.height), light: shot.glow)
        }
        if let ba = shot.beforeAfter {
            drawBeforeAfter(ctx, heard: ba.0, sent: ba.1, level: ba.2, top: h * 0.725)
        }
    }

    // A dissolve at the very foot so the cut-off reads as intended.
    let foot = CGGradient(colorsSpace: space, colors: [ground, ground.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(foot, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 150 * k), options: [])

    let out = outDir.appendingPathComponent(shot.out + ".png")
    let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(out.path)")
}
