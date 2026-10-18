import QuartzCore
import SwiftUI
import UIKit

/// The one big button. Tap to start / tap to stop, or press and hold to talk (release stops).
/// The mic opens on touch-down so a hold never misses its first word.
///
/// What it looks like, state by state (the polish pass, Oct 18 2026 — the quality of the Camera
/// shutter and the Voice Memos button; the mechanics are unchanged):
///
/// - **Ready** — an ink glass disc inside the Thread's spectrum ring, the mic glyph in ink.
/// - **Pressed** — the disc sinks (0.93) on the frame the finger lands; the ring brightens.
/// - **Starting / listening / live** — the disc turns ember and one ring of light leaves it as the
///   mic opens; the stop square takes the glyph's place. The light round it follows the voice
///   through `VoiceDriver` (attack fast, release slow — alive, never jittery): a lit rim, a soft
///   bloom and a thin ring that breathes outward with the level. All of it is Core Animation
///   (`MicLightView`), a display link only while the mic is open — nothing re-renders in SwiftUI
///   per frame, and it costs nothing at rest.
/// - **Finishing** — the words settling after the mic closed: the disc is ink again, a teal arc
///   turns in place of the glyph, and a tap waits (the recorder is still active).
/// - **Sending · sent · queued · error** — the ring takes the meaning colour (teal, mint, ochre,
///   rose) and, when a dictation lands, a mint ring arrives into the button — the mirror of the
///   ring that left when the mic opened.
/// - **Microphone off** — dim, `mic.slash`, and disabled until it's turned on in Settings.
///
/// Reduce Motion: no rings leave or arrive, the light holds a calm fixed glow, the arc is still,
/// and every change is a fade. Reduce Transparency: a solid disc. Increase Contrast: a firm ring
/// and a pure-white glyph.
struct MicButton: View {
    var recording: Bool
    /// The mic has closed and the last words are settling; a tap does nothing yet.
    var finishing: Bool = false
    /// The screen's state (the Thread's), for the ring's colour and the landing.
    var mode: FilamentMode = .ready
    /// The mic can't open until a permission is turned on in Settings.
    var disabled: Bool = false
    var meter: LevelMeter
    /// Touch-down. Return value unused; the caller decides start vs. stop.
    var onDown: () -> Void
    /// Touch-up, with how long it was held.
    var onUp: (TimeInterval) -> Void
    var onAccessibilityToggle: () -> Void

    static let holdThreshold: TimeInterval = 0.3
    @State private var pressedAt: Date?
    /// Resets itself if the system cancels the touch (a permission alert, a call banner),
    /// which never reaches onEnded — without it the button would stay "held" forever.
    @GestureState private var touching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotionSetting
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparencySetting
    @Environment(\.colorSchemeContrast) private var contrastSetting
    @Environment(\.isEnabled) private var enabled
    /// Bumped when the mic opens: one ring of light leaves the button.
    @State private var opened = 0
    /// Bumped when a dictation lands: one ring of light arrives.
    @State private var landed = 0
    private let size: CGFloat = 92

    private var reduceMotion: Bool { reduceMotionSetting || Self.debugA11y.contains("motion") }
    private var reduceTransparency: Bool { reduceTransparencySetting || Self.debugA11y.contains("transparency") }
    private var highContrast: Bool { contrastSetting == .increased || Self.debugA11y.contains("contrast") }
    private var pressed: Bool { pressedAt != nil || Self.debugLook == "pressed" || Self.debugLook == "holding" }

