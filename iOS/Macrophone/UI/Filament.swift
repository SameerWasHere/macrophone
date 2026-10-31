import QuartzCore
import SwiftUI
import UIKit

// The Filament: the Hey Claude Thread (SameerOS-Mac `Voice/VoiceThread.swift` + `Views/ThreadRig.swift`)
// on the iPhone, in Core Animation. Three strands braided into one luminous ribbon — spectrum
// fills through ribbon masks, a soft glow, white-hot cores, and a bloom of light behind it.
//
// Ready      — at rest in a soft S that flows (Oct 18 2026, Sameer: "a subtle wave flow animation
//              … when idle"): the weave drifts along the ribbon, a cycle about every eleven
//              seconds, and the S and its light breathe on a seven-second swell. At 30 fps; still
//              (no display link at all) in Low Power Mode and under Reduce Motion.
// Listening  — the mic is open, no words yet: the cool end of the spectrum, a sweep of light, and
//              the weave already following the voice.
// Live       — words arriving: the full spectrum. The weave's height, the strands' spread and
//              thickness, and the light all follow the level (attack fast, release slow); the phase
//              runs faster while he speaks and calms in pauses; an onset lifts the cores.
// Sending    — the working weave, beads of light flowing along the strands.
// Delivered  — settles flat in mint (the ✓ is the caller's), then flows faintly like Ready.
// Queued     — flat, ochre, dim, flowing faintly.
// Error      — rose, broken into dashes, still.
//
// A CADisplayLink runs only while something moves (live looks, the sending weave, a transition
// settling) at 60 fps — 30 in Low Power Mode. Reduce Motion: a still Thread whose light follows the
// level (15 fps, light only).

enum FilamentMode: Equatable {
    case ready, listening, live, sending, delivered, queued, error

    var isLive: Bool { self == .listening || self == .live }
}

/// The level → motion rules (Hey Claude's `VoiceDriver`), pure.
struct VoiceDriver {
    /// Per second. Attack ~45 ms, release ~0.4 s: it breathes with speech, it doesn't flicker.
    static let attack = 22.0
    static let release = 2.4
    private(set) var level = 0.0
    /// The weave's speed follows a slower copy of the level, so a pause winds it down gently.
    private(set) var tempo = 0.0
    private(set) var phase = 0.0
    /// The voice's weight (a slower level): the strands' thickness.
    private(set) var body = 0.0
    /// An onset (a sudden rise): the cores lift, then decay.
    private(set) var flash = 0.0
    private var slow = 0.0

    /// Radians a second: about eight seconds a cycle at rest, about one while he speaks.
    static func speed(_ tempo: Double) -> Double { 0.8 + 5.4 * tempo }

    mutating func step(raw: Double, dt: Double) {
        let x = min(max(raw, 0), 1)
        level += (x - level) * min(1, (x > level ? Self.attack : Self.release) * dt)
        tempo += (level - tempo) * min(1, (level > tempo ? 6 : 1.1) * dt)
        phase += dt * Self.speed(tempo)
        if phase > 2 * .pi * 1000 { phase -= 2 * .pi * 1000 }
        body += (level - body) * min(1, (level > body ? 9 : 2.5) * dt)
        flash *= exp(-dt * 6)
        if x - slow > 0.28 { flash = min(1, flash + 0.6) }
        slow += (x - slow) * min(1, 1.5 * dt)
    }
}

/// The SwiftUI face: a fixed-height band; the light reaches past it.
struct Filament: View {
    var mode: FilamentMode
    var meter: LevelMeter
    var height: CGFloat = 104

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ThreadRepresentable(mode: mode, meter: meter, reduceMotion: reduceMotion)
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ThreadRepresentable: UIViewRepresentable {
    var mode: FilamentMode
    var meter: LevelMeter
    var reduceMotion: Bool

    func makeUIView(context: Context) -> ThreadView { ThreadView(meter: meter) }
    func updateUIView(_ v: ThreadView, context: Context) {
        v.reduceMotion = reduceMotion
        v.set(mode)
    }
    static func dismantleUIView(_ v: ThreadView, coordinator: ()) { v.stopLink() }
}

/// Holds the display link weakly (a CADisplayLink retains its target).
private final class LinkProxy: NSObject {
    weak var owner: ThreadView?
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

final class ThreadView: UIView {
    private let meter: LevelMeter
    var reduceMotion = false

