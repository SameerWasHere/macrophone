import AppKit
import QuartzCore
import SwiftUI

/// The Filament — the Thread from SameerOS: a tapered luminous ribbon lying in one soft S,
/// hairline at the tips, full in the middle. `peak` is how far the S swings (0 = flat, 1 = the
/// full swell). Pure geometry — static, so it costs nothing while it sits still.
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

    /// One S rising left to right, still at the tips (the Thread's resting curve), peak ≈ 1.
    static func centre(_ u: Double) -> Double {
        -sin(2 * .pi * (u - 0.5)) * pow(sin(.pi * u), 1.25) / 0.66
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
            let half = (thin + (thick - thin) * CGFloat(pow(sin(.pi * u), 0.7))) / 2
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
        return LinearGradient(stops: Self.threadStops, startPoint: .leading, endPoint: .trailing)
    }

    /// The Thread's spectrum, cool to warm — violet, cyan, mint, gold, coral (as in SameerOS).
    static let threadStops: [Gradient.Stop] = [
        .init(color: Light.violet, location: 0), .init(color: Light.cyan, location: 0.25), .init(color: Light.mint, location: 0.5),
        .init(color: Light.gold, location: 0.75), .init(color: Color(red: 0.914, green: 0.502, blue: 0.416), location: 1),
    ]

    /// The Thread is a ribbon, not a hairline: callers pass the old line weights.
    private var t: CGFloat { thick * 2.4 }

    var body: some View {
        ZStack {
            if dashed {
                // Error: the line broken into dashes.
                FilamentShape(peak: 0, thin: thick * 0.8, thick: thick * 0.8)
                    .fill(fill)
                    .mask(DashMask())
            } else {
                // Halo and glow, the body, then the white-hot core.
                FilamentShape(peak: peak, thin: t * 0.6, thick: t * 2.6)
                    .fill(fill)
                    .blur(radius: t * 1.4)
                    .opacity(glow)
                FilamentShape(peak: peak, thin: 0.2, thick: t)
                    .fill(fill)
                // No blend mode here: a blend inside the drawing group composites against black
                // and left a dark plate around the mark (the sidebar, the popup, the setup page).
                FilamentShape(peak: peak, thin: 0.05, thick: t * 0.36)
                    .fill(LinearGradient(stops: [.init(color: .white.opacity(0.12), location: 0.1),
                                                 .init(color: .white.opacity(0.78), location: 0.5),
                                                 .init(color: .white.opacity(0.12), location: 0.9)],
                                         startPoint: .leading, endPoint: .trailing))
            }
        }
        // Not a drawing group: the offscreen pass flattened the glow's blur onto a dark plate
        // (visible around the mark in the sidebar and the popup).
        .compositingGroup()
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
