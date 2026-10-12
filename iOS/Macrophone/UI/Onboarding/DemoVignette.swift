import SwiftUI

/// The pitch, as a loop: you talk into the phone, the light runs across, the words land on the Mac.
struct DemoVignette: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let period = 5.2
    private let line1 = "Refactor the uploader to"
    private let line2 = "retry with backoff."

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 4.2 : ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
            Canvas { g, size in draw(&g, size: size, t: t) }
        }
        .frame(height: 210)
        .accessibilityElement()
        .accessibilityLabel("Animation: you speak into your iPhone and the words appear on your Mac.")
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        let phone = CGRect(x: w * 0.06, y: h * 0.14, width: 74, height: 148)
        let screen = CGRect(x: w - 196 - w * 0.04, y: h * 0.12, width: 196, height: 124)
        let base = CGRect(x: screen.minX - 14, y: screen.maxY + 2, width: screen.width + 28, height: 8)

        let speaking = t < 1.9
        let travel = min(max((t - 1.6) / 0.9, 0), 1)
        let typing = min(max((t - 2.4) / 1.6, 0), 1)
        let fade = t > period - 0.5 ? (period - t) / 0.5 : 1

        // The phone.
        let phonePath = Path(roundedRect: phone, cornerRadius: 16, style: .continuous)
        g.fill(phonePath, with: .color(Ink.raised))
        g.stroke(phonePath, with: .color(Ink.lineStrong), lineWidth: 1.2)
        let mic = CGRect(x: phone.midX - 13, y: phone.maxY - 40, width: 26, height: 26)
        g.fill(Path(ellipseIn: mic), with: .color(speaking ? Light.ember : Ink.ink.opacity(0.15)))
        // A tiny filament on the phone.
        var wave = Path()
        let wy = phone.minY + 58
        for i in 0...30 {
            let u = Double(i) / 30
            let env = pow(sin(.pi * u), 1.5)
            let amp = speaking ? 9 * env * sin(u * 14 + t * 9) * (0.6 + 0.4 * sin(t * 5)) : 0
            let p = CGPoint(x: phone.minX + 10 + (phone.width - 20) * u, y: wy + amp)
            if i == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
        }
        g.stroke(wave, with: .linearGradient(Gradient(colors: [Light.cyan, Light.mint, Light.gold, Light.ember]),
                                             startPoint: CGPoint(x: phone.minX, y: 0), endPoint: CGPoint(x: phone.maxX, y: 0)),
                 style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

        // The Mac.
        let screenPath = Path(roundedRect: screen, cornerRadius: 10, style: .continuous)
        g.fill(screenPath, with: .color(Ink.raised))
        g.stroke(screenPath, with: .color(Ink.lineStrong), lineWidth: 1.2)
        g.fill(Path(roundedRect: base, cornerRadius: 4), with: .color(Ink.ink.opacity(0.14)))
        // A text field on the Mac with the words arriving.
        let field = screen.insetBy(dx: 14, dy: 18)
        g.fill(Path(roundedRect: field, cornerRadius: 8), with: .color(Ink.sunk))
        let chars1 = Int(Double(line1.count) * min(typing * 1.6, 1))
        let chars2 = Int(Double(line2.count) * max(min((typing - 0.62) / 0.38, 1), 0))
        let text1 = Text(String(line1.prefix(chars1))).font(.system(size: 11.5, design: .serif)).foregroundColor(Ink.ink)
        let text2 = Text(String(line2.prefix(chars2))).font(.system(size: 11.5, design: .serif)).foregroundColor(Ink.ink)
        g.opacity = fade
        g.draw(text1, at: CGPoint(x: field.minX + 10, y: field.minY + 14), anchor: .leading)
        g.draw(text2, at: CGPoint(x: field.minX + 10, y: field.minY + 32), anchor: .leading)
        if typing >= 1 {
            let check = Text(Image(systemName: "checkmark.circle.fill")).font(.system(size: 14)).foregroundColor(Light.mint)
            g.draw(check, at: CGPoint(x: field.maxX - 14, y: field.maxY - 14))
        }
        g.opacity = 1

        // The light crossing from phone to Mac.
        let a = CGPoint(x: phone.maxX + 6, y: wy)
        let b = CGPoint(x: screen.minX - 6, y: screen.midY)
        var bridge = Path()
        bridge.move(to: a)
        bridge.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 40))
        g.stroke(bridge, with: .color(Ink.ink.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
        if travel > 0 && travel < 1 {
            let p = quad(a, CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 40), b, travel)
            let glow = CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)
            g.fill(Path(ellipseIn: glow), with: .radialGradient(Gradient(colors: [Light.mint.opacity(0.9), Light.mint.opacity(0)]),
                                                                center: p, startRadius: 0, endRadius: 14))
            g.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white))
        }
    }

    private func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}