    var body: some View {
        ZStack {
            MicLight(live: recording, meter: meter, opened: opened, landed: landed, size: size,
                     reduceMotion: reduceMotion, highContrast: highContrast)
                .frame(width: size * 2.4, height: size * 2.4)
                .allowsHitTesting(false)
            MicFace(recording: recording, disabled: disabled, pressed: pressed, size: size,
                    ringColor: ringColor, ringOpacity: ringOpacity,
                    reduceTransparency: reduceTransparency, highContrast: highContrast)
            glyph
        }
        .frame(width: size * 1.3, height: size * 1.25)
        .scaleEffect(pressed ? 0.93 : 1)
        .animation(Motion.pick(Motion.snap, reduce: reduceMotion), value: pressed)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: recording)
        .animation(.easeInOut(duration: 0.25), value: finishing)
        .animation(.easeInOut(duration: 0.3), value: mode)
        .animation(.easeInOut(duration: 0.25), value: disabled)
        // The whole ring is the target, not only the disc.
        .contentShape(Circle().scale(0.9))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { _ in
                    guard pressedAt == nil, !disabled else { return }
                    pressedAt = Date()
                    onDown()
                }
                .onEnded { _ in
                    guard pressedAt != nil else { return }
                    let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
                    pressedAt = nil
                    onUp(held)
                }
        )
        .onChange(of: touching) { _, now in
            guard !now else { return }
            // Give onEnded the first word; if it never came, the touch was cancelled.
            DispatchQueue.main.async {
                guard pressedAt != nil else { return }
                pressedAt = nil
                onUp(0)   // treated as a tap: a recording it started keeps going
            }
        }
        .onChange(of: recording) { _, now in if now { opened += 1 } }
        .onChange(of: mode) { _, now in if now == .delivered { landed += 1 } }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !disabled { onAccessibilityToggle() } }
        // Microphone off: no touch and no VoiceOver activation until it's turned on in Settings.
        .disabled(disabled)
        .accessibilityShowsLargeContentViewer { Label(accessibilityLabel, systemImage: largeContentSymbol) }
        .accessibilityIdentifier("mic-button")
    }

    // MARK: The glyph

    @ViewBuilder private var glyph: some View {
        let inkColor = highContrast ? Color.white : Ink.ink
        Group {
            if recording {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if finishing {
                FinishingArc(color: Light.teal, reduceMotion: reduceMotion)
                    .frame(width: 34, height: 34)
                    .transition(.opacity)
            } else if disabled {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .transition(.opacity)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(inkColor)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: The ring's meaning colour

    /// The ring: the spectrum at rest and while the mic is open (where it gives way to the light),
    /// else the meaning colour of what just happened.
    private var ringColor: Color? {
        guard !recording, !disabled else { return nil }
        switch mode {
        case .ready, .listening, .live: return nil
        case .sending: return Light.teal
        case .delivered: return Light.mint
        case .queued: return Light.ochre
        case .error: return Light.rose
        }
    }

    private var ringOpacity: Double {
        if recording { return 0 }
        if disabled { return highContrast ? 0.6 : 0.3 }
        if highContrast { return 1 }
        if pressed { return 1 }
        if finishing { return 0.45 }
        return ringColor == nil ? 0.7 : 0.95
    }

    // MARK: Accessibility

    private var accessibilityLabel: String {
        if disabled { return "Microphone off" }
        if recording { return "Stop and send" }
        if finishing { return "Finishing dictation" }
        return "Start dictation"
    }

    private var accessibilityHint: String {
        if disabled { return "Turn the microphone on for Macrophone in Settings to dictate." }
        if recording { return "Stops listening and sends the text to your Mac." }
        if finishing { return "Waits for the last words to settle, then sends." }
        return "Starts listening. Double-tap again to stop and send, or hold while you talk and let go to send."
    }

    private var largeContentSymbol: String {
        if disabled { return "mic.slash.fill" }
        if recording { return "stop.fill" }
        return "mic.fill"
    }

    // MARK: Debug

    /// `MACROPHONE_MIC_LOOK=pressed|holding` holds the pressed look; `MACROPHONE_A11Y=motion,
    /// transparency,contrast` stands in for those settings (the simulator can't flip them live).
    static var debugLook: String? {
        #if DEBUG
        return DebugHooks.env["MACROPHONE_MIC_LOOK"]
        #else
        return nil
        #endif
    }
    static var debugA11y: Set<String> {
        #if DEBUG
        return Set((DebugHooks.env["MACROPHONE_A11Y"] ?? "").split(separator: ",").map(String.init))
        #else
        return []
        #endif
    }
}

/// The button's face. iOS 26+: a disc of Liquid Glass — ink-dark at rest inside the spectrum ring,
/// lit ember while the mic is open — that answers the finger. Below (or with Reduce
/// Transparency): the solid gradient disc. The ring sits 6pt outside the disc: the spectrum at
/// rest, or one meaning colour, with a breath of the same light under it so it reads as light,
/// not a line. Increase Contrast: a firm 2pt ring.
private struct MicFace: View {
    var recording: Bool
    var disabled: Bool
    var pressed: Bool
    var size: CGFloat
    var ringColor: Color?
    var ringOpacity: Double
    var reduceTransparency: Bool
    var highContrast: Bool

    private static let inkTint = Color(red: 0.13, green: 0.14, blue: 0.20)
    private static let spectrum = AngularGradient(colors: [Light.cyan, Light.teal, Light.mint, Light.gold, Light.ember, Light.violet, Light.cyan], center: .center)

    var body: some View {
        face
            .overlay {
                // A specular rim on the disc itself: lit from above, like light on glass.
                if !recording {
                    Circle().strokeBorder(
                        LinearGradient(colors: [Ink.ink.opacity(highContrast ? 0.5 : 0.28), Ink.ink.opacity(0.06), Ink.ink.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
            }
            .overlay { ring }
            .shadow(color: (recording ? Light.ember : Light.cyan).opacity(recording ? 0.35 : 0.14), radius: recording ? 18 : 14, y: recording ? 0 : 4)
            .opacity(disabled ? 0.55 : 1)
            .frame(width: size, height: size)
    }

    @ViewBuilder private var ring: some View {
        let width: CGFloat = highContrast ? 2 : 1.5
        ZStack {
            if let c = ringColor {
                // The meaning colour, with its light under it.
                Circle().strokeBorder(c, lineWidth: width)
                    .shadow(color: c.opacity(0.55), radius: 6)
            } else {
                Circle().strokeBorder(Self.spectrum, lineWidth: width)
                    .shadow(color: Light.cyan.opacity(pressed ? 0.5 : 0.25), radius: 5)
            }
        }
        .padding(-6)
        .opacity(ringOpacity)
    }

    @ViewBuilder private var face: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            Color.clear
                .frame(width: size, height: size)
                .glassEffect(Glass.regular
                    .tint(recording ? Light.ember.opacity(0.9) : Self.inkTint.opacity(pressed ? 0.7 : 0.55))
                    .interactive(), in: Circle())
        } else {
            Circle()
                .fill(recording
                      ? AnyShapeStyle(LinearGradient(colors: [Light.ember, Color(red: 0.80, green: 0.32, blue: 0.24)], startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(LinearGradient(colors: [pressed ? Color(red: 0.18, green: 0.19, blue: 0.26) : Self.inkTint, Ink.raised], startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(recording ? Color.white.opacity(0.25) : (highContrast ? Ink.ink.opacity(0.45) : Ink.lineStrong), lineWidth: 1))
        }
    }
}

/// The arc that turns while the last words settle (a still three-quarter arc under Reduce Motion).
private struct FinishingArc: View {
    var color: Color
    var reduceMotion: Bool
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(turning && !reduceMotion ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
            }
    }
}

// MARK: - The light round the button (Core Animation)

/// The light: a lit rim and a soft bloom that follow the voice, a thin ring that breathes with the
/// level, and the one-shot rings — one leaving as the mic opens, one arriving as a dictation lands.
private struct MicLight: UIViewRepresentable {
    var live: Bool
    var meter: LevelMeter
    var opened: Int
    var landed: Int
    var size: CGFloat
    var reduceMotion: Bool
    var highContrast: Bool

    func makeUIView(context: Context) -> MicLightView {
        let v = MicLightView(meter: meter, disc: size)
        v.reduceMotion = reduceMotion
        v.highContrast = highContrast
        context.coordinator.opened = opened
        context.coordinator.landed = landed
        return v
    }

    func updateUIView(_ v: MicLightView, context: Context) {
        v.reduceMotion = reduceMotion
        v.highContrast = highContrast
        v.set(live: live)
        if context.coordinator.opened != opened {
            context.coordinator.opened = opened
            v.ring(.out, color: RGB.ember)
        }
        if context.coordinator.landed != landed {
            context.coordinator.landed = landed
            v.ring(.in, color: RGB.mint)
        }
    }

    static func dismantleUIView(_ v: MicLightView, coordinator: Coordinator) { v.stopLink() }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var opened = 0; var landed = 0 }
}

/// Holds the display link weakly (a CADisplayLink retains its target).
private final class MicLinkProxy: NSObject {
    weak var owner: MicLightView?
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

final class MicLightView: UIView {
    enum Direction { case out, `in` }

    private let meter: LevelMeter
    private let disc: CGFloat
    var reduceMotion = false
    var highContrast = false

    private let bloom = CAGradientLayer()    // the wide soft light behind the disc
    private let rim = CAGradientLayer()      // the lit edge just outside the disc
    private let level = CAShapeLayer()       // the thin ring that breathes with the voice
    private var driver = VoiceDriver()
    private var live = false
    private var link: CADisplayLink?
    private let proxy = MicLinkProxy()
    private var lastTick: CFTimeInterval = 0
    private var builtSize: CGSize = .zero

    init(meter: LevelMeter, disc: CGFloat) {
        self.meter = meter
        self.disc = disc
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = false
        proxy.owner = self
        let ember = UIColor(red: RGB.ember.r, green: RGB.ember.g, blue: RGB.ember.b, alpha: 1)
        // The light is a lighter ember than the disc, so it reads as light on it, not as a stain.
        let lit = RGB.ember.mix(.white, 0.3)
        let light = UIColor(red: lit.r, green: lit.g, blue: lit.b, alpha: 1)
        for g in [bloom, rim] {
            g.type = .radial
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 1)
            g.opacity = 0
            layer.addSublayer(g)
        }
        // Both gradients run from the centre to their layer's edge. The bloom (2.2 discs across)
        // fades from the disc's edge (0.45 of its radius) outward; the rim (1.5 discs) is a tight
        // band just outside the edge (0.67 of its radius).
        bloom.colors = [ember.withAlphaComponent(0.5).cgColor, ember.withAlphaComponent(0.2).cgColor, ember.withAlphaComponent(0).cgColor]
        bloom.locations = [0.45, 0.6, 1]
        rim.colors = [light.withAlphaComponent(0).cgColor, light.withAlphaComponent(0.7).cgColor, light.withAlphaComponent(0).cgColor]
        rim.locations = [0.64, 0.70, 0.92]
        level.fillColor = nil
        level.strokeColor = light.cgColor
        level.lineWidth = 1.5
        level.opacity = 0
        layer.addSublayer(level)
        for l in [bloom, rim, level] as [CALayer] {
            let none = NSNull()
            l.actions = ["position": none, "bounds": none, "path": none, "opacity": none, "hidden": none,
                         "colors": none, "transform": none, "frame": none]
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit { link?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = window?.screen.scale ?? 3
        layer.contentsScale = scale
        layer.sublayers?.forEach { $0.contentsScale = scale }
        if window == nil { stopLink() } else { updateLink() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != builtSize, bounds.width > 4 else { return }
        builtSize = bounds.size
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The bloom reaches to 2.2 discs across; the rim to 1.5; the level ring sits 6pt outside the disc.
        bloom.bounds = CGRect(x: 0, y: 0, width: disc * 2.2, height: disc * 2.2); bloom.position = c
        rim.bounds = CGRect(x: 0, y: 0, width: disc * 1.5, height: disc * 1.5); rim.position = c
        let r = disc / 2 + 6
        level.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2); level.position = c
        level.path = UIBezierPath(ovalIn: CGRect(x: 0.75, y: 0.75, width: r * 2 - 1.5, height: r * 2 - 1.5)).cgPath
        CATransaction.commit()
        render(now: CACurrentMediaTime())
    }

    // MARK: State

    func set(live now: Bool) {
        guard now != live else { return }
        live = now
        let t = CACurrentMediaTime()
        if now {
            driver = VoiceDriver()
            lastTick = t
            liveSince = t
            for l in [bloom, rim, level] as [CALayer] { l.removeAllAnimations() }
            if reduceMotion {
                // No display link under Reduce Motion: the light fades up once and holds.
                CATransaction.begin()
                for l in [bloom, rim, level] as [CALayer] {
                    let a = CABasicAnimation(keyPath: "opacity")
                    a.fromValue = 0
                    a.duration = 0.25
                    l.add(a, forKey: "fade")
                }
                render(now: t)
                CATransaction.commit()
            } else {
                render(now: t)   // the first frame; the light ramps up over the next 0.25 s
            }
        } else {
            #if DEBUG
            if DebugHooks.env["MACROPHONE_MIC_TIMING"] == "1", !frameCost.isEmpty {
                let s = frameCost.sorted()
                print("[mic] light: \(s.count) frames, main thread per frame median \(Int(s[s.count / 2] * 1e6)) µs, p95 \(Int(s[Int(Double(s.count) * 0.95)] * 1e6)) µs, max \(Int(s.last! * 1e6)) µs")
                frameCost = []
            }
            #endif
            // The mic closed: the light goes out from where it is.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for l in [bloom, rim, level] as [CALayer] {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = l.presentation()?.opacity ?? l.opacity
                a.toValue = 0
                a.duration = 0.35
                l.add(a, forKey: "fade")
                l.opacity = 0
            }
            CATransaction.commit()
        }
        updateLink()
    }

    private var liveSince: CFTimeInterval = 0
    #if DEBUG
    /// `MACROPHONE_MIC_TIMING=1`: each live frame's main-thread cost, printed when the mic closes.
    private var frameCost: [CFTimeInterval] = []
    #endif

    /// One ring of light: out (the mic opening) or in (a dictation landing). A single Core
    /// Animation group; nothing under Reduce Motion.
    func ring(_ direction: Direction, color: RGB) {
        guard !reduceMotion, bounds.width > 4 else { return }
        let r = disc / 2
        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.strokeColor = UIColor(red: color.r, green: color.g, blue: color.b, alpha: 1).cgColor
        ring.lineWidth = direction == .out ? 2 : 1.5
        ring.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.path = UIBezierPath(ovalIn: ring.bounds.insetBy(dx: 1, dy: 1)).cgPath
        ring.contentsScale = layer.contentsScale
        layer.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        let fade = CABasicAnimation(keyPath: "opacity")
        switch direction {
        case .out:
            scale.fromValue = 1; scale.toValue = 1.8
            fade.fromValue = 0.8; fade.toValue = 0
        case .in:
            scale.fromValue = 1.9; scale.toValue = 1.08
            fade.fromValue = 0; fade.toValue = 0.9
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = direction == .out ? 0.7 : 0.55
        group.timingFunction = CAMediaTimingFunction(name: direction == .out ? .easeOut : .easeInEaseOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak ring] in
            guard let ring else { return }
            if direction == .in {
                // Arrived: it rests on the disc's edge for a moment, then goes.
                let out = CABasicAnimation(keyPath: "opacity")
                out.fromValue = 0.9; out.toValue = 0
                out.beginTime = CACurrentMediaTime() + 0.5
                out.duration = 0.6
                out.isRemovedOnCompletion = false
                out.fillMode = .forwards
                CATransaction.begin()
                CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
                ring.add(out, forKey: "out")
                CATransaction.commit()
            } else {
                ring.removeFromSuperlayer()
            }
        }
        ring.add(group, forKey: "ring")
        CATransaction.commit()
    }

    // MARK: Motion

    private func updateLink() {
        guard window != nil, bounds.width > 4, live, !reduceMotion else { stopLink(); return }
        if link == nil {
            let l = CADisplayLink(target: proxy, selector: #selector(MicLinkProxy.tick(_:)))
            let fps: Float = ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 60
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: fps, preferred: fps)
            l.add(to: .main, forMode: .common)
            link = l
            lastTick = CACurrentMediaTime()
        }
    }

    func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ l: CADisplayLink) {
        let t = CACurrentMediaTime()
        render(now: t)
        #if DEBUG
        if DebugHooks.env["MACROPHONE_MIC_TIMING"] == "1" { frameCost.append(CACurrentMediaTime() - t) }
        #endif
    }

    /// One frame: the level in, the light out.
    private func render(now: CFTimeInterval) {
        guard bounds.width > 4 else { return }
        let dt = min(max(now - lastTick, 0), 0.1)
        lastTick = now
        guard live else { return }
        let L: Double
        let up: Double   // the light coming up as the mic opens
        if reduceMotion {
            // A calm fixed glow: the ember says the mic is open; nothing pulses.
            L = 0.3
            up = 1
        } else {
            driver.step(raw: Double(meter.level), dt: dt)
            L = driver.level
            up = min(1, (now - liveSince) / 0.25)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let strong = (highContrast ? 1.2 : 1.0) * up
        bloom.opacity = Float(min(1, (0.45 + 0.55 * L) * strong))
        bloom.transform = CATransform3DMakeScale(CGFloat(1 + 0.22 * L), CGFloat(1 + 0.22 * L), 1)
        rim.opacity = Float(min(1, (0.5 + 0.5 * L) * strong))
        level.opacity = Float(min(1, (0.4 + 0.55 * L + 0.2 * driver.flash) * strong))
        let s = CGFloat(1 + 0.11 * L + 0.03 * driver.flash)
        level.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }
}
