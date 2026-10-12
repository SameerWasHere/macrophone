#!/usr/bin/env swift
// Renders Macrophone's app icon and menu bar template icons into the asset catalog.
//
//   swift Mac/scripts/render-icon.swift            # writes into Mac/Resources/Assets.xcassets
//   swift Mac/scripts/render-icon.swift <outdir>   # or anywhere else (e.g. a preview)
//
// The mark (docs/DESIGN.md › App icon): a dark ink squircle on the macOS grid with the
// Filament crossing it as one luminous stroke that swells in the middle like a voice peak,
// in the spectrum cyan → teal → mint → gold → ember → violet.

import AppKit
import CoreImage
import Foundation

let args = CommandLine.arguments.dropFirst()
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let assets = args.first.map { URL(fileURLWithPath: $0) }
    ?? scriptDir.deletingLastPathComponent().appendingPathComponent("Resources/Assets.xcassets")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let spectrum: [(UInt32, CGFloat)] = [
    (0x58B9DE, 0.00), (0x5CD3C3, 0.22), (0x5ED6A2, 0.40), (0xE8C06C, 0.60), (0xE9714F, 0.80), (0x9A86E6, 1.00),
]

// MARK: The Filament's geometry (shared by the app icon and the menu bar glyph)

/// Centre line: calm at the tips, one voice peak in the middle with a dip either side.
func centre(_ u: CGFloat, amp: CGFloat) -> CGFloat {
    func g(_ c: CGFloat, _ w: CGFloat) -> CGFloat { exp(-pow((u - c) / w, 2)) }
    return amp * (g(0.5, 0.085) - 0.42 * g(0.395, 0.06) - 0.42 * g(0.605, 0.06) + 0.12 * g(0.27, 0.07) + 0.12 * g(0.73, 0.07))
}

/// A tapered ribbon along the centre line: hairline at the tips, `thick` at the peak.
func filamentPath(in rect: CGRect, amp: CGFloat, thin: CGFloat, thick: CGFloat, samples: Int = 400) -> CGPath {
    var top: [CGPoint] = [], bottom: [CGPoint] = []
    for i in 0...samples {
        let u = CGFloat(i) / CGFloat(samples)
        let x = rect.minX + u * rect.width
        let y = rect.midY + centre(u, amp: amp)
        // Normal from the slope.
        let du: CGFloat = 1 / CGFloat(samples)
        let dy = (centre(min(1, u + du), amp: amp) - centre(max(0, u - du), amp: amp)) / (2 * du * rect.width)
        let len = sqrt(1 + dy * dy)
        let nx = -dy / len, ny = 1 / len
        let swell = pow(sin(.pi * u), 1.6)
        let peak = exp(-pow((u - 0.5) / 0.16, 2))
        let half = (thin + (thick - thin) * (0.55 * swell + 0.45 * peak)) / 2
        top.append(CGPoint(x: x + nx * half, y: y + ny * half))
        bottom.append(CGPoint(x: x - nx * half, y: y - ny * half))
    }
    let p = CGMutablePath()
    p.move(to: top[0])
    for pt in top.dropFirst() { p.addLine(to: pt) }
    for pt in bottom.reversed() { p.addLine(to: pt) }
    p.closeSubpath()
    return p
}

func context(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func gradient(_ stops: [(UInt32, CGFloat)], alpha: CGFloat = 1) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { rgb($0.0, alpha) } as CFArray,
               locations: stops.map(\.1))!
}

