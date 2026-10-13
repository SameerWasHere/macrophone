// Renders Macrophone's icons — the Thread (the luminous ribbon from SameerOS's Hey Claude)
// meeting a glass microphone, on a dusk sky — for the iPhone app, the Mac app and the website.
// No external tools: SwiftUI's ImageRenderer on macOS.
//
//   xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 scripts/render-icons.swift -o /tmp/render-icons
//   /tmp/render-icons preview <dir>     # every design variant side by side, for choosing
//   /tmp/render-icons install           # writes the iOS, Mac and website icons in place (run from the repo root)
//
// iOS icons are opaque (App Store Connect rejects alpha). The Mac icon is the macOS squircle
// on a transparent canvas with the standard margin and shadow.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Palette (Macrophone's lights — the same values as docs/DESIGN.md)

enum Palette {
    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let violet = rgb(0x9A86E6), cyan = rgb(0x58B9DE), mint = rgb(0x5ED6A2), gold = rgb(0xE8C06C), coral = rgb(0xE9806A)
    /// The Thread, cool to warm.
    static let thread: [Color] = [violet, cyan, mint, gold, coral]
}

enum Design: String, CaseIterable {
    case through   // the ribbon flows through a glass mic
    case inside    // the ribbon lives inside the mic's capsule
}

enum Appearance: CaseIterable { case light, dark, tinted }

struct IconArt: View {
    static let side: CGFloat = 1024
    var design: Design
    var appearance: Appearance = .light
    /// The macOS squircle (inset, rounded, shadowed) instead of the full-bleed iOS square.
    var mac = false

