import SwiftUI

// The Filament: a tapered, luminous line in the spectrum gradient that moves with the voice.
//
// Ready     — a calm, dim, still line in the cool end.
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
                .blur(radius: 14)
                .blendMode(.plusLighter)
                .opacity(0.9)
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
        case .ready: targetAmp = 0; targetBright = 0.42; targetTint = 0; targetDash = 0
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

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, now: Date, glow: Bool) {
        let s = state
        let w = size.width, h = size.height, mid = h / 2
        let n = 96
        let maxAmp = Double(h) * 0.40
        let strands: [(phase: Double, amp: Double, alpha: Double, width: Double)] = glow
            ? [(0, 1, 0.55, 5.5)]
            : [(0, 1, 1, 1), (2.1, 0.72, 0.42, 0.55), (4.3, 0.5, 0.28, 0.4)]

        // The gradient, built per frame: spectrum (or the meaning colour) with the bead of light.
        let stopsCount = 24
        var stops: [Gradient.Stop] = []
        stops.reserveCapacity(stopsCount + 1)
        for i in 0...stopsCount {
            let u = Double(i) / Double(stopsCount)
            var c = RGB.spectrumAt(u).mix(meaning, s.tint)
            if mode == .ready && s.tint < 0.01 {
                c = RGB.spectrumAt(u * 0.45).mix(.violet, 0.15)   // the cool end, calm
            }
            if s.flow > 0 {
                let d = (u - (s.flow - 0.15)) / 0.08
                c = c.mix(.white, 0.75 * exp(-d * d))
            }
            stops.append(.init(color: c.color(s.bright), location: u))
        }
        let shading = GraphicsContext.Shading.linearGradient(Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: w, y: 0))

        for strand in strands {
            if s.amp < 0.01 && strand.phase != 0 { continue }   // flat: one line
            var top: [CGPoint] = []
            var bottom: [CGPoint] = []
            top.reserveCapacity(n + 1)
            bottom.reserveCapacity(n + 1)
            for i in 0...n {
                let u = Double(i) / Double(n)
                let env = pow(sin(.pi * u), 1.5)
                let p = s.phase + strand.phase
                let wave = 0.55 * sin(2 * .pi * 1.2 * u + p)
                    + 0.30 * sin(2 * .pi * 2.7 * u - 1.7 * p + 1.0)
                    + 0.15 * sin(2 * .pi * 5.3 * u + 2.3 * p)
                let y = Double(mid) + maxAmp * s.amp * strand.amp * env * wave
                let thick = (0.5 + (1.6 + 3.2 * s.level) * pow(env, 0.8)) * strand.width
                let x = Double(w) * u
                top.append(CGPoint(x: x, y: y - thick))
                bottom.append(CGPoint(x: x, y: y + thick))
            }
            var opacity = strand.alpha
            if glow { opacity *= 0.35 + 0.65 * s.bright }
            if s.dash > 0.02 {
                // Broken: draw every other run of points.
                let run = 6
                var start = 0
                var on = true
                while start < n {
                    let end = min(start + run, n)
                    if on { fill(&ctx, top: top, bottom: bottom, range: start...end, shading: shading, opacity: opacity) }
                    else if s.dash < 0.98 { fill(&ctx, top: top, bottom: bottom, range: start...end, shading: shading, opacity: opacity * (1 - s.dash)) }
                    on.toggle()
                    start = end
                }
            } else {
                fill(&ctx, top: top, bottom: bottom, range: 0...n, shading: shading, opacity: opacity)
            }
            // A bright core along the main strand, the "luminous" part.
            if !glow && strand.phase == 0 && s.dash < 0.5 {
                var core = Path()
                core.move(to: CGPoint(x: (top[0].x), y: (top[0].y + bottom[0].y) / 2))
                for i in 1...n { core.addLine(to: CGPoint(x: top[i].x, y: (top[i].y + bottom[i].y) / 2)) }
                ctx.stroke(core, with: .color(.white.opacity(0.35 * s.bright)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            }
        }
    }

    private func fill(_ ctx: inout GraphicsContext, top: [CGPoint], bottom: [CGPoint], range: ClosedRange<Int>,
                      shading: GraphicsContext.Shading, opacity: Double) {
        var path = Path()
        path.move(to: top[range.lowerBound])
        for i in range.dropFirst() { path.addLine(to: top[i]) }
        for i in range.reversed() { path.addLine(to: bottom[i]) }
        path.closeSubpath()
        var c = ctx
        c.opacity = opacity
        c.fill(path, with: shading)
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
