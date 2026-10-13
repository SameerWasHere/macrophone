import SwiftUI

// The Filament: the Thread from SameerOS — a tapered, luminous ribbon in the spectrum that moves
// with the voice.
//
// Ready     — at rest in a soft S, still (costs nothing).
// Live      — the full spectrum; height and brightness follow the mic (attack fast, release slow).
// Sending   — nearly flat; a bead of light runs along it.
// Delivered — settles flat in mint (the ✓ is drawn by the caller).
// Queued    — flat, ochre, dim.
// Error     — rose, broken into dashes.
//
// Drawn with Canvas in a TimelineView that only ticks while something is moving, so a
// still screen costs nothing. Reduce Motion: a still line whose brightness follows the level.

enum FilamentMode: Equatable {
    case ready, live, sending, delivered, queued, error
}

/// Per-frame state, smoothed between modes. A reference type so the Canvas can step it.
final class FilamentState {
    var level = 0.0
    var tempo = 0.0
    var phase = 0.0
    var amp = 0.0
    var bright = 0.45
    var tint = 0.0        // 0 = spectrum, 1 = flat meaning colour
    var dash = 0.0        // 0 solid … 1 broken
    var flow = 0.0        // the sending bead's position
    var lastTime: Date?
}

struct Filament: View {
    var mode: FilamentMode
    var meter: LevelMeter
    /// Height of the band the line moves in.
    var height: CGFloat = 140

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state = FilamentState()
    @State private var settling = false

    private var animating: Bool {
        switch mode {
        case .live, .sending: return true
        default: return settling
        }
    }

    var body: some View {
        // 60 fps while it moves; 30 in Low Power Mode. Paused (free) whenever it's still.
        TimelineView(.animation(minimumInterval: ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / 30 : 1.0 / 60, paused: !animating)) { context in
            let now = context.date
            ZStack {
                // The glow: the same shape, wider, blurred by the render server.
                Canvas { ctx, size in
                    draw(&ctx, size: size, now: now, glow: true)
                }
                .blur(radius: 16)
                .blendMode(.plusLighter)
                .opacity(0.95)
                Canvas { ctx, size in
                    step(now: now)
                    draw(&ctx, size: size, now: now, glow: false)
                }
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: mode) { _, _ in settle() }
        .onAppear { settle() }
    }

    /// Keep ticking a little after a mode change so the line eases into its new pose.
    private func settle() {
        settling = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            settling = false
        }
    }

    // MARK: Motion

    private func step(now: Date) {
        let s = state
        let dt = min(max(now.timeIntervalSince(s.lastTime ?? now), 0), 0.05)
        s.lastTime = now
        let raw = mode == .live ? Double(meter.level) : 0
        s.level += (raw - s.level) * min(1, (raw > s.level ? 22 : 2.4) * dt)
        s.tempo += (s.level - s.tempo) * min(1, (s.level > s.tempo ? 6 : 1.1) * dt)

        let targetAmp: Double
        let targetBright: Double
        let targetTint: Double
        let targetDash: Double
        switch mode {
        case .ready: targetAmp = 0; targetBright = 0.62; targetTint = 0; targetDash = 0
        case .live: targetAmp = 0.06 + 0.94 * s.level; targetBright = 0.78 + 0.22 * s.level; targetTint = 0; targetDash = 0
        case .sending: targetAmp = 0.05; targetBright = 0.8; targetTint = 0; targetDash = 0
        case .delivered: targetAmp = 0; targetBright = 0.95; targetTint = 1; targetDash = 0
        case .queued: targetAmp = 0; targetBright = 0.6; targetTint = 1; targetDash = 0
        case .error: targetAmp = 0; targetBright = 0.75; targetTint = 1; targetDash = 1
        }
        let k = min(1, 5 * dt)
        s.amp += ((reduceMotion ? 0 : targetAmp) - s.amp) * (targetAmp > s.amp ? min(1, 14 * dt) : k)
        s.bright += (targetBright - s.bright) * k
        s.tint += (targetTint - s.tint) * min(1, 6 * dt)
        s.dash += (targetDash - s.dash) * min(1, 8 * dt)
        if !reduceMotion {
            s.phase += dt * (0.8 + 5.4 * s.tempo + (mode == .sending ? 1.5 : 0))
            if mode == .sending { s.flow = (s.flow + dt * 0.75).truncatingRemainder(dividingBy: 1.3) } else { s.flow = 0 }
        }
    }

    private var meaning: RGB {
        switch mode {
        case .delivered: return .mint
        case .queued: return .ochre
        case .error: return .rose
        default: return .cyan
        }
    }

    // MARK: Drawing — the Thread (SameerOS's luminous ribbon): a tapered band in the spectrum,
    // a halo, a glow and a white-hot core. At rest it lies in a soft S; a voice swells it.