    var body: some View {
        Canvas { ctx, size in
            if mac {
                // macOS icon grid: 824 pt body in a 1024 canvas, corner ~185, soft drop shadow.
                let body = CGRect(x: 100, y: 92, width: 824, height: 824)
                let shape = Path(roundedRect: body, cornerRadius: 185, style: .continuous)
                var shadow = ctx
                shadow.addFilter(.shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 12))
                shadow.fill(shape, with: .color(.black))
                var inner = ctx
                inner.clip(to: shape)
                inner.translateBy(x: body.minX, y: body.minY)
                inner.scaleBy(x: body.width / size.width, y: body.height / size.height)
                draw(inner, size)
                // A hairline of light on the rim.
                ctx.stroke(shape, with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .white.opacity(0.04)]),
                                                        startPoint: CGPoint(x: 0, y: body.minY), endPoint: CGPoint(x: 0, y: body.maxY)),
                           lineWidth: 2)
            } else {
                draw(ctx, size)
            }
        }
        .frame(width: Self.side, height: Self.side)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        drawSky(ctx, size)
        drawGrain(ctx, size)
        drawStars(ctx, size)
        switch design {
        case .through: drawThrough(ctx, size)
        case .inside: drawInside(ctx, size)
        }
    }

    // MARK: Sky — deep ink at the top, a dusk plum, an ember of light low down

    private func drawSky(_ ctx: GraphicsContext, _ size: CGSize) {
        let full = Path(CGRect(origin: .zero, size: size))
        let stops: [Gradient.Stop]
        switch appearance {
        case .light:
            stops = [.init(color: Palette.rgb(0x15132B), location: 0), .init(color: Palette.rgb(0x2B1F4A), location: 0.48),
                     .init(color: Palette.rgb(0x4A2A52), location: 0.78), .init(color: Palette.rgb(0x7A3F48), location: 1)]
        case .dark:
            stops = [.init(color: Palette.rgb(0x07070F), location: 0), .init(color: Palette.rgb(0x14112A), location: 0.6),
                     .init(color: Palette.rgb(0x2A1830), location: 1)]
        case .tinted:
            stops = [.init(color: Color(white: 0.02), location: 0), .init(color: Color(white: 0.08), location: 1)]
        }
        ctx.fill(full, with: .linearGradient(Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        let haze: Color = appearance == .tinted ? .white : Palette.cyan
        ctx.fill(full, with: .radialGradient(Gradient(colors: [haze.opacity(appearance == .dark ? 0.10 : 0.14), haze.opacity(0)]),
                                             center: CGPoint(x: size.width * 0.5, y: size.height * 0.44),
                                             startRadius: 0, endRadius: size.width * 0.5))
    }

    private func drawGrain(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let grain = Self.grain else { return }
        var g = ctx
        g.blendMode = .softLight
        g.opacity = 0.05
        g.draw(Image(decorative: grain, scale: 1), in: CGRect(origin: .zero, size: size))
    }

    private static let grain: CGImage? = {
        let side = Int(IconArt.side)
        var bytes = [UInt8](repeating: 0, count: side * side)
        var gen = Seeded(seed: 0x5EED)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &gen) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    private func drawStars(_ ctx: GraphicsContext, _ size: CGSize) {
        guard appearance != .tinted else { return }
        var gen = Seeded(seed: 0xC0FFEE)
        for _ in 0..<34 {
            let x = Double.random(in: 0.04...0.96, using: &gen), y = Double.random(in: 0.03...0.30, using: &gen)
            // Keep the mic's head clear.
            if abs(x - 0.5) < 0.2, y > 0.12 { continue }
            let r = Double.random(in: 1.0...2.6, using: &gen)
            let a = (0.25 + 0.5 * (1 - y / 0.3)) * (appearance == .dark ? 0.45 : 0.6)
            let p = CGPoint(x: x * size.width, y: y * size.height)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(a)))
        }
    }

    // MARK: The Thread

    private var threadGradient: Gradient {
        if appearance == .tinted {
            return Gradient(colors: [Color(white: 0.7), Color(white: 0.92), .white, Color(white: 0.92), Color(white: 0.75)])
        }
        return Gradient(colors: Palette.thread)
    }

    /// One soft S, still at the tips — the Thread's resting curve, a voice's swell in the middle.
    private func centerline(_ size: CGSize, cy: CGFloat, width: CGFloat, amp: Double) -> [CGPoint] {
        let x0 = (size.width - width) / 2
        return (0...400).map { i in
            let u = Double(i) / 400
            let env = pow(sin(.pi * u), 1.25)
            let y = -Double(width) * amp * sin(2 * .pi * (u - 0.5)) * env
            return CGPoint(x: x0 + CGFloat(u) * width, y: cy + CGFloat(y))
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
        var p = Path()
        p.addLines(top)
        p.addLines(bottom.reversed())
        p.closeSubpath()
        return p
    }

    private func drawThread(_ ctx: GraphicsContext, pts: [CGPoint], half: CGFloat, haloWidth: CGFloat, glowScale: CGFloat = 1) {
        let shading = GraphicsContext.Shading.linearGradient(threadGradient, startPoint: CGPoint(x: pts.first!.x, y: 0),
                                                             endPoint: CGPoint(x: pts.last!.x, y: 0))
        var spine = Path()
        spine.addLines(Array(pts[60...340]))
        var halo = ctx
        halo.opacity = appearance == .tinted ? 0.14 : 0.5
        halo.addFilter(.blur(radius: 60 * glowScale))
        halo.stroke(spine, with: shading, style: StrokeStyle(lineWidth: haloWidth, lineCap: .round, lineJoin: .round))
        var glow = ctx
        glow.opacity = appearance == .tinted ? 0.45 : 0.9
        glow.addFilter(.blur(radius: 22 * glowScale))
        glow.fill(ribbon(pts, half: half * 2.3), with: shading)
        ctx.fill(ribbon(pts, half: half), with: shading)
        var core = ctx
        core.blendMode = .plusLighter
        core.opacity = 0.5
        core.addFilter(.blur(radius: 7))
        core.fill(ribbon(pts, half: half * 0.36), with: .color(.white))
    }

    // MARK: The microphone

    struct Mic {
        var capsule: CGRect
        var cradleTop: CGFloat, cradleBottom: CGFloat, cradleWidth: CGFloat
        var stemBottom: CGFloat, baseWidth: CGFloat
        var line: CGFloat
    }

    private func mic(_ size: CGSize, capsuleWidth: CGFloat, capsuleHeight: CGFloat, top: CGFloat) -> Mic {
        let cx = size.width / 2
        let capsule = CGRect(x: cx - capsuleWidth / 2, y: top, width: capsuleWidth, height: capsuleHeight)
        let gap = capsuleWidth * 0.2
        return Mic(capsule: capsule,
                   cradleTop: capsule.midY + capsuleHeight * 0.06,
                   cradleBottom: capsule.maxY + gap * 1.2,
                   cradleWidth: capsuleWidth + gap * 2,
                   stemBottom: capsule.maxY + gap * 1.2 + capsuleWidth * 0.36,
                   baseWidth: capsuleWidth * 0.78,
                   line: capsuleWidth * 0.095)
    }

    private func capsulePath(_ m: Mic) -> Path {
        Path(roundedRect: m.capsule, cornerRadius: m.capsule.width / 2, style: .continuous)
    }

    /// The U cradle under the head, the stem and the base — in light.
    private func drawStand(_ ctx: GraphicsContext, _ m: Mic, color: Color) {
        let cx = m.capsule.midX
        var p = Path()
        let l = cx - m.cradleWidth / 2, r = cx + m.cradleWidth / 2
        p.move(to: CGPoint(x: l, y: m.cradleTop))
        p.addLine(to: CGPoint(x: l, y: m.cradleBottom - m.cradleWidth / 2))
        p.addArc(center: CGPoint(x: cx, y: m.cradleBottom - m.cradleWidth / 2), radius: m.cradleWidth / 2,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: r, y: m.cradleTop))
        p.move(to: CGPoint(x: cx, y: m.cradleBottom))
        p.addLine(to: CGPoint(x: cx, y: m.stemBottom))
        p.move(to: CGPoint(x: cx - m.baseWidth / 2, y: m.stemBottom))
        p.addLine(to: CGPoint(x: cx + m.baseWidth / 2, y: m.stemBottom))
        var glow = ctx
        glow.addFilter(.blur(radius: 10))
        glow.stroke(p, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: m.line * 1.6, lineCap: .round, lineJoin: .round))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: m.line, lineCap: .round, lineJoin: .round))
    }

    private var standColor: Color { appearance == .tinted ? Color(white: 0.85) : Color(white: 0.93).opacity(0.85) }

    // MARK: Designs

    /// The ribbon sweeps across the icon and through a glass capsule: your voice, picked up.
    private func drawThrough(_ ctx: GraphicsContext, _ size: CGSize) {
        let m = mic(size, capsuleWidth: size.width * 0.30, capsuleHeight: size.width * 0.46, top: size.height * 0.15)
        let pts = centerline(size, cy: m.capsule.midY, width: size.width * 0.84, amp: 0.11)
        drawThread(ctx, pts: pts, half: 36, haloWidth: 140)
        // The glass head over it: frosted, so the ribbon reads as inside the mic.
        let cap = capsulePath(m)
        ctx.fill(cap, with: .linearGradient(Gradient(colors: [.white.opacity(0.16), .white.opacity(0.05)]),
                                            startPoint: CGPoint(x: 0, y: m.capsule.minY), endPoint: CGPoint(x: 0, y: m.capsule.maxY)))
        var inside = ctx
        inside.clip(to: cap)
        inside.blendMode = .plusLighter
        inside.opacity = 0.35
        inside.addFilter(.blur(radius: 16))
        inside.fill(ribbon(pts, half: 52), with: .linearGradient(threadGradient, startPoint: CGPoint(x: pts.first!.x, y: 0),
                                                                endPoint: CGPoint(x: pts.last!.x, y: 0)))
        ctx.stroke(cap, with: .linearGradient(Gradient(colors: [.white.opacity(0.75), .white.opacity(0.25)]),
                                              startPoint: CGPoint(x: 0, y: m.capsule.minY), endPoint: CGPoint(x: 0, y: m.capsule.maxY)),
                   lineWidth: m.line * 0.8)
        drawStand(ctx, m, color: standColor)
    }

    /// The ribbon lives inside the capsule — the head of the mic is the Thread, glowing.
    private func drawInside(_ ctx: GraphicsContext, _ size: CGSize) {
        let m = mic(size, capsuleWidth: size.width * 0.36, capsuleHeight: size.width * 0.52, top: size.height * 0.11)
        let cap = capsulePath(m)
        // Light spilling out of the head.
        var spill = ctx
        spill.addFilter(.blur(radius: 70))
        spill.opacity = appearance == .tinted ? 0.25 : 0.45
        spill.fill(cap, with: .linearGradient(threadGradient, startPoint: CGPoint(x: m.capsule.minX, y: m.capsule.maxY),
                                              endPoint: CGPoint(x: m.capsule.maxX, y: m.capsule.minY)))
        ctx.fill(cap, with: .color(.black.opacity(0.35)))
        var inner = ctx
        inner.clip(to: cap)
        // A vertical-ish S inside the head, turned so it fills the capsule.
        let pts = centerline(size, cy: m.capsule.midY, width: m.capsule.height * 1.05, amp: 0.15)
            .map { p -> CGPoint in
                let dx = p.x - size.width / 2, dy = p.y - m.capsule.midY
                // Rotate −90° about the capsule's centre.
                return CGPoint(x: size.width / 2 + dy, y: m.capsule.midY - dx)
            }
        drawThread(inner, pts: pts, half: 34, haloWidth: 110, glowScale: 0.8)
        ctx.stroke(cap, with: .linearGradient(Gradient(colors: [.white.opacity(0.8), .white.opacity(0.3)]),
                                              startPoint: CGPoint(x: 0, y: m.capsule.minY), endPoint: CGPoint(x: 0, y: m.capsule.maxY)),
                   lineWidth: m.line * 0.8)
        drawStand(ctx, m, color: standColor)
    }
}

struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Output

@MainActor
func render(_ art: IconArt) -> CGImage {
    let r = ImageRenderer(content: art)
    r.proposedSize = ProposedViewSize(width: IconArt.side, height: IconArt.side)
    r.scale = 1
    return r.cgImage!
}

func resized(_ image: CGImage, to px: Int, opaque: Bool) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
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
    print("wrote \(path)")
}

@main
struct Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("usage: render-icons preview <dir> | install [design]"); exit(2) }
        if args[1] == "preview", args.count == 3 {
            for d in Design.allCases {
                writePNG(resized(render(IconArt(design: d)), to: 1024, opaque: true), "\(args[2])/\(d.rawValue)-ios.png")
                writePNG(render(IconArt(design: d, mac: true)), "\(args[2])/\(d.rawValue)-mac.png")
                writePNG(resized(render(IconArt(design: d, appearance: .dark)), to: 1024, opaque: true), "\(args[2])/\(d.rawValue)-dark.png")
            }
            return
        }
        guard args[1] == "install" else { exit(2) }
        let design = args.count > 2 ? Design(rawValue: args[2]) ?? .through : .through
        // iPhone: light (any), dark and tinted, 1024 opaque.
        let ios = "iOS/Macrophone/Resources/Assets.xcassets/AppIcon.appiconset"
        writePNG(resized(render(IconArt(design: design)), to: 1024, opaque: true), "\(ios)/AppIcon-1024.png")
        writePNG(resized(render(IconArt(design: design, appearance: .dark)), to: 1024, opaque: true), "\(ios)/AppIcon-1024-dark.png")
        writePNG(resized(render(IconArt(design: design, appearance: .tinted)), to: 1024, opaque: true), "\(ios)/AppIcon-1024-tinted.png")
        // Mac: every size of the squircle.
        let mac = render(IconArt(design: design, mac: true))
        let macDir = "Mac/Resources/Assets.xcassets/AppIcon.appiconset"
        for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
            writePNG(resized(mac, to: pt * scale, opaque: false), "\(macDir)/\(name)")
        }
        // Website (the sameer.us repo): favicon/touch/512 from the iOS art (rounded by the browser/OS).
        let web = NSString(string: "~/claude-projects/_web/sameer-gpt/public/macrophone/assets").expandingTildeInPath
        let flat = render(IconArt(design: design))
        writePNG(resized(flat, to: 512, opaque: true), "\(web)/icon-512.png")
        writePNG(resized(flat, to: 180, opaque: true), "\(web)/icon-180.png")
        writePNG(resized(mac, to: 64, opaque: false), "\(web)/icon-32.png")
    }
}
