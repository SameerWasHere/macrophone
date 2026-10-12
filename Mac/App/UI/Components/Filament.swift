import AppKit
import QuartzCore
import SwiftUI

/// The Filament (docs/DESIGN.md): a tapered luminous line. Hairline at the tips, swelling
/// toward the middle; `peak` raises a single voice peak with a dip either side (the mark),
/// 0 draws it calm and flat. Pure geometry — static, so it costs nothing while it sits still.
struct FilamentShape: Shape {
    /// 0 = flat, 1 = the mark's full voice peak.
    var peak: Double
    var thin: CGFloat = 0.8
    var thick: CGFloat = 3
    var samples = 160

    var animatableData: Double {
        get { peak }
        set { peak = newValue }
    }

    static func centre(_ u: Double) -> Double {
        func g(_ c: Double, _ w: Double) -> Double { exp(-pow((u - c) / w, 2)) }
        return g(0.5, 0.085) - 0.42 * g(0.395, 0.06) - 0.42 * g(0.605, 0.06) + 0.12 * g(0.27, 0.07) + 0.12 * g(0.73, 0.07)
    }

    func path(in rect: CGRect) -> Path {
        let amp = Double(rect.height) / 2 - Double(thick)
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        let n = max(24, samples)
        for i in 0...n {
            let u = Double(i) / Double(n)
            let x = rect.minX + CGFloat(u) * rect.width
            // SwiftUI's y grows downward: subtract to raise the peak.
            let y = rect.midY - CGFloat(amp * peak * Self.centre(u))
            let du = 1.0 / Double(n)
            let dy = -amp * peak * (Self.centre(min(1, u + du)) - Self.centre(max(0, u - du))) / (2 * du * Double(rect.width))
            let len = sqrt(1 + dy * dy)
            let nx = CGFloat(-dy / len), ny = CGFloat(1 / len)
            let swell = pow(sin(.pi * u), 1.6)
            let bump = exp(-pow((u - 0.5) / 0.16, 2))
            let half = (thin + (thick - thin) * CGFloat(0.55 * swell + 0.45 * bump * max(peak, 0.35))) / 2
            top.append(CGPoint(x: x + nx * half, y: y - ny * half))
            bottom.append(CGPoint(x: x - nx * half, y: y + ny * half))
        }
        var p = Path()
        p.move(to: top[0])
        top.dropFirst().forEach { p.addLine(to: $0) }
        bottom.reversed().forEach { p.addLine(to: $0) }
        p.closeSubpath()
        return p
    }
}

/// The Filament drawn with its light: the spectrum (or one meaning colour), a soft glow
/// under it, a white core at the peak.
struct FilamentView: View {
    var peak: Double = 1
    var thick: CGFloat = 3
    /// Nil = the full spectrum.
    var tint: Color?
    var glow: Double = 0.75
    var dashed = false

    private var fill: LinearGradient {
        if let tint {
            return LinearGradient(colors: [tint.opacity(0.65), tint, tint.opacity(0.65)], startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(stops: Light.spectrumStops, startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        ZStack {
            if dashed {
                // Error: the line broken into dashes.
                FilamentShape(peak: 0, thin: thick * 0.6, thick: thick * 0.6)
                    .fill(fill)
                    .mask(DashMask())
            } else {
                FilamentShape(peak: peak, thin: thick * 0.9, thick: thick * 3.2)
                    .fill(fill)
                    .blur(radius: thick * 1.6)
                    .opacity(glow)
                FilamentShape(peak: peak, thin: thick * 0.25, thick: thick)
                    .fill(fill)
                FilamentShape(peak: peak, thin: 0.1, thick: thick * 0.32)
                    .fill(LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.2),
                                                 .init(color: .white.opacity(0.8), location: 0.5),
                                                 .init(color: .white.opacity(0), location: 0.8)],
                                         startPoint: .leading, endPoint: .trailing))
            }
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

private struct DashMask: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                var x: CGFloat = 0
                while x < geo.size.width {
                    p.addRect(CGRect(x: x, y: 0, width: 7, height: geo.size.height))
                    x += 12
                }
            }
            .fill(Color.white)
        }
    }
}

/// A breathing dot driven by Core Animation, so it costs the app nothing while it breathes
/// (a SwiftUI repeat animation redraws on the CPU every frame).
struct PulseDot: NSViewRepresentable {
    var color: NSColor
    var size: CGFloat = 7

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size * 3, height: size * 3))
        v.wantsLayer = true
        let halo = CALayer(), dot = CALayer()
        for (l, s) in [(halo, size * 2.6), (dot, size)] {
            l.bounds = CGRect(x: 0, y: 0, width: s, height: s)
            l.cornerRadius = s / 2
            l.position = CGPoint(x: size * 1.5, y: size * 1.5)
            v.layer?.addSublayer(l)
        }
        dot.backgroundColor = color.cgColor
        halo.backgroundColor = color.withAlphaComponent(0.28).cgColor
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 0.35; a.toValue = 1
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 0.9; o.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [a, o]
            g.duration = 1.8
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            halo.add(g, forKey: "pulse")
        } else {
            halo.opacity = 0
        }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
}