    private var meaningRGB: RGB { meaning }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, now: Date, glow: Bool) {
        let s = state
        let w = size.width, h = size.height, mid = h / 2
        let n = 120
        let inset = w * 0.04
        let span = w - inset * 2
        // The resting S (always there) plus the voice (only while live).
        let restAmp = Double(h) * 0.16
        let voiceAmp = Double(h) * 0.30
        let half = Double(h) * (0.055 + 0.05 * s.level)

        // The gradient: the Thread's spectrum, or the meaning colour, with the sending bead.
        let stopsCount = 24
        var stops: [Gradient.Stop] = []
        stops.reserveCapacity(stopsCount + 1)
        for i in 0...stopsCount {
            let u = Double(i) / Double(stopsCount)
            var c = RGB.threadAt(u).mix(meaningRGB, s.tint)
            if s.flow > 0 {
                let d = (u - (s.flow - 0.15)) / 0.08
                c = c.mix(.white, 0.75 * exp(-d * d))
            }
            stops.append(.init(color: c.color(s.bright), location: u))
        }
        let shading = GraphicsContext.Shading.linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: inset, y: 0),
                                                             endPoint: CGPoint(x: w - inset, y: 0))

        // The centre line.
        var centre: [CGPoint] = []
        centre.reserveCapacity(n + 1)
        for i in 0...n {
            let u = Double(i) / Double(n)
            let env = pow(sin(.pi * u), 1.25)
            // The rest: one S, rising left to right, flattening as the Thread settles to a meaning.
            let rest = -restAmp * (1 - 0.7 * s.tint) * sin(2 * .pi * (u - 0.5)) * env
            // The voice: slow, smooth swells travelling along it.
            let p = s.phase
            let voice = voiceAmp * s.amp * env * (0.62 * sin(2 * .pi * 1.1 * u + p) + 0.38 * sin(2 * .pi * 2.3 * u - 1.4 * p + 0.8))
            centre.append(CGPoint(x: Double(inset) + Double(span) * u, y: Double(mid) + rest + voice))
        }

        func band(_ k: Double) -> (top: [CGPoint], bottom: [CGPoint]) {
            var top: [CGPoint] = [], bottom: [CGPoint] = []
            top.reserveCapacity(n + 1); bottom.reserveCapacity(n + 1)
            for i in 0...n {
                let a = centre[max(i - 1, 0)], b = centre[min(i + 1, n)]
                let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 0.0001)
                let nx = -dy / len, ny = dx / len
                let u = Double(i) / Double(n)
                let t = half * k * pow(sin(.pi * u), 0.7)
                top.append(CGPoint(x: centre[i].x + nx * t, y: centre[i].y + ny * t))
                bottom.append(CGPoint(x: centre[i].x - nx * t, y: centre[i].y - ny * t))
            }
            return (top, bottom)
        }

        if glow {
            // The halo and the glow: wide, soft (the view blurs this layer).
            let wide = band(2.6)
            fillBand(&ctx, wide, shading: shading, opacity: 0.55 * (0.4 + 0.6 * s.bright))
            return
        }
        let body = band(1)
        if s.dash > 0.02 {
            let run = 8
            var start = 0
            var on = true
            while start < n {
                let end = min(start + run, n)
                let o = on ? 1 : max(0, 1 - s.dash)
                if o > 0.01 { fillBand(&ctx, body, range: start...end, shading: shading, opacity: o) }
                on.toggle()
                start = end
            }
        } else {
            fillBand(&ctx, body, shading: shading, opacity: 1)
            // The white-hot core.
            var core = ctx
            core.blendMode = .plusLighter
            fillBand(&core, band(0.36), shading: .color(.white), opacity: 0.55 * s.bright)
        }
    }

    private func fillBand(_ ctx: inout GraphicsContext, _ b: (top: [CGPoint], bottom: [CGPoint]), range: ClosedRange<Int>? = nil,
                          shading: GraphicsContext.Shading, opacity: Double) {
        let r = range ?? 0...(b.top.count - 1)
        var path = Path()
        path.move(to: b.top[r.lowerBound])
        for i in r.dropFirst() { path.addLine(to: b.top[i]) }
        for i in r.reversed() { path.addLine(to: b.bottom[i]) }
        path.closeSubpath()
        var c = ctx
        c.opacity = opacity
        c.fill(path, with: shading)
    }
}

extension RGB {
    static let coral = RGB(r: 0.914, g: 0.502, b: 0.416)
    /// The Thread's spectrum, cool to warm — violet, cyan, mint, gold, coral (as in SameerOS).
    static let thread: [RGB] = [.violet, .cyan, .mint, .gold, .coral]

    static func threadAt(_ u: Double) -> RGB {
        let x = min(max(u, 0), 1) * Double(thread.count - 1)
        let i = min(Int(x), thread.count - 2)
        return thread[i].mix(thread[i + 1], x - Double(i))
    }
}

/// The ✓ that pops in over the line when a dictation lands.
struct DeliveredCheck: View {
    var visible: Bool
    var color: Color = Light.mint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Ink.ground).frame(width: 34, height: 34)
            Circle().strokeBorder(color.opacity(0.6), lineWidth: 1).frame(width: 34, height: 34)
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color)
        }
        .shadow(color: color.opacity(0.5), radius: 10)
        .scaleEffect(visible ? 1 : (reduceMotion ? 1 : 0.4))
        .opacity(visible ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .interpolatingSpring(stiffness: 260, damping: 14), value: visible)
        .accessibilityHidden(true)
    }
}