func blurred(_ image: CGImage, radius: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return CIContext().createCGImage(ci, from: ci.extent)!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: App icon

func appIcon(size: Int) -> CGImage {
    let S = CGFloat(size)
    let k = S / 1024
    let ctx = context(size)
    // The macOS grid: an 824pt squircle centred on 1024, a soft drop shadow under it.
    let plate = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let squircle = CGPath(roundedRect: plate, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: rgb(0x000000, 0.45))
    ctx.addPath(squircle); ctx.setFillColor(rgb(0x05060D)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    // Ink, a touch lighter at the top for depth.
    ctx.drawLinearGradient(gradient([(0x1A1D2C, 0), (0x0B0C16, 0.55), (0x05060D, 1)]),
                           start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    // The light the filament throws on the plate.
    let glowCentre = CGPoint(x: plate.midX, y: plate.midY + 8 * k)
    ctx.drawRadialGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                      colors: [rgb(0x5CD3C3, 0.20), rgb(0x5CD3C3, 0)] as CFArray, locations: [0, 1])!,
                           startCenter: glowCentre, startRadius: 0, endCenter: glowCentre, endRadius: 360 * k, options: [])

    // The Filament: a blurred glow, the spectrum ribbon, then a white-hot core at the peak.
    let lineRect = CGRect(x: plate.minX + 92 * k, y: plate.midY - 20 * k, width: plate.width - 184 * k, height: 40 * k)
    let amp = 150 * k
    let ribbon = filamentPath(in: lineRect, amp: amp, thin: 3 * k, thick: 46 * k)

    let glowCtx = context(size)
    glowCtx.addPath(filamentPath(in: lineRect, amp: amp, thin: 18 * k, thick: 110 * k)); glowCtx.clip()
    glowCtx.drawLinearGradient(gradient(spectrum), start: CGPoint(x: lineRect.minX, y: 0), end: CGPoint(x: lineRect.maxX, y: 0), options: [])
    ctx.setAlpha(0.85)
    ctx.draw(blurred(glowCtx.makeImage()!, radius: 34 * k), in: CGRect(x: 0, y: 0, width: S, height: S))
    ctx.setAlpha(1)

    ctx.saveGState()
    ctx.addPath(ribbon); ctx.clip()
    ctx.drawLinearGradient(gradient(spectrum), start: CGPoint(x: lineRect.minX, y: 0), end: CGPoint(x: lineRect.maxX, y: 0), options: [])
    ctx.restoreGState()

    let coreCtx = context(size)
    coreCtx.addPath(filamentPath(in: lineRect, amp: amp, thin: 0.5 * k, thick: 15 * k)); coreCtx.clip()
    // White in the middle, fading to nothing toward the tips.
    coreCtx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                          colors: [rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.85), rgb(0xFFFFFF, 0)] as CFArray,
                                          locations: [0.18, 0.5, 0.82])!,
                               start: CGPoint(x: lineRect.minX, y: 0), end: CGPoint(x: lineRect.maxX, y: 0), options: [])
    ctx.draw(blurred(coreCtx.makeImage()!, radius: 1.2 * k), in: CGRect(x: 0, y: 0, width: S, height: S))

    // A hairline catching the light along the top edge.
    ctx.resetClip()
    ctx.addPath(squircle); ctx.clip()
    ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 1.5 * k, dy: 1.5 * k), cornerWidth: 184 * k, cornerHeight: 184 * k, transform: nil))
    ctx.setLineWidth(3 * k)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                      colors: [rgb(0xF4F2FA, 0.22), rgb(0xF4F2FA, 0.04), rgb(0xF4F2FA, 0.0)] as CFArray,
                                      locations: [0, 0.4, 1])!,
                           start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: Menu bar template glyphs (18pt, black on clear; the system tints them)

enum Glyph { case idle, connected, received }

func menuGlyph(scale: Int, kind: Glyph) -> CGImage {
    let W = 22, H = 16
    let k = CGFloat(scale)
    let ctx = CGContext(data: nil, width: W * scale, height: H * scale, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(rgb(0x000000))
    let lineRect = CGRect(x: 1 * k, y: 8 * k - 0.5 * k, width: 20 * k, height: 1 * k)
    ctx.addPath(filamentPath(in: lineRect, amp: 5.8 * k, thin: 1.0 * k, thick: 1.9 * k, samples: 120))
    ctx.fillPath()
    switch kind {
    case .idle: break
    case .connected:
        // A small dot under the right shoulder: a phone is connected.
        ctx.fillEllipse(in: CGRect(x: 17.2 * k, y: 0.6 * k, width: 3.6 * k, height: 3.6 * k))
    case .received:
        // A tick in the top-right corner, shown for a moment after a silent copy.
        ctx.setStrokeColor(rgb(0x000000)); ctx.setLineWidth(1.6 * k); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: 16.0 * k, y: 3.2 * k)); ctx.addLine(to: CGPoint(x: 17.8 * k, y: 1.4 * k))
        ctx.addLine(to: CGPoint(x: 21.0 * k, y: 4.9 * k)); ctx.strokePath()
    }
    return ctx.makeImage()!
}

// MARK: Write

let fm = FileManager.default
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try? fm.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for s in [1, 2] {
        let px = pt * s
        let name = "icon_\(pt)x\(pt)\(s == 2 ? "@2x" : "").png"
        writePNG(appIcon(size: px), to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(s)x", "filename": name])
    }
}
let iconJSON: [String: Any] = ["images": images, "info": ["author": "render-icon.swift", "version": 1]]
try JSONSerialization.data(withJSONObject: iconJSON, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))

for (kind, setName) in [(Glyph.idle, "MenuBarIcon"), (.connected, "MenuBarIconConnected"), (.received, "MenuBarIconReceived")] {
    let dir = assets.appendingPathComponent("\(setName).imageset")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var list: [[String: String]] = []
    for s in [1, 2, 3] {
        let name = "\(setName)\(s == 1 ? "" : "@\(s)x").png"
        writePNG(menuGlyph(scale: s, kind: kind), to: dir.appendingPathComponent(name))
        list.append(["idiom": "universal", "scale": "\(s)x", "filename": name])
    }
    let json: [String: Any] = ["images": list, "info": ["author": "render-icon.swift", "version": 1],
                               "properties": ["template-rendering-intent": "template"]]
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        .write(to: dir.appendingPathComponent("Contents.json"))
}

// A large preview next to the catalog for review (not shipped).
if let preview = ProcessInfo.processInfo.environment["MACROPHONE_ICON_PREVIEW"] {
    writePNG(appIcon(size: 1024), to: URL(fileURLWithPath: preview))
}
print("Rendered the app icon and menu bar glyphs into \(assets.path)")