    // Layers, back to front.
    private let bloom = CAGradientLayer()          // the light behind it, breathing with the voice
    private let container = CALayer()               // everything on the strands, faded at the tips
    private let tipFade = CAGradientLayer()
    private let glowFill = CAGradientLayer()
    private let glowMask = CALayer()
    private var glowStrokes: [CAShapeLayer] = []
    private let bodyFill = CAGradientLayer()
    private let bodyMask = CALayer()
    private var bodies: [CAShapeLayer] = []
    private var cores: [CAShapeLayer] = []
    private let dashes = CAShapeLayer()
    private let sweep = CAGradientLayer()
    private var beads: [CAGradientLayer] = []

    private(set) var mode: FilamentMode = .ready
    private var driver = VoiceDriver()
    private var link: CADisplayLink?
    private let proxy = LinkProxy()
    private var lastTick: CFTimeInterval = 0
    private var modeStart: CFTimeInterval = CACurrentMediaTime()
    /// The pose on screen, and the one a change blends from.
    private var shown: [[CGPoint]] = []
    private var from: [[CGPoint]] = []
    private var blendStart: CFTimeInterval = 0
    private static let blendTime: CFTimeInterval = 0.45
    private static let settleTime: CFTimeInterval = 1.1
    private var builtSize: CGSize = .zero

