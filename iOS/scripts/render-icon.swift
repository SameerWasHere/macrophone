#!/usr/bin/env swift
// Renders the Macrophone app icon: a dark ink field with the Filament crossing it as one
// luminous stroke that swells in the middle like a voice peak, in the spectrum gradient.
//
//   swift iOS/scripts/render-icon.swift [output.png] [size]
//
// Default output: iOS/Macrophone/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
// The PNG is opaque (no alpha) as the App Store requires; iOS applies the rounded mask.

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let scriptDir = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
let defaultOut = scriptDir.appendingPathComponent("../Macrophone/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png").standardized
let outURL = args.count > 1 ? URL(fileURLWithPath: args[1]) : defaultOut
let S = args.count > 2 ? Int(args[2]) ?? 1024 : 1024
let s = CGFloat(S)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let cyan = rgb(0.345, 0.725, 0.871)
let teal = rgb(0.361, 0.827, 0.765)
let mint = rgb(0.369, 0.839, 0.635)
let gold = rgb(0.910, 0.753, 0.424)
let ember = rgb(0.914, 0.443, 0.310)
let violet = rgb(0.604, 0.525, 0.902)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("no context") }

// MARK: Ground — ink, a breath lighter in the middle where the light is.
ctx.setFillColor(rgb(0.020, 0.024, 0.051))
ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
let ground = CGGradient(colorsSpace: space, colors: [rgb(0.090, 0.098, 0.160), rgb(0.020, 0.024, 0.051)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(ground, startCenter: CGPoint(x: s / 2, y: s * 0.52), startRadius: 0,
                       endCenter: CGPoint(x: s / 2, y: s * 0.52), endRadius: s * 0.72, options: [.drawsAfterEndLocation])

// MARK: The filament
let spectrum = CGGradient(colorsSpace: space, colors: [cyan, teal, mint, gold, ember, violet] as CFArray,
                          locations: [0, 0.22, 0.42, 0.6, 0.8, 1])!

/// Points of the centre line and half-thickness for one strand.
func strand(amp: CGFloat, phase: CGFloat, thick: CGFloat, margin: CGFloat) -> (top: [CGPoint], bottom: [CGPoint], mid: [CGPoint]) {
    let n = 400
    var top: [CGPoint] = [], bottom: [CGPoint] = [], mid: [CGPoint] = []
    let x0 = margin, x1 = s - margin
    for i in 0...n {
        let u = CGFloat(i) / CGFloat(n)
        let x = x0 + (x1 - x0) * u
        // The voice peak: a bell in the middle, tapering to nothing at both ends.
        let bell = exp(-pow((u - 0.5) / 0.17, 2))
        let taper = pow(sin(.pi * u), 1.2)
        let wave = sin(2 * .pi * 3.0 * (u - 0.5) + phase) * 0.78 + sin(2 * .pi * 5.2 * (u - 0.5) + phase * 1.7) * 0.22
        let y = s / 2 + amp * bell * wave
        let hw = (2.5 + thick * pow(bell, 0.7) + 7 * taper) * s / 1024
        mid.append(CGPoint(x: x, y: y))
        top.append(CGPoint(x: x, y: y + hw))
        bottom.append(CGPoint(x: x, y: y - hw))
    }
    return (top, bottom, mid)
}

func shape(_ t: [CGPoint], _ b: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    p.move(to: t[0])
    for q in t.dropFirst() { p.addLine(to: q) }
    for q in b.reversed() { p.addLine(to: q) }
    p.closeSubpath()
    return p
}

func fillGradient(_ path: CGPath, alpha: CGFloat, glow: CGFloat = 0, glowColor: CGColor? = nil) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    if glow > 0 {
        // Glow: a blurred shadow of the shape in the spectrum's middle light.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setShadow(offset: .zero, blur: glow, color: glowColor)
        ctx.addPath(path)
        ctx.setFillColor(rgb(1, 1, 1, 0.9))
        ctx.fillPath()
        ctx.endTransparencyLayer()
    }
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(spectrum, start: CGPoint(x: s * 0.12, y: 0), end: CGPoint(x: s * 0.88, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

let margin = s * 0.10
let amp = s * 0.25

// A wide soft bloom behind the peak.
let bloom = CGGradient(colorsSpace: space, colors: [rgb(0.43, 0.80, 0.70, 0.30), rgb(0.43, 0.80, 0.70, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0,
                       endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s * 0.36, options: [])

// Two quiet strands behind, then the main one.
for (a, ph, th, al) in [(amp * 0.62, 2.2, 7.0, 0.28), (amp * 0.82, 4.1, 9.0, 0.4)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    let st = strand(amp: a, phase: ph, thick: th, margin: margin)
    fillGradient(shape(st.top, st.bottom), alpha: al)
}
let main = strand(amp: amp, phase: 0.35, thick: 36, margin: margin)
let mainPath = shape(main.top, main.bottom)
// Outer glow, then the body.
fillGradient(mainPath, alpha: 0.55, glow: s * 0.06, glowColor: rgb(0.40, 0.85, 0.75, 0.9))
fillGradient(mainPath, alpha: 1)

// The luminous core: a thin bright line down the middle of the main strand.
let core = CGMutablePath()
core.move(to: main.mid[0])
for q in main.mid.dropFirst() { core.addLine(to: q) }
ctx.saveGState()
ctx.addPath(core)
ctx.setLineWidth(6 * s / 1024)
ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(1, 1, 1, 0.75))
ctx.setShadow(offset: .zero, blur: 10 * s / 1024, color: rgb(1, 1, 1, 0.8))
ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: outURL)
print("wrote \(outURL.path) (\(S)×\(S))")
