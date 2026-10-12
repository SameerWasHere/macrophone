#!/usr/bin/env swift
// Renders the DMG window background (640×400 pt, @1x and @2x PNGs).
//   swift Mac/scripts/render-dmg-background.swift <outdir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let W: CGFloat = 640, H: CGFloat = 400
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(colors: [c(0x131520), c(0x05060D)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    // A soft light behind the arrow, like the filament throws.
    NSGradient(colors: [c(0x5CD3C3, 0.16), c(0x5CD3C3, 0)])!.draw(fromCenter: NSPoint(x: W / 2, y: 205), radius: 0,
                                                                   toCenter: NSPoint(x: W / 2, y: 205), radius: 220, options: [])
    // The arrow: a short spectrum line from the app to Applications.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 252, y: 205)); arrow.line(to: NSPoint(x: 384, y: 205))
    arrow.lineWidth = 2.5; arrow.lineCapStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let stroked = NSBezierPath()
    stroked.appendRect(NSRect(x: 250, y: 203.5, width: 136, height: 3))
    stroked.addClip()
    NSGradient(colors: [c(0x58B9DE), c(0x5ED6A2), c(0xE8C06C)])!.draw(in: NSRect(x: 250, y: 200, width: 136, height: 10), angle: 0)
    NSGraphicsContext.restoreGraphicsState()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 378, y: 213)); head.line(to: NSPoint(x: 388, y: 205)); head.line(to: NSPoint(x: 378, y: 197))
    head.lineWidth = 2.5; head.lineCapStyle = .round; head.lineJoinStyle = .round
    c(0xE8C06C).setStroke(); head.stroke()
    // Words.
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let title = NSAttributedString(string: "Drag Macrophone to Applications", attributes: [
        .font: NSFont(descriptor: NSFont.systemFont(ofSize: 17, weight: .regular).fontDescriptor.withDesign(.serif)!, size: 17)!,
        .foregroundColor: c(0xF4F2FA), .paragraphStyle: p])
    title.draw(in: NSRect(x: 0, y: 318, width: W, height: 28))
    let sub = NSAttributedString(string: "Then open it from Applications — it lives in your menu bar.", attributes: [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: c(0x9E9DA5), .paragraphStyle: p])
    sub.draw(in: NSRect(x: 0, y: 296, width: W, height: 20))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (s, name) in [(CGFloat(1), "background.png"), (2, "background@2x.png")] {
    try! render(scale: s).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
print("Rendered DMG background into \(out.path)")
