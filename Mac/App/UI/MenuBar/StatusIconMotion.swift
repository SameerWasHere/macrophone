import AppKit
import QuartzCore

/// A moment in a dictation's life the menu bar icon answers (DeliveryEngine says them).
enum StatusIconCue {
    /// It reached this Mac and is on its way in (a countdown, a paste under way).
    case arriving(UUID)
    /// Pasted, sent or copied — where it was meant to go.
    case landed(UUID)
    /// It didn't land where it was meant to (copied instead, or not at all).
    case failed(UUID)
    /// Over without a word (cancelled).
    case settled(UUID)
}

/// The menu bar icon, alive the way the system's own are: a quick pulse with Apple Intelligence's
/// colours when a dictation lands, a shake in red when one fails, a slow breath while one is on
/// its way in, and a fade (the ring settling in) when a phone starts or stops watching.
///
/// Everything is Core Animation on the button's own layer, run by the render server: nothing
/// ticks in the app, and at rest there's no animation, no timer and no extra layer. The icon
/// itself stays the template image AppKit draws (light / dark menu bar, highlighted while the
/// menu is open); the colour is a short-lived layer masked by the same glyph, laid over it and
/// taken away when it has faded. Reduce Motion: only fades — no scale, no shake, no breathing.
@MainActor
final class StatusIconMotion {
    private weak var button: NSStatusBarButton?
    /// Dictations under way (more than one can be).
    private var pending: Set<UUID> = []
    private var breatheWork: DispatchWorkItem?
    private var breatheCap: DispatchWorkItem?
    private var breathing = false
    private var overlay: OverlayView?
    private var overlayWork: DispatchWorkItem?

    /// A delivery quicker than this (the usual case: nobody at the Mac, no countdown) never
    /// breathes — the landing pulse says it all.
    static let breatheAfter: TimeInterval = 0.35
    /// The breath gives up after this, whatever happened (a lost outcome never leaves it going).
    static let breatheLimit: TimeInterval = 30

    init(button: NSStatusBarButton?) {
        self.button = button
        button?.wantsLayer = true
    }