    init(meter: LevelMeter) {
        self.meter = meter
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = false
        proxy.owner = self
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(motionSettingsChanged),
                                               name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(motionSettingsChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    deinit { link?.invalidate() }

    // MARK: Building

    private func build() {
        bloom.type = .radial
        bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloom.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(bloom)

        layer.addSublayer(container)
        container.mask = tipFade
        tipFade.startPoint = CGPoint(x: 0, y: 0.5); tipFade.endPoint = CGPoint(x: 1, y: 0.5)
        let w = UIColor.white
        tipFade.colors = [w.withAlphaComponent(0).cgColor, w.cgColor, w.cgColor, w.withAlphaComponent(0).cgColor]
        tipFade.locations = [0, 0.13, 0.87, 1]

        // The glow: one spectrum fill through soft strokes. iOS has no layer filters, so each
        // stroke's own shadow is its blur (the mask renders it): a wide halo round the middle
        // strand and a tighter glow round all three.
        for g in [glowFill, bodyFill] { g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5) }
        for alpha in [0.5, 0.6] as [Float] {
            let s = CAShapeLayer()
            s.fillColor = nil
            s.strokeColor = UIColor.black.cgColor
            s.lineCap = .round; s.lineJoin = .round
            s.opacity = alpha
            s.shadowColor = UIColor.black.cgColor
            s.shadowOpacity = 1
            s.shadowOffset = .zero
            glowMask.addSublayer(s)
            glowStrokes.append(s)
        }
        glowFill.mask = glowMask
        container.addSublayer(glowFill)

        // The strands: one spectrum fill through three ribbons (the middle one strongest).
        for i in 0..<3 {
            let s = CAShapeLayer()
            s.fillColor = UIColor.black.cgColor
            s.opacity = i == 1 ? 1 : 0.72
            bodyMask.addSublayer(s)
            bodies.append(s)
        }
        bodyFill.mask = bodyMask
        container.addSublayer(bodyFill)

        // The white-hot cores.
        for _ in 0..<3 {
            let c = CAShapeLayer()
            c.fillColor = UIColor.white.cgColor
            container.addSublayer(c)
            cores.append(c)
        }

        dashes.fillColor = nil
        dashes.lineCap = .round
        dashes.isHidden = true
        container.addSublayer(dashes)

        Self.makeGlow(sweep, .white, strength: 0.55)
        sweep.isHidden = true
        container.addSublayer(sweep)
        for _ in 0..<4 {
            let b = CAGradientLayer()
            Self.makeGlow(b, UIColor(red: 0.85, green: 1, blue: 0.98, alpha: 1), strength: 0.9)
            b.isHidden = true
            container.addSublayer(b)
            beads.append(b)
        }
        noActions(layer)
    }

    private static func makeGlow(_ g: CAGradientLayer, _ color: UIColor, strength: CGFloat) {
        g.type = .radial
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.colors = [color.withAlphaComponent(strength).cgColor, color.withAlphaComponent(strength * 0.3).cgColor,
                    color.withAlphaComponent(0).cgColor]
    }

    /// Nothing here animates implicitly; every change is ours.
    private func noActions(_ l: CALayer) {
        let none = NSNull()
        l.actions = ["position": none, "bounds": none, "path": none, "opacity": none, "hidden": none,
                     "colors": none, "locations": none, "transform": none, "frame": none, "contents": none]
        l.sublayers?.forEach(noActions)
        if let m = l.mask { noActions(m) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = window?.screen.scale ?? 3
        func walk(_ l: CALayer) { l.contentsScale = scale; l.sublayers?.forEach(walk); if let m = l.mask { walk(m) } }
        walk(layer)
        if window == nil { stopLink() } else { updateLink() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != builtSize, bounds.width > 4, bounds.height > 4 else { return }
        builtSize = bounds.size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = bounds
        // The light reaches past the band.
        let reach = CGRect(x: -16, y: -b.height * 0.6, width: b.width + 32, height: b.height * 2.2)
        container.frame = reach
        tipFade.frame = container.bounds
        for l in [glowFill, bodyFill] { l.frame = container.bounds }
        for l in [glowMask, bodyMask, dashes] as [CALayer] { l.frame = container.bounds }
        for l in glowStrokes + bodies + cores { l.frame = container.bounds }
        bloom.frame = CGRect(x: b.width * 0.05, y: -b.height * 0.9, width: b.width * 0.9, height: b.height * 2.8)
        let glowSize = 64 * k
        sweep.bounds = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
        for bd in beads { bd.bounds = CGRect(x: 0, y: 0, width: 26 * k, height: 26 * k) }
        glowStrokes[0].lineWidth = 5 * k
        glowStrokes[0].shadowRadius = 18 * k
        glowStrokes[1].lineWidth = 3 * k
        glowStrokes[1].shadowRadius = 7 * k
        dashes.lineWidth = 1.8 * k
        dashes.lineDashPattern = [NSNumber(value: Double(7 * k)), NSNumber(value: Double(6 * k))]
        CATransaction.commit()
        shown = []
        applyColors(animated: false)
        render(now: CACurrentMediaTime())
        updateLink()
    }

    // MARK: Geometry (ThreadRig's, in the band's own space)

    /// The band inside the container (which reaches past the view for the light).
    private var band: CGRect {
        let c = container.frame
        return CGRect(x: -c.minX + bounds.width * 0.02, y: -c.minY, width: bounds.width * 0.96, height: bounds.height)
    }
    private var amp: Double { Double(bounds.height) * 0.5 }
    /// Thickness: 1.2 at 104 pt.
    private var k: CGFloat { min(1.45, max(0.8, bounds.height / 88)) }
    private static let samples = 96
    private static let phases: [Double] = [0, 2.1, 4.2]

    private func env(_ u: Double) -> Double { pow(sin(.pi * u), 1.25) }

    /// One strand's centre line for a look at `t` seconds into it.
    private func line(_ s: Int, look: FilamentMode, t: Double) -> [CGPoint] {
        let n = Self.samples
        let phi = Self.phases[s]
        let spread = Double(s - 1)
        let r = band
        let w = Double(r.width)
        let f = min(1.4, max(1, w / 360))
        let A = amp
        let v = driver
        let still = reduceMotion
        return (0...n).map { i in
            let u = Double(i) / Double(n)
            let e = env(u)
            let rest = -A * 0.36 * sin(2 * .pi * (u - 0.5)) * e
            var y: Double
            switch look {
            case .listening, .live:
                if still {
                    y = rest + A * 0.1 * e * sin(2 * .pi * 1.5 * f * u + phi)
                } else {
                    // His voice: the energy sits in the middle (a bell under the taper), the weave
                    // rises with the level and travels with the phase; a standing bulge breathes the
                    // braid apart when he is loud.
                    let a = v.level
                    let bell = exp(-pow((u - 0.5) / 0.26, 2))
                    let shape = e * (0.25 + 0.75 * bell)
                    // The peaks travel left to right, faster and taller with his voice (Oct 30
                    // 2026, Sameer: "moves like a wave with the peaks flowing from left to right").
                    let weave = A * (0.22 + 0.55 * a) * (1 + 0.12 * spread) * shape * sin(2 * .pi * 1.4 * f * u - (v.phase + Self.waveSpeed * t) + phi)
                    let stand = A * 0.14 * a * shape * sin(3 * .pi * u) * cos(0.45 * v.phase + phi * 0.5)
                    y = rest * (0.3 - 0.15 * a) + weave + stand
                }
            case .sending:
                let tt = still ? 0 : t
                let stand = A * 0.1 * e * sin(3 * .pi * u) * cos(2 * .pi * tt / 3.4)
                let weave = A * (0.3 + 0.05 * spread) * e * sin(2 * .pi * 1.8 * f * u - 2 * Self.waveSpeed * tt + phi)
                y = rest * 0.3 + stand + weave
            case .delivered, .queued:
                let q = still ? 1 : min(max(t / Self.settleTime, 0), 1)
                let settle = 1 - pow(1 - q, 3)
                let tt = still ? 0 : t
                let lively = rest * 0.5 + A * 0.12 * e * sin(2 * .pi * 1.5 * f * u + phi)
                y = lively * (1 - settle) + restingWave(u: u, e: e, phi: phi, f: f, A: A, rest: rest, t: tt) * settle
            case .error:
                y = rest * 0.35
            case .ready:
                // The idle flow: the weave travels along the ribbon and the S breathes.
                y = restingWave(u: u, e: e, phi: phi, f: f, A: A, rest: rest, t: still ? 0 : t)
            }
            return CGPoint(x: Double(r.minX) + u * w, y: Double(r.midY) + y)
        }
    }

    /// At rest: a gentle S with a wave rolling through it, left to right, one crest about every
    /// two and a half seconds; each strand a touch out of step, so the braid ripples.
    private func restingWave(u: Double, e: Double, phi: Double, f: Double, A: Double, rest: Double, t: Double) -> Double {
        let swell = 1 + 0.1 * sin(2 * .pi * t / Self.breath + phi * 0.4)
        let crest = A * 0.26 * e * sin(2 * .pi * 1.25 * f * u - Self.waveSpeed * t + phi * 0.6)
        return rest * 0.45 * swell + crest * swell
    }

    private func ribbon(_ pts: [CGPoint], half: CGFloat) -> CGPath {
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        top.reserveCapacity(pts.count); bottom.reserveCapacity(pts.count)
        for i in pts.indices {
            let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 0.0001)
            let nx = -dy / len, ny = dx / len
            let u = Double(i) / Double(pts.count - 1)
            let hw = half * CGFloat(pow(sin(.pi * u), 0.65))
            top.append(CGPoint(x: pts[i].x + nx * hw, y: pts[i].y + ny * hw))
            bottom.append(CGPoint(x: pts[i].x - nx * hw, y: pts[i].y - ny * hw))
        }
        let path = CGMutablePath()
        path.addLines(between: top)
        path.addLines(between: bottom.reversed())
        path.closeSubpath()
        return path
    }

    private func point(at u: Double, on l: [CGPoint]) -> CGPoint {
        l[min(l.count - 1, max(0, Int((u * Double(l.count - 1)).rounded())))]
    }

    // MARK: Looks

    func set(_ m: FilamentMode) {
        guard m != mode else { return }
        let was = mode
        mode = m
        let now = CACurrentMediaTime()
        modeStart = now
        // Live to live keeps its pose (the voice continues); anything else blends from where it is.
        if !(was.isLive && m.isLive) {
            from = shown
            blendStart = now
        }
        if m.isLive && !was.isLive { driver = VoiceDriver() }
        applyColors(animated: true)
        render(now: now)
        updateLink()
    }

    private static let spectrum: [UIColor] = RGB.thread.map { UIColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) }

    private func stops() -> [(UIColor, Double)] {
        let s = Self.spectrum   // violet, cyan, mint, gold, coral
        func c(_ r: RGB) -> UIColor { UIColor(red: r.r, green: r.g, blue: r.b, alpha: 1) }
        switch mode {
        case .ready, .listening: return [(s[0], 0), (s[1], 0.5), (s[2], 1)]
        case .live: return s.enumerated().map { ($1, Double($0) / Double(s.count - 1)) }
        case .sending: return [(s[1], 0), (s[2], 0.35), (c(.teal), 0.65), (s[1], 1)]
        case .delivered:
            let m = c(.mint)
            return [(m.withAlphaComponent(0.75), 0), (m, 0.3), (UIColor(red: 0.85, green: 1, blue: 0.93, alpha: 1), 0.5), (m, 0.7), (m.withAlphaComponent(0.75), 1)]
        case .queued: return [(c(.ochre), 0), (c(.ochre), 1)]
        case .error: return [(c(.rose), 0), (c(.rose), 1)]
        }
    }

    private func bloomColor() -> UIColor {
        func c(_ r: RGB, _ a: CGFloat) -> UIColor { UIColor(red: r.r, green: r.g, blue: r.b, alpha: a) }
        switch mode {
        case .ready: return c(.cyan, 0.10)
        case .listening: return c(.cyan, 0.16)
        case .live: return c(.ember, 0.20)
        case .sending: return c(.teal, 0.16)
        case .delivered: return c(.mint, 0.20)
        case .queued: return c(.ochre, 0.12)
        case .error: return c(.rose, 0.14)
        }
    }

    private func applyColors(animated: Bool) {
        let st = stops()
        let c = container.bounds
        guard c.width > 0 else { return }
        let r = band
        let lo = Double(r.minX / c.width), hi = Double(r.maxX / c.width)
        CATransaction.begin()
        if animated && !reduceMotion {
            CATransaction.setAnimationDuration(0.35)
        } else {
            CATransaction.setDisableActions(true)
        }
        for g in [glowFill, bodyFill] {
            let colors = st.map { $0.0.cgColor }
            let locs = st.map { NSNumber(value: lo + $0.1 * (hi - lo)) }
            if animated {
                let a = CABasicAnimation(keyPath: "colors"); a.fromValue = g.presentation()?.colors ?? g.colors; a.toValue = colors
                a.duration = reduceMotion ? 0.2 : 0.35
                g.add(a, forKey: "colors")
            }
            g.colors = colors
            g.locations = locs
        }
        let bc = bloomColor()
        let bcolors = [bc.cgColor, bc.withAlphaComponent(bc.cgColor.alpha * 0.35).cgColor, bc.withAlphaComponent(0).cgColor]
        if animated {
            let a = CABasicAnimation(keyPath: "colors"); a.fromValue = bloom.presentation()?.colors ?? bloom.colors; a.toValue = bcolors
            a.duration = 0.5
            bloom.add(a, forKey: "colors")
        }
        bloom.colors = bcolors
        bloom.locations = [0, 0.45, 1]
        let rose = UIColor(red: RGB.rose.r, green: RGB.rose.g, blue: RGB.rose.b, alpha: 0.9)
        dashes.strokeColor = rose.cgColor
        CATransaction.commit()
    }

    // MARK: Motion

    /// The idle flow: radians a second the weave travels (a cycle about every eleven seconds), and
    /// the seconds of one breath of the S and its light.
    static let flowSpeed = 0.55
    /// How fast the crests roll left to right (radians a second: one about every 2.5 s at rest).
    static let waveSpeed = 2.5
    static let breath = 7.0

    /// At rest, flowing: Ready, and Delivered or Queued once settled — not in Low Power Mode or
    /// under Reduce Motion, where it holds still and costs nothing.
    private var idleFlow: Bool {
        (mode == .ready || mode == .delivered || mode == .queued) && !reduceMotion
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Whether anything is moving: the display link runs only then.
    private var moving: Bool {
        let now = CACurrentMediaTime()
        if mode.isLive || mode == .sending || idleFlow { return true }
        if now - blendStart < Self.blendTime + 0.05 { return true }
        if (mode == .delivered || mode == .queued) && now - modeStart < Self.settleTime + 0.05 && !reduceMotion { return true }
        return false
    }

    private func updateLink() {
        guard window != nil, bounds.width > 4 else { stopLink(); return }
        if moving {
            let fps = wantedFPS
            if link == nil {
                let l = CADisplayLink(target: proxy, selector: #selector(LinkProxy.tick(_:)))
                l.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 30), maximum: fps, preferred: fps)
                l.add(to: .main, forMode: .common)
                link = l
                lastTick = CACurrentMediaTime()
            } else {
                link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 30), maximum: fps, preferred: fps)
            }
        } else {
            stopLink()
        }
    }