    private var reduceMotion: Bool {
        #if DEBUG
        if Self.debugReduceMotion { return true }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    #if DEBUG
    /// MACROPHONE_MENUBAR_DEMO=…,reduced: as with Reduce Motion on, without touching the setting.
    static var debugReduceMotion = false
    #endif
    private var layer: CALayer? { button?.layer }

    // MARK: Cues

    func cue(_ c: StatusIconCue) {
        switch c {
        case .arriving(let id):
            pending.insert(id)
            scheduleBreath()
        case .landed(let id):
            finish(id)
            landed()
        case .failed(let id):
            finish(id)
            failed()
        case .settled(let id):
            finish(id)
        }
    }

    private func finish(_ id: UUID) {
        pending.remove(id)
        if pending.isEmpty { stopBreathing() }
    }

    // MARK: Arriving — a slow breath

    private func scheduleBreath() {
        guard !breathing, breatheWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.breatheWork = nil
            if !self.pending.isEmpty { self.startBreathing() }
        }
        breatheWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.breatheAfter, execute: w)
    }

    private func startBreathing() {
        guard let layer, !breathing else { return }
        breathing = true
        let a: CABasicAnimation
        if reduceMotion {
            // A held dim, no pulsing.
            a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.5
            a.duration = 0.3
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
        } else {
            a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.42
            a.duration = 0.8
            a.autoreverses = true
            a.repeatCount = .infinity
        }
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "arriving")
        let cap = DispatchWorkItem { [weak self] in
            self?.pending.removeAll()
            self?.stopBreathing()
        }
        breatheCap = cap
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.breatheLimit, execute: cap)
    }

    private func stopBreathing() {
        breatheWork?.cancel(); breatheWork = nil
        breatheCap?.cancel(); breatheCap = nil
        guard breathing, let layer else { breathing = false; return }
        breathing = false
        // From wherever the breath was back to full, never a jump.
        let now = (layer.presentation()?.opacity).map(Double.init) ?? 1
        layer.removeAnimation(forKey: "arriving")
        guard now < 0.99 else { return }
        let back = CABasicAnimation(keyPath: "opacity")
        back.fromValue = now
        back.toValue = 1
        back.duration = 0.18
        back.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(back, forKey: "arrivingEnd")
    }

    // MARK: Landed — a pulse in the Intelligence colours

    private func landed() {
        if !reduceMotion, let layer, let b = button {
            // Up a touch, a small give, and home: half a second, once.
            let a = CAKeyframeAnimation(keyPath: "transform")
            a.values = [1, 1.2, 0.95, 1.0].map { NSValue(caTransform3D: Self.scale($0, about: b.bounds)) }
            a.keyTimes = [0, 0.32, 0.68, 1]
            a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                                 CAMediaTimingFunction(name: .easeOut)]
            a.duration = 0.5
            layer.add(a, forKey: "pulse")
        }
        tint(.intelligence, hold: 0.3)
    }

    // MARK: Failed — a shake in red

    private func failed() {
        if !reduceMotion, let layer {
            let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
            a.values = [0, -3.5, 3.5, -2.5, 2.5, -1, 0]
            a.keyTimes = [0, 0.14, 0.32, 0.5, 0.68, 0.86, 1]
            a.duration = 0.45
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "shake")
        }
        tint(.failure, hold: 0.5)
    }

    // MARK: The icon's own changes — a fade, and the ring settling in

    /// Call just before the image changes. `watching`: true when the ring arrives, false when it
    /// goes, nil for any other change (the dot, the tick).
    func willSwapImage(watching: Bool?) {
        guard let layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = watching == nil ? 0.25 : 0.35
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "swap")
        // The ring settles in like the camera light coming on: from a touch smaller, a hair past.
        if watching == true, !reduceMotion, let b = button {
            let a = CAKeyframeAnimation(keyPath: "transform")
            a.values = [0.82, 1.08, 1.0].map { NSValue(caTransform3D: Self.scale($0, about: b.bounds)) }
            a.keyTimes = [0, 0.55, 1]
            a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            a.duration = 0.45
            layer.add(a, forKey: "ring")
        }
    }

    // MARK: The tint

    private enum Tint { case intelligence, failure }

    /// The glyph in colour for a moment: fades in, holds, fades out, and the layer goes.
    /// Never while the menu is open (the icon sits on the highlight then).
    private func tint(_ kind: Tint, hold: TimeInterval) {
        guard let b = button, !b.isHighlighted, let image = b.image else { return }
        overlayWork?.cancel()
        overlay?.removeFromSuperview()
        let v = OverlayView(frame: b.bounds)
        v.autoresizingMask = [.width, .height]
        b.addSubview(v)
        overlay = v
        guard let root = v.layer else { return }
        let scale = b.window?.backingScaleFactor ?? 2
        // Where the button draws its image: in the middle.
        let size = image.size
        let rect = NSRect(x: ((b.bounds.width - size.width) / 2).rounded(), y: ((b.bounds.height - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
        let mask = CALayer()
        mask.frame = rect
        mask.contents = image.layerContents(forContentsScale: scale)
        mask.contentsScale = scale
        mask.contentsGravity = .resize

        let colour: CALayer
        switch kind {
        case .intelligence:
            let g = CAGradientLayer()
            g.colors = MacOSIntelligence.colours
            g.startPoint = CGPoint(x: 0, y: 0.2)
            g.endPoint = CGPoint(x: 1, y: 0.8)
            colour = g
        case .failure:
            let c = CALayer()
            c.backgroundColor = NSColor.systemRed.cgColor
            colour = c
        }
        colour.frame = rect
        colour.mask = mask
        mask.frame = colour.bounds
        root.addSublayer(colour)

        let total = 0.16 + hold + 0.34
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 1, 1, 0]
        a.keyTimes = [0, NSNumber(value: 0.16 / total), NSNumber(value: (0.16 + hold) / total), 1]
        a.duration = total
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        root.opacity = 0
        root.add(a, forKey: "tint")
        if case .intelligence = kind, !reduceMotion, let g = colour as? CAGradientLayer {
            // The colours drift across the glyph while it shows, as the landing ring's do.
            let drift = CABasicAnimation(keyPath: "startPoint")
            drift.fromValue = CGPoint(x: -0.6, y: 0.2)
            drift.toValue = CGPoint(x: 0.3, y: 0.2)
            let driftEnd = CABasicAnimation(keyPath: "endPoint")
            driftEnd.fromValue = CGPoint(x: 0.4, y: 0.8)
            driftEnd.toValue = CGPoint(x: 1.3, y: 0.8)
            let group = CAAnimationGroup()
            group.animations = [drift, driftEnd]
            group.duration = total
            g.add(group, forKey: "drift")
        }
        let w = DispatchWorkItem { [weak self, weak v] in
            v?.removeFromSuperview()
            if self?.overlay === v { self?.overlay = nil }
        }
        overlayWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.05, execute: w)
    }

    /// A scale about the middle of a layer-backed view (its layer's anchor is the corner).
    private static func scale(_ s: CGFloat, about bounds: NSRect) -> CATransform3D {
        let cx = bounds.midX, cy = bounds.midY
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }

    /// Laid over the button for a tint: draws nothing of its own, takes no clicks.
    private final class OverlayView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var allowsVibrancy: Bool { false }
    }
}