    /// Sixty while it follows a voice or settles; thirty for the slow idle flow (smooth at half the cost).
    private var wantedFPS: Float {
        let now = CACurrentMediaTime()
        let busy = mode.isLive || mode == .sending || now - blendStart < Self.blendTime + 0.05
            || ((mode == .delivered || mode == .queued) && now - modeStart < Self.settleTime + 0.05)
        return reduceMotion ? 15 : (ProcessInfo.processInfo.isLowPowerModeEnabled || !busy ? 30 : 60)
    }

    /// Low Power Mode or Reduce Motion turned off while it held still: the flow starts again.
    @objc private func motionSettingsChanged() { DispatchQueue.main.async { [weak self] in self?.updateLink() } }

    func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        render(now: now)
        if !moving { stopLink(); return }
        // A send settling into the idle flow drops to its slower pace.
        let fps = wantedFPS
        if l.preferredFrameRateRange.preferred != fps {
            l.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 30), maximum: fps, preferred: fps)
        }
    }

    /// One frame: the level in, the pose and the light out.
    private func render(now: CFTimeInterval) {
        guard bounds.width > 4 else { return }
        let dt = min(max(now - lastTick, 0), 0.1)
        lastTick = now
        if mode.isLive { driver.step(raw: Double(meter.level), dt: dt) }
        let t = now - modeStart

        var lines = (0..<3).map { line($0, look: mode, t: t) }
        // A change of look glides from the pose on screen.
        let bq = (now - blendStart) / Self.blendTime
        if bq < 1, from.count == 3, from[0].count == lines[0].count, !reduceMotion {
            let e = bq * bq * (3 - 2 * bq)
            for s in 0..<3 {
                for i in lines[s].indices {
                    let a = from[s][i], b = lines[s][i]
                    lines[s][i] = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
                }
            }
        }
        shown = lines

        let L = mode.isLive ? driver.level : 0
        let weight: CGFloat = mode.isLive && !reduceMotion ? CGFloat(0.88 + 0.55 * driver.body + 0.2 * driver.level) : 1
        let kk = k

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let broken = mode == .error
        for (i, l) in lines.enumerated() {
            bodies[i].path = ribbon(l, half: (i == 1 ? 2.9 : 1.5) * kk * weight)
            cores[i].path = ribbon(l, half: (i == 1 ? 0.62 : 0.3) * kk * weight)
        }
        let spines = CGMutablePath()
        for l in lines { spines.addLines(between: l) }
        let mid = lines[1]
        let midSpine = CGMutablePath()
        midSpine.addLines(between: Array(mid[(mid.count / 10)...(mid.count * 9 / 10)]))
        glowStrokes[0].path = midSpine
        glowStrokes[1].path = spines

        bodyFill.isHidden = broken
        cores.forEach { $0.isHidden = broken }
        dashes.isHidden = !broken
        if broken {
            let p = CGMutablePath(); p.addLines(between: mid); dashes.path = p
        }

        // The light follows the level: bloom, glow, strands and cores brighten as he speaks.
        switch mode {
        case .listening, .live:
            container.opacity = mode == .listening ? 0.86 : 0.97
            glowFill.opacity = Float(0.5 + 0.5 * L)
            bodyFill.opacity = Float(0.66 + 0.34 * L)
            for c in cores { c.opacity = Float(min(1, 0.3 + 0.5 * L + 0.3 * driver.flash)) }
            bloom.opacity = Float(0.45 + 0.55 * L)
            bloom.transform = CATransform3DMakeScale(1, CGFloat(0.85 + 0.3 * L), 1)
        case .ready:
            // The light breathes with the S.
            let b = reduceMotion ? 0 : sin(2 * .pi * t / Self.breath)
            container.opacity = 0.9
            glowFill.opacity = Float(0.5 + 0.06 * b)
            bodyFill.opacity = 0.82
            for c in cores { c.opacity = Float(0.42 + 0.06 * b) }
            bloom.opacity = Float(0.6 + 0.07 * b)
            bloom.transform = CATransform3DMakeScale(1, CGFloat(1 + 0.04 * b), 1)
        case .sending:
            container.opacity = 0.95
            glowFill.opacity = 0.6
            bodyFill.opacity = 0.8
            for c in cores { c.opacity = 0.55 }
            bloom.opacity = 0.8
            bloom.transform = CATransform3DIdentity
        case .delivered:
            container.opacity = 1
            glowFill.opacity = 0.7
            bodyFill.opacity = 0.9
            for c in cores { c.opacity = 0.6 }
            bloom.opacity = 1
            bloom.transform = CATransform3DIdentity
        case .queued:
            container.opacity = 0.62
            glowFill.opacity = 0.35
            bodyFill.opacity = 0.8
            for c in cores { c.opacity = 0.2 }
            bloom.opacity = 0.7
            bloom.transform = CATransform3DIdentity
        case .error:
            container.opacity = 0.9
            glowFill.opacity = 0.22
            bloom.opacity = 0.8
            bloom.transform = CATransform3DIdentity
        }

        // The listening sweep: a pass of light along the strand every 3.4 s.
        let sweeping = mode == .listening && !reduceMotion
        sweep.isHidden = !sweeping
        if sweeping {
            let p = t.truncatingRemainder(dividingBy: 3.4)
            let q = min(p / 2.4, 1)
            let u = min(max(-0.1 + 1.2 * (q * q * (3 - 2 * q)), 0), 1)
            sweep.position = point(at: u, on: mid)
            sweep.opacity = Float(p < 2.4 ? (1 - 0.6 * L) * sin(.pi * u) : 0)
        }

        // Sending: beads of light flowing along the strands, left to right.
        let flowing = mode == .sending && !reduceMotion
        for (i, b) in beads.enumerated() {
            b.isHidden = !flowing
            guard flowing else { continue }
            let s = i % 3
            let u = (t / 1.4 + Double(i) * 0.27).truncatingRemainder(dividingBy: 1)
            b.position = point(at: u, on: lines[s])
            b.opacity = Float(sin(.pi * u))
        }
        CATransaction.commit()
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
